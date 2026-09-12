import AppKit
import SwiftUI

struct VocabularyRulesView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var newEntry = ""

    var body: some View {
        SettingsPage(title: "personalization.title", subtitle: "personalization.subtitle") {
            CorrectionLearningSection(learning: environment.learning)
            SettingsSection(title: "personalization.dictionary") {
                TermInputRow(
                    placeholder: "personalization.newTerm",
                    value: $newEntry,
                    actionLabel: "personalization.addTerm",
                    onAdd: addEntry
                )
                if environment.dictionaryWords.isEmpty {
                    EmptySettingsRow(text: "personalization.preferredEmpty", icon: "text.book.closed")
                } else {
                    ForEach(Array(environment.dictionaryWords.enumerated()), id: \.element) { index, entry in
                        EditableTermRow(
                            icon: "textformat",
                            term: entry,
                            showsDivider: index < environment.dictionaryWords.count - 1,
                            onSave: { saveEntry(entry, as: $0) },
                            onDelete: { deleteEntry(entry) }
                        )
                    }
                }
            }
        }
    }

    private func addEntry() {
        let clean = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUnique(clean, in: environment.dictionaryWords) else {
            NSSound.beep()
            return
        }
        environment.saveDictionary(environment.dictionaryWords + [clean])
        newEntry = ""
    }

    private func saveEntry(_ old: String, as new: String) -> Bool {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUnique(clean, in: environment.dictionaryWords, excluding: old) else { return false }
        environment.saveDictionary(environment.dictionaryWords.map { $0 == old ? clean : $0 })
        return true
    }

    private func deleteEntry(_ entry: String) {
        environment.saveDictionary(environment.dictionaryWords.filter { $0 != entry })
    }

    private func isUnique(_ value: String, in values: [String], excluding: String? = nil) -> Bool {
        guard !value.isEmpty else { return false }
        return !values.contains {
            $0 != excluding && $0.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

private struct TermInputRow: View {
    let placeholder: LocalizedStringKey
    @Binding var value: String
    let actionLabel: LocalizedStringKey
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $value)
                .onSubmit(onAdd)
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .help(actionLabel)
            .accessibilityLabel(actionLabel)
            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 12)
        }
    }
}

private struct EmptySettingsRow: View {
    let text: LocalizedStringKey
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
    }
}

private struct EditableTermRow: View {
    let icon: String
    let term: String
    let showsDivider: Bool
    let onSave: (String) -> Bool
    let onDelete: () -> Void

    @State private var draft: String
    @State private var isEditing = false

    init(
        icon: String,
        term: String,
        showsDivider: Bool,
        onSave: @escaping (String) -> Bool,
        onDelete: @escaping () -> Void
    ) {
        self.icon = icon
        self.term = term
        self.showsDivider = showsDivider
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: term)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if isEditing {
                TextField("", text: $draft)
                    .onSubmit(commit)
            } else {
                Text(verbatim: term)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                if isEditing { commit() } else { isEditing = true }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .frame(
                        minWidth: SettingsControlMetrics.minIconHitTarget,
                        minHeight: SettingsControlMetrics.minIconHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isEditing ? "common.done" : "common.edit")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .frame(
                        minWidth: SettingsControlMetrics.minIconHitTarget,
                        minHeight: SettingsControlMetrics.minIconHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("common.delete")
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider().padding(.leading, 44) }
        }
        .onChange(of: term) { _, value in draft = value }
    }

    private func commit() {
        if onSave(draft) {
            isEditing = false
        } else {
            NSSound.beep()
        }
    }
}

struct PromptStudioSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var tab = PromptStudioTab.edit
    @State private var draft = ""
    @State private var testInput = ""
    @State private var showingDiscardConfirmation = false
    @FocusState private var testEditorFocused: Bool

    private var savedPrompt: String {
        environment.settings.customPrompt.isEmpty
            ? ReasoningService.defaultCleanupPrompt
            : environment.settings.customPrompt
    }

    private var isDirty: Bool { draft != savedPrompt }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("promptStudio.title")
                        .font(.title2.weight(.semibold))
                    Text("promptStudio.subtitle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Picker("", selection: $tab) {
                    Label("promptStudio.edit", systemImage: "pencil").tag(PromptStudioTab.edit)
                    Label("promptStudio.test", systemImage: "testtube.2").tag(PromptStudioTab.test)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button {
                    if isDirty {
                        showingDiscardConfirmation = true
                    } else {
                        dismiss()
                    }
                } label: {
                    if isDirty {
                        Text("common.cancel")
                    } else {
                        Text("common.close")
                    }
                }
                Spacer()
                Button("promptStudio.reset") {
                    draft = ReasoningService.defaultCleanupPrompt
                }
                Button("common.save") {
                    var settings = environment.settings
                    settings.customPrompt = draft == ReasoningService.defaultCleanupPrompt ? "" : draft
                    environment.saveSettings(settings)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
            }
            .padding(16)
        }
        .frame(width: 720, height: 570)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog(
            "promptStudio.discard.title",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("promptStudio.discard", role: .destructive) { dismiss() }
            Button("common.cancel", role: .cancel) {}
        }
        .onAppear {
            draft = savedPrompt
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .edit:
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        case .test:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("promptStudio.testShortcutHint", systemImage: "keyboard")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: dictationHotkeyName)
                        .font(.callout.monospaced().weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $testInput)
                        .font(.body)
                        .focused($testEditorFocused)
                        .padding(8)
                    if testInput.isEmpty && !testEditorFocused {
                        Text("promptStudio.testPlaceholder")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
        }
    }

    private var dictationHotkeyName: String {
        HotkeyCapture.displayName(
            for: environment.settings.dictationKey,
            language: environment.settings.uiLanguage
        )
    }
}

private enum PromptStudioTab: String, CaseIterable {
    case edit
    case test
}
