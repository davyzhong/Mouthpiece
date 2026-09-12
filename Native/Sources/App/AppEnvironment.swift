import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var settings = AppSettings()
    @Published private(set) var transcriptions: [TranscriptionRecord] = []
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var permissions = PermissionSnapshot(microphone: false, accessibility: false)
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var dictionaryWords: [String] = []
    @Published private(set) var selectedLocalModelInstalled = false
    @Published private(set) var modelInstallationState = ModelInstallationState.idle
    // P2-7: `startupError` is the FATAL channel — only the two genuine
    // init failures write it (a corrupted settings store in init(), the
    // initialize() catch), and the control panel / onboarding keep it on
    // screen until the user dismisses it. Every recoverable runtime
    // failure (history write, credential save, launch-at-login toggle,
    // hotkey re-registration after a permission refresh) now lands on
    // `operationError` instead, so a failed history delete can no longer
    // erase the startup diagnostic — and a startup error can no longer
    // hide an operation failure by occupying the only slot.
    @Published private(set) var startupError: String?
    @Published private(set) var operationError: String?
    // P2-14: `initialize()` used to set `isReady = true` on BOTH its
    // success and its failure tail, so an init that never built the
    // DictationCoordinator still reported a live app: the dictation UI
    // stayed armed and the hotkey path hit `guard let coordinator else
    // { return }` in complete silence, with no explanation and no way to
    // retry. The failure tail now leaves `isReady = false` and records the
    // reason here, which both keeps the P2-13 lifecycle guards
    // short-circuited and gives the control panel something actionable to
    // show. Non-nil implies `isReady == false`; `retryInitialize()` and
    // the success tail are the only clearers.
    @Published private(set) var degradedReason: String?
    // P2-14: Test seam. Counts launched initialization attempts (the one
    // from init(bootstrap:) plus every retryInitialize()), so the
    // regression test can prove a retry genuinely re-attempts instead of
    // only clearing the banner.
    private(set) var initializeAttemptCount = 0
    // P2-13: Test seam. Counts how many times the activation-observer
    // handler body has executed past the `isReady` guard. Regression
    // tests read this to deterministically confirm that a pre-init
    // activation event short-circuits before mutating any state —
    // independent of the host's audio devices or granted permissions.
    private(set) var recoverSystemIntegrationsInvocationCount = 0

    // P2-6: The ~50 Hz dictation state (phase / partial transcript /
    // audio level) lives here, on its own ObservableObject, so only the
    // capsule/HUD side subscribes to the per-frame stream. Deliberately a
    // plain `let` and NOT `@Published`: publishing the reference would
    // forward every inner change to AppEnvironment's own
    // `objectWillChange` and put the whole control panel back on the 50 Hz
    // invalidation path this split exists to remove.
    let session = DictationSessionModel()
    let settingsRepository: SettingsRepository
    let keychain = KeychainStore()
    let audio = AudioCaptureService()
    let audioCues = AudioCueService()
    let permissionsService = PermissionService()
    let insertion = TextInsertionService()
    let learning = CorrectionLearningController()
    let correctionHotkey = HotkeyService()
    let capsule = CapsuleController()
    let hotkey = HotkeyService()
    let translationHotkey = HotkeyService(swallowMatchedEvents: true)
    let escapeHotkey = HotkeyService(swallowMatchedEvents: true)
    let modelInstaller = LocalModelInstallationService()
    let updates = UpdateController()

    private var history: HistoryRepository?
    private var logger: DebugLogStore?
    private var coordinator: DictationCoordinator?
    private var hotkeyPressedAt: ContinuousClock.Instant?
    private var pendingMainHotkeyTask: Task<Void, Never>?
    private var mainHotkeyActivationPending = false
    private var toggleDictationObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var escapeLocalMonitor: Any?
    private var activeActivation: DictationActivation = .main
    private var isShuttingDown = false
    private var localModelStatusRequest = 0
    private var dictionarySaveRevision = 0
    private var dictionarySaveTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    // P2-14: guards `startInitialization()` so a second Retry click (or a
    // retry racing the bootstrap attempt) cannot run two initializations
    // against the same coordinator/history slots.
    private var isInitializing = false
    private var localModelOperationTask: Task<Void, Never>?
    private static let historyPageSize = 200
    private var historyQuery = ""
    private var historyLoadRevision = 0

    init(bootstrap: Bool = true, autoMarkReady: Bool = true, settingsRepository: SettingsRepository? = nil) {
        self.settingsRepository = settingsRepository ?? SettingsRepository()
        if self.settingsRepository.loadFailed {
            reportStartupFailure(SettingsRepositoryError.corruptedStore.localizedDescription)
        }
        toggleDictationObserver = NotificationCenter.default.addObserver(
            forName: .mouthpieceToggleDictation,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggleDictation() }
        }
        registerLifecycleObservers()
        AppDelegate.shutdownHandler = { [weak self] in
            await self?.shutdown()
        }
        if bootstrap {
            startInitialization()
        } else if autoMarkReady {
            // P2-13: existing `bootstrap: false` callers (production
            // never uses it; tests such as `testEnvironmentStartsReady`
            // depend on it) keep the previous isReady = true semantics.
            // Passing `autoMarkReady: false` lets a regression test hold
            // the environment at isReady = false to simulate a pre-init
            // activation window.
            isReady = true
        }
    }

    func saveSettings(_ next: AppSettings) {
        do {
            let previous = settings
            settings = try settingsRepository.update { $0 = next }
            learning.settings = settings
            updateCorrectionHotkey()
            let changes = RuntimeSettingsChanges(previous: previous, current: settings)
            if changes.debugLogging {
                synchronizeDebugLogging(settings.debugLoggingEnabled)
            }
            if changes.hotkeys {
                cancelPendingMainHotkey()
                updateHotkeyRegistrations()
            }
            if changes.systemIntegrations { applySystemSettings() }
            if changes.localModel { refreshLocalModelStatus() }
        } catch {
            report(error)
        }
    }

    func refreshHistory() {
        // P2-21: `[weak self]` prevents the fire-and-forget Task from
        // strongly retaining the environment past `shutdown()`. If the
        // environment has been released by the time the closure runs,
        // both `self?.reloadHistory()` and the error branch turn into
        // no-ops via optional-chaining.
        Task { [weak self] in
            do {
                try await self?.reloadHistory()
            } catch {
                self?.report(error)
            }
        }
    }

    func searchHistory(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != historyQuery else { return }
        historyQuery = clean
        refreshHistory()
    }

    func loadMoreHistory() {
        guard let history, hasMoreHistory else { return }
        historyLoadRevision += 1
        let revision = historyLoadRevision
        let query = historyQuery
        let offset = transcriptions.count
        // P2-21: `[weak self]` keeps the closure from strongly retaining
        // the environment across the DB fetch — a stalled SQLite call
        // used to pin the AppEnvironment alive past `shutdown()`. The
        // post-await `guard let self` re-strengthens only to write the
        // page in; the error branch stays weak so it silently drops on
        // a released environment.
        Task { [weak self] in
            do {
                let page = try await Self.fetchHistoryPage(history: history, query: query, offset: offset)
                guard let self, revision == self.historyLoadRevision else { return }
                self.transcriptions += page
                self.hasMoreHistory = page.count == Self.historyPageSize
            } catch {
                self?.report(error)
            }
        }
    }

    func clearHistory() {
        // P2-21: `[weak self]` keeps the closure from retaining the
        // environment past `shutdown()`; the actor-isolated
        // `history.clear()` still commits on its own actor even if the
        // environment is released mid-write, and the reload/error
        // branches then no-op through `self?`.
        Task { [weak self] in
            do {
                guard let history = self?.history else { return }
                try await history.clear()
                try await self?.reloadHistory()
                await self?.learning.refresh()
            } catch {
                self?.report(error)
            }
        }
    }

    func deleteTranscription(_ id: Int64) {
        // P2-21: same weak-self rationale as `clearHistory()`.
        Task { [weak self] in
            do {
                guard let history = self?.history else { return }
                try await history.delete(id: id)
                try await self?.reloadHistory()
                await self?.learning.refresh()
            } catch {
                self?.report(error)
            }
        }
    }

    func restoreTranscription(_ record: TranscriptionRecord) {
        // P2-21: same weak-self rationale as `clearHistory()`.
        Task { [weak self] in
            do {
                guard let history = self?.history else { return }
                try await history.restore(record)
                try await self?.reloadHistory()
            } catch {
                self?.report(error)
            }
        }
    }

    func saveDictionary(_ words: [String]) {
        var next = settings
        next.terminologyProfile.preferredTerms = words
        next.normalize()
        let normalizedWords = next.terminologyProfile.preferredTerms
        saveSettings(next)
        guard settings.terminologyProfile.preferredTerms == normalizedWords else { return }
        dictionaryWords = normalizedWords

        dictionarySaveRevision += 1
        let revision = dictionarySaveRevision
        let previousSave = dictionarySaveTask
        dictionarySaveTask = Task { [weak self] in
            await previousSave?.value
            guard let self else { return }
            defer {
                if revision == self.dictionarySaveRevision {
                    self.dictionarySaveTask = nil
                }
            }
            guard let history = self.history else { return }
            do {
                try await history.replaceDictionary(normalizedWords)
            } catch {
                guard revision == self.dictionarySaveRevision else { return }
                self.report(error)
            }
        }
    }

    func credential(_ account: CredentialAccount) async throws -> String {
        try await keychain.read(account) ?? ""
    }

    func saveCredential(_ value: String, account: CredentialAccount) async throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try await keychain.delete(account)
        } else {
            try await keychain.write(clean, for: account)
        }
    }

    func requestMicrophonePermission() {
        // P2-21: The TCC prompt suspends for as long as the user takes
        // to answer, so `[weak self]` is required to prevent that wait
        // from pinning the environment alive past `shutdown()`. The
        // service itself is captured directly so the request still
        // completes; `self?.refreshPermissions()` no-ops on a released
        // environment.
        Task { [weak self, permissionsService] in
            _ = await permissionsService.requestMicrophone()
            self?.refreshPermissions()
        }
    }

    func requestAccessibilityPermission() {
        permissionsService.requestAccessibility(language: settings.uiLanguage) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func openMicrophoneSettings() { permissionsService.openMicrophoneSettings() }
    func openAccessibilitySettings() { permissionsService.openAccessibilitySettings() }

    func refreshPermissions() {
        permissions = permissionsService.current()
        updateHotkeyRegistrations()
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        // P3-5: SettingsRepository.save() debounces the UserDefaults write, so
        // the very last user mutation (a slider dragged moments before quit,
        // a checkbox toggle right before Cmd+Q) can still sit in memory when
        // shutdown fires. Flushing first — before any awaits — persists the
        // pending blob synchronously so it survives termination.
        settingsRepository.flush()
        correctionHotkey.stop()
        await learning.shutdown()
        // P2-14: a quick Cmd+Q used to reach `coordinator.shutdown()` below,
        // which cancels the frame task, resets the state machine and drops
        // the retained PCM — the sentence the user was still speaking
        // vanished with no history row and no insertion. Give a live
        // session the real stop() path (finalize -> insert -> history
        // write) first, but strictly time-boxed: quitting must not hang on
        // a half-dead provider socket. The clipboard restore is flushed
        // AFTER that, because stop()'s insertion is what registers it.
        if let coordinator, session.phase.isActive {
            let stopTask = Task { await coordinator.stop() }
            await Self.awaitStopWithTimeout(stopTask)
        }
        insertion.flushPendingRestore()
        initializationTask?.cancel()
        hotkey.stop()
        translationHotkey.stop()
        escapeHotkey.stop()
        stopEscapeLocalMonitor()
        removeLifecycleObservers()
        cancelPendingMainHotkey()
        hotkeyPressedAt = nil
        localModelOperationTask?.cancel()
        await initializationTask?.value
        initializationTask = nil
        await localModelOperationTask?.value
        localModelOperationTask = nil
        await dictionarySaveTask?.value
        await coordinator?.shutdown()
        await logger?.write(.info, "Application shutdown completed")
    }

    func completeOnboarding() {
        var next = settings
        next.onboardingCompleted = true
        saveSettings(next)
        updateHotkeyRegistrations()
    }

    // P2-7: the sole writer of the fatal channel — called by init()'s
    // corrupted-store branch and initialize()'s catch. Internal (not
    // private) so `testOperationErrorDoesNotOverwriteStartupError` can
    // seed the exact state those two paths produce without corrupting the
    // real UserDefaults settings store.
    func reportStartupFailure(_ message: String) { startupError = message }

    // P2-14: initialize()'s failure tail. Still writes the fatal channel so
    // the existing alert/banner fires unchanged, and additionally holds the
    // app in the degraded state: `isReady = false` keeps every P2-13
    // lifecycle guard (toggleDictation / recoverSystemIntegrations /
    // prepareForSleep) short-circuited instead of driving a nil
    // coordinator, and `degradedReason` gives the control panel the text
    // plus the Retry affordance. Internal (not private) so the regression
    // test can seed exactly this state without having to break the host's
    // Application Support directory or SQLite — the same rationale as
    // P2-7's reportStartupFailure, and the same real production writer.
    func reportInitializationFailure(_ error: Error) {
        let reason = error.localizedDescription
        reportStartupFailure(reason)
        isReady = false
        degradedReason = reason
    }

    // P2-14: the degraded state's only exit. Clears the banner state first
    // (a second failure re-arms it) and then re-runs the very same
    // initialization path used at startup; `startInitialization()`'s
    // `isInitializing` guard makes a double-click a no-op.
    func retryInitialize() {
        guard !isInitializing, !isShuttingDown else { return }
        degradedReason = nil
        dismissStartupError()
        startInitialization()
    }

    // P2-7: transient channel. Recoverable runtime failures land here and
    // are shown as an auto-dismissing toast, so they neither overwrite nor
    // get blocked by a fatal `startupError`.
    func report(_ error: Error) { operationError = error.localizedDescription }

    func dismissStartupError() { startupError = nil }
    func dismissOperationError() { operationError = nil }
    func checkForUpdates() { updates.checkForUpdates() }

    func suspendHotkeysForCapture() {
        cancelPendingMainHotkey()
        hotkey.stop()
        translationHotkey.stop()
        escapeHotkey.stop()
        stopEscapeLocalMonitor()
    }

    func resumeHotkeysAfterCapture() {
        updateHotkeyRegistrations()
    }

    func refreshLocalModelStatus() {
        let provider = settings.localTranscriptionProvider
        let model = selectedLocalModelID
        localModelStatusRequest += 1
        let request = localModelStatusRequest
        selectedLocalModelInstalled = false
        if localModelOperationTask == nil,
           modelInstallationState.modelID != nil,
           modelInstallationState.modelID != model {
            modelInstallationState = .idle
        }
        // P2-21: `[weak self]` prevents the fire-and-forget lookup from
        // keeping the environment alive past `shutdown()`. The installer
        // is captured directly so the async probe still runs; the
        // post-await request-vs-current guard requires `self` and the
        // mutation is skipped cleanly if the environment was released
        // while the check was in flight.
        Task { [weak self, modelInstaller] in
            let installed = await modelInstaller.isInstalled(provider: provider, model: model)
            guard let self,
                  request == self.localModelStatusRequest,
                  provider == self.settings.localTranscriptionProvider,
                  model == self.selectedLocalModelID else { return }
            self.selectedLocalModelInstalled = installed
        }
    }

    func installSelectedLocalModel() {
        guard localModelOperationTask == nil else { return }
        let provider = settings.localTranscriptionProvider
        let model = selectedLocalModelID
        localModelOperationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishLocalModelOperation() }
            do {
                try await modelInstaller.install(provider: provider, model: model) { [weak self] state in
                    Task { @MainActor in
                        guard let self,
                              provider == self.settings.localTranscriptionProvider,
                              model == self.selectedLocalModelID else { return }
                        self.modelInstallationState = state
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard provider == settings.localTranscriptionProvider,
                      model == selectedLocalModelID else { return }
                modelInstallationState = .failed(model: model, message: error.localizedDescription)
            }
        }
    }

    func removeSelectedLocalModel() {
        guard localModelOperationTask == nil else { return }
        let provider = settings.localTranscriptionProvider
        let model = selectedLocalModelID
        localModelOperationTask = Task { [weak self] in
            guard let self else { return }
            defer { finishLocalModelOperation() }
            do {
                try await modelInstaller.remove(provider: provider, model: model)
                guard provider == settings.localTranscriptionProvider,
                      model == selectedLocalModelID else { return }
                modelInstallationState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                guard provider == settings.localTranscriptionProvider,
                      model == selectedLocalModelID else { return }
                modelInstallationState = .failed(model: model, message: error.localizedDescription)
            }
        }
    }

    private func finishLocalModelOperation() {
        localModelOperationTask = nil
        guard !isShuttingDown else { return }
        if modelInstallationState.modelID != nil,
           modelInstallationState.modelID != selectedLocalModelID {
            modelInstallationState = .idle
        }
        refreshLocalModelStatus()
    }

    func startDictation(translation: Bool = false) {
        guard let coordinator else { return }
        activeActivation = translation ? .translation : .main
        if settings.audioCuesEnabled { audioCues.playStart(preset: settings.soundPreset) }
        var sessionSettings = settings
        sessionSettings.translationEnabled = translation
        Task { await coordinator.start(settings: sessionSettings) }
    }

    func stopDictation() {
        guard let coordinator else { return }
        if settings.audioCuesEnabled { audioCues.playStop(preset: settings.soundPreset) }
        // P2-21: `[weak self]` prevents a stalled `coordinator.stop()`
        // from keeping the environment alive past `shutdown()`. The
        // local `coordinator` is captured strongly so its own actor
        // still drives the stop; the history refresh no-ops via
        // `self?` if the environment has been released.
        Task { [weak self] in
            await coordinator.stop()
            self?.refreshHistory()
        }
    }

    func cancelDictation() {
        guard let coordinator else { return }
        if settings.audioCuesEnabled { audioCues.playStop(preset: settings.soundPreset) }
        Task { await coordinator.cancel() }
    }

    // P2-14: the single place an initialization attempt is launched —
    // init(bootstrap:) at startup and retryInitialize() from the degraded
    // control panel — so both share one re-entrancy guard and one counter.
    private func startInitialization() {
        guard !isInitializing, !isShuttingDown else { return }
        isInitializing = true
        initializeAttemptCount += 1
        initializationTask = Task { [weak self] in
            await self?.initialize()
        }
    }

    private func initialize() async {
        defer { isInitializing = false }
        do {
            try ensureInitializationCanContinue()
            try AppPaths.prepareApplicationSupport()
            settings = settingsRepository.load()
            learning.settings = settings
            let history = try HistoryRepository()
            self.history = history
            let learningReasoning = ReasoningService(keychain: keychain)
            do {
                try await learning.configure(history: history) { samples, excluded, settings in
                    try await learningReasoning.extractCorrectionTerms(samples: samples, excludedTerms: excluded, settings: settings)
                }
            } catch { report(error) }
            let logger = DebugLogStore(enabled: settings.debugLoggingEnabled)
            self.logger = logger
            try? await logger.prune()
            try ensureInitializationCanContinue()
            // F1: 启动打开库后执行一次历史保留清理；失败仅记日志，不阻断初始化。
            do {
                let pruned = try await history.prune()
                if pruned > 0 { await logger.write(.info, "History prune removed \(pruned) records") }
            } catch {
                await logger.write(.warning, "History prune failed: \(error.localizedDescription)")
            }
            try ensureInitializationCanContinue()
            try await reloadHistory()
            try ensureInitializationCanContinue()
            let storedDictionary = try await history.dictionary()
            try ensureInitializationCanContinue()
            dictionaryWords = settings.terminologyProfile.preferredTerms
            if storedDictionary != dictionaryWords {
                try await history.replaceDictionary(dictionaryWords)
                try ensureInitializationCanContinue()
            }
            microphones = audio.availableInputDevices()
            permissions = permissionsService.current()

            let coordinator = DictationCoordinator(
                audio: audio,
                history: history,
                keychain: keychain,
                logger: logger,
                insertion: insertion,
                capsule: capsule,
                onTranscriptionSaved: { [weak self] record, target, before in
                    guard let self, !self.isShuttingDown else { return }
                    self.learning.receive(record, target: target, before: before)
                }
            ) { [weak self] snapshot in
                // P2-6: the ~50 Hz write site. Writing the snapshot into
                // `session` (its own ObservableObject) keeps the per-frame
                // level/partial stream off AppEnvironment's publisher; the
                // coarse follow-up below stays here because it only fires on
                // real phase/session transitions.
                self?.session.apply(snapshot)
                self?.learning.isDictating = snapshot.phase.isActive
                self?.escapeHotkey.setSwallowArmed(snapshot.phase.isActive)
            }
            self.coordinator = coordinator
            hotkey.onPress = { [weak self] in self?.handleHotkeyPress() }
            correctionHotkey.onPress = { [weak self] in self?.learning.captureSelectedCorrection() }
            hotkey.onRelease = { [weak self] in self?.handleHotkeyRelease() }
            escapeHotkey.onPress = { [weak self] in self?.handleEscape(53) }
            escapeHotkey.setSwallowArmed(false)
            translationHotkey.onPress = { [weak self] in self?.handleTranslationHotkeyPress() }
            // 翻译热键只应在主听写键按住期间吞键，闲置时放行全局组合键。
            translationHotkey.setSwallowArmed(false)
            updateHotkeyRegistrations()
            applySystemSettings()
            refreshLocalModelStatus()
            degradedReason = nil
            isReady = true
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            // P2-14: pre-fix this tail also ran `isReady = true`, so a
            // half-initialised app (no coordinator, no hotkey callbacks)
            // presented itself as fully live.
            reportInitializationFailure(error)
        }
    }

    private func ensureInitializationCanContinue() throws {
        try Task.checkCancellation()
        if isShuttingDown { throw CancellationError() }
    }

    private func reloadHistory() async throws {
        guard let history else { return }
        historyLoadRevision += 1
        let revision = historyLoadRevision
        let query = historyQuery
        let page = try await Self.fetchHistoryPage(history: history, query: query, offset: 0)
        guard revision == historyLoadRevision else { return }
        transcriptions = page
        hasMoreHistory = page.count == Self.historyPageSize
    }

    private static func fetchHistoryPage(
        history: HistoryRepository,
        query: String,
        offset: Int
    ) async throws -> [TranscriptionRecord] {
        query.isEmpty
            ? try await history.recent(limit: historyPageSize, offset: offset)
            : try await history.search(query: query, limit: historyPageSize, offset: offset)
    }

    private var selectedLocalModelID: String {
        switch settings.localTranscriptionProvider {
        case .whisper: settings.whisperModel
        case .parakeet: settings.parakeetModel.isEmpty ? "parakeet-tdt-0.6b-v3" : settings.parakeetModel
        case .qwen: settings.qwenASRModel
        }
    }

    private func applySystemSettings() {
        applyActivationPolicy(settings.showInDock ? .regular : .accessory)
        capsule.setLanguage(settings.uiLanguage)
        NotificationCenter.default.post(
            name: .mouthpieceRuntimeSettingsChanged,
            object: nil,
            userInfo: [
                "language": settings.uiLanguage.rawValue,
                "showInMenuBar": settings.showInMenuBar,
                "showInDock": settings.showInDock,
            ]
        )
        do {
            switch LaunchAtLoginAction.resolve(
                enabled: settings.launchAtLogin,
                status: SMAppService.mainApp.status
            ) {
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            case .none:
                break
            }
        } catch {
            report(error)
        }
    }

    private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        // Switching to .accessory deactivates the app, dropping the control
        // panel behind the previously frontmost app; restore activation when
        // the app was active before the switch.
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(policy)
        guard wasActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func synchronizeDebugLogging(_ enabled: Bool) {
        Task { [weak self] in
            guard let self, self.settings.debugLoggingEnabled == enabled else { return }
            await self.logger?.setEnabled(enabled)
        }
    }

    private func toggleDictation() {
        // P2-13: The mouthpieceToggleDictation observer is registered
        // in init() before the async initialize() finishes wiring the
        // coordinator and hotkey callbacks. A menu-bar toggle-dictation
        // click that arrives during that window must not race the
        // half-initialised state — short-circuit until isReady is set
        // at the tail of initialize().
        guard isReady else { return }
        session.phase.isActive ? stopDictation() : startDictation(translation: false)
    }

    private func handleHotkeyPress() {
        hotkeyPressedAt = .now
        // 主键按下期间才允许翻译后缀组合被吞掉，见 updateTranslationHotkey。
        translationHotkey.setSwallowArmed(true)
        guard effectiveTranslationHotkey != nil, settings.translationEnabled else {
            performMainHotkeyPress()
            return
        }

        cancelPendingMainHotkey(resetPressTime: false)
        mainHotkeyActivationPending = true
        pendingMainHotkeyTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            // A suffix press can cancel this task after the sleep already
            // resumed; without this check the main press still fires and
            // races the translation restart for the session slot.
            guard let self, !Task.isCancelled else { return }
            self.mainHotkeyActivationPending = false
            self.pendingMainHotkeyTask = nil
            self.performMainHotkeyPress()
        }
    }

    private func performMainHotkeyPress() {
        switch settings.hotkeyBehavior {
        case .toggle:
            session.phase.isActive ? stopDictation() : startDictation(translation: false)
        case .pushToTalk:
            if !session.phase.isActive { startDictation(translation: false) }
        case .automatic:
            session.phase.isActive ? stopDictation() : startDictation(translation: false)
        }
    }

    private func handleHotkeyRelease() {
        // 主键松开后恢复放行翻译组合键，避免闲置时吞掉全局 Cmd+, 等按键。
        translationHotkey.setSwallowArmed(false)
        let shouldCompletePendingPress = mainHotkeyActivationPending
        cancelPendingMainHotkey(resetPressTime: false)
        if shouldCompletePendingPress {
            performMainHotkeyPress()
        }
        performMainHotkeyRelease()
    }

    private func performMainHotkeyRelease() {
        defer { hotkeyPressedAt = nil }
        guard activeActivation == .main else { return }
        switch settings.hotkeyBehavior {
        case .pushToTalk:
            stopDictation()
        case .automatic:
            guard let hotkeyPressedAt else { return }
            if hotkeyPressedAt.duration(to: .now) >= .milliseconds(450) {
                stopDictation()
            }
        case .toggle:
            break
        }
    }

    private func handleTranslationHotkeyPress() {
        guard settings.translationEnabled, effectiveTranslationHotkey != nil,
              let coordinator else { return }
        guard hotkeyPressedAt != nil else {
            Task { [logger] in
                await logger?.write(.debug, "Translation hotkey ignored: main key not held")
            }
            return
        }
        cancelPendingMainHotkey(resetPressTime: false)
        if session.phase.isActive, activeActivation == .translation {
            stopDictation()
            return
        }
        activeActivation = .translation
        if settings.audioCuesEnabled { audioCues.playStart(preset: settings.soundPreset) }
        var sessionSettings = settings
        sessionSettings.translationEnabled = true
        Task { [weak self] in
            // The coordinator decides cancel-vs-start against its real state;
            // the @Published snapshot read here lags the actor, and racing the
            // main hotkey used to skip the cancel and leave the activation
            // owner pointing at a session that never switched.
            let started = await coordinator.restartForTranslation(settings: sessionSettings)
            guard let self, !started else { return }
            // The translation session did not take effect (start failed);
            // hand the activation back so push-to-talk release still stops
            // whatever is running.
            self.activeActivation = .main
        }
    }

    private func updateHotkeyRegistrations() {
        updateCorrectionHotkey()
        updateEscapeHotkey()
        guard settings.onboardingCompleted, permissions.accessibility else {
            hotkey.stop()
            translationHotkey.stop()
            return
        }

        do {
            try hotkey.update(key: settings.dictationKey)
        } catch {
            hotkey.stop()
            translationHotkey.stop()
            report(error)
            return
        }
        updateTranslationHotkey()
    }

    private func updateCorrectionHotkey() {
        guard !isShuttingDown, settings.onboardingCompleted, permissions.accessibility,
              settings.correctionLearningEnabled else {
            correctionHotkey.stop()
            return
        }
        do { try correctionHotkey.update(key: "Command+Option+Shift+L") }
        catch { report(error) }
    }

    private func updateTranslationHotkey() {
        guard permissions.accessibility,
              settings.translationEnabled,
              let key = effectiveTranslationHotkey else {
            translationHotkey.stop()
            return
        }
        do {
            try translationHotkey.update(key: key)
            // 新建的 tap 默认吞键；仅当主听写键正按住时才保持吞键。
            translationHotkey.setSwallowArmed(hotkeyPressedAt != nil)
        } catch {
            translationHotkey.stop()
            report(error)
        }
    }

    nonisolated static func shouldCancelForEscape(keyCode: UInt16, enabled: Bool, isActive: Bool) -> Bool {
        keyCode == 53 && enabled && isActive
    }

    private func updateEscapeHotkey() {
        stopEscapeLocalMonitor()
        guard settings.escapeCancelsRecording else {
            escapeHotkey.stop()
            return
        }
        guard permissions.accessibility else {
            escapeHotkey.stop()
            installEscapeLocalMonitor()
            return
        }
        do {
            try escapeHotkey.update(key: "Escape")
        } catch {
            escapeHotkey.stop()
            report(error)
            installEscapeLocalMonitor()
        }
    }

    private func installEscapeLocalMonitor() {
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            Task { @MainActor in self?.handleEscape(keyCode) }
            return event
        })
    }

    private func stopEscapeLocalMonitor() {
        guard let escapeLocalMonitor else { return }
        NSEvent.removeMonitor(escapeLocalMonitor)
        self.escapeLocalMonitor = nil
    }

    private func handleEscape(_ keyCode: UInt16) {
        guard Self.shouldCancelForEscape(
            keyCode: keyCode,
            enabled: settings.escapeCancelsRecording,
            isActive: session.phase.isActive
        ) else { return }
        cancelPendingMainHotkey()
        // P2-21: match the translation-hotkey log site's `[logger]`
        // capture so the fire-and-forget debug write does not retain
        // the environment past `shutdown()`.
        Task { [logger] in await logger?.write(.debug, "Escape cancellation requested") }
        cancelDictation()
    }

    private var effectiveTranslationHotkey: String? {
        TranslationHotkey.combination(
            dictationKey: settings.dictationKey,
            suffix: settings.translationHotkeySuffix
        )
    }

    private func cancelPendingMainHotkey(resetPressTime: Bool = true) {
        pendingMainHotkeyTask?.cancel()
        pendingMainHotkeyTask = nil
        mainHotkeyActivationPending = false
        if resetPressTime { hotkeyPressedAt = nil }
    }

    private func registerLifecycleObservers() {
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recoverSystemIntegrations() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.prepareForSleep() }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.recoverSystemIntegrations()
            }
        })
    }

    private func removeLifecycleObservers() {
        if let toggleDictationObserver {
            NotificationCenter.default.removeObserver(toggleDictationObserver)
            self.toggleDictationObserver = nil
        }
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func prepareForSleep() async {
        // P2-13: The willSleep observer is registered in init() before
        // the async initialize() finishes. A sleep notification during
        // that window must not tear down hotkey taps that were never
        // started or await a nil coordinator — short-circuit until
        // initialize() sets isReady.
        guard isReady else { return }
        cancelPendingMainHotkey()
        hotkey.stop()
        translationHotkey.stop()
        escapeHotkey.stop()
        stopEscapeLocalMonitor()
        hotkeyPressedAt = nil
        await coordinator?.shutdown()
    }

    // P2-13: `internal` (not `private`) so the regression test
    // `testActivationBeforeInitializeDoesNotArmSwallowing` can invoke
    // the handler directly to simulate a pre-init NSApplication /
    // NSWorkspace activation event.
    func recoverSystemIntegrations() {
        // P2-13: didBecomeActive and didWake observers are registered
        // in init() before the async initialize() finishes wiring the
        // coordinator, hotkey onPress/onRelease callbacks, and the
        // explicit `translationHotkey/escapeHotkey.setSwallowArmed(false)`
        // resets. Without this guard a notification arriving during the
        // init window would run refreshPermissions() ->
        // updateHotkeyRegistrations() which starts CGEventTap hotkeys
        // whose HotkeyService.swallowArmed still defaults to `true`,
        // swallowing user keystrokes with no handler wired. Return early
        // until initialize() sets isReady at its own tail.
        guard isReady, !isShuttingDown else { return }
        recoverSystemIntegrationsInvocationCount += 1
        microphones = audio.availableInputDevices()
        refreshPermissions()
        capsule.repositionIfVisible()
    }
}

// MARK: - Bounded quit-time flush (P2-14)

private extension AppEnvironment {
    // Bounded variant of `await coordinator.stop()` for `shutdown()`.
    // stop() finalizes through the network (bounded at 8 s by the
    // coordinator's own finishWithTimeout), reasoning, insertion and the
    // history write, but a socket that never answers and ignores
    // cancellation would otherwise park the quit sequence forever with the
    // user staring at a beach ball — `applicationShouldTerminate` already
    // returned `.terminateLater` and only replies after this returns. Race
    // the stop against a watchdog so the first winner resumes the
    // continuation even when the loser refuses to unwind (a `withTaskGroup`
    // variant would still block on the group's implicit join). This mirrors
    // DictationCoordinator's P2-2 `awaitDrainWithTimeout` shape, which
    // lives in a fileprivate extension there and so cannot be called from
    // this file. Losing an unfinishable tail beats blocking quit; dropping
    // the whole recording — the pre-fix behavior — is worse than both.
    nonisolated static func awaitStopWithTimeout(
        _ stopTask: Task<Void, Never>,
        timeout: Duration = .seconds(3)
    ) async {
        let gate = ShutdownClaimGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await stopTask.value
                if gate.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.claim() {
                    stopTask.cancel()
                    continuation.resume()
                }
            }
        }
    }
}

// Single-winner gate for the racer above: exactly one of the two branches
// may resume the continuation. Same contract as DictationCoordinator's
// ClaimGate (P2-2/P2-4), duplicated here only because that one is nested
// and private to the coordinator.
private final class ShutdownClaimGate: @unchecked Sendable {
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

private enum DictationActivation {
    case main
    case translation
}

enum LaunchAtLoginAction: Equatable {
    case register
    case unregister
    case none

    static func resolve(enabled: Bool, status: SMAppService.Status) -> Self {
        if enabled, status == .notRegistered { return .register }
        if !enabled, status == .enabled || status == .requiresApproval { return .unregister }
        return .none
    }
}

struct RuntimeSettingsChanges: Equatable {
    let debugLogging: Bool
    let hotkeys: Bool
    let systemIntegrations: Bool
    let localModel: Bool

    init(debugLogging: Bool, hotkeys: Bool, systemIntegrations: Bool, localModel: Bool) {
        self.debugLogging = debugLogging
        self.hotkeys = hotkeys
        self.systemIntegrations = systemIntegrations
        self.localModel = localModel
    }

    init(previous: AppSettings, current: AppSettings) {
        debugLogging = previous.debugLoggingEnabled != current.debugLoggingEnabled
        hotkeys = previous.dictationKey != current.dictationKey
            || previous.translationHotkeySuffix != current.translationHotkeySuffix
            || previous.translationEnabled != current.translationEnabled
            || previous.escapeCancelsRecording != current.escapeCancelsRecording
        systemIntegrations = previous.uiLanguage != current.uiLanguage
            || previous.launchAtLogin != current.launchAtLogin
            || previous.showInDock != current.showInDock
            || previous.showInMenuBar != current.showInMenuBar
        localModel = previous.useLocalTranscription != current.useLocalTranscription
            || previous.localTranscriptionProvider != current.localTranscriptionProvider
            || previous.whisperModel != current.whisperModel
            || previous.parakeetModel != current.parakeetModel
            || previous.qwenASRModel != current.qwenASRModel
    }
}

private extension ModelInstallationState {
    var modelID: String? {
        switch self {
        case .idle: nil
        case .installing(let model, _), .installed(let model), .failed(let model, _): model
        }
    }
}
