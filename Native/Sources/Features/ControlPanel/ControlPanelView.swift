import AppKit
import SwiftUI

enum ControlPanelWindowMetrics {
    static let minimumContentSize = NSSize(width: 1000, height: 600)
    static let minimumWindowSize = NSSize(width: 1000, height: 640)
    static let defaultContentSize = NSSize(width: 1040, height: 700)
}

enum ControlPanelSection: String, CaseIterable, Identifiable {
    case usage
    case dictation
    case processing
    case vocabulary
    case history
    case privacy

    var id: String { rawValue }

    static func resolve(_ value: String) -> ControlPanelSection {
        ControlPanelSection(rawValue: value) ?? .usage
    }

    var title: LocalizedStringKey {
        switch self {
        case .usage: "sidebar.general"
        case .dictation: "sidebar.speechRecognition"
        case .processing: "sidebar.textProcessing"
        case .vocabulary: "sidebar.personalization"
        case .history: "sidebar.history"
        case .privacy: "sidebar.privacy"
        }
    }

    var icon: String {
        switch self {
        case .usage: "switch.2"
        case .dictation: "waveform"
        case .processing: "wand.and.stars"
        case .vocabulary: "text.book.closed"
        case .history: "clock"
        case .privacy: "hand.raised"
        }
    }
}

struct ControlPanelView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @AppStorage("controlPanel.selectedSection") private var storedSelection = ControlPanelSection.usage.rawValue
    // P3-1: Reduce Motion 打开时侧栏选中态切换不再走 160ms ease-out。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !environment.isReady {
                // P2-14: a failed initialize() now stays at isReady = false,
                // so this branch must offer the reason and a retry instead of
                // spinning forever on an app that will never become ready.
                if let reason = environment.degradedReason {
                    degradedStartupPane(reason)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if !environment.settings.onboardingCompleted {
                OnboardingView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail(for: selectedSection)
                }
                .navigationSplitViewStyle(.balanced)
                .frame(
                    minWidth: ControlPanelWindowMetrics.minimumContentSize.width,
                    minHeight: ControlPanelWindowMetrics.minimumContentSize.height
                )
                .background(ControlPanelWindowConfiguration())
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CorrectionEditorHost(learning: environment.learning))
        .onAppear { ControlPanelWindowAccess.open = openWindow }
        .alert(
            AppLocalization.string("common.error", language: environment.settings.uiLanguage),
            isPresented: Binding(
                get: { environment.settings.onboardingCompleted && environment.startupError != nil },
                set: { presented in if !presented { environment.dismissStartupError() } }
            )
        ) {
            Button("common.ok") { environment.dismissStartupError() }
        } message: {
            Text(environment.startupError ?? "")
        }
        // P2-7: transient operation failures get their own presentation so
        // they neither overwrite nor are blocked by the fatal startup alert
        // above. The toast auto-dismisses; a newer message restarts the
        // window because changing the `.task` id cancels the pending timer.
        .overlay(alignment: .bottom) {
            if let message = environment.operationError {
                operationErrorToast(message)
            }
        }
        .task(id: environment.operationError) {
            guard environment.operationError != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            environment.dismissOperationError()
        }
    }

    // P2-14: the degraded startup state. `initialize()` failing leaves the
    // environment at isReady = false with a reason attached, so the panel
    // states what broke and offers the only recovery that exists —
    // re-running the same initialization — instead of a spinner that will
    // never resolve. The fatal `startupError` alert above still fires
    // independently; this pane is what remains on screen after it is
    // dismissed.
    private func degradedStartupPane(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("common.error")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("common.retry") { environment.retryInitialize() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func operationErrorToast(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Button {
                environment.dismissOperationError()
            } label: {
                Image(systemName: "xmark")
                    .frame(
                        minWidth: SettingsControlMetrics.minIconHitTarget,
                        minHeight: SettingsControlMetrics.minIconHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("common.close")
            .accessibilityLabel("common.close")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
    }

    private var selectedSection: ControlPanelSection {
        ControlPanelSection.resolve(storedSelection)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                MouthpieceBrandIcon(size: 24)
                Text("Mouthpiece")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if !environment.permissions.accessibility {
                AccessibilityPermissionBanner()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(ControlPanelSection.allCases) { section in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                storedSelection = section.rawValue
                            }
                        } label: {
                            SidebarNavigationRow(
                                section: section,
                                isSelected: section == selectedSection
                            )
                        }
                        .buttonStyle(SidebarNavigationButtonStyle())
                        .help(section.title)
                        .accessibilityAddTraits(section == selectedSection ? .isSelected : [])
                        .onMoveCommand(perform: moveSelection)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .background(SidebarGlassBackground())
        .navigationSplitViewColumnWidth(min: 188, ideal: 196, max: 204)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = ControlPanelSection.allCases
        guard let index = sections.firstIndex(of: selectedSection) else { return }
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(sections.startIndex, index - 1)
        case .down:
            nextIndex = min(sections.index(before: sections.endIndex), index + 1)
        default:
            return
        }
        storedSelection = sections[nextIndex].rawValue
    }

    @ViewBuilder
    private func detail(for section: ControlPanelSection) -> some View {
        switch section {
        case .usage: UsageSettingsView()
        case .dictation: DictationSettingsView()
        case .processing: ProcessingSettingsView()
        case .vocabulary: VocabularyRulesView()
        case .history: HistoryView()
        case .privacy: PrivacyDiagnosticsView()
        }
    }
}

private struct SidebarNavigationRow: View {
    @Environment(\.colorScheme) private var colorScheme
    // P3-1: Reduce Motion 关闭 hover / isSelected 的 120-160ms ease-out；
    // Increase Contrast 给选中态描边加粗+抬高不透明度，避免仅凭 accent 微弱渐变
    // 区分选中/未选中行。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    let section: ControlPanelSection
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .scaleEffect(isSelected ? 1.06 : 1)
                .frame(width: 18)
            Text(section.title)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundGradient)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isSelected ? selectionStrokeColor : .clear,
                    lineWidth: selectionStrokeWidth
                )
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isSelected
        )
    }

    private var selectionStrokeColor: Color {
        let base = colorScheme == .dark ? 0.28 : 0.2
        return Color.accentColor.opacity(contrast == .increased ? min(1, base + 0.4) : base)
    }

    private var selectionStrokeWidth: CGFloat {
        contrast == .increased ? 1.4 : 0.5
    }

    private var backgroundGradient: LinearGradient {
        let leadingOpacity: Double
        let trailingOpacity: Double
        if isSelected {
            leadingOpacity = colorScheme == .dark ? 0.2 : 0.16
            trailingOpacity = colorScheme == .dark ? 0.11 : 0.08
        } else if isHovered {
            leadingOpacity = colorScheme == .dark ? 0.08 : 0.055
            trailingOpacity = colorScheme == .dark ? 0.04 : 0.025
        } else {
            leadingOpacity = 0
            trailingOpacity = 0
        }
        return LinearGradient(
            colors: [
                Color.accentColor.opacity(leadingOpacity),
                Color.accentColor.opacity(trailingOpacity),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

// D12: 辅助功能权限缺失时的显著引导；按钮跳转系统设置的辅助功能面板。
private struct AccessibilityPermissionBanner: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("permissions.accessibilityBanner.title")
                    .font(.caption.weight(.semibold))
            }
            Text("permissions.accessibilityBanner.message")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("permissions.openSettings") {
                environment.openAccessibilitySettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        }
    }
}

private struct ControlPanelWindowConfiguration: NSViewRepresentable {
    final class WindowProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ControlPanelWindowConfiguration.configure(window)
        }
    }

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(frame: .zero)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {}

    @MainActor
    private static func configure(_ window: NSWindow) {
        let currentSize = window.frame.size
        window.minSize = ControlPanelWindowMetrics.minimumWindowSize
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbar?.isVisible = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if currentSize.width < ControlPanelWindowMetrics.minimumWindowSize.width
            || currentSize.height < ControlPanelWindowMetrics.minimumWindowSize.height {
            window.setContentSize(ControlPanelWindowMetrics.defaultContentSize)
            window.center()
        }
    }
}
