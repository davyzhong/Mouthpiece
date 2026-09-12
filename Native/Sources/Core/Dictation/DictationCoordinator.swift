import Foundation
import Carbon

// Test seam: the local transcription edge runs out-of-process (whisper /
// parakeet / qwen servers), which unit tests cannot launch. These are the only
// three calls the coordinator makes on it; LocalModelRuntime is the production
// conformance and stays the default.
protocol LocalTranscriptionRuntime: Sendable {
    func status(provider: LocalTranscriptionProvider, model: String) async -> LocalModelStatus
    func transcribe(pcm16: Data, settings: AppSettings, prompt: String?) async throws -> String
    func stopAll() async
}

extension LocalModelRuntime: LocalTranscriptionRuntime {}

actor DictationCoordinator {
    private let audio: AudioCaptureService
    private let history: HistoryRepository
    // P1-15: widened from `KeychainStore` to the CredentialStore protocol so
    // tests can inject an in-memory store and skip the SecurityAgent prompt
    // that otherwise makes DictationCoordinatorTests XCTSkip on CI / locked
    // screens. The production wire-up in AppEnvironment still passes the
    // KeychainStore singleton, so behavior is unchanged.
    private let keychain: any CredentialStore
    private let logger: DebugLogStore
    private let insertion: TextInsertionService
    private let capsule: CapsuleController
    private let batchClient: BatchTranscriptionClient
    private let bailianProvider: BailianRealtimeProvider
    private let deepgramProvider: DeepgramRealtimeProvider
    private let sonioxProvider: SonioxRealtimeProvider
    private let assemblyAIProvider: AssemblyAIRealtimeProvider
    private let volcengineProvider: VolcengineRealtimeProvider
    private let localRuntime: any LocalTranscriptionRuntime
    private let reasoning: ReasoningService
    private let mediaPlayback = MediaPlaybackController()
    // Test seam: swaps the selected realtime provider for a scripted stub in
    // unit tests; nil (the default) keeps the production provider wiring.
    private let realtimeProviderOverride: (any RealtimeTranscriptionProvider)?
    private let onSnapshot: @MainActor @Sendable (DictationSnapshot) -> Void
    private let onTranscriptionSaved: (@MainActor @Sendable (TranscriptionRecord, TextInsertionTarget?, CorrectionTextSnapshot?) -> Void)?

    private var machine = DictationStateMachine()
    private var target: TextInsertionTarget?
    private var pcm = Data()
    private var provider: (any RealtimeTranscriptionProvider)?
    private var providerSessionID: UUID?
    private var activeSettings = AppSettings()
    // P2-10: the session's single sensitive-app decision, taken from the target
    // captured at start() and read by every transcript sink (insertion,
    // history, debug log, cloud reasoning) so they cannot drift apart.
    private var sensitivity = SensitivityGate.inactive
    private var speechGate = SpeechActivityGate()
    private var maximumDurationTask: Task<Void, Never>?
    private var preparingWatchdogTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<(Data, Double)>.Continuation?
    // P2-1: single-consumer AsyncStream drains provider events in emit
    // order. Pre-fix, one unstructured `Task { await handle(event) }` per
    // callback let a late `.partial` overwrite a `.final`. `testEventHandleDelay`
    // is the DEBUG-only seam for `testProviderEventsProcessInOrder`; nil
    // (default) means the delay hook is inert in production.
    private var providerEventTask: Task<Void, Never>?
    private var providerEventContinuation: AsyncStream<RealtimeTranscriptionEvent>.Continuation?
    private var testEventHandleDelay: (@Sendable (RealtimeTranscriptionEvent) -> Duration?)?
    private var reasoningTask: Task<String, Error>?
    private var mediaPauseTask: Task<Void, Never>?

    init(
        audio: AudioCaptureService,
        history: HistoryRepository,
        keychain: any CredentialStore,
        logger: DebugLogStore,
        insertion: TextInsertionService,
        capsule: CapsuleController,
        batchClient: BatchTranscriptionClient = BatchTranscriptionClient(),
        bailianProvider: BailianRealtimeProvider = BailianRealtimeProvider(),
        deepgramProvider: DeepgramRealtimeProvider = DeepgramRealtimeProvider(),
        sonioxProvider: SonioxRealtimeProvider = SonioxRealtimeProvider(),
        assemblyAIProvider: AssemblyAIRealtimeProvider = AssemblyAIRealtimeProvider(),
        volcengineProvider: VolcengineRealtimeProvider = VolcengineRealtimeProvider(),
        localRuntime: any LocalTranscriptionRuntime = LocalModelRuntime(),
        reasoningService: ReasoningService? = nil,
        realtimeProviderOverride: (any RealtimeTranscriptionProvider)? = nil,
        onTranscriptionSaved: (@MainActor @Sendable (TranscriptionRecord, TextInsertionTarget?, CorrectionTextSnapshot?) -> Void)? = nil,
        onSnapshot: @escaping @MainActor @Sendable (DictationSnapshot) -> Void
    ) {
        self.audio = audio
        self.history = history
        self.keychain = keychain
        self.logger = logger
        self.insertion = insertion
        self.capsule = capsule
        self.batchClient = batchClient
        self.bailianProvider = bailianProvider
        self.deepgramProvider = deepgramProvider
        self.sonioxProvider = sonioxProvider
        self.assemblyAIProvider = assemblyAIProvider
        self.volcengineProvider = volcengineProvider
        self.localRuntime = localRuntime
        self.reasoning = reasoningService ?? ReasoningService(keychain: keychain)
        self.realtimeProviderOverride = realtimeProviderOverride
        self.onSnapshot = onSnapshot
        self.onTranscriptionSaved = onTranscriptionSaved
    }

    func warmup(settings: AppSettings) async {
        guard settings.cloudTranscriptionProvider == "bailian",
              let key = try? await keychain.read(.bailian),
              !key.isEmpty else { return }
        let configuration = realtimeConfiguration(settings: settings, apiKey: key)
        do {
            try await bailianProvider.warmup(configuration: configuration)
            await logger.write(
                .debug,
                "Bailian realtime connection warmed",
                metadata: bailianMetadata(configuration)
            )
        } catch {
            var metadata = bailianMetadata(configuration)
            metadata["error"] = error.localizedDescription
            await logger.write(.warning, "Bailian warmup failed", metadata: metadata)
        }
    }

    func shutdown() async {
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        preparingWatchdogTask?.cancel()
        preparingWatchdogTask = nil
        frameTask?.cancel()
        frameTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
        terminateProviderEventStream()
        reasoningTask?.cancel()
        reasoningTask = nil
        await audio.stop()
        await resumePausedMedia()
        await bailianProvider.cancel()
        await deepgramProvider.cancel()
        await sonioxProvider.cancel()
        await assemblyAIProvider.cancel()
        await volcengineProvider.cancel()
        await localRuntime.stopAll()
        provider = nil
        providerSessionID = nil
        target = nil
        sensitivity = .inactive
        pcm.removeAll(keepingCapacity: false)
        machine.reset()
        await publish()
        await capsule.hide()
    }

    func start(settings: AppSettings) async {
        guard !machine.snapshot.phase.isActive else { return }
        let sessionID = UUID()
        do {
            try machine.begin(sessionID: sessionID, isTranslation: settings.translationEnabled)
            armPreparingWatchdog(for: sessionID)
            activeSettings = settings
            speechGate = SpeechActivityGate()
            if settings.pauseOtherMediaDuringDictation {
                // The MediaRemote perl adapter can take seconds in the worst
                // case; pause in parallel so it never delays audio start-up.
                let mediaPlayback = mediaPlayback
                let logger = logger
                mediaPauseTask = Task {
                    let paused = await mediaPlayback.pauseIfPlaying()
                    if !paused {
                        await logger.write(
                            .debug,
                            "No active media session was paused",
                            sessionID: sessionID
                        )
                    }
                }
            }
            await capsule.setLanguage(settings.uiLanguage)
            pcm.removeAll(keepingCapacity: true)
            target = await insertion.captureTarget()
            sensitivity = SensitivityGate(target: target, settings: settings)
            await capsule.setTarget(
                processIdentifier: target?.processIdentifier,
                applicationName: target?.applicationName
            )
            await publish(show: true)
            // P2-10: the log sink records that the gate closed, never any
            // transcript text — that is the whole point of gating it here.
            var startMetadata: [String: String] = settings.translationEnabled ? ["translation": "true"] : [:]
            if sensitivity.isProtectedSession { startMetadata["sensitiveApp"] = "true" }
            await logger.write(
                .info,
                "Dictation session started",
                metadata: startMetadata,
                sessionID: sessionID
            )
            await Self.logPreparingStep("audioPermission.begin", logger: logger, sessionID: sessionID)
            guard await audio.requestPermission() else { throw AudioCaptureError.permissionDenied }
            await Self.logPreparingStep("audioPermission.end", logger: logger, sessionID: sessionID)
            guard isCurrent(sessionID, phase: .preparing) else { return }
            // One consumer task per session instead of one unstructured Task
            // per 20ms frame (50/s, ~90k per half-hour session). The stream
            // finishes when audio tear-down releases the onFrame closure.
            let (frames, frameContinuation) = AsyncStream<(Data, Double)>.makeStream(
                bufferingPolicy: .unbounded
            )
            frameTask?.cancel()
            self.frameContinuation?.finish()
            self.frameContinuation = frameContinuation
            frameTask = Task { [weak self] in
                for await (frame, rms) in frames {
                    await self?.consume(frame: frame, rms: rms, sessionID: sessionID)
                }
            }
            await Self.logPreparingStep("audioStart.begin", logger: logger, sessionID: sessionID)
            try await audio.start(
                selectedDeviceUID: settings.selectedMicrophoneUID,
                onFrame: { frame, rms in frameContinuation.yield((frame, rms)) },
                onLevel: nil,
                onSessionInterrupted: { [weak self] in
                    Task { await self?.handleAudioSessionInterruption(sessionID: sessionID) }
                },
                onDiagnostics: { [weak self] droppedFrames in
                    Task { await self?.reportDroppedFrames(droppedFrames, sessionID: sessionID) }
                }
            )
            await Self.logPreparingStep("audioStart.end", logger: logger, sessionID: sessionID)
            guard isCurrent(sessionID, phase: .preparing) else {
                await audio.stop()
                return
            }

            if !settings.useLocalTranscription, let realtime = realtimeProvider(for: settings) {
                await Self.logPreparingStep("apiKeyRead.begin", logger: logger, sessionID: sessionID)
                guard let key = try await keychain.read(realtime.account), !key.isEmpty else {
                    throw BailianRealtimeError.missingAPIKey
                }
                await Self.logPreparingStep("apiKeyRead.end", logger: logger, sessionID: sessionID)
                guard isCurrent(sessionID, phase: .preparing) else { return }
                provider = realtime.provider
                providerSessionID = sessionID
                let configuration = realtimeConfiguration(
                    settings: settings,
                    apiKey: key,
                    defaultModel: realtime.defaultModel
                )
                // P2-1: one consumer task per session drains provider events
                // sequentially in emit order. Pre-fix, each event spawned its
                // own unstructured `Task { await handle(event) }`, so a late
                // `.partial` could overwrite a `.final` on `partialText`.
                let yieldEvent = armProviderEventStream(sessionID: sessionID)
                await Self.logPreparingStep("realtimeConnect.begin", logger: logger, sessionID: sessionID)
                do {
                    try await realtime.provider.connect(
                        configuration: configuration,
                        onEvent: yieldEvent
                    )
                    if settings.cloudTranscriptionProvider == "bailian" {
                        await logger.write(
                            .debug,
                            "Bailian realtime task started",
                            metadata: bailianMetadata(configuration),
                            sessionID: sessionID
                        )
                    }
                    guard isCurrent(sessionID, phase: .preparing) else {
                        await realtime.provider.cancel()
                        return
                    }
                } catch {
                    await realtime.provider.cancel()
                    guard isCurrent(sessionID, phase: .preparing) else { return }
                    if !providerHasBatchEndpoint(settings.cloudTranscriptionProvider) {
                        throw error
                    }
                    await logger.write(
                        .warning,
                        "Realtime connection failed; retaining audio for batch fallback",
                        metadata: ["error": error.localizedDescription],
                        sessionID: sessionID
                    )
                    provider = nil
                    providerSessionID = nil
                }
            }
            try machine.transition(to: .recording, sessionID: sessionID)
            preparingWatchdogTask?.cancel()
            preparingWatchdogTask = nil
            armMaximumDuration(for: sessionID)
            await logger.write(.debug, "Dictation phase changed", metadata: ["phase": "recording"], sessionID: sessionID)
            await publish()
        } catch {
            if machine.snapshot.sessionID == sessionID, machine.snapshot.phase.isActive {
                await fail(error, sessionID: sessionID)
            }
        }
    }

    func stop() async {
        guard let sessionID = machine.snapshot.sessionID,
              machine.snapshot.phase == .recording || machine.snapshot.phase == .preparing else { return }
        // A fast double-toggle stops before any audio arrives; surfacing
        // noAudioFrames for 2.4s would punish the user for changing their mind.
        if machine.snapshot.phase == .preparing, pcm.isEmpty {
            await cancel()
            return
        }
        do {
            maximumDurationTask?.cancel()
            maximumDurationTask = nil
            preparingWatchdogTask?.cancel()
            preparingWatchdogTask = nil
            try machine.transition(to: .stopping, sessionID: sessionID)
            await publish()
            await audio.stop()
            // audio.stop() drained the converter (emitRemainder included), so
            // every tail frame has been yielded by now. Finish the stream and
            // wait for the consumer to append/send them before snapshotting
            // the PCM; frames landing after the snapshot used to be lost.
            frameContinuation?.finish()
            frameContinuation = nil
            // P2-1: drain every already-yielded provider event through the
            // single consumer before we snapshot partialText for the fallback.
            providerEventContinuation?.finish()
            providerEventContinuation = nil
            // P2-2: bound both drains with a shared watchdog so a hung audio
            // engine (never releasing the frame continuation) or a dead
            // provider socket (whose event stream never finishes) can't wedge
            // the session in .stopping forever. On timeout we cancel the
            // consumers (safe: AsyncStream `for await` exits on cancellation)
            // and let finalize proceed with whatever PCM/partial text is
            // available — losing an in-flight tail beats losing the whole
            // recording, which is what unbounded drains cost the user pre-fix.
            await runBoundedStopDrain(sessionID: sessionID)
            await resumePausedMedia()
            guard isCurrent(sessionID, phase: .stopping) else { return }
            try machine.transition(to: .finalizing, sessionID: sessionID)
            await publish()

            let recordedPCM = speechGate.trimmed(pcm)
            let capturedByteCount = pcm.count
            // Free the raw capture buffer now (about 2 MB per recorded minute);
            // keeping it alive alongside the trimmed copy and the WAV payload
            // tripled peak memory on long sessions.
            pcm.removeAll(keepingCapacity: false)
            await logger.write(
                .debug,
                "Audio capture completed",
                metadata: [
                    "bytes": String(capturedByteCount),
                    "durationMilliseconds": String(capturedByteCount * 1_000 / (AudioCaptureService.outputSampleRate * 2)),
                    "peakRMS": String(format: "%.6f", speechGate.peakRMS),
                    "speechDetected": String(speechGate.speechDetectedEver),
                ],
                sessionID: sessionID
            )

            var rawText = machine.snapshot.partialText
            // NEW-7: this path used to rethrow for providers without a batch
            // endpoint whenever no partial existed, and fail() -> resetIfCurrent
            // wipes the captured PCM — so a realtime error or finalize timeout
            // destroyed recoverable audio even with local fallback available.
            // Remember the error instead and let the same recovery ladder the
            // empty-transcript trigger uses decide; it resurfaces this error
            // when no fallback route exists.
            var realtimeError: Error?
            if let provider, providerSessionID == sessionID {
                do {
                    let realtimeText = try await Self.finishWithTimeout(provider)
                    guard isCurrent(sessionID, phase: .finalizing) else { return }
                    if !realtimeText.isEmpty { rawText = realtimeText }
                } catch {
                    guard isCurrent(sessionID, phase: .finalizing) else { return }
                    realtimeError = error
                    let hasPartial = !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    await logger.write(
                        .warning,
                        hasPartial
                            ? "Realtime finalize failed; using the latest partial transcript"
                            : "Realtime finalize failed; recovering from the retained audio",
                        metadata: ["error": error.localizedDescription],
                        sessionID: sessionID
                    )
                    guard isCurrent(sessionID, phase: .finalizing) else { return }
                }
                await provider.cancel()
                self.provider = nil
                providerSessionID = nil
                guard isCurrent(sessionID, phase: .finalizing) else { return }
            }
            guard isCurrent(sessionID, phase: .finalizing) else { return }
            if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let recovered = try await recoverEmptyRealtimeTranscript(
                    pcm16: recordedPCM,
                    capturedByteCount: capturedByteCount,
                    realtimeError: realtimeError,
                    sessionID: sessionID
                ) else { return }
                rawText = recovered
            }
            guard isCurrent(sessionID, phase: .finalizing) else { return }
            let normalizedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRawText.isEmpty else {
                throw DictationSessionError.noSpeech
            }
            let willProcess = ReasoningService.shouldCallModel(settings: activeSettings, target: target)
            if willProcess {
                try machine.transition(to: .processing, sessionID: sessionID)
                await publish()
            }
            let finalText: String
            let reasoningStartedAt = Date()
            var reasoningError: Error?
            // F4: reasoningTask holds the bounded wrapper, so cancel() /
            // shutdown() also cancels the request and the deadline timer.
            let task = Self.startBoundedReasoning(service: reasoning, text: normalizedRawText, settings: activeSettings, target: target)
            reasoningTask = task
            do {
                // Bound cloud cleanup at 8s; a slow provider falls back to the
                // raw transcript instead of stalling finalize for the full
                // request timeout.
                finalText = try await task.value
                if machine.snapshot.sessionID == sessionID { reasoningTask = nil }
                guard isCurrent(sessionID, phase: .finalizing) || isCurrent(sessionID, phase: .processing) else { return }
            } catch {
                if machine.snapshot.sessionID == sessionID { reasoningTask = nil }
                // Cancellation belongs to cancel()/shutdown(): no raw fallback.
                if error is CancellationError { return }
                guard isCurrent(sessionID, phase: .finalizing) || isCurrent(sessionID, phase: .processing) else { return }
                finalText = normalizedRawText
                reasoningError = error
                await capsule.flashStatus(localizedKey: "capsule.polishingFallback")
                guard isCurrent(sessionID, phase: .finalizing) || isCurrent(sessionID, phase: .processing) else { return }
            }
            await Self.logReasoning(
                logger, willProcess: willProcess, startedAt: reasoningStartedAt, settings: activeSettings,
                rawText: normalizedRawText, result: reasoningError == nil ? finalText : nil,
                error: reasoningError, sessionID: sessionID
            )

            // insert() only guards the auto-paste branch; without this the
            // transcript still lands in the clipboard while a password manager
            // or bank app is frontmost. P2-10: same decision as every other
            // sink, so the policies cannot diverge again.
            if sensitivity.blocksInsertion, let target {
                throw TextInsertionError.blockedSensitiveApplication(target.applicationName)
            }

            let completionPhase: DictationPhase
            var correctionBefore: CorrectionTextSnapshot?
            if activeSettings.automaticallyPasteTranscription, let target {
                try machine.transition(to: .inserting, sessionID: sessionID)
                await publish()
                if activeSettings.correctionLearningEnabled, !activeSettings.translationEnabled,
                   !sensitivity.blocksPersistence {
                    correctionBefore = await TextInsertionService.correctionSnapshot(for: target)
                    guard isCurrent(sessionID, phase: .inserting) else { return }
                }
                try await insertOrReportSecureInputBlock(finalText, into: target, sessionID: sessionID)
                completionPhase = .inserting
            } else {
                // F1: after reasoning the session is in .processing, not
                // .finalizing; both are allowed to reach .completed.
                guard machine.snapshot.phase == .finalizing || machine.snapshot.phase == .processing else { return }
                completionPhase = machine.snapshot.phase
            }
            guard isCurrent(sessionID, phase: completionPhase) else { return }
            if activeSettings.keepTranscriptionInClipboard {
                await insertion.copyToClipboard(finalText)
                guard isCurrent(sessionID, phase: completionPhase) else { return }
            }
            // P2-10: a sensitive session never reaches SQLite. Pre-fix this only
            // held when the insertion gate above threw first, so a user who
            // allowed insertion into a password manager still got the password
            // written to the history database in clear text. The clipboard stays
            // tied to the insertion policy the user opted into above.
            try await persistIfAllowed(text: finalText, rawText: normalizedRawText, correctionBefore: correctionBefore)
            guard isCurrent(sessionID, phase: completionPhase) else { return }
            try machine.transition(to: .completed, sessionID: sessionID)
            await logger.write(.info, "Dictation session completed", sessionID: sessionID)
            await publish()
            try? await Task.sleep(for: .milliseconds(550))
            await resetIfCurrent(sessionID)
        } catch {
            await fail(error, sessionID: sessionID)
        }
    }

    // Secure Input (password fields, `sudo`) makes the window server drop the
    // synthetic Cmd+V; insert() detects it and leaves the transcript on the
    // clipboard instead. Swallow that one error so the session still completes
    // and the history entry is written — failing here would reset the session
    // and leave the user with neither an insert nor an explanation.
    private func insertOrReportSecureInputBlock(_ text: String, into target: TextInsertionTarget, sessionID: UUID) async throws {
        do {
            try await insertion.insert(text, into: target, settings: activeSettings)
        } catch TextInsertionError.secureInputActive {
            let message = "Secure Input blocked the automatic paste; transcript kept on the clipboard"
            await logger.write(.warning, message, sessionID: sessionID)
            await capsule.flashStatus(localizedKey: "capsule.secureInputBlocked")
        }
    }

    // P2-10: history is a gated sink, not an unconditional one. Kept as its own
    // method so stop() states the intent in one line and keeps its complexity.
    private func persistIfAllowed(text: String, rawText: String, correctionBefore: CorrectionTextSnapshot?) async throws {
        guard !sensitivity.blocksPersistence else { return }
        let record = try await history.save(text: text, rawText: rawText)
        if activeSettings.correctionLearningEnabled, !activeSettings.translationEnabled,
           !IsSecureEventInputEnabled(),
           target.map({ !TextInsertionService.isSensitive($0) }) ?? true {
            await onTranscriptionSaved?(record, target, correctionBefore)
        }
    }

    func cancel() async {
        guard let sessionID = machine.snapshot.sessionID, machine.snapshot.phase.isActive else { return }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        preparingWatchdogTask?.cancel()
        preparingWatchdogTask = nil
        reasoningTask?.cancel()
        reasoningTask = nil
        await audio.stop()
        await resumePausedMedia()
        if providerSessionID == sessionID { await provider?.cancel() }
        do { try machine.transition(to: .cancelled, sessionID: sessionID) } catch { return }
        await logger.write(.info, "Dictation session cancelled", sessionID: sessionID)
        await publish()
        try? await Task.sleep(for: .milliseconds(250))
        await resetIfCurrent(sessionID)
    }

    // B4: the translation hotkey used to decide cancel-vs-start from the
    // @Published UI snapshot, which lags the actor; a suffix press racing the
    // main hotkey skipped the cancel, start() no-oped against the already
    // active main session, and the mis-set activation owner kept push-to-talk
    // release from stopping it. Deciding on the actor against the machine's
    // real state closes that window. Returns true when the now-active session
    // is a translation session, so the caller only claims the translation
    // activation when it actually took effect.
    func restartForTranslation(settings: AppSettings) async -> Bool {
        // The settle sleep suspends the actor, so a queued main-hotkey start
        // can claim the session slot before our start() runs and turn the
        // translation restart into a silent no-op. Re-cancel whatever
        // appeared, bounded so a genuinely failing start cannot loop forever.
        for _ in 0..<3 {
            if machine.snapshot.phase.isActive {
                await cancel()
                // Preserve the brief settle delay the hotkey handler used between
                // cancel and restart so the capsule hide/reset publishes cleanly.
                try? await Task.sleep(for: .milliseconds(80))
                continue
            }
            await start(settings: settings)
            break
        }
        let started = machine.snapshot.phase.isActive && machine.snapshot.isTranslation
        if !started {
            await logger.write(
                .warning,
                "Translation restart did not take effect",
                metadata: ["phase": String(describing: machine.snapshot.phase)],
                sessionID: machine.snapshot.sessionID
            )
        }
        return started
    }

    func snapshot() -> DictationSnapshot { machine.snapshot }

    private func consume(frame: Data, rms: Double, sessionID: UUID) async {
        guard machine.snapshot.sessionID == sessionID else { return }
        // Frames are only meaningful while capture is live: preparing covers
        // the audio.start-to-recording window and stopping covers the tail
        // drain. isActive also spans finalizing/processing/inserting, where a
        // late frame would land after the PCM snapshot and desync provider
        // and history.
        switch machine.snapshot.phase {
        case .preparing, .recording, .stopping: break
        default: return
        }
        pcm.append(frame)
        let activity = speechGate.consume(frame, rms: rms)
        await consume(level: activity.visualLevel, sessionID: sessionID)
        guard providerSessionID == sessionID, let provider else { return }
        do {
            try await provider.send(pcm16: frame)
        } catch {
            await degradeOrFailAfterRealtimeError(
                error,
                sessionID: sessionID,
                context: "Realtime frame send failed"
            )
        }
    }

    // A1: AVAudioEngineConfigurationChange fired for the session's engine —
    // the input device disappeared or changed (Bluetooth drop, unplugged
    // mic) and the engine stopped delivering frames. Owner-driven tear-downs
    // remove the observer before touching the engine, so only a live capture
    // (preparing/recording) reaches the fail path here.
    private func handleAudioSessionInterruption(sessionID: UUID) async {
        guard machine.snapshot.sessionID == sessionID else { return }
        switch machine.snapshot.phase {
        case .preparing, .recording:
            await fail(AudioCaptureError.inputDeviceChanged, sessionID: sessionID)
        default:
            break
        }
    }

    private func reportDroppedFrames(_ droppedFrames: Int, sessionID: UUID) async {
        await logger.write(
            .warning,
            "Audio frames were dropped during capture",
            metadata: ["droppedFrames": String(droppedFrames)],
            sessionID: sessionID
        )
    }

    private func consume(level: Float, sessionID: UUID) async {
        guard (try? machine.updateAudioLevel(level, sessionID: sessionID)) != nil else { return }
        await capsule.updateAudioLevel(level, sessionID: sessionID)
    }

    // A2: both the frame-send catch and the realtime `.error` event used to
    // decide degrade-vs-fail on their own, and the send catch failed the
    // session unconditionally for realtime-only providers — even mid-stop with
    // an essentially complete partial — so fail() -> resetIfCurrent wiped the
    // captured PCM. Routing both through this single policy keeps them from
    // diverging again and gives the send path the same hasPartial/winding-down
    // guard the event path already had.
    private func degradeOrFailAfterRealtimeError(_ error: Error, sessionID: UUID, context: String) async {
        let phase = machine.snapshot.phase
        let hasPartial = !machine.snapshot.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isWindingDown = phase == .stopping || phase == .finalizing || phase == .processing || phase == .inserting

        // Stop streaming into the broken task before deciding degrade-vs-fail,
        // for every provider: otherwise a batch-capable session keeps sending
        // frames into a dead socket every 20 ms for the rest of the recording.
        // During wind-down keep the provider so an in-flight finish() can still
        // resolve (it has a hard timeout, so this cannot wedge finalizing).
        if phase == .preparing || phase == .recording,
           providerSessionID == sessionID, let provider {
            self.provider = nil
            providerSessionID = nil
            await provider.cancel()
        }

        guard !providerHasBatchEndpoint(activeSettings.cloudTranscriptionProvider) else {
            // Batch-capable providers keep the retained PCM for the fallback.
            await logger.write(
                .warning,
                "\(context); retaining audio for batch fallback",
                metadata: ["error": error.localizedDescription],
                sessionID: sessionID
            )
            return
        }

        guard hasPartial || isWindingDown else {
            // No text yet and still early in the session: nothing to salvage,
            // so surface the failure immediately.
            await logger.write(
                .warning,
                context,
                metadata: ["error": error.localizedDescription],
                sessionID: sessionID
            )
            await fail(error, sessionID: sessionID)
            return
        }

        await logger.write(
            .warning,
            "\(context); degrading to the partial transcript fallback",
            metadata: ["error": error.localizedDescription, "phase": phase.rawValue],
            sessionID: sessionID
        )
    }

    private func batchTranscribe(pcm16: Data, settings: AppSettings) async throws -> String {
        guard providerHasBatchEndpoint(settings.cloudTranscriptionProvider) else {
            throw BailianRealtimeError.protocolError("The selected provider only supports realtime transcription.")
        }
        let account: CredentialAccount
        switch settings.cloudTranscriptionProvider {
        case "mistral": account = .mistral
        case "groq": account = .groq
        case "deepgram": account = .deepgram
        case "soniox": account = .soniox
        case "assemblyai": account = .assemblyAI
        case "custom": account = .customTranscription
        default: account = .openAI
        }
        guard let key = try await keychain.read(account), !key.isEmpty else {
            throw BailianRealtimeError.protocolError("The selected transcription API key is missing.")
        }
        let base = batchBaseURL(settings)
        guard let endpoint = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions") else {
            throw BailianRealtimeError.protocolError("The transcription endpoint is invalid.")
        }
        var configuration = BatchTranscriptionConfiguration(
            provider: settings.cloudTranscriptionProvider,
            endpoint: endpoint,
            apiKey: key,
            model: settings.cloudTranscriptionModel,
            language: settings.preferredLanguage == "auto" ? nil : settings.preferredLanguage,
            prompt: activeSettings.terminologyProfile.preferredTerms.joined(separator: ", ")
        )
        if settings.cloudTranscriptionProvider == "mistral" {
            configuration.authorizationHeader = "x-api-key"
            configuration.authorizationPrefix = ""
        }
        return try await batchClient.transcribe(
            wavData: WAVEncoder.pcm16Mono(pcm16),
            configuration: configuration
        )
    }

    private func transcribeRecordedAudio(
        pcm16: Data,
        settings: AppSettings,
        sessionID: UUID
    ) async throws -> String {
        if settings.useLocalTranscription {
            do {
                return try await localRuntime.transcribe(
                    pcm16: pcm16,
                    settings: settings,
                    prompt: terminologyPrompt(settings)
                )
            } catch {
                await logger.write(
                    .warning,
                    "Local transcription failed",
                    metadata: ["error": error.localizedDescription],
                    sessionID: sessionID
                )
                guard settings.allowCloudFallback else { throw error }
                return try await batchTranscribe(pcm16: pcm16, settings: settings)
            }
        }

        do {
            return try await batchTranscribe(pcm16: pcm16, settings: settings)
        } catch {
            guard settings.allowLocalFallback else { throw error }
            await logger.write(
                .warning,
                "Cloud transcription failed; trying local Whisper fallback",
                metadata: ["error": error.localizedDescription],
                sessionID: sessionID
            )
            var fallback = settings
            fallback.useLocalTranscription = true
            fallback.localTranscriptionProvider = .whisper
            fallback.whisperModel = settings.fallbackWhisperModel
            return try await localRuntime.transcribe(
                pcm16: pcm16,
                settings: fallback,
                prompt: terminologyPrompt(settings)
            )
        }
    }

    private func terminologyPrompt(_ settings: AppSettings) -> String? {
        let terms = settings.terminologyProfile.preferredTerms
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    private func batchBaseURL(_ settings: AppSettings) -> String {
        switch settings.cloudTranscriptionProvider {
        case "groq": "https://api.groq.com/openai/v1"
        case "mistral": "https://api.mistral.ai/v1"
        case "custom": settings.cloudTranscriptionBaseURL
        default: "https://api.openai.com/v1"
        }
    }

    private func realtimeProvider(
        for settings: AppSettings
    ) -> (provider: any RealtimeTranscriptionProvider, account: CredentialAccount, defaultModel: String)? {
        let selected: (provider: any RealtimeTranscriptionProvider, account: CredentialAccount, defaultModel: String)?
        switch settings.cloudTranscriptionProvider {
        case "bailian":
            selected = (bailianProvider, .bailian, BailianRealtimeProvider.defaultModel)
        case "volcengine":
            selected = (volcengineProvider, .volcengine, VolcengineRealtimeProvider.model)
        case "deepgram" where settings.deepgramStreamingEnabled:
            selected = (deepgramProvider, .deepgram, "nova-3")
        case "soniox" where settings.sonioxRealtimeEnabled:
            selected = (sonioxProvider, .soniox, "stt-rt-v4")
        case "assemblyai" where settings.assemblyAIStreaming:
            selected = (assemblyAIProvider, .assemblyAI, "universal-streaming-multilingual")
        default:
            selected = nil
        }
        guard let selected else { return nil }
        if let realtimeProviderOverride {
            return (realtimeProviderOverride, selected.account, selected.defaultModel)
        }
        return selected
    }

    private func realtimeConfiguration(
        settings: AppSettings,
        apiKey: String,
        defaultModel: String = BailianRealtimeProvider.defaultModel
    ) -> RealtimeTranscriptionConfiguration {
        RealtimeTranscriptionConfiguration(
            apiKey: apiKey,
            model: realtimeModel(
                provider: settings.cloudTranscriptionProvider,
                configured: settings.cloudTranscriptionModel,
                fallback: defaultModel
            ),
            language: settings.preferredLanguage,
            preferredTerms: settings.terminologyProfile.preferredTerms
        )
    }

    private func realtimeModel(provider: String, configured: String, fallback: String) -> String {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case "bailian": return BailianASRModel(rawValue: value)?.rawValue ?? fallback
        case "volcengine": return VolcengineRealtimeProvider.model
        case "deepgram": return value.hasPrefix("nova-") ? value : fallback
        case "soniox": return value.hasPrefix("stt-rt-") ? value : fallback
        case "assemblyai": return value.hasPrefix("universal-streaming") ? value : fallback
        default: return value.isEmpty ? fallback : value
        }
    }

    private func bailianMetadata(
        _ configuration: RealtimeTranscriptionConfiguration
    ) -> [String: String] {
        let strategy: String
        if configuration.preferredTerms.isEmpty {
            strategy = "none"
        } else {
            strategy = configuration.model == BailianASRModel.funASR.rawValue
                ? "precompiled"
                : "inline"
        }
        return [
            "provider": "bailian",
            "model": configuration.model,
            "hotwordStrategy": strategy,
            "hotwordCount": String(configuration.preferredTerms.count),
        ]
    }

    // Join the parallel pause first: resuming before pauseIfPlaying set its
    // "paused by us" flag would no-op and leave the user's media stuck paused.
    private func resumePausedMedia() async {
        if let task = mediaPauseTask {
            mediaPauseTask = nil
            await task.value
        }
        await mediaPlayback.resumeIfPaused()
    }

    private func fail(_ error: Error, sessionID: UUID) async {
        guard machine.snapshot.sessionID == sessionID, machine.snapshot.phase.isActive else { return }
        await Self.logFailEntry(error, logger: logger, sessionID: sessionID)
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        preparingWatchdogTask?.cancel()
        preparingWatchdogTask = nil
        reasoningTask?.cancel()
        reasoningTask = nil
        // Lock the state machine first: the awaits below allow other queued
        // actor calls (stop, max-duration) to interleave, and once audio/media
        // were already torn down there is no way to hand the session back.
        do {
            try machine.fail(error.localizedDescription, sessionID: sessionID)
        } catch {
            return
        }
        await audio.stop()
        await resumePausedMedia()
        if providerSessionID == sessionID { await provider?.cancel() }
        await logger.write(
            .error,
            "Dictation session failed",
            metadata: ["error": error.localizedDescription],
            sessionID: sessionID
        )
        await publish()
        try? await Task.sleep(for: .seconds(2.4))
        await resetIfCurrent(sessionID)
    }

    private func resetIfCurrent(_ sessionID: UUID) async {
        guard machine.snapshot.sessionID == sessionID else { return }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        preparingWatchdogTask?.cancel()
        preparingWatchdogTask = nil
        frameTask?.cancel()
        frameTask = nil
        frameContinuation?.finish()
        frameContinuation = nil
        // F2: fail() can be running ON the event consumer task; awaiting its
        // drain here self-deadlocked and wedged the session in .failed.
        terminateProviderEventStream()
        reasoningTask?.cancel()
        reasoningTask = nil
        provider = nil
        providerSessionID = nil
        target = nil
        sensitivity = .inactive
        pcm.removeAll(keepingCapacity: false)
        machine.reset()
        await publish()
        // A new session may already be on screen (error-display overlap);
        // never hide its capsule from the stale reset.
        await capsule.hideIfIdle()
    }

    private func isCurrent(_ sessionID: UUID, phase: DictationPhase) -> Bool {
        machine.snapshot.sessionID == sessionID && machine.snapshot.phase == phase
    }

    private func armMaximumDuration(for sessionID: UUID) {
        maximumDurationTask?.cancel()
        maximumDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30 * 60))
            guard !Task.isCancelled, let self else { return }
            await self.stopForMaximumDuration(sessionID)
        }
    }

    private func armPreparingWatchdog(for sessionID: UUID) {
        preparingWatchdogTask?.cancel()
        preparingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            await self.failPreparingTimeout(sessionID)
        }
    }

    private func failPreparingTimeout(_ sessionID: UUID) async {
        guard isCurrent(sessionID, phase: .preparing) else { return }
        await fail(DictationSessionError.preparingTimedOut, sessionID: sessionID)
    }

    private final class ClaimGate: @unchecked Sendable {
        private var claimed = false
        private let lock = NSLock()

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    // finish() can hang forever when the socket is half-dead (send never
    // completes and ignores cancellation), which would wedge this actor and
    // freeze the capsule in finalizing. Race it against a deadline and abandon
    // the loser; a timeout falls into the existing partial/batch fallback.
    nonisolated static func finishWithTimeout(
        _ provider: any RealtimeTranscriptionProvider,
        timeout: Duration = .seconds(8)
    ) async throws -> String {
        let gate = ClaimGate()
        return try await withCheckedThrowingContinuation { continuation in
            let finishTask = Task {
                do {
                    let text = try await provider.finish()
                    if gate.claim() { continuation.resume(returning: text) }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    finishTask.cancel()
                    continuation.resume(throwing: DictationSessionError.finalizeTimedOut)
                }
            }
        }
    }

    private func stopForMaximumDuration(_ sessionID: UUID) async {
        guard isCurrent(sessionID, phase: .recording) else { return }
        await logger.write(
            .warning,
            DictationSessionError.maximumDurationReached.localizedDescription,
            sessionID: sessionID
        )
        await stop()
    }

    private func publish(show: Bool = false) async {
        let snapshot = machine.snapshot
        await onSnapshot(snapshot)
        if show { await capsule.show(snapshot) } else { await capsule.update(snapshot) }
    }
}

// MARK: - Empty-transcript degradation ladder (P1-2)

private extension DictationCoordinator {
    // A provider capability, not a fallback policy: bailian/volcengine expose
    // no batch/HTTP transcription endpoint, so a failed or empty stream cannot
    // be re-uploaded to the same vendor. Callers that mean "no fallback at all"
    // must additionally consult the user's settings — conflating the two is
    // what made allowLocalFallback inert and lost the user's speech.
    func providerHasBatchEndpoint(_ provider: String) -> Bool {
        provider != "bailian" && provider != "volcengine"
    }

    // The realtime transcript came back empty, or finalizing it failed. This
    // used to throw noSpeech / rethrow the provider error for realtime-only
    // providers before transcribeRecordedAudio was ever reached, discarding the
    // retained PCM even with local fallback enabled and a model installed. Both
    // triggers converge here so they cannot drift apart again. Returns nil when
    // the session was superseded mid-recovery, so stop() bails out as it did
    // inline.
    func recoverEmptyRealtimeTranscript(
        pcm16: Data,
        capturedByteCount: Int,
        realtimeError: Error?,
        sessionID: UUID
    ) async throws -> String? {
        guard capturedByteCount > 0 else { throw AudioCaptureError.noAudioFrames }
        // Uploading an all-silence capture wastes a round-trip and can
        // hallucinate text; the gate already knows nothing was said.
        guard speechGate.speechDetectedEver else { throw DictationSessionError.noSpeech }
        // Speech was said but no text came back, so anything still reachable
        // beats dropping the audio. With nothing reachable, surface the realtime
        // failure that got us here — reporting noSpeech for a broken stream
        // would blame the user for the provider's error.
        guard let settings = await fallbackTranscriptionSettings(sessionID: sessionID) else {
            throw realtimeError ?? DictationSessionError.noSpeech
        }
        guard isCurrent(sessionID, phase: .finalizing) else { return nil }
        return try await transcribeRecordedAudio(pcm16: pcm16, settings: settings, sessionID: sessionID)
    }

    // Picks the surviving route for the retained audio: the provider's own
    // batch endpoint where it has one (unchanged behavior), otherwise the local
    // model when the user enabled local fallback and it is actually installed.
    func fallbackTranscriptionSettings(sessionID: UUID) async -> AppSettings? {
        if providerHasBatchEndpoint(activeSettings.cloudTranscriptionProvider) { return activeSettings }
        guard activeSettings.allowLocalFallback else { return nil }
        let model = activeSettings.fallbackWhisperModel
        let status = await localRuntime.status(provider: .whisper, model: model)
        guard status.runtimeAvailable, status.modelAvailable else { return nil }
        await logger.write(
            .warning,
            "Realtime transcript was empty; falling back to local transcription",
            metadata: ["model": model],
            sessionID: sessionID
        )
        var fallback = activeSettings
        fallback.useLocalTranscription = true
        fallback.localTranscriptionProvider = .whisper
        fallback.whisperModel = model
        // No batch endpoint to escalate to: keep a local failure from bouncing
        // into batchTranscribe, which would only replace the real error with
        // "the selected provider only supports realtime transcription".
        fallback.allowCloudFallback = false
        return fallback
    }
}

// MARK: - Provider event stream (P2-1)

private extension DictationCoordinator {
    // Moved out of the actor body so SwiftLint's type_body_length rule keeps
    // its 800-line envelope intact. Semantics are unchanged from the pre-fix
    // implementation apart from the DEBUG-only delay seam.
    func handle(event: RealtimeTranscriptionEvent, sessionID: UUID) async {
        #if DEBUG
        if let delay = testEventHandleDelay?(event) {
            try? await Task.sleep(for: delay)
        }
        #endif
        guard machine.snapshot.sessionID == sessionID else { return }
        switch event {
        case .partial(let stable, let active):
            try? machine.updatePartial(stable + active, sessionID: sessionID)
            await publish()
        case .final(let text), .sessionFinished(let text):
            try? machine.updatePartial(text, sessionID: sessionID)
            await publish()
        case .speechStarted:
            break
        case .error(let message):
            await degradeOrFailAfterRealtimeError(
                BailianRealtimeError.protocolError(message),
                sessionID: sessionID,
                context: "Realtime provider error"
            )
        }
    }

    // Creates the per-session AsyncStream and spawns the single consumer
    // Task. Returns the @Sendable closure that yields events into the
    // continuation so start() can hand it straight to provider.connect.
    func armProviderEventStream(
        sessionID: UUID
    ) -> @Sendable (RealtimeTranscriptionEvent) -> Void {
        let (events, continuation) = AsyncStream<RealtimeTranscriptionEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        providerEventTask?.cancel()
        providerEventContinuation?.finish()
        providerEventContinuation = continuation
        providerEventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event, sessionID: sessionID)
            }
        }
        return { event in continuation.yield(event) }
    }

    // F2: termination-path (fail/cancel/reset/shutdown) event-stream
    // teardown. Unlike the bounded drain in stop(), this never awaits the
    // consumer task: fail() itself can be executing ON that task
    // (.error → degradeOrFailAfterRealtimeError → fail), and awaiting its
    // .value would be a self-deadlock. Synchronous finish + cancel + release
    // only; events already inside handle() still run, guarded by their own
    // session/phase checks. Normal stop keeps runBoundedStopDrain.
    func terminateProviderEventStream() {
        providerEventContinuation?.finish()
        providerEventContinuation = nil
        providerEventTask?.cancel()
        providerEventTask = nil
    }
}

// MARK: - Stop drain watchdog (P2-2)

private extension DictationCoordinator {
    // Extracts the stop() drain block into an actor method so the
    // `if !drainedCleanly` branch does not inflate stop()'s cyclomatic
    // complexity beyond its pre-fix count. Captures the pending consumer
    // Tasks into local `let`s so the actor stops referencing them while
    // the racer inside awaitDrainWithTimeout still holds them, then logs
    // a single warning when the watchdog fires. The finish() bookkeeping
    // for the two continuations stays inline in stop() next to its
    // P2-1 comment.
    func runBoundedStopDrain(sessionID: UUID) async {
        let pendingFrameTask = frameTask
        let pendingEventTask = providerEventTask
        frameTask = nil
        providerEventTask = nil
        let drainedCleanly = await Self.awaitDrainWithTimeout(
            frame: pendingFrameTask,
            event: pendingEventTask
        )
        if !drainedCleanly {
            await logger.write(
                .warning,
                "Stop drain watchdog fired; finalizing with the retained PCM and partial",
                sessionID: sessionID
            )
        }
    }

    // Bounded variant of `await frameTask?.value` + `await
    // providerEventTask?.value`. Pre-fix stop() awaited each drain
    // unbounded, so a hung audio engine that never released the frame
    // continuation or a dead provider socket whose event stream never
    // finished parked the session in .stopping forever with no user
    // recourse except Escape. Race the combined drain against a watchdog
    // via the same claim-gate shape as finishWithTimeout so the
    // continuation resumes on the first winner even when the loser Task
    // ignores cancellation (a `withTaskGroup` variant would still block
    // on the group's implicit join in that case). Cancelling the frame
    // and event consumer Tasks on timeout is best-effort: AsyncStream
    // `for await` exits on cancellation, but a stuck downstream await
    // (e.g. provider.send parked on a dead socket) won't unblock — the
    // point of the helper is to unwedge stop(), not to force the leak
    // task to unwind. Lives in this extension so SwiftLint's
    // type_body_length rule keeps the actor body under 800 lines, same
    // as the P2-1 helpers above.
    nonisolated static func awaitDrainWithTimeout(
        frame frameTask: Task<Void, Never>?,
        event eventTask: Task<Void, Never>?,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let gate = ClaimGate()
        return await withCheckedContinuation { continuation in
            let drainTask = Task {
                await frameTask?.value
                await eventTask?.value
                if gate.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    frameTask?.cancel()
                    eventTask?.cancel()
                    drainTask.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

#if DEBUG
extension DictationCoordinator {
    // Test seam for DictationCoordinatorTests.testProviderEventsProcessInOrder.
    // Kept in a non-private extension so `@testable import` can reach it while
    // `testEventHandleDelay` itself stays `private` on the actor body.
    func setTestEventHandleDelay(
        _ delay: (@Sendable (RealtimeTranscriptionEvent) -> Duration?)?
    ) {
        testEventHandleDelay = delay
    }
}
#endif
