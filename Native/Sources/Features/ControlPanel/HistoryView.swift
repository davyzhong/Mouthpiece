import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.undoManager) private var undoManager

    @State private var query = ""
    @State private var dateFilter = HistoryDateFilter.all
    @State private var showingClearConfirmation = false

    var body: some View {
        let records = filteredRecords
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                SettingsPageHeader(title: "history.title", subtitle: "history.subtitle")
                Spacer()
                Picker("history.filter", selection: $dateFilter) {
                    ForEach(HistoryDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("history.clear", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(environment.transcriptions.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            if records.isEmpty {
                HistoryEmptyView(hasSearch: !query.isEmpty || dateFilter != .all)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(records) { item in
                            HistoryCard(
                                item: item,
                                onCopyProcessed: { copy(item.text) },
                                onCopyOriginal: { rawText in copy(rawText) },
                                onDelete: { delete(item) },
                                onCorrect: environment.settings.correctionLearningEnabled
                                    ? { environment.learning.editCorrection(item) } : nil
                            )
                        }
                        if environment.hasMoreHistory {
                            Button("history.loadMore") {
                                environment.loadMoreHistory()
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            }

            // P1-8: 保留策略披露——固定文案说明 90 天/2000 行的自动清理阈值。
            // 与 HistoryRepository.retention* 常量绑定，确保 UI 与实际策略一致。
            Text(
                String(
                    format: NSLocalizedString("history.retentionFooter", comment: ""),
                    HistoryRepository.retentionDays,
                    HistoryRepository.retentionMaxRows
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $query, placement: .toolbar, prompt: Text("history.search"))
        .task(id: query) {
            // D7: 简单 debounce 后将搜索词下推到 SQL 查询。
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            environment.searchHistory(query)
        }
        .confirmationDialog(
            "history.clear.confirmTitle",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("history.clear.confirm", role: .destructive) {
                environment.clearHistory()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("history.clear.confirmBody")
        }
        .onAppear {
            environment.refreshHistory()
        }
    }

    private var filteredRecords: [TranscriptionRecord] {
        // 文本匹配已下推到 SQL（environment.searchHistory）；此处仅保留日期过滤。
        environment.transcriptions.filter { dateFilter.includes($0.timestamp) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.writeTranscriptText(text)
    }

    private func delete(_ item: TranscriptionRecord) {
        environment.deleteTranscription(item.id)
        undoManager?.registerUndo(withTarget: environment) { target in
            target.restoreTranscription(item)
        }
        undoManager?.setActionName(
            AppLocalization.string(
                "history.delete.action",
                language: environment.settings.uiLanguage
            )
        )
    }
}

private struct HistoryCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: TranscriptionRecord
    let onCopyProcessed: () -> Void
    let onCopyOriginal: (String) -> Void
    let onDelete: () -> Void
    var onCorrect: (() -> Void)? = nil

    private var originalText: String? {
        guard let rawText = item.rawText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else { return nil }
        return rawText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                Text(item.timestamp.formatted(date: .long, time: .shortened))
                Spacer()
                if let onCorrect {
                    Button("learning.correct", action: onCorrect)
                        .buttonStyle(.bordered)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(
                            minWidth: SettingsControlMetrics.minIconHitTarget,
                            minHeight: SettingsControlMetrics.minIconHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("common.delete")
                .accessibilityLabel("common.delete")
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                textColumn(
                    title: "history.processedText",
                    text: item.text,
                    copyLabel: "history.copyProcessed",
                    onCopy: onCopyProcessed
                )
                Divider()
                textColumn(
                    title: "history.originalText",
                    text: originalText,
                    copyLabel: "history.copyOriginal",
                    onCopy: { if let originalText { onCopyOriginal(originalText) } }
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorder, lineWidth: 0.5)
        }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }

    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.075)
    }

    private func textColumn(
        title: LocalizedStringKey,
        text: String?,
        copyLabel: LocalizedStringKey,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .frame(
                            minWidth: SettingsControlMetrics.minIconHitTarget,
                            minHeight: SettingsControlMetrics.minIconHitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copyLabel)
                .accessibilityLabel(copyLabel)
                .disabled(text == nil)
            }
            if let text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("history.originalUnavailable")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct HistoryEmptyView: View {
    let hasSearch: Bool

    var body: some View {
        ContentUnavailableView(
            hasSearch ? "history.noResults.title" : "history.empty.title",
            systemImage: hasSearch ? "magnifyingglass" : "waveform",
            description: Text(hasSearch ? "history.noResults.body" : "history.empty.body")
        )
    }
}

enum HistoryDateFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case week
    case month

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "history.filter.all"
        case .today: "history.filter.today"
        case .week: "history.filter.week"
        case .month: "history.filter.month"
        }
    }

    func includes(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            true
        case .today:
            calendar.isDate(date, inSameDayAs: now)
        case .week:
            date >= calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .month:
            date >= calendar.date(byAdding: .month, value: -1, to: now) ?? .distantPast
        }
    }
}

enum HistorySearch {
    static func matches(
        _ item: TranscriptionRecord,
        query: String,
        dateFilter: HistoryDateFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard dateFilter.includes(item.timestamp, now: now, calendar: calendar) else { return false }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return true }
        return item.text.localizedCaseInsensitiveContains(cleanQuery)
            || item.rawText?.localizedCaseInsensitiveContains(cleanQuery) == true
    }
}
