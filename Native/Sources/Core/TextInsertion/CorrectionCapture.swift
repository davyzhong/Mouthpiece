import AppKit
import ApplicationServices
import Carbon

struct CorrectionTextSnapshot: @unchecked Sendable {
    let element: AXUIElement
    let text: String
    let selection: NSRange
}

/// Conservative anchoring: edits outside the inserted span invalidate automatic capture.
/// Full surrounding text stays in memory only; it is never persisted or sent to the LLM.
struct CorrectionAnchor: Equatable, Sendable {
    let prefix: String
    let suffix: String
    let original: String

    init?(before: String, selection: NSRange, inserted: String, after: String) {
        guard let range = Range(selection, in: before), !inserted.isEmpty else { return nil }
        prefix = String(before[..<range.lowerBound])
        suffix = String(before[range.upperBound...])
        original = inserted
        guard after == prefix + inserted + suffix else { return nil }
    }

    func correctedText(in value: String) -> String? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count else { return nil }
        let text = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 16_000 else { return nil }
        // A completely different message or a large rewrite is not a lexical correction.
        let a = Array(original), b = Array(text)
        let commonPrefix = zip(a, b).prefix(while: { $0 == $1 }).count
        let commonSuffix = zip(a.dropFirst(commonPrefix).reversed(), b.dropFirst(commonPrefix).reversed())
            .prefix(while: { $0 == $1 }).count
        let changed = max(a.count, b.count) - commonPrefix - commonSuffix
        guard changed <= 100, (a.count <= 30 || commonPrefix + commonSuffix >= min(a.count, b.count) / 2) else { return nil }
        return text
    }
}

extension TextInsertionService {
    /// No key logging, clipboard writes or UI mutations. All AX messaging is bounded off-main.
    nonisolated static func correctionSnapshot(for target: TextInsertionTarget, selectedOnly: Bool = false) async -> CorrectionTextSnapshot? {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isSensitive(target), AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        if !selectedOnly {
            let bundle = target.bundleIdentifier?.lowercased() ?? ""
            // Terminal values can contain scrollback/output rather than an editable command.
            guard !["ghostty", "iterm", "terminal", "warp", "kitty", "alacritty"].contains(where: bundle.contains) else { return nil }
        }
        let focused = await currentFocusedElement(processIdentifier: target.processIdentifier)
        guard let element = focused.element else { return nil }
        let box = AXElementBox(element: element)
        let result = await raceWithTimeout(.milliseconds(700)) { () -> CorrectionTextSnapshot? in
            AXUIElementSetMessagingTimeout(box.element, 0.25)
            func attribute(_ name: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(box.element, name as CFString, &value) == .success else { return nil }
                return value
            }
            guard attribute(kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
            if selectedOnly {
                guard let text = attribute(kAXSelectedTextAttribute) as? String,
                      !text.isEmpty, text.utf16.count <= 16_000 else { return nil }
                return CorrectionTextSnapshot(element: box.element, text: text, selection: NSRange(location: 0, length: text.utf16.count))
            }
            guard let role = attribute(kAXRoleAttribute) as? String,
                  [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return nil }
            var writable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(box.element, kAXSelectedTextAttribute as CFString, &writable) == .success,
                  writable.boolValue,
                  let text = attribute(kAXValueAttribute) as? String, text.utf16.count <= 16_000,
                  let rawRange = attribute(kAXSelectedTextRangeAttribute),
                  CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
            let axRange = unsafeDowncast(rawRange, to: AXValue.self)
            guard AXValueGetType(axRange) == .cfRange else { return nil }
            var range = CFRange()
            guard AXValueGetValue(axRange, .cfRange, &range), range.location >= 0, range.length >= 0,
                  range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
            return CorrectionTextSnapshot(element: box.element, text: text,
                                          selection: NSRange(location: range.location, length: range.length))
        }
        guard await MainActor.run(body: { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }) else { return nil }
        return result ?? nil
    }
}
