import AppKit
import ApplicationServices
import XCTest
@testable import Mouthpiece

final class CorrectionCaptureLiveTests: XCTestCase {
    @MainActor
    func testLiveNativeFieldCapturesUserCorrectionWithoutModelCall() async throws {
        guard let fixture = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.mouthpiece.correction-fixture"
        }) else { throw XCTSkip("Opt-in: launch scripts/correction-capture-fixture.swift as the fixture app first.") }
        guard AXIsProcessTrusted() else {
            XCTFail("The test host needs Accessibility permission for the live fixture; capture was not verified.")
            return
        }
        fixture.activate()
        try await Task.sleep(for: .milliseconds(500))
        let target = TextInsertionTarget(processIdentifier: fixture.processIdentifier,
                                         bundleIdentifier: fixture.bundleIdentifier, applicationName: "Correction fixture")
        let snapshot = await TextInsertionService.correctionSnapshot(for: target)
        let before = try XCTUnwrap(snapshot)
        XCTAssertEqual(before.text, "🙂 前文：；后文")
        let original = "打开 Mouth peace 的设置"
        let inserted = await TextInsertionService.insertViaAccessibility(original, on: before.element)
        if case .inserted = inserted {} else { XCTFail("Fixture insertion failed"); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.db"))
        let record = try await repository.save(text: original, rawText: nil)
        let controller = CorrectionLearningController()
        controller.settings.correctionLearningEnabled = true
        try await controller.configure(history: repository) { _, _, _ in
            XCTFail("One edit must not call the model before the batch threshold")
            return []
        }
        controller.receive(record, target: target, before: before)
        try await Task.sleep(for: .milliseconds(500))
        let box = TextInsertionService.AXElementBox(element: before.element)
        // This mutation stands in for the user editing only their dictated span.
        let edited = await TextInsertionService.raceWithTimeout(.seconds(1)) {
            AXUIElementSetAttributeValue(box.element, kAXValueAttribute as CFString,
                                         "🙂 前文：打开 Mouthpiece 的设置；后文" as CFString) == .success
        }
        XCTAssertEqual(edited, true)
        try await Task.sleep(for: .seconds(4))
        await controller.shutdown()
        let samples = try await repository.correctionSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.original, original)
        XCTAssertEqual(samples.first?.corrected, "打开 Mouthpiece 的设置")
        XCTAssertEqual(samples.first?.ready, true)
    }
}
