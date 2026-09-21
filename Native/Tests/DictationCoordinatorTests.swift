import XCTest
@testable import Mouthpiece

// E4(1): DictationCoordinator orchestration against a scripted realtime
// provider and a stubbed microphone. The stubs replace only the hardware and
// network edges; state machine, keychain lookup, history persistence, and
// snapshot publishing run for real.
@MainActor
final class DictationCoordinatorTests: XCTestCase {
    func testConnectFailureFailsTheSessionAndAllowsARestart() async throws {
        let provider = ScriptedRealtimeProvider(connect: .fail("socket refused"))
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())

        let failure = harness.recorder.snapshots.first { $0.phase == .failed }
        XCTAssertNotNil(failure, "A realtime-only connect failure must surface a failed snapshot")
        XCTAssertEqual(failure?.errorMessage, "socket refused")
        let afterFailure = await harness.coordinator.snapshot()
        XCTAssertEqual(afterFailure.phase, .idle, "The failed session must reset back to idle")

        // The same coordinator must accept a fresh session once the provider recovers.
        await provider.setConnectBehavior(.succeed)
        await harness.coordinator.start(settings: makeSettings())
        let restarted = await harness.coordinator.snapshot()
        XCTAssertEqual(restarted.phase, .recording)
        await harness.coordinator.cancel()
    }

    func testStopUsesTheRealtimeTranscriptAndCompletesTheSession() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "hello from realtime")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // A captured frame must reach the provider through the consumer task.
        harness.audio.emitFrame()
        var frameForwarded = false
        for _ in 0..<200 {
            if await provider.sentFrameCount > 0 {
                frameForwarded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(frameForwarded, "Audio frames must be forwarded to the realtime provider")

        // Partial events flow into the published snapshot while recording.
        await provider.emit(.partial(stable: "", active: "hello"))
        var partialSeen = false
        for _ in 0..<200 {
            if harness.recorder.snapshots.contains(where: { $0.partialText == "hello" }) {
                partialSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(partialSeen, "Partial transcripts must be published while recording")

        await harness.coordinator.stop()

        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let finalSnapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(finalSnapshot.phase, .idle, "A completed session must reset back to idle")
        let records = try await harness.history.recent(limit: 10)
        XCTAssertEqual(records.first?.text, "hello from realtime")
        XCTAssertEqual(records.first?.rawText, "hello from realtime")
    }

    func testCancelReturnsToIdleAndSuppressesLateProviderEvents() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "ignored")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        await harness.coordinator.cancel()

        let cancelled = await harness.coordinator.snapshot()
        XCTAssertEqual(cancelled.phase, .idle)
        let providerCancelCount = await provider.cancelCount
        XCTAssertGreaterThanOrEqual(providerCancelCount, 1)

        // A late event from the abandoned session must not publish anything.
        let snapshotCount = harness.recorder.snapshots.count
        await provider.emit(.final("late text"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.recorder.snapshots.count, snapshotCount)
        let finalSnapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(finalSnapshot.phase, .idle)
        XCTAssertEqual(finalSnapshot.partialText, "")
    }

    // B2: frames yielded into the stream right before stop() must all reach
    // the provider before finish() is called; without the drain barrier
    // (finish the stream + await the consumer) tail frames raced the PCM
    // snapshot and could arrive after finalize or be lost entirely.
    func testStopDeliversAllQueuedFramesToTheProviderBeforeFinish() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "tail preserved")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // Prime the streaming path so the provider is known to receive frames.
        harness.audio.emitFrame()
        var frameForwarded = false
        for _ in 0..<200 {
            if await provider.sentFrameCount > 0 {
                frameForwarded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(frameForwarded, "Audio frames must be forwarded to the realtime provider")

        // Enqueue three tail frames and stop immediately without yielding to
        // the consumer task: the barrier must deliver them before finalizing.
        harness.audio.emitFrame()
        harness.audio.emitFrame()
        harness.audio.emitFrame()
        await harness.coordinator.stop()

        let sentAtFinish = await provider.sentFrameCountAtFinish
        XCTAssertEqual(sentAtFinish, 4, "All queued tail frames must be sent before finish() is called")
        let sentTotal = await provider.sentFrameCount
        XCTAssertEqual(sentTotal, 4, "No frame may arrive at the provider after finish()")
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "tail preserved")
    }

    // B4: the translation hotkey now decides cancel-vs-start on the actor.
    // While a main session is recording, restartForTranslation must cancel it
    // and activate a fresh translation session.
    func testRestartForTranslationWhileRecordingCancelsAndActivatesTranslation() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "unused")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let mainSession = await harness.coordinator.snapshot()
        XCTAssertEqual(mainSession.phase, .recording)
        XCTAssertFalse(mainSession.isTranslation)

        var translationSettings = makeSettings()
        translationSettings.translationEnabled = true
        let activated = await harness.coordinator.restartForTranslation(settings: translationSettings)

        XCTAssertTrue(activated, "restartForTranslation must report the translation session as active")
        let restarted = await harness.coordinator.snapshot()
        XCTAssertEqual(restarted.phase, .recording)
        XCTAssertTrue(restarted.isTranslation)
        XCTAssertNotEqual(restarted.sessionID, mainSession.sessionID, "A fresh session must replace the cancelled one")
        let cancels = await provider.cancelCount
        XCTAssertGreaterThanOrEqual(cancels, 1, "The active main session must be cancelled before the restart")
        await harness.coordinator.cancel()
    }

    // B4: from idle the atomic restart must skip the cancel path and simply
    // start a translation session.
    func testRestartForTranslationFromIdleStartsDirectly() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "unused")
        let harness = try await makeHarness(provider: provider)

        var translationSettings = makeSettings()
        translationSettings.translationEnabled = true
        let activated = await harness.coordinator.restartForTranslation(settings: translationSettings)

        XCTAssertTrue(activated)
        let snapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .recording)
        XCTAssertTrue(snapshot.isTranslation)
        let cancels = await provider.cancelCount
        XCTAssertEqual(cancels, 0, "No session was active, so nothing must be cancelled")
        await harness.coordinator.cancel()
    }

    // The settle sleep inside restartForTranslation suspends the actor; a
    // queued main-hotkey start used to claim the session slot in that window
    // and turn the translation start into a silent no-op. The bounded retry
    // must cancel the stolen session and still activate translation.
    func testRestartForTranslationReclaimsSlotFromCompetingStart() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "unused")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let mainSession = await harness.coordinator.snapshot()
        XCTAssertEqual(mainSession.phase, .recording)

        var translationSettings = makeSettings()
        translationSettings.translationEnabled = true
        async let restart = harness.coordinator.restartForTranslation(settings: translationSettings)

        // Wait for the restart's cancel to land, then steal the freed slot
        // with a competing normal start while the restart is settling.
        var slotFreed = false
        for _ in 0..<200 {
            if await !harness.coordinator.snapshot().phase.isActive {
                slotFreed = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(slotFreed, "The restart must cancel the main session first")
        await harness.coordinator.start(settings: makeSettings())

        let activated = await restart
        XCTAssertTrue(activated, "The translation restart must reclaim the slot from the competing start")
        let snapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .recording)
        XCTAssertTrue(snapshot.isTranslation)
        await harness.coordinator.cancel()
    }

    // C1: a realtime-only provider error while recording must degrade the
    // connection instead of failing the session once a partial transcript
    // exists; stop() then completes with the retained partial.
    func testRealtimeErrorAfterPartialDegradesAndStopCompletesWithPartial() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "must not be used")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let startedPhase = await harness.coordinator.snapshot().phase
        XCTAssertEqual(startedPhase, .recording)

        await provider.emit(.partial(stable: "hello ", active: "world"))
        var partialSeen = false
        for _ in 0..<200 {
            if await harness.coordinator.snapshot().partialText == "hello world" {
                partialSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(partialSeen, "The partial transcript must land before the error is injected")

        await provider.emit(.error("stream broke"))
        var degraded = false
        for _ in 0..<200 {
            if await provider.cancelCount >= 1 {
                degraded = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(degraded, "The broken provider task must be cancelled when degrading")
        let phaseAfterError = await harness.coordinator.snapshot().phase
        XCTAssertEqual(
            phaseAfterError,
            .recording,
            "An error with a retained partial must not fail the live session"
        )
        XCTAssertFalse(harness.recorder.snapshots.contains { $0.phase == .failed })

        await harness.coordinator.stop()

        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let finishCalls = await provider.finishCallCount
        XCTAssertEqual(finishCalls, 0, "A degraded provider must not be asked to finish")
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "hello world")
    }

    // C1: with no partial transcript there is nothing to salvage, so an early
    // realtime-only error must still fail the session immediately.
    func testEarlyRealtimeErrorWithoutPartialFailsTheSession() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "unused")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let earlyPhase = await harness.coordinator.snapshot().phase
        XCTAssertEqual(earlyPhase, .recording)

        await provider.emit(.error("early boom"))
        var failure: DictationSnapshot?
        for _ in 0..<200 {
            if let failed = harness.recorder.snapshots.first(where: { $0.phase == .failed }) {
                failure = failed
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(failure, "An early error without any partial transcript must fail the session")
        XCTAssertEqual(failure?.errorMessage, "early boom")

        // F2: after the 2.4s error display the session must actually reset to
        // idle — pre-fix the consumer self-awaited its own task and wedged in
        // .failed forever.
        var reachedIdle = false
        for _ in 0..<300 {
            if await harness.coordinator.snapshot().phase == .idle {
                reachedIdle = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(reachedIdle, "Session must reset to idle after the error display")
    }

    // F2: starting a new session during the previous one's error display must
    // survive the old error timer: the new session keeps recording and the
    // stale reset neither steals the state machine nor hides its capsule.
    func testNewSessionSurvivesPreviousErrorDisplay() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "second session text")
        let harness = try await makeHarness(provider: provider)
        await harness.coordinator.start(settings: makeSettings())
        await provider.emit(.error("first session boom"))
        // Wait for the failure to publish, then start the next session while
        // the 2.4s error display is still on screen.
        for _ in 0..<200 {
            if harness.recorder.snapshots.contains(where: { $0.phase == .failed }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await harness.coordinator.start(settings: makeSettings())
        harness.audio.emitFrame()
        // Outlast the old error display + scheduling slack.
        try await Task.sleep(for: .seconds(3))
        let snapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .recording, "New session must keep recording past the old error timer")
        await harness.coordinator.stop()
        let records = try await harness.history.recent(limit: 10)
        XCTAssertEqual(records.first?.text, "second session text")
    }

    // C1: an error event that lands while stop() is already finalizing must
    // not interrupt the wind-down; finish() resolves the session on its own.
    func testRealtimeErrorDuringFinalizingDoesNotInterruptCompletion() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "final text")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let liveRecordingPhase = await harness.coordinator.snapshot().phase
        XCTAssertEqual(liveRecordingPhase, .recording)

        await provider.blockFinish()
        let coordinator = harness.coordinator
        let stopTask = Task { await coordinator.stop() }
        var finishing = false
        for _ in 0..<200 {
            if await provider.finishCallCount > 0 {
                finishing = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(finishing, "stop() must reach the provider finish call while it is gated")

        await provider.emit(.error("mid-finalize boom"))
        // Give the queued error event time to reach the coordinator while the
        // session is still parked in finalizing, then let finish() resolve.
        try await Task.sleep(for: .milliseconds(150))
        await provider.releaseFinish()
        await stopTask.value

        XCTAssertFalse(
            harness.recorder.snapshots.contains { $0.phase == .failed },
            "An error during wind-down must not fail the finalizing session"
        )
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "final text")
    }

    // A2: a realtime-only socket that dies during the stop drain must not fail
    // the session and wipe the captured audio — the retained partial has to
    // survive into history. Pre-fix the send catch called fail() ->
    // resetIfCurrent (pcm.removeAll) for realtime-only providers, so the
    // session ended .failed with nothing saved.
    func testSendFailureDuringStopKeepsPartialTranscript() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed)
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        await provider.emit(.partial(stable: "hello ", active: "world"))
        var partialSeen = false
        for _ in 0..<200 {
            if await harness.coordinator.snapshot().partialText == "hello world" {
                partialSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(partialSeen, "The partial transcript must land before the socket dies")

        // The socket dies during the stop drain: the queued tail frame's send
        // throws while the session is winding down.
        await provider.setShouldFailSend(true)
        harness.audio.emitFrame()
        await harness.coordinator.stop()

        XCTAssertFalse(
            harness.recorder.snapshots.contains { $0.phase == .failed },
            "A send failure with a retained partial must not fail the session"
        )
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let finalSnapshot = await harness.coordinator.snapshot()
        XCTAssertEqual(finalSnapshot.phase, .idle, "A completed session must reset back to idle")
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "hello world")
    }

    // P1-2: for a realtime-only provider (no batch endpoint) an empty realtime
    // transcript used to throw noSpeech before transcribeRecordedAudio was ever
    // reached, so the retained PCM was discarded and the user's speech lost
    // even with local fallback enabled and a model installed. With speech
    // detected the session must now recover through the local model.
    func testRealtimeOnlyFinalizeFailureUsesLocalFallbackWhenEnabled() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "")
        let localRuntime = StubLocalRuntime(text: "recovered by the local model")
        let harness = try await makeHarness(provider: provider, localRuntime: localRuntime)

        var settings = makeSettings()
        settings.allowLocalFallback = true
        settings.fallbackWhisperModel = "small"
        await harness.coordinator.start(settings: settings)
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // 300 ms above the gate's speech threshold: speech was definitely said,
        // so an empty realtime transcript means the stream failed us, not the user.
        for _ in 0..<15 { harness.audio.emitFrame(rms: 0.02) }
        await harness.coordinator.stop()

        XCTAssertFalse(
            harness.recorder.snapshots.contains { $0.phase == .failed },
            "An empty realtime transcript must not fail the session while local fallback is available"
        )
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let localCalls = await localRuntime.transcribeCallCount
        XCTAssertEqual(localCalls, 1, "The retained audio must reach the local transcription path")
        let routedSettings = await localRuntime.lastSettings
        XCTAssertEqual(routedSettings?.useLocalTranscription, true, "The fallback must route into the local branch")
        XCTAssertEqual(routedSettings?.localTranscriptionProvider, .whisper)
        XCTAssertEqual(routedSettings?.whisperModel, "small", "The configured fallback model must be used")
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "recovered by the local model")

        // The opposite case is unchanged: nothing was ever spoken, so uploading
        // silence to any engine would only risk hallucinated text.
        let silentProvider = ScriptedRealtimeProvider(connect: .succeed, finishText: "")
        let silentLocalRuntime = StubLocalRuntime(text: "must not be used")
        let silentHarness = try await makeHarness(provider: silentProvider, localRuntime: silentLocalRuntime)
        await silentHarness.coordinator.start(settings: settings)
        let silentRecording = await silentHarness.coordinator.snapshot()
        XCTAssertEqual(silentRecording.phase, .recording)

        for _ in 0..<15 { silentHarness.audio.emitFrame(rms: 0.001) }
        await silentHarness.coordinator.stop()

        let failure = silentHarness.recorder.snapshots.first { $0.phase == .failed }
        XCTAssertEqual(
            failure?.errorMessage,
            DictationSessionError.noSpeech.localizedDescription,
            "A capture with no detected speech must still fail with noSpeech"
        )
        let silentLocalCalls = await silentLocalRuntime.transcribeCallCount
        XCTAssertEqual(silentLocalCalls, 0, "Silence must never reach the local transcription path")
    }

    // NEW-7: the same data-loss hole as P1-2 reached through the other trigger —
    // finalizing the realtime stream errored (or timed out) instead of returning
    // empty text. That rethrow reached fail() -> resetIfCurrent, which wipes the
    // captured PCM, so the audio was destroyed before the recovery ladder could
    // route it to the installed local model. Both triggers now share the ladder.
    func testRealtimeOnlyFinalizeErrorUsesLocalFallbackWhenEnabled() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "never returned")
        await provider.setFinishError(.connectionLost("socket closed during finalize"))
        let localRuntime = StubLocalRuntime(text: "salvaged after a finalize error")
        let harness = try await makeHarness(provider: provider, localRuntime: localRuntime)

        var settings = makeSettings()
        settings.allowLocalFallback = true
        settings.fallbackWhisperModel = "small"
        await harness.coordinator.start(settings: settings)
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // 300 ms above the gate's speech threshold and no partial ever arrived,
        // so the retained audio is the only surviving copy of the user's speech.
        for _ in 0..<15 { harness.audio.emitFrame(rms: 0.02) }
        await harness.coordinator.stop()

        let finishCalls = await provider.finishCallCount
        XCTAssertEqual(finishCalls, 1, "The recovery must follow a real finish() attempt")
        XCTAssertFalse(
            harness.recorder.snapshots.contains { $0.phase == .failed },
            "A finalize error must not fail the session while local fallback is available"
        )
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        let localCalls = await localRuntime.transcribeCallCount
        XCTAssertEqual(localCalls, 1, "The retained audio must reach the local transcription path")
        let routedSettings = await localRuntime.lastSettings
        XCTAssertEqual(routedSettings?.useLocalTranscription, true, "The fallback must route into the local branch")
        XCTAssertEqual(routedSettings?.localTranscriptionProvider, .whisper)
        XCTAssertEqual(routedSettings?.whisperModel, "small", "The configured fallback model must be used")
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(records.first?.text, "salvaged after a finalize error")

        // With no fallback route the session still fails as before, but the user
        // must see the provider's real error instead of a misleading "no speech".
        let strandedProvider = ScriptedRealtimeProvider(connect: .succeed)
        await strandedProvider.setFinishError(.connectionLost("socket closed during finalize"))
        let strandedRuntime = StubLocalRuntime(text: "must not be used")
        let strandedHarness = try await makeHarness(provider: strandedProvider, localRuntime: strandedRuntime)
        var strandedSettings = settings
        strandedSettings.allowLocalFallback = false
        await strandedHarness.coordinator.start(settings: strandedSettings)
        let strandedRecording = await strandedHarness.coordinator.snapshot()
        XCTAssertEqual(strandedRecording.phase, .recording)

        for _ in 0..<15 { strandedHarness.audio.emitFrame(rms: 0.02) }
        await strandedHarness.coordinator.stop()

        let failure = strandedHarness.recorder.snapshots.first { $0.phase == .failed }
        XCTAssertEqual(
            failure?.errorMessage,
            BailianRealtimeError.connectionLost("socket closed during finalize").localizedDescription,
            "Without a fallback the original realtime error must surface"
        )
        XCTAssertNotEqual(
            failure?.errorMessage,
            DictationSessionError.noSpeech.localizedDescription,
            "Speech was detected, so noSpeech would blame the user for the provider's failure"
        )
        let strandedLocalCalls = await strandedRuntime.transcribeCallCount
        XCTAssertEqual(strandedLocalCalls, 0, "A disabled local fallback must never be invoked")
    }

    // D8 / P3-3: the VoiceOver announcement mapping must cover every non-idle
    // phase with a non-nil localized key so screen-reader users hear feedback
    // for every visible capsule state. `.idle` stays silent so the announcement
    // is not re-fired when a session ends and the capsule dismisses.
    func testCapsuleAnnouncementKeysCoverExactlyTheAnnouncedPhases() {
        XCTAssertNil(CapsuleController.announcementKey(for: .idle), "idle must not announce")
        XCTAssertEqual(CapsuleController.announcementKey(for: .preparing), "capsule.preparing")
        XCTAssertEqual(CapsuleController.announcementKey(for: .recording), "capsule.listening")
        XCTAssertEqual(CapsuleController.announcementKey(for: .stopping), "capsule.transcribing")
        XCTAssertEqual(CapsuleController.announcementKey(for: .finalizing), "capsule.transcribing")
        XCTAssertEqual(CapsuleController.announcementKey(for: .processing), "capsule.polishing")
        XCTAssertEqual(CapsuleController.announcementKey(for: .inserting), "capsule.inserting")
        XCTAssertEqual(CapsuleController.announcementKey(for: .completed), "capsule.success")
        XCTAssertEqual(CapsuleController.announcementKey(for: .cancelled), "capsule.cancelled")
        XCTAssertEqual(CapsuleController.announcementKey(for: .failed), "capsule.failed")
    }

    // P3-3: iteration-based backstop — any future `DictationPhase` case that
    // forgets to add an announcement key (or a localization) fails here
    // regardless of whether the pinned test above is updated.
    func testEveryNonIdlePhaseHasAnnouncement() {
        for phase in DictationPhase.allCases {
            let key = CapsuleController.announcementKey(for: phase)
            if phase == .idle {
                XCTAssertNil(key, "\(phase) must not announce")
                continue
            }
            guard let key else {
                XCTFail("\(phase) must map to a non-nil announcement key")
                continue
            }
            for language in [UILanguage.english, .simplifiedChinese, .traditionalChinese] {
                let localized = AppLocalization.string(key, language: language)
                XCTAssertFalse(
                    localized.isEmpty || localized == key,
                    "\(phase) key \(key) missing localization for \(language)"
                )
            }
        }
    }

    // P2-1: realtime provider events must be processed in emit order.
    // Pre-fix, each event spawned its own unstructured `Task { await
    // handle(event) }`, so a delayed `.final` could race against a trailing
    // `.partial` and overwrite it on the machine's `partialText`, corrupting
    // the transcript at stop() time. Post-fix the single-consumer
    // AsyncStream drains events sequentially so the last emit always wins.
    func testProviderEventsProcessInOrder() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // Force a deterministic reordering pre-fix: delay `.final` by 60 ms
        // so a Task-per-event scheme applies the trailing `.partial("stale")`
        // first and then lets the woken `.final("ABC")` overwrite it. Post-fix
        // the single consumer parks on the delayed `.final` and only pulls
        // the trailing `.partial("stale")` afterwards, so "stale" wins.
        await harness.coordinator.setTestEventHandleDelay { event in
            if case .final = event { return .milliseconds(60) }
            return nil
        }

        await provider.emit(.partial(stable: "", active: "A"))
        await provider.emit(.partial(stable: "", active: "AB"))
        await provider.emit(.final("ABC"))
        await provider.emit(.partial(stable: "", active: "stale"))

        // 60 ms delay + slack for actor hops and MainActor publish.
        try await Task.sleep(for: .milliseconds(300))

        let partial = await harness.coordinator.snapshot().partialText
        XCTAssertEqual(
            partial,
            "stale",
            "Events must be applied in emit order; pre-fix the delayed .final overwrites the trailing .partial and lands on \"ABC\""
        )

        // Belt-and-suspenders: at rest, no snapshot with the post-final
        // trailing partial ("stale") may be followed by a later snapshot that
        // reverts to the earlier `.final` text ("ABC"). Post-fix the consumer
        // orders these strictly; pre-fix the racing task reintroduces "ABC"
        // after "stale" already landed.
        let published = harness.recorder.snapshots.map(\.partialText)
        if let staleIndex = published.lastIndex(of: "stale") {
            XCTAssertFalse(
                published[staleIndex...].contains("ABC"),
                "A later `.final` snapshot must never follow the trailing `.partial`"
            )
        }

        await harness.coordinator.cancel()
    }

    // P2-2: stop()'s drain used to `await frameTask?.value` and `await
    // providerEventTask?.value` unbounded, so a hung audio engine or a
    // dead provider socket whose event stream never finishes parked the
    // session in .stopping forever with no user recourse except Escape.
    // Wedge the provider event drain via the DEBUG delay seam and prove
    // stop() completes within the shared watchdog and still saves the
    // retained partial to history. Pre-fix stop() awaits providerEventTask
    // forever; the XCTest expectation timeout keeps the whole run from
    // hanging so the regression surfaces as a clean failure.
    func testStopDrainTimesOutAndFinalizes() async throws {
        // A wedged actor must not cascade into the follow-up assertions.
        continueAfterFailure = false

        let provider = ScriptedRealtimeProvider(connect: .succeed, finishText: "")
        let harness = try await makeHarness(provider: provider)

        await harness.coordinator.start(settings: makeSettings())
        let recording = await harness.coordinator.snapshot()
        XCTAssertEqual(recording.phase, .recording)

        // Land a partial cleanly (no delay yet); this is what the retained-
        // partial recovery path must save into history once the watchdog
        // gives up on the wedged drain.
        await provider.emit(.partial(stable: "hello ", active: "world"))
        var partialSeen = false
        for _ in 0..<200 {
            if await harness.coordinator.snapshot().partialText == "hello world" {
                partialSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(partialSeen, "The partial must land before we wedge the drain")

        // Wedge the provider event consumer: the next event's handle() parks
        // on a 30 s Task.sleep before touching state, so providerEventTask
        // never completes on its own. `.speechStarted` is applied as a
        // no-op by handle(), so even if the wedged event resumes after we
        // cancel the task, it cannot overwrite partialText.
        await harness.coordinator.setTestEventHandleDelay { _ in .seconds(30) }
        await provider.emit(.speechStarted)

        let stopFinished = XCTestExpectation(description: "stop() completes within the drain watchdog")
        let coordinator = harness.coordinator
        Task {
            await coordinator.stop()
            stopFinished.fulfill()
        }
        // 8 s comfortably covers the 3 s drain watchdog plus the finalize
        // path (finishWithTimeout returns immediately for an empty final,
        // no reasoning/insertion/clipboard in makeSettings). Without the
        // P2-2 watchdog stop() awaits providerEventTask forever and this
        // expectation trips instead of hanging the whole run.
        await fulfillment(of: [stopFinished], timeout: 8)

        XCTAssertTrue(
            harness.recorder.snapshots.contains { $0.phase == .completed },
            "The retained partial must reach the completed phase once the watchdog fires"
        )
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(
            records.first?.text,
            "hello world",
            "The retained partial must be saved to history after the drain watchdog fires"
        )
    }

    // P2-10: the sensitive-app gate used to be applied to insertion only.
    // History, the debug log and the cloud reasoning upload each answered the
    // question themselves (or never asked it), so a password dictated into
    // 1Password was still written to SQLite whenever the user left "block
    // insertion" off. One SensitivityGate per session now feeds every sink.
    func testSensitiveGateHonouredAcrossAllSinks() async throws {
        // The test process is the target so the process-exists guard passes and
        // the sensitive-app decision is the only deciding branch.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let sensitiveTarget = TextInsertionTarget(
            processIdentifier: ownPID,
            bundleIdentifier: "com.agilebits.onepassword7",
            applicationName: "1Password"
        )
        let ordinaryTarget = TextInsertionTarget(
            processIdentifier: ownPID,
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit"
        )
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (200, Self.sseChatBody("POLISHED"))
        }

        // The leak the audit found: protection on, but the user allowed
        // insertion into the password manager, so nothing threw before the
        // history/log/cloud sinks ran.
        var settings = makeSettings()
        settings.sensitiveAppProtectionEnabled = true
        settings.sensitiveAppBlockInsertion = false
        settings.allowSensitiveAppCloudReasoning = false
        settings.useReasoningModel = true
        let leaky = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "secret"),
            capturedTarget: sensitiveTarget,
            logging: true,
            reasoningSession: makeStubbedReasoningSession()
        )
        await leaky.coordinator.start(settings: settings)
        let leakyRecording = await leaky.coordinator.snapshot()
        XCTAssertEqual(leakyRecording.phase, .recording)
        leaky.audio.emitFrame(rms: 0.02)
        await leaky.coordinator.stop()

        XCTAssertTrue(
            leaky.recorder.snapshots.contains { $0.phase == .completed },
            "Allowing insertion must still complete the session; only the sinks are gated"
        )
        let leakyRows = try await leaky.history.recent(limit: 10)
        XCTAssertTrue(
            leakyRows.isEmpty,
            "Pre-fix the password reached SQLite as soon as the insertion gate stopped throwing"
        )
        XCTAssertEqual(
            ReasoningStubURLProtocol.requests.count,
            0,
            "A sensitive transcript must never be uploaded to the reasoning provider"
        )
        let leakyLog = try logContents(leaky.logDirectory)
        XCTAssertFalse(leakyLog.contains("secret"), "The debug log must not carry a sensitive transcript")
        XCTAssertTrue(
            leakyLog.contains("sensitiveApp"),
            "The log sink must record that the gate closed, so the skip is auditable"
        )

        // The pre-existing insertion gate is unchanged: with the block policy on
        // the session fails with blockedSensitiveApplication and saves nothing.
        var blockingSettings = settings
        blockingSettings.sensitiveAppBlockInsertion = true
        let blocking = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "secret"),
            capturedTarget: sensitiveTarget,
            logging: true,
            reasoningSession: makeStubbedReasoningSession()
        )
        await blocking.coordinator.start(settings: blockingSettings)
        blocking.audio.emitFrame(rms: 0.02)
        await blocking.coordinator.stop()

        XCTAssertEqual(
            blocking.recorder.snapshots.first { $0.phase == .failed }?.errorMessage,
            TextInsertionError.blockedSensitiveApplication("1Password").localizedDescription
        )
        let blockedRows = try await blocking.history.recent(limit: 10)
        XCTAssertTrue(blockedRows.isEmpty)
        XCTAssertEqual(ReasoningStubURLProtocol.requests.count, 0)

        // Flip the decision: an ordinary app keeps every sink open.
        var ordinarySettings = settings
        ordinarySettings.useReasoningModel = false
        let ordinary = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "secret"),
            capturedTarget: ordinaryTarget,
            logging: true,
            reasoningSession: makeStubbedReasoningSession()
        )
        await ordinary.coordinator.start(settings: ordinarySettings)
        ordinary.audio.emitFrame(rms: 0.02)
        await ordinary.coordinator.stop()

        XCTAssertTrue(ordinary.recorder.snapshots.contains { $0.phase == .completed })
        let ordinaryRows = try await ordinary.history.recent(limit: 10)
        XCTAssertEqual(ordinaryRows.first?.text, "secret", "A non-sensitive app must still be persisted")
        XCTAssertEqual(ordinaryRows.first?.rawText, "secret")
        let ordinaryLog = try logContents(ordinary.logDirectory)
        XCTAssertFalse(
            ordinaryLog.contains("sensitiveApp"),
            "The gate marker must only appear for a protected session"
        )

        // …and the cloud sink is genuinely reachable, so the gate above is a
        // decision and not a blanket block. Only the upload is asserted here:
        // reasoning parks the session in .processing, whose completion handling
        // is out of this item's scope, so the run is cancelled afterwards.
        let cloud = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "secret"),
            capturedTarget: ordinaryTarget,
            reasoningSession: makeStubbedReasoningSession()
        )
        await cloud.coordinator.start(settings: settings)
        cloud.audio.emitFrame(rms: 0.02)
        await cloud.coordinator.stop()

        XCTAssertEqual(
            ReasoningStubURLProtocol.requests.count,
            1,
            "A non-sensitive transcript must still reach the reasoning provider"
        )
        XCTAssertEqual(ReasoningStubURLProtocol.requests.first?.url?.path, "/v1/chat/completions")
        await cloud.coordinator.cancel()
    }

    // P2-5: a non-streaming reasoning call that times out or errors must not
    // block finalize. `ReasoningService` pins `timeoutInterval = 30` on every
    // provider POST (the shared `jsonRequest` builder), and `stop()` wraps the
    // reasoning call so a throw routes to `finalText = <raw transcript>` with a
    // `capsule.polishingFallback` status — the session still completes, inserts,
    // and saves the RAW transcript. The reasoning stub returns HTTP 500 so
    // `ReasoningService.process` throws the way a timed-out / erroring provider
    // would; if the fallback catch regressed, the session would instead end
    // `.failed` with nothing saved.
    func testReasoningTimeoutFallsBackToRawTranscript() async throws {
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (500, #"{"error":"reasoning provider timed out"}"#)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let target = TextInsertionTarget(
            processIdentifier: ownPID,
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit"
        )
        let harness = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "hello raw world"),
            capturedTarget: target,
            reasoningSession: makeStubbedReasoningSession()
        )
        // Coordinator tests run without an Accessibility grant, so the real
        // insert() path throws at its AXIsProcessTrusted() guard. Stub insertion
        // (the P2-5 seam) and capture the delivered text to prove the RAW
        // transcript is what reached the target after the reasoning fallback.
        let probe = InsertionProbe()
        harness.insertion.insertOverride = { text, _, _ in probe.record(text) }

        var settings = makeSettings()
        settings.useReasoningModel = true // route finalize through the reasoning POST
        settings.automaticallyPasteTranscription = true // default; completion runs through inserting

        await harness.coordinator.start(settings: settings)
        let recordingPhase = await harness.coordinator.snapshot().phase
        XCTAssertEqual(recordingPhase, .recording)
        harness.audio.emitFrame(rms: 0.02)

        let startedAt = ContinuousClock.now
        await harness.coordinator.stop()
        XCTAssertLessThan(
            ContinuousClock.now - startedAt,
            .seconds(10),
            "A failing reasoning call must not block finalize"
        )

        XCTAssertEqual(
            ReasoningStubURLProtocol.requests.count,
            1,
            "The reasoning POST must actually be attempted so the throw path is exercised"
        )
        XCTAssertFalse(
            harness.recorder.snapshots.contains { $0.phase == .failed },
            "A reasoning failure must fall back to the raw transcript, not fail the session"
        )
        XCTAssertTrue(
            harness.recorder.snapshots.contains { $0.phase == .completed },
            "The session must still complete after the reasoning fallback"
        )
        XCTAssertEqual(
            probe.insertedText,
            "hello raw world",
            "The RAW transcript must be what gets inserted when reasoning fails"
        )
        let records = try await harness.history.recent(limit: 5)
        XCTAssertEqual(
            records.first?.text,
            "hello raw world",
            "History must store the raw transcript after the reasoning fallback"
        )
        XCTAssertEqual(records.first?.rawText, "hello raw world")
    }

    // Streaming: the OpenAI-compatible path now sends stream:true and reads an
    // SSE stream. Prove the parser concatenates multi-chunk deltas in order and
    // ignores both the include_usage terminator (empty choices) and [DONE].
    func testReasoningConcatenatesStreamedSSEDeltas() async throws {
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (200,
                "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n"
                    + "data: {\"choices\":[{\"delta\":{\"content\":\"世界\"}}]}\n\n"
                    + "data: {\"choices\":[],\"usage\":{\"completion_tokens\":2}}\n\n"
                    + "data: [DONE]\n\n")
        }
        let keychain = InMemoryCredentialStore(seed: [.openAI: "unit-test-reasoning-key"])
        let service = ReasoningService(keychain: keychain, session: makeStubbedReasoningSession())
        var settings = makeSettings()
        settings.useReasoningModel = true

        let result = try await service.process("原始文本", settings: settings, target: nil)

        XCTAssertEqual(result, "你好世界")
        XCTAssertEqual(ReasoningStubURLProtocol.requests.first?.url?.path, "/v1/chat/completions")
    }

    // The 8s reasoning deadline returns the value untouched when the call
    // finishes in time.
    func testReasoningWithTimeoutReturnsValueBeforeDeadline() async throws {
        let task = Task<String, Error> { "done" }
        let text = try await DictationCoordinator.reasoningWithTimeout(task, timeout: .seconds(5))
        XCTAssertEqual(text, "done")
    }

    // …and cancels the in-flight task and throws finalizeTimedOut once the
    // deadline passes, so stop() routes to the raw-transcript fallback instead
    // of stalling on a slow provider.
    func testReasoningWithTimeoutCancelsAndThrowsOnDeadline() async throws {
        let startedAt = ContinuousClock.now
        let task = Task<String, Error> {
            try await Task.sleep(for: .seconds(30))
            return "never"
        }
        do {
            _ = try await DictationCoordinator.reasoningWithTimeout(task, timeout: .milliseconds(100))
            XCTFail("The deadline must throw instead of returning")
        } catch {
            XCTAssertEqual(error as? DictationSessionError, .finalizeTimedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
        XCTAssertTrue(task.isCancelled)
    }

    // MARK: - Reliability audit regressions (2026-09-05 plan F1-F4)

    // F1: reasoning enabled + auto-paste off must still complete and save history.
    func testAuditReasoningWithoutAutoPasteCompletesAndSavesHistory() async throws {
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (200, Self.sseChatBody("cleaned transcript"))
        }
        let harness = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "raw transcript"),
            reasoningSession: makeStubbedReasoningSession()
        )
        var settings = makeSettings()
        settings.useReasoningModel = true
        settings.reasoningProvider = "openai"
        await harness.coordinator.start(settings: settings)
        harness.audio.emitFrame()
        await harness.coordinator.stop()
        let snapshot = await harness.coordinator.snapshot()
        let records = try await harness.history.recent(limit: 10)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        XCTAssertEqual(records.first?.text, "cleaned transcript")
        await harness.coordinator.cancel()
    }

    // F1 matrix cell: auto-paste ON but no captured target must behave like
    // paste-off — complete, save history, and honour keepTranscriptionInClipboard.
    // The pasteboard is snapshotted and restored so the test never pollutes the
    // user's real clipboard.
    func testReasoningPasteEnabledWithoutTargetCompletesAndCopiesToClipboard() async throws {
        let pasteboard = NSPasteboard.general
        let previousClipboard = pasteboard.string(forType: .string)
        addTeardownBlock {
            pasteboard.clearContents()
            if let previousClipboard { pasteboard.setString(previousClipboard, forType: .string) }
        }
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (200, Self.sseChatBody("cleaned transcript"))
        }
        let harness = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "raw transcript"),
            reasoningSession: makeStubbedReasoningSession()
        )
        // Force target capture to come back empty; otherwise the real frontmost
        // app becomes the target and the auto-paste branch runs for real.
        harness.insertion.capturedTargetOverride = { nil }
        var settings = makeSettings()
        settings.useReasoningModel = true
        settings.reasoningProvider = "openai"
        settings.automaticallyPasteTranscription = true
        settings.keepTranscriptionInClipboard = true
        await harness.coordinator.start(settings: settings)
        harness.audio.emitFrame()
        await harness.coordinator.stop()
        let snapshot = await harness.coordinator.snapshot()
        let records = try await harness.history.recent(limit: 10)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .completed })
        XCTAssertEqual(records.first?.text, "cleaned transcript")
        XCTAssertEqual(records.first?.rawText, "raw transcript")
        XCTAssertEqual(pasteboard.string(forType: .string), "cleaned transcript")
        await harness.coordinator.cancel()
    }

    // F2: a fatal provider .error with no partial must reset to idle after the
    // error display instead of deadlocking the event consumer on itself.
    func testAuditFatalProviderEventResetsAfterErrorDisplay() async throws {
        let provider = ScriptedRealtimeProvider(connect: .succeed)
        let harness = try await makeHarness(provider: provider)
        await harness.coordinator.start(settings: makeSettings())
        await provider.emit(.error("audit stream failure"))
        try await Task.sleep(for: .seconds(4))
        let snapshot = await harness.coordinator.snapshot()
        XCTAssertTrue(harness.recorder.snapshots.contains { $0.phase == .failed })
        XCTAssertEqual(snapshot.phase, .idle, "Error display lasts 2.4s; cleanup should have completed")
    }

    // F3: stream end-state matrix. Each body runs through the real SSE parser
    // on the stubbed session; outcomes follow the 2026-09-05 plan's completion
    // rules (error on sight, truncation rejected, EOF without a completion
    // signal rejected, explicit stop compatible without [DONE], extra choices
    // never merged, comments/heartbeats inert).
    func testReasoningStreamEndStateMatrix() async throws {
        func makeService() -> ReasoningService {
            ReasoningService(
                keychain: InMemoryCredentialStore(seed: [.openAI: "audit-test-key"]),
                session: makeStubbedReasoningSession()
            )
        }
        func stream(_ body: String) async throws -> String {
            ReasoningStubURLProtocol.reset()
            ReasoningStubURLProtocol.handler = { _ in (200, body) }
            var settings = makeSettings()
            settings.useReasoningModel = true
            settings.reasoningProvider = "openai"
            return try await makeService().process("原文", settings: settings, target: nil)
        }
        func expectFailure(_ name: String, _ body: String) async {
            do {
                let text = try await stream(body)
                XCTFail("\(name) was accepted as success: \(text)")
            } catch {
                XCTAssertTrue(error is ReasoningServiceError, "\(name) threw \(error)")
            }
        }
        addTeardownBlock { ReasoningStubURLProtocol.reset() }

        // Error as the very first event.
        await expectFailure(
            "first-event error",
            "data: {\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}\n\n"
        )
        // Partial content then EOF without [DONE] or a stop finish.
        await expectFailure(
            "EOF without completion signal",
            "data: {\"choices\":[{\"delta\":{\"content\":\"abc\"}}]}\n\n"
        )
        // Truncated (length) then [DONE] — the terminator must not wash it away.
        await expectFailure(
            "length finish before DONE",
            "data: {\"choices\":[{\"delta\":{\"content\":\"abc\"},\"finish_reason\":\"length\"}]}\n\n"
                + "data: [DONE]\n\n"
        )
        // Malformed business JSON must not silently succeed.
        await expectFailure(
            "malformed payload",
            "data: {not json}\n\n"
        )

        // Explicit stop without [DONE] is a compatible normal completion.
        var result = try await stream(
            "data: {\"choices\":[{\"delta\":{\"content\":\"abc\"},\"finish_reason\":\"stop\"}]}\n\n"
        )
        XCTAssertEqual(result, "abc")

        // Comments, heartbeats, and usage-only events carry no text.
        result = try await stream(
            ": heartbeat\n\n"
                + "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n"
                + "data: {\"choices\":[],\"usage\":{\"completion_tokens\":1}}\n\n"
                + "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\n"
                + "data: [DONE]\n\n"
        )
        XCTAssertEqual(result, "你好")

        // Only the first choice contributes content.
        result = try await stream(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"A\"}},"
                + "{\"index\":1,\"delta\":{\"content\":\"B\"}}]}\n\n"
                + "data: [DONE]\n\n"
        )
        XCTAssertEqual(result, "A")
    }

    // F4: cancelling the bounded wait (what cancel()/shutdown() hold via
    // reasoningTask) must propagate to the operation and surface as
    // CancellationError promptly — never as a raw-transcript fallback.
    func testReasoningWithTimeoutPropagatesCallerCancellation() async throws {
        let operation = Task<String, Error> {
            try await Task.sleep(for: .seconds(30))
            return "never"
        }
        let waiter = Task {
            try await DictationCoordinator.reasoningWithTimeout(operation, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let startedAt = ContinuousClock.now
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(5))
        XCTAssertTrue(operation.isCancelled)
    }

    // F4: cancelling mid-reasoning produces no output: no completed snapshot,
    // no history entry, no late fallback text, and the session ends idle.
    func testCancelDuringReasoningProducesNoOutput() async throws {
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            // Hold the reasoning response so cancel() lands mid-wait.
            Thread.sleep(forTimeInterval: 0.7)
            return (200, Self.sseChatBody("cleaned transcript"))
        }
        let harness = try await makeHarness(
            provider: ScriptedRealtimeProvider(connect: .succeed, finishText: "raw transcript"),
            reasoningSession: makeStubbedReasoningSession()
        )
        var settings = makeSettings()
        settings.useReasoningModel = true
        settings.reasoningProvider = "openai"
        await harness.coordinator.start(settings: settings)
        harness.audio.emitFrame()
        let stopTask = Task { await harness.coordinator.stop() }
        // Wait until the reasoning request is actually in flight (bounded).
        let deadline = ContinuousClock.now + .seconds(5)
        while ReasoningStubURLProtocol.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ReasoningStubURLProtocol.requests.count, 1)
        await harness.coordinator.cancel()
        await stopTask.value
        let snapshot = await harness.coordinator.snapshot()
        let records = try await harness.history.recent(limit: 10)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertFalse(harness.recorder.snapshots.contains { $0.phase == .completed })
        XCTAssertTrue(records.isEmpty)
    }

    // F4: the 8s reasoning deadline must not wait for an uncooperative task.
    func testAuditReasoningDeadlineDoesNotWaitForUncooperativeTask() async throws {
        let task = Task<String, Error> {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
                    continuation.resume(returning: "late result")
                }
            }
        }
        let startedAt = ContinuousClock.now
        do {
            _ = try await DictationCoordinator.reasoningWithTimeout(task, timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? DictationSessionError, .finalizeTimedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .milliseconds(300))
    }

    // F3: an in-stream SSE error after partial content must fail, not return
    // the partial prefix as a successful cleanup result.
    func testAuditReasoningRejectsStreamErrorAfterPartialContent() async throws {
        ReasoningStubURLProtocol.reset()
        addTeardownBlock { ReasoningStubURLProtocol.reset() }
        ReasoningStubURLProtocol.handler = { _ in
            (200,
                "data: {\"choices\":[{\"delta\":{\"content\":\"incomplete prefix\"}}]}\n\n"
                    + "data: {\"error\":{\"code\":\"server_error\",\"message\":\"stream failed\"}}\n\n")
        }
        let service = ReasoningService(
            keychain: InMemoryCredentialStore(seed: [.openAI: "audit-test-key"]),
            session: makeStubbedReasoningSession()
        )
        var settings = makeSettings()
        settings.useReasoningModel = true
        settings.reasoningProvider = "openai"
        do {
            let text = try await service.process("complete original transcript", settings: settings, target: nil)
            XCTFail("Stream error was accepted as success: \(text)")
        } catch {
            XCTAssertTrue(error is ReasoningServiceError)
        }
    }

    // MARK: - Harness

    // Minimal OpenAI-compatible SSE body: one content delta, the include_usage
    // terminator chunk (empty choices), then [DONE]. Content here is simple
    // enough that no JSON escaping is needed.
    static func sseChatBody(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n\n"
            + "data: {\"choices\":[],\"usage\":{\"completion_tokens\":1}}\n\n"
            + "data: [DONE]\n\n"
    }

    private struct Harness {
        let coordinator: DictationCoordinator
        let audio: StubAudioCapture
        let recorder: SnapshotRecorder
        let history: HistoryRepository
        let insertion: TextInsertionService
        let logDirectory: URL
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        // Bailian is realtime-only, so provider failures fail the session
        // instead of falling back to a batch upload.
        settings.cloudTranscriptionProvider = "bailian"
        settings.useLocalTranscription = false
        settings.useReasoningModel = false
        settings.translationEnabled = false
        settings.automaticallyPasteTranscription = false
        settings.keepTranscriptionInClipboard = false
        settings.pauseOtherMediaDuringDictation = false
        // The captured target is whatever app happens to be frontmost while
        // the suite runs; keep the sensitive-app guard out of these scenarios.
        settings.sensitiveAppProtectionEnabled = false
        return settings
    }

    private func makeHarness(
        provider: ScriptedRealtimeProvider,
        localRuntime: any LocalTranscriptionRuntime = LocalModelRuntime(),
        capturedTarget: TextInsertionTarget? = nil,
        logging: Bool = false,
        reasoningSession: URLSession = .shared
    ) async throws -> Harness {
        // P1-15: an in-memory CredentialStore seeded with the bailian key keeps
        // this harness off the real keychain entirely. Previously the harness
        // wrote to an isolated keychain service, which still hits the
        // SecurityAgent ACL prompt on fresh test-host signatures — on CI /
        // locked screens that prompt is impossible and every test in this
        // class silently XCTSkip'd. The coordinator is being exercised for its
        // orchestration, not its storage, so this seam is behaviourally
        // identical to a keychain hit that always returned "unit-test-key".
        let keychain = InMemoryCredentialStore(seed: [
            .bailian: "unit-test-key",
            .openAI: "unit-test-reasoning-key",
        ])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mouthpiece-Coordinator-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )

        let audio = StubAudioCapture()
        let recorder = SnapshotRecorder()
        let insertion = TextInsertionService()
        // P2-10: the frontmost app during a test run is arbitrary, so the
        // sensitive-app sinks are only coverable with a pinned target.
        if let capturedTarget { insertion.capturedTargetOverride = { capturedTarget } }
        let logDirectory = directory.appendingPathComponent("logs", isDirectory: true)
        let coordinator = DictationCoordinator(
            audio: audio,
            history: history,
            keychain: keychain,
            logger: DebugLogStore(enabled: logging, directory: logDirectory),
            insertion: insertion,
            capsule: CapsuleController(),
            localRuntime: localRuntime,
            reasoningService: ReasoningService(keychain: keychain, session: reasoningSession),
            realtimeProviderOverride: provider,
            onSnapshot: { recorder.append($0) }
        )
        return Harness(
            coordinator: coordinator,
            audio: audio,
            recorder: recorder,
            history: history,
            insertion: insertion,
            logDirectory: logDirectory
        )
    }

    // P2-10: every reasoning round-trip is counted, so the test can prove a
    // sensitive session uploads nothing while an ordinary one still reaches the
    // cloud cleanup.
    private func makeStubbedReasoningSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReasoningStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func logContents(_ directory: URL) throws -> String {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return try files
            .filter { $0.pathExtension == "log" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

@MainActor
private final class SnapshotRecorder {
    private(set) var snapshots: [DictationSnapshot] = []

    func append(_ snapshot: DictationSnapshot) { snapshots.append(snapshot) }
}

// P2-5: records the text delivered to the stubbed insertion path so the
// reasoning-fallback regression can prove the RAW transcript is what got
// inserted after the reasoning call threw.
@MainActor
private final class InsertionProbe {
    private(set) var insertedText: String?

    func record(_ text: String) { insertedText = text }
}

@MainActor
private final class StubAudioCapture: AudioCaptureService {
    private var frameSink: (@Sendable (Data, Double) -> Void)?

    override func requestPermission() async -> Bool { true }

    override func start(
        selectedDeviceUID: String?,
        onFrame: @escaping @Sendable (Data, Double) -> Void,
        onLevel: (@Sendable (Float) -> Void)?,
        onSessionInterrupted: (@Sendable () -> Void)?,
        onDiagnostics: (@Sendable (Int) -> Void)?
    ) async throws {
        // The stub replaces only the hardware edge: it keeps the frame sink so
        // tests can inject PCM frames. The interruption and diagnostics hooks
        // are accepted (signature parity with the A1/A3 production API) but
        // never fired, because no real device exists in unit tests.
        frameSink = onFrame
    }

    override func stop() async {
        frameSink = nil
    }

    func emitFrame(byteCount: Int = 640, rms: Double = 0.02) {
        frameSink?(Data(repeating: 0, count: byteCount), rms)
    }
}

private actor ScriptedRealtimeProvider: RealtimeTranscriptionProvider {
    enum ConnectBehavior {
        case succeed
        case fail(String)
    }

    private var connectBehavior: ConnectBehavior
    private let finishText: String
    private var onEvent: (@Sendable (RealtimeTranscriptionEvent) -> Void)?
    // A2: simulates a socket that dies mid-stream so send() throws; defaults
    // off so existing scenarios are unaffected.
    private var shouldFailSend = false
    // NEW-7: simulates a realtime finalize that dies (socket drop / timeout) so
    // finish() throws; nil by default so existing scenarios are unaffected.
    private var finishError: BailianRealtimeError?
    private(set) var sentFrameCount = 0
    private(set) var cancelCount = 0
    private(set) var finishCallCount = 0
    // Captured at the moment finish() is entered: proves whether every queued
    // frame was drained to the provider before finalization (B2).
    private(set) var sentFrameCountAtFinish: Int?
    private var finishBlocked = false
    private var finishGate: CheckedContinuation<Void, Never>?

    init(connect: ConnectBehavior, finishText: String = "") {
        connectBehavior = connect
        self.finishText = finishText
    }

    func setConnectBehavior(_ behavior: ConnectBehavior) {
        connectBehavior = behavior
    }

    func setShouldFailSend(_ value: Bool) {
        shouldFailSend = value
    }

    func setFinishError(_ error: BailianRealtimeError) {
        finishError = error
    }

    // Parks the next finish() call until releaseFinish(), so a test can hold
    // the coordinator in finalizing and inject events into that window.
    func blockFinish() {
        finishBlocked = true
    }

    func releaseFinish() {
        finishBlocked = false
        finishGate?.resume()
        finishGate = nil
    }

    func warmup(configuration: RealtimeTranscriptionConfiguration) async throws {}

    func connect(
        configuration: RealtimeTranscriptionConfiguration,
        onEvent: @escaping @Sendable (RealtimeTranscriptionEvent) -> Void
    ) async throws {
        switch connectBehavior {
        case .succeed:
            self.onEvent = onEvent
        case .fail(let message):
            throw BailianRealtimeError.protocolError(message)
        }
    }

    func send(pcm16: Data) async throws {
        if shouldFailSend {
            throw BailianRealtimeError.connectionLost("socket closed mid-stream")
        }
        sentFrameCount += 1
    }

    func finish() async throws -> String {
        finishCallCount += 1
        sentFrameCountAtFinish = sentFrameCount
        if finishBlocked {
            await withCheckedContinuation { continuation in
                finishGate = continuation
            }
        }
        if let finishError { throw finishError }
        return finishText
    }

    func cancel() async {
        cancelCount += 1
    }

    // Deliberately usable after cancel(): a real socket can deliver an
    // in-flight message after the session was abandoned.
    func emit(_ event: RealtimeTranscriptionEvent) {
        onEvent?(event)
    }
}

// P1-2: the local transcription edge is an out-of-process whisper server in
// production, so the realtime-only local fallback is only testable through the
// LocalTranscriptionRuntime seam.
private actor StubLocalRuntime: LocalTranscriptionRuntime {
    private let text: String
    private let installedStatus: LocalModelStatus
    private(set) var transcribeCallCount = 0
    private(set) var lastSettings: AppSettings?

    init(text: String, runtimeAvailable: Bool = true, modelAvailable: Bool = true) {
        self.text = text
        installedStatus = LocalModelStatus(
            runtimeAvailable: runtimeAvailable,
            modelAvailable: modelAvailable,
            running: false
        )
    }

    func status(provider: LocalTranscriptionProvider, model: String) -> LocalModelStatus {
        installedStatus
    }

    func transcribe(pcm16: Data, settings: AppSettings, prompt: String?) -> String {
        transcribeCallCount += 1
        lastSettings = settings
        return text
    }

    func stopAll() {}
}

// P2-10: counts every reasoning round-trip so the sensitive-app gate can be
// asserted against the real network seam instead of a behavioural proxy.
private final class ReasoningStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var requests: [URLRequest] {
        lock.withLock { capturedRequests }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            capturedRequests.removeAll()
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> (Int, String) in
            Self.capturedRequests.append(request)
            return Self.handler?(request) ?? (500, #"{"error":"missing handler"}"#)
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
