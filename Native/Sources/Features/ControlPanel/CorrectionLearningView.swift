import SwiftUI

struct CorrectionLearningSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var learning: CorrectionLearningController
    @State private var showClearConfirmation = false
    @State private var filter = "pending"

    var body: some View {
        SettingsSection(title: "learning.title") {
            SettingsRow(icon: "text.badge.checkmark", title: "learning.enable", detail: "learning.privacy") {
                Toggle("learning.enable", isOn: settingBinding(environment, \.correctionLearningEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if environment.settings.correctionLearningEnabled {
                SettingsRow(icon: "calendar", title: "learning.schedule") {
                    Picker("learning.schedule", selection: settingBinding(environment, \.correctionLearningSchedule)) {
                        Text("learning.schedule.count").tag("count")
                        Text("learning.schedule.daily").tag("daily")
                    }
                    .labelsHidden().frame(width: 180)
                }
                if environment.settings.correctionLearningSchedule == "count" {
                    SettingsRow(icon: "number", title: "learning.batchSize") {
                        Stepper(value: settingBinding(environment, \.correctionLearningBatchSize), in: 10...100, step: 10) {
                            Text(environment.settings.correctionLearningBatchSize, format: .number).monospacedDigit()
                        }.frame(width: 130)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("learning.schedule.help").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: AppLocalization.string("learning.progress", language: environment.settings.uiLanguage),
                                learning.samples.count, learning.samples.filter(\.hasCorrection).count))
                    Text(LocalizedStringKey(learning.captureStatus)).font(.caption).foregroundStyle(.secondary)
                    Text("learning.shortcut").font(.caption).foregroundStyle(.secondary)
                    if !environment.settings.useReasoningModel {
                        Text("learning.enableModel").foregroundStyle(.secondary)
                    }
                    if let message = learning.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack {
                        if learning.isAnalyzing {
                            ProgressView().controlSize(.small)
                            Text("learning.analyzing")
                        } else {
                            Button(learning.errorMessage == nil ? "learning.analyze" : "common.retry") {
                                learning.analyze(manual: true)
                            }
                            .disabled(!environment.settings.useReasoningModel || learning.isDictating
                                      || !learning.samples.contains(where: \.ready))
                        }
                        Spacer()
                        Button("learning.clear", role: .destructive) { showClearConfirmation = true }
                    }
                    if let date = learning.lastAnalysis {
                        Text("learning.lastAnalysis") + Text(" ") + Text(date, style: .time)
                    }
                }.font(.callout).padding(14)
            }
        }
        .confirmationDialog("learning.clear.title", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("learning.clear", role: .destructive) { Task { await learning.clear() } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("learning.clear.body") }

        if !learning.terms.isEmpty {
            SettingsSection(title: "learning.suggestions") {
                HStack {
                    Picker("learning.filter", selection: $filter) {
                        Text("learning.pending").tag("pending")
                        Text("learning.accepted").tag("accepted")
                        Text("learning.ignored").tag("ignored")
                    }.pickerStyle(.segmented)
                    if filter == "pending" {
                        Button("learning.acceptAll") {
                            let pending = learning.terms.filter { $0.status == "pending" }
                            environment.saveDictionary(environment.dictionaryWords + pending.map(\.term))
                            Task {
                                for term in pending where environment.dictionaryWords.contains(term.term) {
                                    await learning.setStatus(term, status: "accepted")
                                }
                            }
                        }.disabled(learning.terms.allSatisfy { $0.status != "pending" })
                    }
                }.padding(12)
                if learning.terms.allSatisfy({ $0.status != filter }) {
                    Text("learning.empty").foregroundStyle(.secondary).padding(16)
                }
                ForEach(learning.terms.filter { $0.status == filter }) { term in
                    CorrectionTermRow(term: term, learning: learning)
                }
            }
        }
    }
}

private struct CorrectionTermRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    let term: LearnedTerm
    @ObservedObject var learning: CorrectionLearningController
    @State private var spelling = ""
    private var categoryKey: String { "learning.category.\(term.category)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                if term.status == "pending" {
                    TextField("learning.spelling", text: $spelling)
                        .textFieldStyle(.roundedBorder)
                } else { Text(term.term).font(.headline) }
                Text(LocalizedStringKey(categoryKey))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if term.status == "pending" {
                    Button("learning.accept") { accept() }
                        .disabled(spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || spelling.count > 60 || spelling.contains(where: \.isNewline))
                    Button("learning.ignore") { Task { await learning.setStatus(term, status: "ignored") } }
                } else if term.status == "ignored" {
                    Button("learning.restore") { Task { await learning.setStatus(term, status: "pending") } }
                }
            }
            ForEach(term.evidence, id: \.sampleID) { evidence in
                HStack {
                    Text(verbatim: "\(evidence.before) → \(evidence.after)")
                        .font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("learning.evidence") { learning.showEvidence(evidence.sampleID) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .onAppear { spelling = term.term }
    }

    private func accept() {
        let clean = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        environment.saveDictionary(environment.dictionaryWords + [clean])
        guard environment.dictionaryWords.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        Task { await learning.setStatus(term, status: "accepted", spelling: clean) }
    }
}

struct CorrectionEditorHost: View {
    @ObservedObject var learning: CorrectionLearningController
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: $learning.manualRecord) { record in
                CorrectionEditor(record: record, learning: learning, initialText: learning.manualText)
            }
            .sheet(item: $learning.evidenceSample) { sample in
                CorrectionEvidenceView(sample: sample)
            }
    }
}

private struct CorrectionEvidenceView: View {
    let sample: CorrectionSample
    @Environment(\.dismiss) private var dismiss
    private var sourceKey: String { "learning.source.\(sample.source)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("learning.evidence").font(.title2)
            Text(sample.timestamp, style: .date).foregroundStyle(.secondary)
            Text(LocalizedStringKey(sourceKey))
            if !sample.application.isEmpty { Text(sample.application).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("learning.editor.original").font(.headline)
                    Text(sample.original).textSelection(.enabled)
                    Text("learning.editor.corrected").font(.headline)
                    Text(sample.corrected ?? "").textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("common.ok") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 440)
    }
}

private struct CorrectionEditor: View {
    let record: TranscriptionRecord
    @ObservedObject var learning: CorrectionLearningController
    let initialText: String
    @Environment(\.dismiss) private var dismiss
    @State private var corrected = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("learning.correct").font(.title2)
            Text("learning.editor.help").foregroundStyle(.secondary)
            Text("learning.editor.original").font(.headline)
            ScrollView { Text(record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 100)
            Text("learning.editor.corrected").font(.headline)
            TextEditor(text: $corrected).font(.body).frame(minHeight: 140)
                .accessibilityLabel("learning.editor.corrected")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("learning.editor.save") {
                    saving = true
                    Task {
                        do {
                            try await learning.recordCorrection(record, corrected: corrected)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || corrected == record.text || corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !learning.settings.correctionLearningEnabled)
            }
        }
        .padding(24).frame(width: 600, height: 460)
        .onAppear { corrected = initialText }
    }
}
