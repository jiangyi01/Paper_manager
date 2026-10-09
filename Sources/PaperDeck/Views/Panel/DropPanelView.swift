import SwiftUI
import PaperDeckCore

/// View-side state of the floating panel. DropPanelController owns the state
/// machine and the window frame; the view only renders `mode` and reports
/// gestures and measured heights back through the closures.
@Observable
final class DropPanelModel {
    enum Mode: Hashable {
        case collapsed, peek, armed, targeted, processing
    }

    enum TabDrag {
        case changed, ended
    }

    var mode: Mode = .collapsed
    var edge: PanelPrefs.Edge = .right
    /// A drop landed but its file promises are still being received.
    var awaitingDrop = false

    @ObservationIgnored var onMeasure: (Mode, CGFloat) -> Void = { _, _ in }
    @ObservationIgnored var onTabDrag: (TabDrag) -> Void = { _ in }
    @ObservationIgnored var onCollapse: () -> Void = {}
    @ObservationIgnored var onOpenPaper: (String) -> Void = { _ in }
    @ObservationIgnored var onOpenToday: () -> Void = {}
}

/// Root view of the floating panel (content of a `DropHostingView`).
///
/// Every mode lays out at its final size and is pinned to the docked edge of
/// the window, so while the window frame animates the content slides out like
/// a drawer instead of being squeezed.
struct DropPanelView: View {
    let model: DropPanelModel
    let state: AppState
    let dropState: DropTargetState

    var body: some View {
        let edge = model.edge
        let mode = model.mode
        ZStack {
            switch mode {
            case .collapsed:
                PanelTab(state: state, edge: edge, onDrag: model.onTabDrag, onOpenToday: model.onOpenToday)
                    .transition(.opacity)
            case .peek:
                PeekList(state: state, onOpenPaper: model.onOpenPaper, onOpenToday: model.onOpenToday,
                         onOpenMail: { [model, state] in
                             model.onCollapse()
                             state.router.showMail(nil)
                         })
                    .frame(width: DropPanelMetrics.peekWidth)
                    .panelChrome(edge: edge, style: .material)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsHeight { model.onMeasure(.peek, $0) }
                    .transition(.opacity)
            case .armed, .targeted:
                DropZoneView(dropState: dropState)
                    .frame(width: DropPanelMetrics.armedSize.width, height: DropPanelMetrics.armedSize.height)
                    .panelChrome(edge: edge, style: .glass)
                    .transition(.opacity)
            case .processing:
                PanelProcessingView(state: state, model: model, dropState: dropState)
                    .frame(width: DropPanelMetrics.processingWidth)
                    .panelChrome(edge: edge, style: .material)
                    .fixedSize(horizontal: false, vertical: true)
                    .reportsHeight { model.onMeasure(.processing, $0) }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(mode: mode, edge: edge))
    }

    private func alignment(mode: DropPanelModel.Mode, edge: PanelPrefs.Edge) -> Alignment {
        let topAnchored = mode == .peek || mode == .processing
        switch (edge, topAnchored) {
        case (.right, false): return .leading
        case (.right, true): return .topLeading
        case (.left, false): return .trailing
        case (.left, true): return .topTrailing
        }
    }
}

enum DropPanelMetrics {
    static let tabSize = CGSize(width: 22, height: 84)
    static let armedSize = CGSize(width: 300, height: 200)
    static let peekWidth: CGFloat = 280
    static let processingWidth: CGFloat = 320
}

// MARK: - Collapsed tab

/// 22×84 vertical tab: `books.vertical.fill`, today's count and one status glyph
/// (importing / needs attention / overdue). Drag moves it, click opens 今天.
private struct PanelTab: View {
    let state: AppState
    let edge: PanelPrefs.Edge
    let onDrag: (DropPanelModel.TabDrag) -> Void
    let onOpenToday: () -> Void

    var body: some View {
        let plan = state.snapshot?.today
        let count = plan?.count ?? 0
        let overdue = plan?.overdue.count ?? 0
        let busy = state.hasActiveImports
        let attention = PanelFeedback.needsAttention(state)
        VStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.5)
                    .background(overdue > 0 ? Color.red : Color.accentColor, in: Capsule())
                    .frame(maxWidth: 20)
            }
            if attention {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            } else if overdue > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: DropPanelMetrics.tabSize.width, height: DropPanelMetrics.tabSize.height)
        .panelChrome(edge: edge, radius: 9, style: .glass)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in onDrag(.changed) }
                .onEnded { _ in onDrag(.ended) }
        )
        .help(L.panelTabHint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.panelTabLabel(count: count, overdue: overdue)
                            + (attention ? " · " + L.panelAttention : "")
                            + (busy ? " · " + L.panelBusy : ""))
        .accessibilityHint(L.panelTabHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenToday() }
    }
}

// MARK: - Armed / targeted drop zone

private struct DropZoneView: View {
    let dropState: DropTargetState

    var body: some View {
        let targeted = dropState.isTargeted
        let s = dropState.summary
        VStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: targeted)
                .frame(height: 42)
            Text(targeted
                 ? (dropState.mailFiles > 0 && s.importable == 0
                    ? L.Mail.dropEmails(dropState.mailFiles)
                    : L.panelReleaseToAdd(pdfs: s.pdfFiles + s.promises + (s.pdfData ? 1 : 0), folders: s.folders, links: s.links))
                 : L.panelDropHere)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if targeted && s.otherFiles > 0 {
                Label(L.panelIgnoredOthers(s.otherFiles), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text(L.panelDropKinds)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.14) : Color.clear)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary.opacity(0.55)),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [6, 4]))
            }
        }
        .padding(12)
        .animation(.snappy(duration: 0.18), value: targeted)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Processing

private struct PanelProcessingView: View {
    let state: AppState
    let model: DropPanelModel
    let dropState: DropTargetState

    var body: some View {
        let hasRows = !state.importRows.isEmpty || model.awaitingDrop
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: hasRows ? "tray.and.arrow.down.fill" : "bell.fill")
                    .foregroundStyle(.secondary)
                Text(PanelFeedback.title(state, awaitingDrop: model.awaitingDrop))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: model.onCollapse) {
                    Image(systemName: model.edge == .right ? "chevron.right" : "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L.panelCollapse)
                .accessibilityLabel(L.panelCollapse)
            }
            if hasRows {
                ImportProgressList(state: state, maxRows: 5, showsReceivingPlaceholder: model.awaitingDrop,
                                   onOpenPaper: model.onOpenPaper)
            }
            if !state.toasts.isEmpty {
                ToastStack(state: state, maxVisible: 3)
            }
        }
        .padding(14)
        .overlay {
            if dropState.isTargeted {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(L.panelDropMore).font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                .padding(8)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.18), value: dropState.isTargeted)
    }
}

extension PanelFeedback {
    /// Header of the processing list / menu-bar popover.
    static func title(_ state: AppState, awaitingDrop: Bool = false) -> String {
        let active = state.importRows.count(where: { !$0.stage.isTerminal })
        if active > 0 { return L.panelAdding(active) }
        if awaitingDrop { return L.panelStageReceiving }
        return state.importRows.isEmpty ? L.panelNotices : L.panelAddDone
    }
}

// MARK: - Chrome

enum PanelChromeStyle {
    /// Liquid Glass: the tab and the drop zone (control-like surfaces).
    case glass
    /// Regular material: text-heavy lists (peek, processing) for legibility.
    case material
}

extension View {
    /// Card shape flush with the docked screen edge: rounded on the inner side only.
    func panelChrome(edge: PanelPrefs.Edge, radius: CGFloat = 16, style: PanelChromeStyle) -> some View {
        modifier(PanelChrome(edge: edge, radius: radius, style: style))
    }

    fileprivate func reportsHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { action($0) }
    }
}

private struct PanelChrome: ViewModifier {
    let edge: PanelPrefs.Edge
    let radius: CGFloat
    let style: PanelChromeStyle

    func body(content: Content) -> some View {
        let inner = radius, outer: CGFloat = 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .right ? inner : outer,
            bottomLeadingRadius: edge == .right ? inner : outer,
            bottomTrailingRadius: edge == .left ? inner : outer,
            topTrailingRadius: edge == .left ? inner : outer,
            style: .continuous)
        switch style {
        case .glass:
            content
                .glassEffect(.regular, in: shape)
                .contentShape(shape)
        case .material:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                .clipShape(shape)
                .contentShape(shape)
        }
    }
}
