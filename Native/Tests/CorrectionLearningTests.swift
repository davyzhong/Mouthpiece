import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import Mouthpiece

final class CorrectionLearningTests: XCTestCase {
    private func sample(_ id: Int64, corrected: String? = nil, timestamp: Date = .now) -> CorrectionSample {
        CorrectionSample(id: id, original: "打开 Mouth peace 的设置", corrected: corrected,
                         timestamp: timestamp, application: "Test")
    }

    func testCountBatchWaitsForFiftyCompletedDictations() {
        var settings = AppSettings()
        settings.correctionLearningEnabled = true
        var records = (1...49).map { sample(Int64($0)) }
        XCTAssertTrue(CorrectionBatch.select(records, settings: settings).isEmpty)
        records.append(sample(50, corrected: "打开 Mouthpiece 的设置"))
        records[49].ready = false
        XCTAssertTrue(CorrectionBatch.select(records, settings: settings).isEmpty)
        records[49].ready = true
        XCTAssertEqual(CorrectionBatch.select(records, settings: settings).count, 50)
        XCTAssertEqual(CorrectionBatch.select(records, settings: settings).filter(\.hasCorrection).count, 1)
    }

    func testDailyBatchUsesLocalCalendarAndLeavesTodayPending() {
        var settings = AppSettings()
        settings.correctionLearningSchedule = "daily"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = calendar.startOfDay(for: now)
        let records = [sample(1, timestamp: midnight.addingTimeInterval(-1)), sample(2, timestamp: midnight)]
        XCTAssertEqual(CorrectionBatch.select(records, settings: settings, now: now, calendar: calendar).map(\.id), [1])
        XCTAssertEqual(CorrectionBatch.select(records, settings: settings, manual: true).count, 2)
    }

    func testAnchoringHandlesUnicodeAndRejectsUnrelatedEditsAndClearing() throws {
        let before = "🙂 前文：旧内容；后文"
        let selected = (before as NSString).range(of: "旧内容")
        let anchor = try XCTUnwrap(CorrectionAnchor(before: before, selection: selected,
                                                    inserted: "打开 Mouth peace", after: "🙂 前文：打开 Mouth peace；后文"))
        XCTAssertEqual(anchor.correctedText(in: "🙂 前文：打开 Mouthpiece；后文"), "打开 Mouthpiece")
        XCTAssertNil(anchor.correctedText(in: "修改前文：打开 Mouthpiece；后文"))
        XCTAssertNil(anchor.correctedText(in: "🙂 前文：；后文"))
        XCTAssertNil(anchor.correctedText(in: ""))
        XCTAssertNil(CorrectionAnchor(before: before, selection: NSRange(location: 1, length: 0),
                                      inserted: "x", after: "x"))
        XCTAssertNil(CorrectionAnchor(before: "", selection: NSRange(location: 0, length: 0),
                                      inserted: "expected", after: "different"))
    }

    func testExtractionRequiresRealUserCorrectionAndDeduplicates() throws {
        let response = """
        {"terms":[
          {"term":"Mouthpiece","category":"product","evidence":[{"sampleID":1,"before":"Mouth peace","after":"Mouthpiece"}]},
          {"term":"Invented","category":"product","evidence":[{"sampleID":2,"before":"Mouth peace","after":"Invented"}]},
          {"term":"Mouthpiece","category":"product","evidence":[{"sampleID":1,"before":"Mouth peace","after":"Mouthpiece"}]}
        ]}
        """
        let records = [sample(1, corrected: "打开 Mouthpiece 的设置"), sample(2)]
        let result = try CorrectionBatch.parse(response, samples: records, excludedTerms: [])
        XCTAssertEqual(result.map(\.term), ["Mouthpiece"])
        XCTAssertTrue(try CorrectionBatch.parse(response, samples: records, excludedTerms: ["mouthpiece"]).isEmpty)
        XCTAssertTrue(try CorrectionBatch.parse(response, samples: [sample(1), sample(2)], excludedTerms: []).isEmpty)
        XCTAssertThrowsError(try CorrectionBatch.parse("not JSON", samples: records, excludedTerms: []))
        let prompt = try CorrectionBatch.prompt(samples: records, excludedTerms: [])
        XCTAssertTrue(prompt.contains("original"))
        XCTAssertTrue(prompt.contains("corrected"))
        XCTAssertTrue(prompt.contains("NEVER proof"))
    }

    func testPersistenceRejectsStaleBatchesAndScrubsDeletedEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.db"))
        let record = try await repository.save(text: "打开 Mouth peace 的设置", rawText: nil)
        var first = sample(record.id, corrected: "打开 Mouthpiece 的设置")
        try await repository.saveCorrectionSample(first)
        var newer = first
        newer.revision = UUID()
        try await repository.saveCorrectionSample(newer)
        let stale = try await repository.finishCorrectionBatch([first], terms: [])
        XCTAssertFalse(stale)
        let term = LearnedTerm(term: "Mouthpiece", category: "product", evidence: [
            .init(sampleID: record.id, before: "Mouth peace", after: "Mouthpiece")
        ])
        let finished = try await repository.finishCorrectionBatch([newer], terms: [term])
        XCTAssertTrue(finished)
        let pending = try await repository.correctionSamples()
        XCTAssertTrue(pending.isEmpty)
        try await repository.delete(id: record.id)
        first.revision = UUID()
        try await repository.saveCorrectionSample(first)
        let remaining = try await repository.correctionSamples(pendingOnly: false)
        XCTAssertTrue(remaining.isEmpty)
        let terms = try await repository.learnedTerms()
        XCTAssertTrue(terms[0].evidence.isEmpty)
        XCTAssertEqual(terms[0].status, "ignored")
    }

    @MainActor
    func testControllerCallsModelOnceForFiftyAndKeepsFailedBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.db"))
        let recorder = ExtractionRecorder()
        let controller = CorrectionLearningController()
        controller.settings.correctionLearningEnabled = true
        try await controller.configure(history: repository) { samples, _, _ in try await recorder.extract(samples) }
        for _ in 1...49 {
            let record = try await repository.save(text: "打开 Mouth peace 的设置", rawText: nil)
            try await repository.saveCorrectionSample(sample(record.id, corrected: "打开 Mouthpiece 的设置"))
        }
        controller.analyze()
        await controller.waitForAnalysis()
        let initialCalls = await recorder.calls
        XCTAssertEqual(initialCalls, [])
        let record = try await repository.save(text: "打开 Mouth peace 的设置", rawText: nil)
        try await repository.saveCorrectionSample(sample(record.id, corrected: "打开 Mouthpiece 的设置"))
        await recorder.setFail(true)
        controller.analyze()
        await controller.waitForAnalysis()
        XCTAssertNotNil(controller.errorMessage)
        let failedPending = try await repository.correctionSamples()
        XCTAssertEqual(failedPending.count, 50)
        await recorder.setFail(false)
        controller.analyze(manual: true)
        controller.analyze(manual: true) // double-click must not issue another request
        await controller.waitForAnalysis()
        let calls = await recorder.calls
        XCTAssertEqual(calls, [50, 50])
        let pending = try await repository.correctionSamples()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(controller.errorMessage)
        await controller.shutdown()
    }

    @MainActor
    func testDisabledLearningDoesNotAnalyzeAndLegacySettingsKeepDefaults() async throws {
        let suite = "MouthpieceLearningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{\"uiLanguage\":\"en\"}".utf8), forKey: "native.settings.v1")
        let settings = SettingsRepository(defaults: defaults).load()
        XCTAssertFalse(settings.correctionLearningEnabled)
        XCTAssertEqual(settings.correctionLearningBatchSize, 50)
        XCTAssertEqual(settings.uiLanguage, .english)
        let controller = CorrectionLearningController()
        controller.analyze(manual: true)
        XCTAssertFalse(controller.isAnalyzing)
    }

    @MainActor
    func testLearningScreenRendersUsingIsolatedSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MouthpieceLearningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment(bootstrap: false, settingsRepository: SettingsRepository(defaults: defaults))
        var configuration = AppSettings()
        configuration.correctionLearningEnabled = true
        environment.saveSettings(configuration)
        let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.db"))
        let record = try await repository.save(text: "打开 Mouth peace 的设置", rawText: nil)
        try await repository.saveCorrectionSample(sample(record.id, corrected: "打开 Mouthpiece 的设置"))
        try await repository.saveLearnedTerm(LearnedTerm(term: "Mouthpiece", category: "product", evidence: [
            .init(sampleID: record.id, before: "Mouth peace", after: "Mouthpiece")
        ]))
        try await environment.learning.configure(history: repository) { _, _, _ in XCTFail("Rendering must not call a model"); return [] }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/correction-learning")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (language, scheme) in [("zh-Hans", ColorScheme.light), ("en", ColorScheme.dark)] {
            configuration.uiLanguage = language == "en" ? .english : .simplifiedChinese
            environment.saveSettings(configuration)
            let view = VocabularyRulesView().environmentObject(environment)
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                .frame(width: 850, height: 920)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 920),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(language).png"))
            XCTAssertGreaterThan(bitmap.pixelsWide, 800)
            window.contentView = nil
        }
        await environment.shutdown()
    }

    @MainActor
    func testClearDuringRequestCannotRecreateSuggestions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.db"))
        let record = try await repository.save(text: "打开 Mouth peace 的设置", rawText: nil)
        try await repository.saveCorrectionSample(sample(record.id, corrected: "打开 Mouthpiece 的设置"))
        let controller = CorrectionLearningController()
        controller.settings.correctionLearningEnabled = true
        let entered = expectation(description: "Request started")
        try await controller.configure(history: repository) { _, _, _ in
            entered.fulfill()
            try? await Task.sleep(for: .milliseconds(300))
            return [LearnedTerm(term: "Mouthpiece", category: "product", evidence: [])]
        }
        controller.analyze(manual: true)
        await fulfillment(of: [entered], timeout: 2)
        await controller.clear()
        await controller.waitForAnalysis()
        let pending = try await repository.correctionSamples()
        let terms = try await repository.learnedTerms()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(terms.isEmpty)
        XCTAssertFalse(controller.isAnalyzing)
        await controller.shutdown()
    }
}

private actor ExtractionRecorder {
    var calls: [Int] = []
    var fail = false
    func setFail(_ value: Bool) { fail = value }
    func extract(_ records: [CorrectionSample]) throws -> [LearnedTerm] {
        calls.append(records.count)
        if fail { throw CorrectionLearningError.invalidResponse }
        return []
    }
}
