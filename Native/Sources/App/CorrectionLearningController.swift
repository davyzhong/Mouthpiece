import AppKit
import Foundation

@MainActor
final class CorrectionLearningController: ObservableObject {
    @Published private(set) var samples: [CorrectionSample] = []
    @Published private(set) var terms: [LearnedTerm] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var captureStatus = "learning.capture.idle"
    @Published private(set) var lastAnalysis: Date?
    @Published var manualRecord: TranscriptionRecord?
    @Published var evidenceSample: CorrectionSample?
    var manualText = ""
    var isDictating = false {
        didSet { if isDictating && !oldValue { trackingTask?.cancel() } }
    }
    var settings = AppSettings() {
        didSet {
            if oldValue.correctionLearningEnabled && !settings.correctionLearningEnabled {
                generation += 1
                trackingTask?.cancel()
                analysisTask?.cancel()
                captureStatus = "learning.capture.idle"
                let previous = trackingTask
                Task { [weak self] in
                    await previous?.value
                    try? await self?.history?.recoverCorrectionSessions()
                    await self?.refresh()
                }
            }
        }
    }

    typealias Extract = @Sendable ([CorrectionSample], [String], AppSettings) async throws -> [LearnedTerm]
    private var history: HistoryRepository?
    private var extract: Extract?
    private var timerTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt: Date?
    private var lastRecord: TranscriptionRecord?
    private var lastTarget: TextInsertionTarget?
    private var isStopped = false

    #if DEBUG
    func waitForAnalysis() async { await analysisTask?.value }
    #endif

    func configure(history: HistoryRepository, extract: @escaping Extract) async throws {
        isStopped = false
        self.history = history
        self.extract = extract
        do { try await history.recoverCorrectionSessions() }
        catch {
            isStopped = true
            errorMessage = error.localizedDescription
            throw error
        }
        await refresh()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                self?.analyze()
            }
        }
    }

    func refresh() async {
        guard let history else { return }
        do {
            samples = try await history.correctionSamples()
            terms = try await history.learnedTerms()
        } catch { errorMessage = error.localizedDescription }
    }

    func receive(_ record: TranscriptionRecord, target: TextInsertionTarget?, before: CorrectionTextSnapshot?) {
        guard !isStopped, settings.correctionLearningEnabled, let history else { return }
        lastRecord = record
        lastTarget = target
        let previous = trackingTask
        previous?.cancel()
        let epoch = generation
        trackingTask = Task { [weak self] in
            await previous?.value
            guard let self, epoch == self.generation, !Task.isCancelled else { return }
            var sample = CorrectionSample(id: record.id, original: record.text, timestamp: record.timestamp,
                                          application: target?.applicationName ?? "")
            guard sample.original.utf16.count <= 16_000 else {
                self.captureStatus = "learning.capture.unavailable"
                return
            }
            do {
                sample.ready = before == nil
                try await history.saveCorrectionSample(sample)
                await self.refresh()
                if let before, let target {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !Task.isCancelled, let after = await TextInsertionService.correctionSnapshot(for: target),
                       CFEqual(before.element, after.element),
                       let anchor = CorrectionAnchor(before: before.text, selection: before.selection,
                                                     inserted: record.text, after: after.text) {
                        self.captureStatus = "learning.capture.tracking"
                        // ponytail: bounded polling for 90s; add AXObserver only if profiling warrants it.
                        let deadline = Date().addingTimeInterval(90)
                        var observed = record.text
                        var changedAt = Date()
                        while !Task.isCancelled, Date() < deadline, epoch == self.generation {
                            do { try await Task.sleep(for: .milliseconds(750)) } catch { break }
                            guard !Task.isCancelled,
                                  let current = await TextInsertionService.correctionSnapshot(for: target),
                                  epoch == self.generation,
                                  CFEqual(before.element, current.element),
                                  let corrected = anchor.correctedText(in: current.text) else { break }
                            if corrected != observed {
                                observed = corrected
                                changedAt = Date()
                                // A new edit (including Undo) invalidates the previous stable correction.
                                // Do not retain it if the user leaves before the new text settles.
                                if sample.corrected != nil {
                                    sample.corrected = nil
                                    sample.revision = UUID()
                                    try await history.saveCorrectionSample(sample)
                                }
                            } else if Date().timeIntervalSince(changedAt) >= 2,
                                      sample.corrected != (corrected == sample.original ? nil : corrected) {
                                sample.corrected = corrected == sample.original ? nil : corrected
                                sample.revision = UUID()
                                try await history.saveCorrectionSample(sample)
                                await self.refresh()
                            }
                        }
                        self.captureStatus = "learning.capture.finished"
                    } else { self.captureStatus = "learning.capture.unavailable" }
                } else { self.captureStatus = "learning.capture.unavailable" }
                // Capture is local. Only the batch scheduler is allowed to call the model.
                guard epoch == self.generation else { return }
                sample.ready = true
                sample.revision = UUID()
                try await history.saveCorrectionSample(sample)
                await self.refresh()
                self.analyze()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func recordCorrection(_ record: TranscriptionRecord, corrected: String) async throws {
        guard settings.correctionLearningEnabled, let history else { throw CorrectionLearningError.invalidCorrection }
        let clean = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != record.text, clean.utf16.count <= 16_000 else {
            throw CorrectionLearningError.invalidCorrection
        }
        trackingTask?.cancel()
        let epoch = generation
        await trackingTask?.value
        guard epoch == generation, settings.correctionLearningEnabled, !isStopped else { throw CancellationError() }
        var sample = CorrectionSample(id: record.id, original: record.text, corrected: clean,
                                      timestamp: record.timestamp, application: "", source: "manual")
        sample.revision = UUID()
        try await history.saveCorrectionSample(sample)
        await refresh()
        analyze()
    }

    func captureSelectedCorrection() {
        guard !isStopped, settings.correctionLearningEnabled, !isDictating, let record = lastRecord, let target = lastTarget else { return }
        let epoch = generation
        Task { [weak self] in
            guard let self else { return }
            guard let snapshot = await TextInsertionService.correctionSnapshot(for: target, selectedOnly: true) else {
                self.errorMessage = String(localized: "learning.error.selection")
                return
            }
            guard epoch == self.generation, self.settings.correctionLearningEnabled else { return }
            self.manualText = snapshot.text
            self.manualRecord = record
            NSApp.activate(ignoringOtherApps: true)
            ControlPanelWindowAccess.open?(id: ControlPanelWindowAccess.id)
        }
    }

    func analyze(manual: Bool = false) {
        guard !isStopped, settings.correctionLearningEnabled, settings.useReasoningModel,
              !isDictating, !isAnalyzing, let history, let extract else { return }
        if !manual, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 300 { return }
        isAnalyzing = true
        errorMessage = nil
        let epoch = generation
        let configuration = settings
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isAnalyzing = false }
            do {
                let pending = try await history.correctionSamples()
                let batch = CorrectionBatch.select(pending, settings: configuration, manual: manual)
                guard !batch.isEmpty else { return }
                let known = try await history.learnedTerms()
                try Task.checkCancellation()
                guard epoch == self.generation, self.settings.correctionLearningEnabled else { return }
                let excluded = configuration.terminologyProfile.preferredTerms + known.filter { $0.status != "pending" }.map(\.term)
                let result: [LearnedTerm]
                if batch.contains(where: \.hasCorrection) {
                    self.lastAttempt = Date()
                    result = try await extract(batch, excluded, configuration)
                } else { result = [] }
                try Task.checkCancellation()
                guard epoch == self.generation, self.settings.correctionLearningEnabled else { return }
                if try await history.finishCorrectionBatch(batch, terms: result) {
                    self.lastAnalysis = Date()
                    self.lastAttempt = nil
                }
                await self.refresh()
            } catch is CancellationError {
                // Keep the batch pending for the next enabled run.
            } catch {
                self.lastAttempt = Date()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setStatus(_ term: LearnedTerm, status: String, spelling: String? = nil) async {
        guard let history else { return }
        let epoch = generation
        do {
            // Ignore actions from views whose evidence was just cleared/deleted.
            let stored = try await history.learnedTerms()
            guard epoch == generation, stored.contains(where: { $0.id == term.id }) else { return }
            var next = term
            next.status = status
            if let spelling, spelling.caseInsensitiveCompare(term.term) != .orderedSame {
                var old = term
                old.status = "ignored"
                try await history.saveLearnedTerm(old)
                guard epoch == generation else { return }
                next.term = spelling
            }
            try await history.saveLearnedTerm(next)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func editCorrection(_ record: TranscriptionRecord) {
        manualText = samples.first(where: { $0.id == record.id })?.corrected ?? record.text
        manualRecord = record
    }

    func showEvidence(_ id: Int64) {
        let epoch = generation
        Task { [weak self] in
            guard let self, let history = self.history else { return }
            do {
                let sample = try await history.correctionSamples(pendingOnly: false).first { $0.id == id }
                guard epoch == self.generation else { return }
                self.evidenceSample = sample
            }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func clear() async {
        generation += 1
        trackingTask?.cancel()
        analysisTask?.cancel()
        lastRecord = nil
        lastTarget = nil
        manualRecord = nil
        evidenceSample = nil
        do {
            try await history?.clearCorrectionLearning()
            await refresh()
            lastAnalysis = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func shutdown() async {
        isStopped = true
        timerTask?.cancel()
        analysisTask?.cancel()
        trackingTask?.cancel()
        await trackingTask?.value
    }
}
