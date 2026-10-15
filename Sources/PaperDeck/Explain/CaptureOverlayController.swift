import AppKit
import Observation
import SwiftUI
import PaperDeckCore

/// The overlay the shortcut opens (LN §3–§4.1, dive-capture §2): one borderless, non-activating panel
/// per display at screen-saver level (above full-screen apps, every Space), key so Esc / Space /
/// Return / Tab reach it while the PDF app stays frontmost. It shows the HUD (Box | Lens, the
/// hint, Esc), the clipboard offer "Explain copied text ⏎" when the pasteboard changed since the last
/// Explain, and — while Screen Recording is off — the card with the zero-permission ways and
/// [Enable Screen Capture…]. The frame and lens visuals over the frozen screens (`captureLayer`,
/// `CaptureLayerView`) report the user's box to `regionChosen` and a click to `released`.
///
/// The gestures that start a turn mint their ticket here, in their handler: Return / a click on the
/// offer (`.clipboard`), Explain ▸ Explain Copied Text (`.clipboard`), a
/// released box or a click in frame mode (`.box`), a lens click (`.lens`). Owned by the Explain UI
/// lane (A2); the frame / lens layer and the click path by the phase-3 integration.
final class CaptureOverlayController {
    /// What the frame / lens layer gets: the display, the frozen still (nil while still freezing),
    /// the mode, the display's layer state (its still arrives there) and the controller to report to.
    struct LayerContext {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let frozen: FrozenScreens?
        let mode: AssistSettings.OverlayMode
        let controller: CaptureOverlayController
        let layer: CaptureLayerModel
    }

    /// The frame / lens content drawn over each display's frozen still; nil draws the HUD and cards only.
    static var captureLayer: ((LayerContext) -> AnyView)? = { ctx in
        AnyView(CaptureLayerView(layer: ctx.layer, overlay: ctx.controller.model, controller: ctx.controller))
    }

    let model = CaptureOverlayModel()
    private weak var coordinator: ExplainCoordinator?
    private var panels: [CaptureOverlayPanel] = []
    private var frozen: FrozenScreens?
    private var freezeTask: Task<Void, Never>?
    /// Each display's frame / lens state.
    private var layers: [CGDirectDisplayID: CaptureLayerModel] = [:]
    /// The app in front when the overlay opened (it stays frontmost: nothing here activates).
    private var frontApp: NSRunningApplication?
    /// The displays when the overlay opened (CUX-3: a configuration change dismisses it).
    private var openedDisplays: [CaptureOverlayLifecycle.Display] = []
    /// The Space / screen / sleep / session observers while the overlay is up.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The display showing the HUD and the cards.
    private var hudDisplay: CGDirectDisplayID?
    private var noticeTask: Task<Void, Never>?
    /// The chosen capture being cropped and encoded off the main thread (CUX-7); closing cancels it.
    private var finishTask: Task<Void, Never>?
    /// Which overlay session is up: every show and dismiss starts a new one, so a gesture queued
    /// behind an earlier session's freeze is dropped, never delivered into a later session.
    private var session = 0

    init(coordinator: ExplainCoordinator) { self.coordinator = coordinator }

    var isShown: Bool { !panels.isEmpty }
    var windows: [NSWindow] { panels }

    /// The coordinator's phase while the overlay is up.
    var phase: ExplainPhase? {
        guard isShown else { return nil }
        if !model.captureAllowed { return .permissionNeeded }
        return model.capturing ? .capturing : .armed(model.mode)
    }

    // MARK: Show / dismiss

    func show(mode: AssistSettings.OverlayMode) {
        guard let coordinator else { return }
        dismiss()
        session += 1
        frontApp = NSWorkspace.shared.frontmostApplication
        model.mode = mode
        model.language = nil                            // Tab chooses for one request; each opening follows the setting
        model.hotkey = HotKeySpec.display(coordinator.app?.settings.assist.explainHotKey ?? .defaultExplain)
        model.offer = Self.currentOffer(lastConsumed: coordinator.lastClipboardChange)
        model.captureAllowed = coordinator.capturer.preflight()
        model.capturing = false
        model.frozenReady = false
        model.freezeFailed = false
        model.hasCaptureLayer = Self.captureLayer != nil
        model.optionHeld = false
        model.shiftHeld = false
        model.dragging = false
        model.notice = nil
        model.hudEdge = .top
        let mouse = NSEvent.mouseLocation
        openedDisplays = Self.displays()
        hudDisplay = nil
        for screen in NSScreen.screens {
            let panel = CaptureOverlayPanel.make(screen: screen)
            let id = Self.displayID(screen)
            let active = screen.frame.contains(mouse) || NSScreen.screens.count == 1
            let layerModel = CaptureLayerModel(displayID: id, size: screen.frame.size)
            if screen.frame.contains(mouse) {
                let p = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
                layerModel.cursor = p
            }
            if active, hudDisplay == nil {
                hudDisplay = id
                model.hudTopInset = Self.hudTopInset(screen)
                model.hudEdge = CaptureHUD.edge(current: .top, cursor: layerModel.cursor, displaySize: screen.frame.size,
                                                topInset: model.hudTopInset)
            }
            layers[id] = layerModel
            panel.contentView = NSHostingView(rootView: CaptureOverlayView(model: model, active: active && hudDisplay == id,
                                                                           layer: layer(screen: screen, displayID: id, model: layerModel),
                                                                           actions: overlayActions))
            panel.onKey = { [weak self] e in self?.handleKey(e) ?? false }
            panel.onFlags = { [weak self] flags in self?.modifiersChanged(flags) }
            panels.append(panel)
            panel.orderFrontRegardless()
            if active { panel.makeKey() }
        }
        if !panels.contains(where: \.isKeyWindow) { panels.first?.makeKey() }
        observeSystem()
        if model.captureAllowed, model.hasCaptureLayer { freeze() }
    }

    func dismiss() {
        stopObservingSystem()
        session += 1
        finishTask?.cancel()                           // a capture still being prepared is dropped: nothing sent
        finishTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        freezeTask?.cancel()
        freezeTask = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        frozen = nil                                   // the stills (about 60 MB at 5K) go with the overlay
        layers.removeAll()
        model.capturing = false
        model.frozenReady = false
        model.dragging = false
    }

    func toggleMode() { model.mode = model.mode == .frame ? .lens : .frame }

    // MARK: The system (CUX-3)

    /// A Space switch, a display change, the displays sleeping or another session taking the console
    /// while the overlay is up: the still no longer matches what is on screen, and a later release
    /// would read the window of another Space — the overlay closes (nothing sent; the still is dropped).
    private func observeSystem() {
        stopObservingSystem()
        let ws = NSWorkspace.shared.notificationCenter
        let fixed: [(Notification.Name, CaptureOverlayLifecycle.Event)] = [
            (NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged),
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
        ]
        for (name, event) in fixed {
            let token = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemChanged(event) }
            }
            observers.append((ws, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemChanged(.screensChanged(opened: self.openedDisplays, now: Self.displays()))
            }
        }
        observers.append((center, token))
    }

    private func stopObservingSystem() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func systemChanged(_ event: CaptureOverlayLifecycle.Event) {
        guard isShown, CaptureOverlayLifecycle.reaction(to: event) == .dismiss else { return }
        dismiss()
    }

    static func displays() -> [CaptureOverlayLifecycle.Display] {
        NSScreen.screens.map { CaptureOverlayLifecycle.Display(id: displayID($0), frame: $0.frame) }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The HUD's top inset: below the camera housing of a display with a notch; elsewhere the pill
    /// sits over the frozen menu bar (never explained) rather than over the page's top.
    static func hudTopInset(_ screen: NSScreen) -> CGFloat { max(screen.safeAreaInsets.top, 0) }

    // MARK: The pointer (the layer reports; CUX-14)

    /// The pointer moved on a display: the HUD steps out of its way.
    func pointerMoved(_ local: CGPoint?, on displayID: CGDirectDisplayID) {
        guard displayID == hudDisplay, let size = layers[displayID]?.size else { return }
        let edge = CaptureHUD.edge(current: model.hudEdge, cursor: local, displaySize: size, topInset: model.hudTopInset)
        if edge != model.hudEdge { model.hudEdge = edge }
    }

    /// A box is being drawn (the HUD hides) or not.
    func dragChanged(_ dragging: Bool) {
        if model.dragging != dragging { model.dragging = dragging }
        if dragging, model.notice != nil { model.notice = nil }
    }

    /// Nothing legible where the user pointed, or a blank capture (CUX-8): the overlay stays and says
    /// so; nothing is sent.
    private func say(_ notice: CaptureOverlayModel.Notice) {
        model.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.model.notice == notice else { return }
            self.model.notice = nil
        }
    }

    private var overlayActions: CaptureOverlayActions {
        CaptureOverlayActions(
            dismiss: { [weak self] in self?.dismiss() },
            setMode: { [weak self] m in self?.model.mode = m },
            explainOffer: { [weak self] in _ = self?.explainOffer() },
            enableCapture: { [weak self] in
                guard let self, let capturer = self.coordinator?.capturer else { return }
                self.dismiss()
                ScreenPermission.presentExplainer(capturer: capturer)
            },
            openSystemSettings: { [weak self] in
                self?.dismiss()
                ScreenPermission.openSystemSettings()
            })
    }

    private func layer(screen: NSScreen, displayID: CGDirectDisplayID, model layerModel: CaptureLayerModel) -> AnyView? {
        guard let make = Self.captureLayer, model.captureAllowed else { return nil }
        return make(LayerContext(screen: screen, displayID: displayID, frozen: frozen, mode: model.mode, controller: self,
                                 layer: layerModel))
    }

    /// The still the frame and lens draw over and crop from (our own windows excluded). Taken once,
    /// only with Screen Recording already granted (`CaptureFlow` never asks); a refusal shows the
    /// zero-permission card, any other failure says so.
    private func freeze() {
        guard let coordinator else { return }
        let capturer = coordinator.capturer
        let exclude = coordinator.ownWindowIDs
        freezeTask = Task { [weak self] in
            let result = await CaptureFlow.freeze(capturer, excluding: exclude)
            guard !Task.isCancelled, let self, self.isShown else { return }
            switch result {
            case .success(let screens):
                self.frozen = screens
                for (id, layer) in self.layers { layer.still = screens.display(id) }
                self.model.frozenReady = true
            case .failure(.permissionDenied):
                self.model.captureAllowed = false
            case .failure:
                self.model.freezeFailed = true
            }
        }
    }

    /// ⌥ (a figure) and ⇧ (a term) as they are held now.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let option = flags.contains(.option), shift = flags.contains(.shift)
        if model.optionHeld != option { model.optionHeld = option }
        if model.shiftHeld != shift { model.shiftHeld = shift }
    }

    // MARK: Keys

    /// Esc cancels, Space switches frame ↔ lens, Return explains the clipboard offer, Tab switches
    /// the answer language of this request. True when handled.
    private func handleKey(_ e: NSEvent) -> Bool {
        switch CaptureOverlayKeys.action(keyCode: Int(e.keyCode), isRepeat: e.isARepeat) {
        case .dismiss:
            dismiss()
            return true
        case .toggleMode:
            toggleMode()
            return true
        case .explainOffer:
            return explainOffer()
        case .toggleLanguage:
            // From the language this request would use now (CUX-10), not always 中 first.
            let assist = coordinator?.app?.settings.assist ?? AssistSettings()
            model.language = CaptureOverlayKeys.language(afterTab: model.language, setting: assist.explainLanguage, ui: L.lang)
            return true
        case .swallow:
            return true
        case .pass:
            return false
        }
    }

    // MARK: The clipboard (zero permission)

    /// The offer for the general pasteboard now (only its change count and type names are read).
    static func currentOffer(lastConsumed: Int?) -> ClipboardOffer? {
        let pb = NSPasteboard.general
        return ClipboardOffer.make(changeCount: pb.changeCount, lastConsumed: lastConsumed,
                                   types: (pb.types ?? []).map(\.rawValue))
    }

    /// Return on the offer: the pasteboard is read now — the key press is the gesture.
    @discardableResult
    func explainOffer() -> Bool {
        guard let coordinator, let offer = model.offer, NSPasteboard.general.changeCount == offer.changeCount,
              let capture = ExplainClipboard.read(host: frontApp?.bundleIdentifier) else { return false }
        let ticket = ConsentTicket.mint(.clipboard, surface: .explain)
        coordinator.lastClipboardChange = offer.changeCount
        start(capture, ticket: ticket, language: model.language)
        return true
    }

    /// Explain ▸ Explain Copied Text: whatever the pasteboard holds now (the menu click is the gesture).
    func explainClipboardFromMenu() {
        guard let coordinator else { return }
        let pb = NSPasteboard.general
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let capture = ExplainClipboard.read(host: front == Bundle.main.bundleIdentifier ? nil : front)
            ?? ExplainCapture(source: .clipboard)               // nothing copied: the panel says so
        let ticket = ConsentTicket.mint(.clipboard, surface: .explain)
        coordinator.lastClipboardChange = pb.changeCount
        start(capture, ticket: ticket, language: nil)
    }

    private func start(_ capture: ExplainCapture, ticket: ConsentTicket, language: UILang?) {
        guard let coordinator else { return }
        dismiss()
        coordinator.begin(capture: capture, ticket: ticket, anchor: nil, kind: .explain, near: nil, language: language)
    }

    // MARK: Frame / lens (the layer reports here)

    /// The layer's mouse release on a display: a box, or a click on what is under the point.
    func released(_ outcome: CaptureGesture.Outcome, on displayID: CGDirectDisplayID) {
        dragChanged(false)
        switch outcome {
        case .box(let rect, let figure):
            regionChosen(CaptureRegion(displayID: displayID, rect: rect), lens: false, figure: figure)
        case .point(let p, let term, let figure):
            pointChosen(p, displayID: displayID, lens: model.mode == .lens, term: term, figure: figure)
        }
    }

    /// What the user chose: a drawn box (`figure`: ⌥ held), or a click at a display-local point.
    typealias Choice = ExplainImageCrop.Gesture

    /// The user released a box (`lens` false) or clicked the lens on `region` of a display;
    /// `figure`: ⌥ was held (send the image as a figure). The crop comes from the frozen still.
    func regionChosen(_ region: CaptureRegion, lens: Bool, figure: Bool) {
        choose(.box(region, figure: figure), lens: lens)
    }

    /// A click at `local` (display-local points): only what is under it is sent (F3) — the paragraph
    /// (⇧: the term) that local OCR finds in the band around it, else the figure around the click,
    /// else a small band; ⌥ sends the figure itself. The band stays inside the window under the click.
    func pointChosen(_ local: CGPoint, displayID: CGDirectDisplayID, lens: Bool, term: Bool, figure: Bool) {
        guard layers[displayID] != nil || frozen?.display(displayID) != nil else {
            NSSound.beep()
            return
        }
        choose(.click(local, displayID: displayID, term: term, figure: figure), lens: lens)
    }

    /// The gesture's ticket now; the crop from the still (waiting for it if the user was quicker
    /// than the freeze); the window under the capture for its app (privacy) and title (locating).
    /// One capture at a time: a gesture while the last one is being prepared is ignored.
    private func choose(_ choice: Choice, lens: Bool) {
        guard coordinator != nil, finishTask == nil else { return }
        let ticket = ConsentTicket.mint(lens ? .lens : .box, surface: .explain)
        let language = model.language
        let front = frontApp?.bundleIdentifier
        if let frozen {
            finish(choice, frozen: frozen, ticket: ticket, lens: lens, language: language, front: front)
            return
        }
        guard let pending = freezeTask else { NSSound.beep(); return }
        model.capturing = true
        let gen = session
        Task { [weak self] in
            await pending.value
            // The overlay closed (Esc, a Space switch…) while the freeze ran: this click was that
            // session's, even if the overlay is up again by now.
            guard let self, self.isShown, self.session == gen else { return }
            self.model.capturing = false
            guard let frozen = self.frozen else { NSSound.beep(); return }
            self.finish(choice, frozen: frozen, ticket: ticket, lens: lens, language: language, front: front)
        }
    }

    /// The window under the capture is read here (the window list); planning the click, cropping,
    /// the blank check and the encoding run off the main thread (`ExplainImageCrop.run`, CUX-7) while
    /// the overlay stays up — closing it cancels them and nothing is sent.
    private func finish(_ choice: Choice, frozen: FrozenScreens, ticket: ConsentTicket, lens: Bool, language: UILang?, front: String?) {
        guard coordinator != nil, finishTask == nil else { return }
        guard let point = ExplainImageCrop.probe(choice, in: frozen) else { NSSound.beep(); return }
        // The window under the click bounds what is read and sent (F3); it names the app (privacy) and
        // the title (locating) of a box or a click.
        let window = WindowTitleReader.window(at: point)
        model.capturing = true
        finishTask = Task { [weak self] in
            let outcome = await ExplainImageCrop.run(choice, window: window?.bounds, frozen: frozen)
            guard !Task.isCancelled, let self, self.isShown else { return }
            self.finishTask = nil
            self.model.capturing = false
            self.deliver(outcome, frozen: frozen, ticket: ticket, lens: lens, language: language, front: front, window: window,
                         point: point)
        }
    }

    /// The prepared capture opens its panel (the overlay closes). Nothing legible under the click, or
    /// a capture that came back one flat colour (DRM, a sleeping display): the overlay stays and says
    /// so (CUX-8) — nothing is sent.
    private func deliver(_ outcome: ExplainImageCrop.Outcome, frozen: FrozenScreens, ticket: ConsentTicket, lens: Bool,
                         language: UILang?, front: String?, window: WindowTitleReader.Window?, point: CGPoint) {
        guard let coordinator else { return }
        let p: ExplainImageCrop.Prepared
        switch outcome {
        case .ready(let prepared):
            p = prepared
        case .nothingLegible:
            say(.nothingLegible)
            return
        case .blank:
            say(.blankCapture)
            return
        case .failed:
            NSSound.beep()
            return
        case .cancelled:
            return
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let place = CaptureGeometry.placement(p.region, click: p.click, in: frozen, mainHeight: mainHeight) else {
            NSSound.beep()
            return
        }
        var capture = ExplainCapture(source: lens ? .lens : .region, image: p.image, hostBundleID: window?.bundleID ?? front,
                                     windowTitle: window?.title, focus: p.focus, ocrImage: p.ocrImage)
        // A click's capture may hold more than the band the panel opens beside (CUX-8): every window
        // under all of it goes to the privacy check (F1), read now — before the overlay's own windows go.
        if p.readsBeyondRegion, let area = CaptureGeometry.global(p.readArea, in: frozen) {
            capture.surroundings = WindowTitleReader.surroundings(region: area, point: point, excluding: Set(coordinator.ownWindowIDs),
                                                                  own: ExplainOwnWindows.roles(state: coordinator.app))
        }
        dismiss()
        coordinator.begin(capture: capture, ticket: ticket, anchor: nil, kind: p.kind, near: place.near, language: language)
    }
}

/// The overlay's observable state.
@Observable
final class CaptureOverlayModel {
    var mode: AssistSettings.OverlayMode = .frame
    var offer: ClipboardOffer?
    var captureAllowed = false
    var hasCaptureLayer = false
    var frozenReady = false
    /// Freezing the screen failed (not a refusal: that turns `captureAllowed` off).
    var freezeFailed = false
    var capturing = false
    /// ⌥ / ⇧ held (the layer's "As a figure" / "A term" badge).
    var optionHeld = false
    var shiftHeld = false
    /// Tab: this request's answer language (nil: the setting's).
    var language: UILang?
    var hotkey = "⌃⌥E"
    /// A box is being drawn: the HUD hides (CUX-14).
    var dragging = false
    /// Where the HUD pill sits (it steps away from the pointer) and the active display's top inset.
    var hudEdge: CaptureHUD.Edge = .top
    var hudTopInset: CGFloat = 0
    /// A short message instead of a send (CUX-8).
    var notice: Notice?

    enum Notice: Equatable {
        /// Nothing legible under or near the click (a blank area of a page).
        case nothingLegible
        /// The capture came back one flat colour: protected (DRM) content or a sleeping display.
        case blankCapture

        /// What the chip says (English and Chinese).
        var text: String {
            switch self {
            case .nothingLegible:
                return L.ExplainUX.nothingLegible
            case .blankCapture:
                return L.lang == .zh ? "截取的画面是空白的（受 DRM 保护的内容或显示器已休眠），未发送任何内容。"
                    : "The capture came back blank (DRM-protected content or a sleeping display). Nothing was sent."
            }
        }

        var symbol: String {
            switch self {
            case .nothingLegible: return "eye.slash"
            case .blankCapture: return "rectangle.slash"
            }
        }
    }
}

/// One display's overlay window.
final class CaptureOverlayPanel: NSPanel {
    /// Key presses the overlay handles first (true: consumed).
    var onKey: ((NSEvent) -> Bool)?
    /// ⌥ / ⇧ pressed or released.
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        if event.type == .flagsChanged { onFlags?(event.modifierFlags) }
        super.sendEvent(event)
    }

    static func make(screen: NSScreen) -> CaptureOverlayPanel {
        let p = CaptureOverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.acceptsMouseMovedEvents = true
        p.isMovable = false
        p.isExcludedFromWindowsMenu = true
        p.setFrame(screen.frame, display: false)
        return p
    }
}

/// Reading the general pasteboard for Explain — only on a user's Return / click on the offer or a menu
/// click (a double tap of the shortcut only shows the offer, F4).
enum ExplainClipboard {
    /// The pasteboard's text (normalized) or image; nil when empty or concealed (a password manager's item).
    static func read(host: String?) -> ExplainCapture? {
        let pb = NSPasteboard.general
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardOffer.concealedTypes) else { return nil }
        if let s = pb.string(forType: .string), let text = ClipboardOffer.normalize(s) {
            return ExplainCapture(source: .clipboard, text: text, hostBundleID: host)
        }
        for t in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: t), let image = ExplainImageEncoder.encode(data: data) {
                return ExplainCapture(source: .screenshot, image: image, hostBundleID: host)
            }
        }
        return nil
    }
}
