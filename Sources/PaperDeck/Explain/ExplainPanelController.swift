import AppKit
import Observation
import SwiftUI
import PaperDeckCore

/// The floating explanation panel (LN §7.1, dive-ui §4.1): a non-activating `NSPanel` that becomes
/// key — the follow-up field, Esc and the ⌘ shortcuts work — without activating PaperDeck, so the PDF
/// app stays frontmost and keeps its selection (Spotlight-like). It floats above other apps, joins
/// every Space including full-screen ones, and opens beside what was explained (`PanelPlacement`).
/// Clicks elsewhere don't close it; Esc, ✕ or the next capture (unless pinned) do. Owned by the
/// Explain UI lane (A2).
final class ExplainPanel: NSPanel {
    /// Esc (the window's cancel action): stop and close.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// The style every Explain panel uses (a render builds the same one).
    static func make() -> ExplainPanel {
        let p = ExplainPanel(contentRect: NSRect(x: 0, y: 0, width: PanelPlacement.width, height: 320),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.isExcludedFromWindowsMenu = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .utilityWindow
        p.contentMinSize = NSSize(width: 340, height: PanelPlacement.minHeight)
        return p
    }
}

/// A request for the follow-up field's focus (⌘K, "Ask PaperDeck…").
@Observable
final class ExplainPanelFocus {
    var followUpRequest = 0
}

/// One panel window and the conversation it shows.
final class ExplainPanelController: NSObject, NSWindowDelegate {
    let panel: ExplainPanel
    private(set) var state: ExplainPanelState
    let focus = ExplainPanelFocus()
    private weak var coordinator: ExplainCoordinator?
    private let hosting: ExplainPanelHostingView
    /// The user resized the panel: it keeps that size.
    private var userSized = false
    /// The user dragged the panel away: it grows from where they put it (top edge fixed).
    private var userMoved = false
    /// The frame set from here last (a move to anywhere else is the user's).
    private var lastPlaced: CGRect?
    /// What the panel opened beside, the side it went to and that screen's visible frame (CUX-5):
    /// growth keeps the side and never covers the selection.
    private var placement: (anchor: CGRect, side: PanelPlacement.Side, visibleFrame: CGRect)?
    /// `present` ran once (the placeholder state has nothing to close).
    private var presented = false

    init(coordinator: ExplainCoordinator) {
        self.coordinator = coordinator
        panel = ExplainPanel.make()
        // A placeholder until `present` (never shown).
        state = ExplainPanelState(capture: ExplainCapture(source: .clipboard), services: PlaceholderExplainServices(),
                                  language: .zh, depth: .quick)
        hosting = ExplainPanelHostingView(rootView: AnyView(EmptyView()))
        super.init()
        hosting.coordinator = coordinator
        panel.contentView = hosting
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.escape() }
    }

    /// Shows `newState` beside `anchor` (AppKit global; a zero rect at the mouse for text triggers).
    /// The previous conversation of this panel closes (its turn stops, its session ends).
    func present(_ newState: ExplainPanelState, near anchor: CGRect, index: Int) {
        let old = state
        state = newState
        if presented { Task { await old.close() } }
        presented = true
        hosting.rootView = AnyView(rootView())
        userSized = false
        userMoved = false
        let screens = NSScreen.screens
        let i = PanelPlacement.screenIndex(for: CGPoint(x: anchor.midX, y: anchor.midY), frames: screens.map(\.frame)) ?? 0
        let vf = screens.indices.contains(i) ? screens[i].visibleFrame : (NSScreen.main?.visibleFrame ?? .zero)
        // Opened at the smallest height; the content's real height then grows it (`fit`).
        let size = CGSize(width: PanelPlacement.width, height: PanelPlacement.height(for: Self.initialHeight, visibleFrame: vf))
        let placed = PanelPlacement.frame(size: size, anchor: anchor, visibleFrame: vf)
        placement = (anchor, placed.side, vf)
        place(PanelPlacement.cascade(placed.frame, index: index, visibleFrame: vf))
        panel.orderFrontRegardless()
        panel.makeKey()                         // key without activating PaperDeck (non-activating panel)
    }

    /// The height a panel opens at before its content reports its own.
    static let initialHeight: CGFloat = 300

    private func place(_ frame: CGRect) {
        lastPlaced = frame
        panel.setFrame(frame, display: true, animate: false)
        lastPlaced = panel.frame
    }

    private func rootView() -> some View {
        ExplainPanelView(state: state, app: coordinator?.app, focus: focus, actions: actions, style: .glass)
    }

    /// What the view's buttons do besides the panel state's own gestures.
    private var actions: ExplainPanelActions {
        ExplainPanelActions(
            close: { [weak self] in self?.close() },
            setPinned: { [weak self] on in guard let self else { return }; self.coordinator?.setPinned(self, on) },
            canPinMore: { [weak self] in self?.coordinator?.canPinMore ?? false },
            showHistory: { [weak self] in self?.coordinator?.showHistory() },
            copied: { [weak self] in self?.coordinator?.noteOwnPasteboardWrite() },
            idealHeight: { [weak self] h in self?.fit(contentHeight: h) },
            explainAgain: { [weak self] ticket in self?.explainAgain(ticket: ticket) })
    }

    /// "Not this paper" / a picked paper (CUX-6): the same capture explained again with the click's
    /// ticket — the locator now follows the user's correction (`PaperMatchCorrections`).
    private func explainAgain(ticket: ConsentTicket) {
        guard let coordinator else { return }
        let s = state
        let anchor = placement?.anchor ?? panel.frame
        coordinator.begin(capture: s.capture, ticket: ticket, anchor: nil, kind: s.turns.first?.kind ?? s.pending ?? .explain,
                          near: anchor, depth: s.depth, language: s.language)
    }

    func focusFollowUp() { focus.followUpRequest += 1 }

    /// Esc: a running turn stops, then the panel closes.
    private func escape() { close() }

    func close() { coordinator?.close(self) }

    /// Ends the conversation and hides the window (the coordinator forgets the panel).
    func dismiss() {
        let s = state
        Task { await s.close() }
        panel.orderOut(nil)
    }

    /// Grows (or shrinks) the panel to its content within the height range (CUX-5): on the side it
    /// opened on, never over the selection (`PanelPlacement.refit`); a panel the user moved keeps its
    /// top edge where they put it.
    private func fit(contentHeight: CGFloat) {
        guard !userSized, panel.isVisible else { return }
        let vf = placement?.visibleFrame ?? (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let h = PanelPlacement.height(for: contentHeight, visibleFrame: vf)
        let f = panel.frame
        guard abs(f.height - h) > 2 else { return }
        if let p = placement, !userMoved {
            let next = PanelPlacement.refit(f, side: p.side, anchor: p.anchor, height: h, visibleFrame: p.visibleFrame)
            placement?.side = next.side
            place(next.frame)
        } else {
            place(PanelPlacement.refit(f, side: .right, anchor: .zero, height: h, visibleFrame: vf).frame)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { userSized = true }

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, let last = lastPlaced else { return }
        if abs(panel.frame.minX - last.minX) > 1 || abs(panel.frame.maxY - last.maxY) > 1 { userMoved = true }
    }
}

/// The panel's content view: also takes image drops (an image or a screenshot thumbnail dropped on
/// the panel is explained; `DropIntake` mints the drop's ticket).
final class ExplainPanelHostingView: NSHostingView<AnyView> {
    weak var coordinator: ExplainCoordinator?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropIntake.explainDragTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DropIntake.isExplainImageDrag(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let coordinator else { return false }
        return DropIntake.explainImages(sender.draggingPasteboard, coordinator: coordinator,
                                        near: window.map { CGRect(origin: $0.frame.origin, size: .zero) })
    }
}

/// The services of the placeholder state a fresh panel holds before its first `present` (and of the
/// fix renders' fixture panels): nothing is prepared, judged, sent or stored.
final class PlaceholderExplainServices: ExplainServicing {
    var assistSettings: AssistSettings { AssistSettings() }
    var now: Date { Date() }
    func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared {
        ExplainPrepared(selection: nil, image: nil, content: .text, match: nil)
    }
    func privacy(paperID: String?, hostBundleID: String?) async -> AssistPrivacy.Verdict? { nil }
    func request(_ spec: ExplainTurnSpec) -> AssistRequest {
        AssistRequest(surface: .explain, systemPrompt: "", turnText: "", model: "",
                      limits: AssistLimits.defaults(for: .explain, provider: nil))
    }
    func submit(_ request: AssistRequest, ticket: ConsentTicket) async -> AsyncStream<AssistEvent> {
        AsyncStream { $0.finish() }
    }
    func cancelTurn() async {}
    func closeSession(threadKey: String) async {}
    func save(_ record: ExplanationRecord, anchor: ReaderAnchor?) async throws -> ExplanationRecord { record }
    func setPinned(ids: [String], _ pinned: Bool) async {}
    func appendToNotes(id: String) async throws {}
}
