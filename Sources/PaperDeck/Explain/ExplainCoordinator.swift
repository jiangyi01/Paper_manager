import AppKit
import Observation
import PaperDeckCore

/// Explain's coordinator (LN §7.5, plan §7): the overlay the shortcut opens, the floating panels and
/// their conversations (`ExplainPanelState`, Core), the global shortcut, the Services entries and the
/// history window. Every trigger made in PaperDeck ends in `begin(capture:ticket:)` with the ticket
/// its gesture minted (the overlay's box / lens / clipboard offer, an image drop, the reader's
/// toolbar); a Services request opens its panel held at [Send] instead (`holdForSend`, F10). Nothing
/// here mints a ticket; the decisions — what the shortcut does, when it is held, which captures wait
/// — are Core's `ExplainTriggerRules` (F5). Before a capture's panel opens, `begin` adds who was on
/// screen under it (`CaptureSurroundings`: every window in the region, PaperDeck's own readers and
/// their papers, the app copied text came from) for the privacy check (F1 / F2). One unpinned panel
/// is reused by the next capture (its turn is stopped first); up to three pinned panels stay.
/// `isAvailable` false hides every Explain menu item, the shortcut and the Services provider.
/// Owned by the Explain UI lane (Slice A).
@Observable
final class ExplainCoordinator {
    /// Explain ships (menus, hotkey, Services, the panel). Flipped on by the phase-3 integration.
    static let isAvailable = true

    /// At most this many pinned panels.
    static let maxPinned = 3

    /// The shortcut's registration (Settings shows it).
    private(set) var hotKeyStatus: HotKeyRegistration = .notRegistered
    /// The panels on screen: the reusable one and the pinned ones.
    private(set) var panels: [ExplainPanelController] = []

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private let servicesOverride: (any ExplainServicing)?
    @ObservationIgnored private let liveServices: (any ExplainServicing)?
    @ObservationIgnored let capturer: any ScreenCapturing
    @ObservationIgnored let hotKeys: any HotKeyRegistering
    @ObservationIgnored private(set) var overlay: CaptureOverlayController!
    @ObservationIgnored private var debounce = ExplainDebounce()
    @ObservationIgnored private var lastHotKeyPress: Date?
    /// The pasteboard's change count after the last Explain of it or PaperDeck's own copy: the
    /// overlay offers the clipboard only when it changed since.
    @ObservationIgnored var lastClipboardChange: Int?
    /// Which app the pasteboard was last written in (app activations with the change count only).
    @ObservationIgnored private var clipboardSources = ClipboardSourceTracker()
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(state: AppState?, services: (any ExplainServicing)? = nil, capturer: (any ScreenCapturing)? = nil,
         hotKeys: (any HotKeyRegistering)? = nil) {
        self.state = state
        self.servicesOverride = services
        self.liveServices = services == nil ? state.map { LiveExplainServices.make(engine: $0.engine) } : nil
        self.capturer = capturer ?? LiveExplainServices.liveCapturer()
        self.hotKeys = hotKeys ?? CarbonHotKeyCenter.shared
        overlay = CaptureOverlayController(coordinator: self)
        trackClipboardSources()
    }

    var app: AppState? { state }
    var services: (any ExplainServicing)? { servicesOverride ?? liveServices }
    private var settings: AssistSettings { state?.settings.assist ?? AssistSettings() }

    /// What Explain is doing: the overlay's phase while it is up, else the front panel's.
    var phase: ExplainPhase {
        if let p = overlay.phase { return p }
        return panels.last?.state.phase ?? .idle
    }

    // MARK: Triggers (frozen entry points)

    /// Every trigger ends here with the capture and its gesture's ticket.
    func begin(capture: ExplainCapture, ticket: ConsentTicket) {
        begin(capture: capture, ticket: ticket, anchor: nil, kind: .explain, near: nil)
    }

    /// `begin` with the reader's exact anchor (A4), the turn to run (a chip from the reader's
    /// toolbar), the screen rect to open beside — for a box, a lens click or a click's band the
    /// captured region itself (Cocoa), which the privacy check reads the windows of — the depth (⌥)
    /// and the overlay's Tab language. A box is debounced 1 s, any other trigger 0.6 s (F9).
    func begin(capture: ExplainCapture, ticket: ConsentTicket, anchor: ReaderAnchor?, kind: ExplainTurnKind = .explain,
               near rect: CGRect?, depth: AssistSettings.Depth? = nil, language: UILang? = nil) {
        guard state != nil, let services,
              debounce.allow(at: Date(), interval: ExplainTriggerRules.debounce(for: capture)) else { return }
        overlay.dismiss()
        let panelState = makeState(capture: withSurroundings(capture, near: rect), anchor: anchor, services: services)
        if let language { panelState.language = language }
        let panel = reusablePanel()
        panel.present(panelState, near: rect ?? PanelPlacement.pointAnchor(NSEvent.mouseLocation), index: pinnedCount)
        switch ExplainTriggerRules.start(for: ticket.gesture) {
        case .send: panelState.run(kind, ticket: ticket, depth: depth)
        case .holdForSend: panelState.holdForSend(kind)          // a Services invocation never sends by itself
        }
    }

    /// Services ▸ "Explain with PaperDeck" (F10): the panel opens with the selection held at
    /// [Send]; that click or ⏎ in the panel — a fresh gesture in PaperDeck — mints the ticket.
    /// Another app calling the service can't start a turn.
    func holdForSend(capture: ExplainCapture, kind: ExplainTurnKind) {
        guard state != nil, let services else { return }
        overlay.dismiss()
        let panelState = makeState(capture: withSurroundings(capture, near: nil), anchor: nil, services: services)
        let panel = reusablePanel()
        panel.present(panelState, near: PanelPlacement.pointAnchor(NSEvent.mouseLocation), index: pinnedCount)
        panelState.holdForSend(kind)
    }

    /// Services ▸ "Ask PaperDeck…": the panel opens with the selection and the question field
    /// focused; nothing is sent until the user asks.
    func openForQuestion(capture: ExplainCapture) {
        guard state != nil, let services else { return }
        overlay.dismiss()
        let panelState = makeState(capture: withSurroundings(capture, near: nil), anchor: nil, services: services)
        let panel = reusablePanel()
        panel.present(panelState, near: PanelPlacement.pointAnchor(NSEvent.mouseLocation), index: pinnedCount)
        panel.focusFollowUp()
    }

    /// The shortcut (or Explain ▸ Explain…) opens the overlay in `mode`; pressed again while it is up
    /// it switches frame ↔ lens. A warm Claude process may start meanwhile (no turn, no quota).
    func arm(mode: AssistSettings.OverlayMode) {
        guard state != nil else { return }
        if overlay.isShown {
            overlay.toggleMode()
            return
        }
        overlay.show(mode: mode)
        prewarm()
    }

    /// Explain ▸ Explain Copied Text: the clipboard now (the menu click is the gesture).
    func explainClipboard() {
        guard state != nil else { return }
        overlay.explainClipboardFromMenu()
    }

    /// Explain ▸ Explanation History.
    func showHistory() {
        guard let state else { return }
        ExplainHistoryWindowController.show(state: state)
    }

    /// The global shortcut fired (Carbon, on the main thread): `ExplainTriggerRules.onHotKey` decides
    /// — open the overlay, switch frame ↔ lens, or (pressed twice quickly) show the clipboard offer.
    /// The shortcut alone never sends (F4): the offer still needs ⏎ or a click.
    func hotKeyPressed() {
        let now = Date()
        defer { lastHotKeyPress = now }
        switch ExplainTriggerRules.onHotKey(overlayShown: overlay.isShown, lastPress: lastHotKeyPress, now: now,
                                            defaultMode: settings.explainDefaultMode) {
        case .open(let mode):
            arm(mode: mode)
        case .toggleMode:
            overlay.toggleMode()
        case .showOffer:
            let pb = NSPasteboard.general
            overlay.model.offer = ExplainTriggerRules.offerOnDoubleTap(changeCount: pb.changeCount,
                                                                       types: (pb.types ?? []).map(\.rawValue))
        }
    }

    // MARK: Panels

    private func makeState(capture: ExplainCapture, anchor: ReaderAnchor?, services: any ExplainServicing) -> ExplainPanelState {
        ExplainPanelState(capture: capture, anchor: anchor, services: services,
                          language: ExplainLanguageToggle.initial(settings.explainLanguage, ui: L.lang), depth: settings.explainDepth)
    }

    private var pinnedCount: Int { panels.filter { $0.state.pinned }.count }

    /// The unpinned panel (its old conversation closes), or a new one.
    private func reusablePanel() -> ExplainPanelController {
        if let p = panels.first(where: { !$0.state.pinned }) {
            panels.removeAll { $0 === p }
            panels.append(p)
            return p
        }
        let p = ExplainPanelController(coordinator: self)
        panels.append(p)
        return p
    }

    /// Esc / ✕: the panel's turn stops and the panel closes.
    func close(_ panel: ExplainPanelController) {
        panel.dismiss()
        panels.removeAll { $0 === panel }
    }

    /// Pin / unpin (at most `maxPinned`).
    func setPinned(_ panel: ExplainPanelController, _ on: Bool) {
        guard !on || pinnedCount < Self.maxPinned else { NSSound.beep(); return }
        Task { await panel.state.setPinned(on) }
    }

    var canPinMore: Bool { pinnedCount < Self.maxPinned }

    /// Quit, or Explain switched off: every panel and the overlay close.
    func closeAll() {
        overlay.dismiss()
        panels.forEach { $0.dismiss() }
        panels.removeAll()
    }

    /// The windows Explain itself puts on screen (kept out of every capture).
    var ownWindowIDs: [CGWindowID] {
        (panels.map(\.panel) as [NSWindow] + overlay.windows).compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }
    }

    // MARK: Who was on screen (privacy only, F1 / F2)

    /// `capture` with its surroundings (unless the trigger already set them): for a box / lens /
    /// click every window in the region (`near`, Cocoa) and PaperDeck's own windows with their
    /// papers; for Services the calling app's window; for the clipboard the frontmost window and the
    /// app the text was copied in. Read locally, never sent.
    private func withSurroundings(_ capture: ExplainCapture, near rect: CGRect?) -> ExplainCapture {
        guard capture.surroundings == nil else { return capture }
        var c = capture
        let own = ExplainOwnWindows.roles(state: state)
        switch ExplainTriggerRules.surroundings(for: capture.source) {
        case .none:
            break
        case .region:
            guard let rect else { break }
            let region = CaptureGeometry.cocoa(fromQuartz: rect, mainHeight: NSScreen.screens.first?.frame.height ?? 0)
            c.surroundings = WindowTitleReader.surroundings(region: region, point: ExplainTriggerRules.point(in: region, focus: c.focus),
                                                            excluding: Set(ownWindowIDs), own: own)
        case .frontWindow:
            c.surroundings = WindowTitleReader.textSurroundings(copiedIn: nil, own: own)
        case .copiedFrom:
            let source = clipboardSources.source(of: NSPasteboard.general.changeCount)?.bundleID
            c.surroundings = WindowTitleReader.textSurroundings(copiedIn: source, own: own)
        }
        // The window title for the paper locator and the webmail check, when the trigger had none.
        if c.windowTitle == nil, let primary = c.surroundings?.primaryHost, primary.bundleID == c.hostBundleID || c.hostBundleID == nil {
            c.windowTitle = primary.title
            if c.hostBundleID == nil { c.hostBundleID = primary.bundleID }
        }
        return c
    }

    /// Notes each app activation with the pasteboard's change count (never its contents), while
    /// Explain & Ask is on: the clipboard offer then knows which app the text was copied in.
    private func trackClipboardSources() {
        noteActivation(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.noteActivation(id) }
        }
    }

    private func noteActivation(_ bundleID: String?) {
        guard settings.mode != .off else { return }
        clipboardSources.noteActivation(bundleID: bundleID, changeCount: NSPasteboard.general.changeCount)
    }

    /// PaperDeck itself wrote the pasteboard (Copy in a panel): not offered back.
    func noteOwnPasteboardWrite() { lastClipboardChange = NSPasteboard.general.changeCount }

    // MARK: Shortcut

    /// Registers `assist.explain.hotkey` (again after Settings changed it) — only while the shared
    /// switch (`assist.mode`) is on: with it off no global shortcut is held (Explain's menu items
    /// still open the overlay, and the panel offers the switch).
    func registerHotKey() {
        guard settings.mode != .off else {
            hotKeys.unregister()
            hotKeyStatus = .switchedOff
            return
        }
        hotKeyStatus = hotKeys.register(settings.explainHotKey) { [weak self] in self?.hotKeyPressed() }
    }

    func unregisterHotKey() {
        hotKeys.unregister()
        hotKeyStatus = .notRegistered
    }

    // MARK: Warm process

    /// The shortcut armed Explain: Claude may start (and check its login) ahead of the first turn —
    /// only with "Keep Claude ready" on and the gate's `checkSpawn`; idle processes close after
    /// `assist.keepWarm` and cost no quota (spike Q3).
    private func prewarm() {
        guard let engine = state?.engine, ExplainTriggerRules.prewarms(settings) else { return }
        let token = ArmingToken.arm()
        Task { await engine.assist.prewarm(token) }
    }
}
