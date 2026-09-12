import AppKit
import ApplicationServices
import Carbon.HIToolbox

extension NSPasteboard {
    // http://nspasteboard.org/ — clipboard managers (Alfred, Paste, Raycast,
    // Maccy, …) treat any of these marker types as "do not retain in history"
    // signals. AppKit has no first-party concealed flag, so this community
    // convention is the only way to keep dictation content off long-lived
    // clipboard-manager stores.
    static let concealedTranscriptType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientTranscriptType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // Every transcript write in the app funnels through this helper so the
    // markers cannot be forgotten at a call site; the marker payload is empty
    // Data, only the presence of the type matters per the convention.
    // `transient` also stamps TransientType for the paste-then-restore fast
    // path where the transcript is on the clipboard for <1 s.
    // Implementation uses NSPasteboardItem + writeObjects (the same shape
    // `restore()` below uses) so all types are declared atomically — Apple's
    // NSPasteboard.setData docs require declared types, and the recommended
    // modern write path is a single writeObjects call.
    func writeTranscriptText(_ text: String, transient: Bool = false) {
        clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedTranscriptType)
        if transient { item.setData(Data(), forType: Self.transientTranscriptType) }
        writeObjects([item])
    }
}

struct TextInsertionTarget: Equatable, @unchecked Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let focusedElement: AXUIElement?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        focusedElement: AXUIElement? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.focusedElement = focusedElement
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.applicationName == rhs.applicationName
    }
}

enum TextInsertionError: LocalizedError {
    case targetUnavailable
    case blockedSensitiveApplication(String)
    case accessibilityPermissionDenied
    case targetBusy(String)
    case secureInputActive
    case insertionFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: "The application that started dictation is no longer available."
        case .blockedSensitiveApplication(let name): "Text insertion is disabled for \(name)."
        case .accessibilityPermissionDenied: "Accessibility permission is required to insert text."
        case .targetBusy(let name): "\(name) is busy and could not accept text. Try again."
        case .secureInputActive:
            "Secure Input is active, so the text was copied to the clipboard instead of pasted."
        case .insertionFailed(let error): "Text insertion failed with Accessibility error \(error.rawValue)."
        }
    }
}

// P2-10: the single sensitive-app decision for one dictation session. The rule
// used to be re-derived at every sink with a different formula — insert(),
// DictationCoordinator.stop() and ReasoningService.shouldCallModel() each had
// their own — so the sinks drifted apart: a transcript dictated into a password
// manager was still persisted to SQLite (and described in the debug log)
// whenever the user left "block insertion" off. Every sink now reads its answer
// from one value, built once from the target captured at session start.
struct SensitivityGate: Sendable {
    // Nothing captured yet, or the session was torn down: no sink is gated.
    static let inactive = SensitivityGate(target: nil, settings: AppSettings())

    // The captured frontmost app matched the sensitive list and the user left
    // the master protection switch on. Every decision below derives from it.
    let isProtectedSession: Bool
    private let settings: AppSettings

    init(target: TextInsertionTarget?, settings: AppSettings) {
        isProtectedSession = settings.sensitiveAppProtectionEnabled
            && target.map { TextInsertionService.isSensitive($0) } == true
        self.settings = settings
    }

    // Unchanged semantics: master switch plus the per-policy insertion toggle.
    var blocksInsertion: Bool { isProtectedSession && settings.sensitiveAppBlockInsertion }

    // History rows and any transcript-bearing log metadata. Deliberately has no
    // per-policy opt-out: keeping a password field on disk is never intended,
    // and pre-fix this only held as a side effect of the insertion gate
    // throwing first, which is exactly how the leak went unnoticed.
    var blocksPersistence: Bool { isProtectedSession }

    // Cloud round-trip for cleanup/translation, which the user can opt into.
    // Pre-fix this one branch ignored the master switch, so the sinks disagreed
    // in both directions; the switch now governs all of them uniformly.
    var blocksCloudReasoning: Bool {
        isProtectedSession && !settings.allowSensitiveAppCloudReasoning
    }
}

@MainActor
final class TextInsertionService {
    private var lastExternalApplication: NSRunningApplication?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?
    // Test seam: the only public way to detect Secure Input (Apple TN2150) is
    // this global HIToolbox flag, which no test can turn on; injecting it keeps
    // the paste gate coverable. Production always uses the real API.
    var secureInputActive: () -> Bool = { IsSecureEventInputEnabled() }
    #if DEBUG
    // Test seam (P2-10): the captured target is whatever app happens to be
    // frontmost while the suite runs, so no test can exercise the sensitive-app
    // sinks deterministically. DEBUG-only, so release builds always take the
    // real NSWorkspace / AX capture in captureTarget().
    var capturedTargetOverride: (() -> TextInsertionTarget?)?
    // Test seam (P2-5): insert() guards on AXIsProcessTrusted() (false on CI)
    // before it can reach the AX/paste pipeline, so a coordinator session that
    // must run insertion to reach .completed cannot be driven deterministically
    // in tests. When set, insert() delegates here and returns; DEBUG-only, so
    // release builds always run the real AX/paste implementation below.
    var insertOverride: ((String, TextInsertionTarget, AppSettings) async throws -> Void)?
    #endif

    init() {
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Task { @MainActor in self?.rememberExternalApplication(application) }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.writeTranscriptText(text)
    }

    func captureTarget() async -> TextInsertionTarget? {
        #if DEBUG
        if let capturedTargetOverride { return capturedTargetOverride() }
        #endif
        let frontmost = NSWorkspace.shared.frontmostApplication
        if isExternalApplication(frontmost) { rememberExternalApplication(frontmost) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Mouthpiece frontmost means a real window of ours is key (control panel,
        // prompt-studio test): dictate into our own focused field instead of
        // leaking the transcript into the previously active app.
        let candidate = isExternalApplication(frontmost)
            ? frontmost
            : (frontmost?.processIdentifier == ownPID ? frontmost : lastExternalApplication)
        guard let app = candidate,
              isExternalApplication(app) || app.processIdentifier == ownPID else {
            return nil
        }
        // In-process AX requests short-circuit and run AppKit's accessibility
        // handlers on the calling (background) thread, which is unsafe; the
        // self-target insertion uses the paste path and needs no element.
        if app.processIdentifier == ownPID {
            return TextInsertionTarget(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                applicationName: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
                focusedElement: nil
            )
        }
        // Never block the main thread on AX messaging: a hung target app makes
        // the synchronous call spin HIServices exception machinery on this
        // thread, which poisons the Swift concurrency executor state and leads
        // to delayed EXC_BAD_ACCESS crashes in unrelated @MainActor code.
        let focused = await Self.currentFocusedElement(processIdentifier: app.processIdentifier)
        return TextInsertionTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
            focusedElement: focused.element
        )
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard isExternalApplication(application) else { return }
        lastExternalApplication = application
    }

    private func isExternalApplication(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        return Self.isExternalApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            isTerminated: application.isTerminated
        )
    }

    nonisolated static func isExternalApplication(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        currentProcessIdentifier: pid_t,
        currentBundleIdentifier: String?,
        isTerminated: Bool
    ) -> Bool {
        guard !isTerminated, processIdentifier != currentProcessIdentifier else { return false }
        guard let currentBundleIdentifier else { return true }
        return bundleIdentifier != currentBundleIdentifier
    }

    func insert(
        _ text: String,
        into target: TextInsertionTarget,
        settings: AppSettings
    ) async throws {
        #if DEBUG
        if let insertOverride {
            try await insertOverride(text, target, settings)
            return
        }
        #endif
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            throw TextInsertionError.targetUnavailable
        }
        // P2-10: same decision the coordinator's sinks read, so the insertion
        // policy cannot drift from the history/log/cloud policies again.
        if SensitivityGate(target: target, settings: settings).blocksInsertion {
            throw TextInsertionError.blockedSensitiveApplication(target.applicationName)
        }
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityPermissionDenied
        }

        // In-process AX SetValue runs the AppKit handler (NSTextView/TSM
        // mutation) on the calling background thread and trips the main-queue
        // assertion; paste is delivered through the main event loop instead.
        if target.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            try await paste(text, into: target)
            return
        }

        if try await insertViaAccessibilityPreferringLiveFocus(text, into: target) { return }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            application.activate(options: [.activateIgnoringOtherApps])
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                    break
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            let focusedResult = await Self.currentFocusedElement(processIdentifier: target.processIdentifier)
            switch await Self.insertViaAccessibility(text, on: focusedResult.element) {
            case .inserted: return
            case .denied: throw TextInsertionError.accessibilityPermissionDenied
            case .notInserted: break
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            throw TextInsertionError.targetBusy(target.applicationName)
        }

        try await paste(text, into: target)
    }

    // The captured `target.focusedElement` is a snapshot taken when dictation
    // started. If the user clicks another field in the same app while dictating,
    // that stale element usually still is a writable text control, so trying it
    // first wrote the transcript into the field the user had LEFT (audit P1-4).
    // Live focus is therefore authoritative and the captured element is only a
    // fallback for when the live read itself fails (no element, .apiDisabled,
    // timeout) — a live element that merely refuses the write (GPU terminals
    // report AXGroup) must fall through to paste, not to the stale element.
    //
    // Internal (not private) so tests can drive this ordering without a live AX
    // session; both closures default to the real AX calls.
    func insertViaAccessibilityPreferringLiveFocus(
        _ text: String,
        into target: TextInsertionTarget,
        readFocusedElement: @MainActor (pid_t) async -> (element: AXUIElement?, error: AXError) = {
            await TextInsertionService.currentFocusedElement(processIdentifier: $0)
        },
        write: @MainActor (String, AXElementBox?) async -> AXInsertOutcome = {
            await TextInsertionService.insertViaAccessibility($0, on: $1?.element)
        }
    ) async throws -> Bool {
        let live = await readFocusedElement(target.processIdentifier)
        switch await write(text, live.element.map(AXElementBox.init(element:))) {
        case .inserted: return true
        case .denied: throw TextInsertionError.accessibilityPermissionDenied
        case .notInserted: break
        }

        if live.element == nil || live.error != .success {
            switch await write(text, target.focusedElement.map(AXElementBox.init(element:))) {
            case .inserted: return true
            case .denied: throw TextInsertionError.accessibilityPermissionDenied
            case .notInserted: break
            }
        }

        if live.error == .apiDisabled {
            throw TextInsertionError.accessibilityPermissionDenied
        }
        return false
    }

    // Internal (not private) so the insertViaAccessibilityPreferringLiveFocus
    // seam can carry an element across the main-actor boundary the way the rest
    // of this file does: AXUIElement is not Sendable.
    struct AXElementBox: @unchecked Sendable {
        let element: AXUIElement
    }

    // Internal (not private) so tests can assert on the AX outcome reduction.
    enum AXInsertOutcome: Sendable {
        case inserted
        case denied
        case notInserted
    }

    private final class ResumeGate: @unchecked Sendable {
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

    private struct FocusedResult: @unchecked Sendable {
        let element: AXUIElement?
        let error: AXError
    }

    // Internal rather than private so the insertion tests can drive the live
    // focus read directly.
    nonisolated static func currentFocusedElement(
        processIdentifier: pid_t
    ) async -> (element: AXUIElement?, error: AXError) {
        let appElement = AXElementBox(element: AXUIElementCreateApplication(processIdentifier))
        let result = await raceWithTimeout(.milliseconds(1500)) {
            var focusedValue: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                appElement.element,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
            return FocusedResult(
                element: Self.accessibilityElement(from: focusedValue),
                error: err
            )
        }
        guard let result else { return (nil, .cannotComplete) }
        return (result.element, result.error)
    }

    nonisolated static func insertViaAccessibility(
        _ text: String,
        on element: AXUIElement?
    ) async -> AXInsertOutcome {
        guard let element else { return .notInserted }
        let box = AXElementBox(element: element)
        let outcome = await raceWithTimeout(.seconds(3)) { () -> AXInsertOutcome in
            var roleValue: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(
                box.element,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            if roleError == .apiDisabled { return .denied }
            let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
            guard let role = roleValue as? String, editableRoles.contains(role) else {
                // GPU terminals (Ghostty/kitty/Alacritty) expose AXGroup/AXUnknown and
                // never truly accept an AX text set, so skip to the paste fallback.
                return .notInserted
            }
            var beforeValue: CFTypeRef?
            AXUIElementCopyAttributeValue(box.element, kAXValueAttribute as CFString, &beforeValue)
            let before = beforeValue as? String
            let setError = AXUIElementSetAttributeValue(
                box.element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if setError == .apiDisabled { return .denied }
            if setError != .success { return .notInserted }
            // Some fields (VS Code, Google Docs, terminals) report .success but do not
            // change; verify the value actually moved before trusting the write.
            var afterValue: CFTypeRef?
            AXUIElementCopyAttributeValue(box.element, kAXValueAttribute as CFString, &afterValue)
            if let before, let after = afterValue as? String, before == after {
                return .notInserted
            }
            return .inserted
        }
        return outcome ?? .notInserted
    }

    // AX calls are blocking C APIs that ignore Task cancellation, so race them
    // on unstructured GCD threads and abandon the loser. A withTaskGroup child
    // blocked inside AX would keep the scope (and the caller) waiting on a hung
    // target app, which made the previous 3-second timeout unenforceable.
    private final class AbandonedBudget: @unchecked Sendable {
        static let shared = AbandonedBudget()
        private let lock = NSLock()
        private var outstanding = 0

        var hasCapacity: Bool {
            lock.lock()
            defer { lock.unlock() }
            // ponytail: fixed cap of 8 abandoned AX threads; raise or make
            // per-target if a legitimate workload ever hits it.
            return outstanding < 8
        }

        func markAbandoned() {
            lock.lock()
            defer { lock.unlock() }
            outstanding += 1
        }

        func markReturned() {
            lock.lock()
            defer { lock.unlock() }
            outstanding -= 1
        }
    }

    nonisolated static func raceWithTimeout<T: Sendable>(
        _ timeout: DispatchTimeInterval,
        operation: @escaping @Sendable () -> T
    ) async -> T? {
        // Each timeout leaves one GCD thread blocked inside the hung AX call;
        // stop attempting new ones before the pool (~64 threads) drains and
        // let callers fall through to the Cmd+V paste path instead.
        guard AbandonedBudget.shared.hasCapacity else { return nil }
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = operation()
                if gate.claim() {
                    continuation.resume(returning: result)
                } else {
                    AbandonedBudget.shared.markReturned()
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    AbandonedBudget.shared.markAbandoned()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated static func accessibilityElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private nonisolated static func postPasteEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                    continuation.resume()
                    return
                }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                continuation.resume()
            }
        }
    }

    private struct PendingRestore {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
        let text: String
        let task: Task<Void, Never>
    }

    private var pendingRestore: PendingRestore?

    // Internal (not private) so tests can assert the Secure Input path leaves
    // no restore behind to erase the retained transcript.
    var hasPendingClipboardRestore: Bool { pendingRestore != nil }

    // P2-14: the delayed restore below lives in a `Task` that simply dies
    // with the process, so quitting inside its ~1.1 s window left the user's
    // real clipboard replaced by our transcript — permanently, and with the
    // dictated text still sitting there for the next ⌘V in any app. Called
    // from `AppEnvironment.shutdown()`: cancel the timer and run the very
    // same guarded restore synchronously. No await, so it cannot delay
    // termination, and `restore(_:ifUnchanged:expectedText:pasteboard:)`
    // still refuses to touch a clipboard the user has overwritten since.
    func flushPendingRestore() {
        guard let pending = pendingRestore else { return }
        pending.task.cancel()
        pendingRestore = nil
        Self.restore(
            pending.items,
            ifUnchanged: pending.changeCount,
            expectedText: pending.text,
            pasteboard: .general
        )
    }

    // Secure Input (password fields, `sudo` in Terminal, some login forms) makes
    // the window server drop synthetic keystrokes, so the Cmd+V below silently
    // no-ops; the delayed restore would then wipe the transcript from the
    // clipboard too and the dictation vanished with no error at all. Leave the
    // transcript on the clipboard for a manual paste, drop any pending restore
    // that would erase it, and report why. The flag is global rather than
    // per-field (TN2150), so `false` is not a success guarantee — the AX path is
    // still tried first and the paste itself stays best-effort.
    // Internal (not private) so tests can cover both outcomes without posting
    // synthetic keystrokes.
    func retainTranscriptIfSecureInputActive(_ text: String, pasteboard: NSPasteboard) throws {
        guard secureInputActive() else { return }
        pendingRestore?.task.cancel()
        pendingRestore = nil
        pasteboard.writeTranscriptText(text)
        throw TextInsertionError.secureInputActive
    }

    private func paste(_ text: String, into target: TextInsertionTarget) async throws {
        let pasteboard = NSPasteboard.general
        try retainTranscriptIfSecureInputActive(text, pasteboard: pasteboard)
        let oldItems: [[NSPasteboard.PasteboardType: Data]]
        if let pending = pendingRestore {
            // A second dictation within the restore delay would otherwise
            // snapshot our own previous transcript and later "restore" it over
            // the user's real clipboard. Take over the original snapshot the
            // cancelled restore was still holding.
            pending.task.cancel()
            pendingRestore = nil
            oldItems = Self.snapshotForNewPaste(
                pendingItems: pending.items,
                pendingChangeCount: pending.changeCount,
                pendingText: pending.text,
                pasteboard: pasteboard
            )
        } else {
            oldItems = Self.snapshot(of: pasteboard)
        }
        pasteboard.writeTranscriptText(text, transient: true)
        let insertedChangeCount = pasteboard.changeCount

        await Self.postPasteEvents()

        // Restore the original clipboard only after giving the target time to
        // consume it. Some apps (Electron, browsers, busy apps) read the
        // pasteboard asynchronously, so restoring inside a quick defer clobbered
        // the text before they pasted it. The delayed restore no-ops if the user
        // copied something new in the meantime. Register it BEFORE the
        // cancellable pacing sleep below: the paste events are already posted,
        // so a cancelled session must still restore the user's clipboard.
        let delay = pasteDelay(for: target)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay + .milliseconds(900))
            guard !Task.isCancelled else { return }
            Self.restore(
                oldItems,
                ifUnchanged: insertedChangeCount,
                expectedText: text,
                pasteboard: pasteboard
            )
            self?.pendingRestore = nil
        }
        pendingRestore = PendingRestore(
            items: oldItems,
            changeCount: insertedChangeCount,
            text: text,
            task: task
        )
        try await Task.sleep(for: delay)
    }

    static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values.isEmpty ? nil : values
        } ?? []
    }

    // If the pasteboard still holds our previous dictation text, the user's
    // real clipboard is the snapshot the cancelled restore was holding; if the
    // user copied something new since, snapshot the live pasteboard instead.
    static func snapshotForNewPaste(
        pendingItems: [[NSPasteboard.PasteboardType: Data]],
        pendingChangeCount: Int,
        pendingText: String,
        pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]] {
        if pasteboard.changeCount == pendingChangeCount,
           pasteboard.string(forType: .string) == pendingText {
            return pendingItems
        }
        return snapshot(of: pasteboard)
    }

    static func restore(
        _ oldItems: [[NSPasteboard.PasteboardType: Data]],
        ifUnchanged changeCount: Int,
        expectedText: String,
        pasteboard: NSPasteboard
    ) {
        guard pasteboard.changeCount == changeCount,
              pasteboard.string(forType: .string) == expectedText else { return }
        pasteboard.clearContents()
        guard !oldItems.isEmpty else { return }
        let restored = oldItems.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // Internal (not private) so tests can cover the pacing decision table.
    func pasteDelay(for target: TextInsertionTarget) -> Duration {
        let bundle = target.bundleIdentifier?.lowercased() ?? ""
        if bundle.contains("terminal") || bundle.contains("iterm") { return .milliseconds(90) }
        if bundle.contains("electron") || bundle.contains("chrome") || bundle.contains("code") {
            return .milliseconds(220)
        }
        return .milliseconds(180)
    }

    nonisolated static func isSensitive(_ target: TextInsertionTarget) -> Bool {
        let bundleID = target.bundleIdentifier?.lowercased() ?? ""
        let name = target.applicationName.lowercased()
        let sensitiveTokens = [
            "1password", "bitwarden", "keepass", "keychain", "password",
            "wallet", "bank", "authenticator",
        ]
        return sensitiveTokens.contains { bundleID.contains($0) || name.contains($0) }
    }
}
