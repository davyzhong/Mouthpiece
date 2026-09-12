// Disposable native text field for the opt-in CorrectionCaptureLiveTests.
// Never reads user documents, clipboard or credentials. Close the window to exit.
import AppKit

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 220),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mouthpiece correction capture fixture"
        let text = NSTextView(frame: NSRect(x: 20, y: 20, width: 600, height: 180))
        text.font = .systemFont(ofSize: 20)
        text.string = "🙂 前文：；后文"
        text.setSelectedRange(NSRange(location: ("🙂 前文：" as NSString).length, length: 0))
        window.contentView?.addSubview(text)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let fixture = Fixture()
    app.delegate = fixture
    app.setActivationPolicy(.regular)
    app.run()
}
