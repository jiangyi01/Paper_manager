import AppKit
import SwiftUI
import Observation
import PaperDeckCore
import PaperDeckConfig

// MARK: - Preferences

/// UserDefaults keys of the floating panel (§8). Anyone may write them (menu bar,
/// settings): DropPanelController re-applies on `UserDefaults.didChangeNotification`.
enum PanelPrefs {
    enum Edge: String {
        case left, right
    }

    enum Keys {
        static let visible = "panel.visible", edge = "panel.edge", edgeYFraction = "panel.edgeYFraction"
        static let screenID = "panel.screenID", idleOpacity = "panel.idleOpacity"
        static let expandOnDrag = "panel.expandOnDrag", showTodayOnHover = "panel.showTodayOnHover"
    }

    static let opacityChoices: [Double] = [1.0, 0.85, 0.7, 0.55, 0.4]

    /// True while the panel is on screen (user-visible, or armed by `paperdeck://dropzone`).
    /// The menu bar uses its popover for feedback only when this is false.
    static var panelOnScreen = false

    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            Keys.visible: true, Keys.edge: Edge.right.rawValue, Keys.edgeYFraction: 0.62,
            Keys.idleOpacity: 0.85, Keys.expandOnDrag: true, Keys.showTodayOnHover: true,
        ])
    }

    static var visible: Bool {
        get { d.bool(forKey: Keys.visible) }
        set { d.set(newValue, forKey: Keys.visible) }
    }
    static var edge: Edge {
        get { Edge(rawValue: d.string(forKey: Keys.edge) ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: Keys.edge) }
    }
    /// Vertical centre of the tab as a fraction of the screen's visible height (0 = bottom).
    static var edgeYFraction: Double {
        get { min(max(d.double(forKey: Keys.edgeYFraction), 0), 1) }
        set { d.set(min(max(newValue, 0), 1), forKey: Keys.edgeYFraction) }
    }
    static var screenID: String? {
        get { d.string(forKey: Keys.screenID) }
        set { d.set(newValue, forKey: Keys.screenID) }
    }
    static var idleOpacity: Double {
        get { let v = d.double(forKey: Keys.idleOpacity); return v >= 0.2 ? min(v, 1) : 0.85 }
        set { d.set(min(max(newValue, 0.2), 1), forKey: Keys.idleOpacity) }
    }
    static var expandOnDrag: Bool {
        get { d.bool(forKey: Keys.expandOnDrag) }
        set { d.set(newValue, forKey: Keys.expandOnDrag) }
    }
    static var showTodayOnHover: Bool {
        get { d.bool(forKey: Keys.showTodayOnHover) }
        set { d.set(newValue, forKey: Keys.showTodayOnHover) }
    }

    struct Snapshot: Equatable {
        var visible: Bool
        var edge: Edge
        var edgeYFraction: Double
        var screenID: String?
        var idleOpacity: Double

        static var current: Snapshot {
            Snapshot(visible: PanelPrefs.visible, edge: PanelPrefs.edge, edgeYFraction: PanelPrefs.edgeYFraction,
                     screenID: PanelPrefs.screenID, idleOpacity: PanelPrefs.idleOpacity)
        }
    }
}

// MARK: - Observation helper

/// Re-runs `body` whenever an @Observable property it read changes (on the main
/// actor, one hop after the mutation). AppKit controllers use it to follow AppState.
final class PanelObserver {
    private let body: () -> Void
    private var cancelled = false

    init(_ body: @escaping () -> Void) {
        self.body = body
        run()
    }

    func cancel() { cancelled = true }

    private func run() {
        guard !cancelled else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor in self?.run() }
        }
    }
}

/// Owner of the panel's tracking area (kept separate so SwiftUI's own tracking is untouched).
final class PanelHoverRelay: NSResponder {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}

/// Borderless, non-activating panel that never takes key status.
final class DropPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // setFrame(_:display:animate:) blocks while animating; keep the expand/collapse snappy.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.16 }
}

extension NSScreen {
    /// Stable across reboots/reconnects (display UUID), unlike the CGDirectDisplayID.
    var panelStableID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return localizedName
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return String(displayID)
    }
}

// MARK: - Controller

/// The always-available floating drop panel (§2, §8 悬浮窗状态机):
///
///     collapsed ─dragBegan─▶ armed ─entered─▶ targeted ─drop─▶ processing ─settled─▶ collapsed
///     collapsed ─hover 500 ms─▶ peek ─leave 600 ms─▶ collapsed;  click tab → 主窗口 ▸ 今天
final class DropPanelController: NSObject, NSWindowDelegate {
    private typealias Mode = DropPanelModel.Mode

    private let state: AppState
    private let model = DropPanelModel()
    private let dragMonitor = DragMonitor()
    private let janitor: ToastJanitor
    private var panel: DropPanelWindow?
    private var hosting: DropHostingView<DropPanelView>?
    private var hoverRelay: PanelHoverRelay?
    private var observers: [PanelObserver] = []
    private var tokens: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var dragEventMonitor: Any?

    private var appliedPrefs: PanelPrefs.Snapshot?
    private var isPersisting = false
    /// Hidden panel shown only because `paperdeck://dropzone` armed it.
    private var shownTemporarily = false

    private enum ArmReason { case drag, link }
    private var armReason = ArmReason.drag
    private var activity = FeedbackActivity()
    private var measured: [Mode: CGFloat] = [:]
    private var expandedTop: CGFloat?
    private var wasTargeted = false
    private var lastActivity = Date.distantPast
    private var lastDragEvent = Date.distantPast
    private var lastTargetedAt = Date.distantPast
    private var tabDrag: (mouse: NSPoint, origin: NSPoint, moved: Bool)?

    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var armCollapseTask: Task<Void, Never>?
    private var armDeadlineTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var awaitTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private static let screenMargin: CGFloat = 6

    init(state: AppState) {
        self.state = state
        janitor = ToastJanitor(state: state)
        super.init()
        PanelPrefs.registerDefaults()
        janitor.isPaused = { [weak self] in self?.pointerOverPanel ?? false }
        wireModel()
        dragMonitor.onDragBegan = { [weak self] in self?.dragBegan() }
        dragMonitor.onDragEnded = { [weak self] in self?.dragEnded() }
        observers.append(PanelObserver { [weak self] in self?.feedbackChanged() })

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        tokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout(animated: false) }
        })
        applySettings()
    }

    // MARK: Public API

    /// Re-reads the `panel.*` keys (also runs automatically on any defaults change).
    func applySettings() {
        guard !isPersisting else { return }
        let prefs = PanelPrefs.Snapshot.current
        guard prefs != appliedPrefs else { return }
        let previous = appliedPrefs
        appliedPrefs = prefs
        model.edge = prefs.edge
        if prefs.visible || shownTemporarily {
            if prefs.visible { shownTemporarily = false }
            showPanel()
            if let previous, previous.edge != prefs.edge || previous.edgeYFraction != prefs.edgeYFraction
                || previous.screenID != prefs.screenID {
                relayout(animated: true)
            }
            updateAlpha()
        } else {
            hidePanel()
        }
    }

    /// `paperdeck://dropzone`: open the drop zone for `seconds` (shows a hidden panel temporarily).
    func arm(for seconds: TimeInterval) {
        hideTask?.cancel()
        if !PanelPrefs.visible { shownTemporarily = true }
        showPanel()
        guard model.mode != .processing else { return }
        armReason = .link
        setMode(.armed)
        armDeadlineTask?.cancel()
        armDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, seconds)))
            // Never pull the zone away from under a hovering drag.
            while !Task.isCancelled, self?.model.mode == .targeted {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self, self.model.mode == .armed else { return }
            self.collapse()
        }
    }

    // MARK: Window

    private var isOnScreen: Bool { panel?.isVisible == true }

    /// Geometric check (tracking-area state is unreliable while the frame animates).
    private var pointerOverPanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private func showPanel() {
        if panel == nil { makePanel() }
        dragMonitor.start()
        guard let panel, !panel.isVisible else { return }
        model.mode = .collapsed
        relayout(animated: false)
        updateAlpha()
        panel.orderFrontRegardless()
        PanelPrefs.panelOnScreen = true
    }

    private func hidePanel() {
        cancelTransientTasks()
        settleTask?.cancel()
        removeDragEventMonitor()
        dragMonitor.stop()
        model.awaitingDrop = false
        model.mode = .collapsed
        panel?.orderOut(nil)
        PanelPrefs.panelOnScreen = false
    }

    private func makePanel() {
        let p = DropPanelWindow(contentRect: NSRect(origin: .zero, size: DropPanelMetrics.tabSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.isExcludedFromWindowsMenu = true
        p.animationBehavior = .none
        p.delegate = self

        let view = DropHostingView(rootView: DropPanelView(model: model, state: state, dropState: DropTargetState()))
        view.rootView = DropPanelView(model: model, state: state, dropState: view.dropState)
        // The window frame is driven by the state machine, never by SwiftUI's ideal sizes.
        view.sizingOptions = []
        let engine = state.engine
        view.incomingDirectory = { engine.paths.incoming }
        view.onDrop = { [weak self] items, ignored in self?.received(items, ignored: ignored) }
        p.contentView = view

        let relay = PanelHoverRelay()
        relay.onEnter = { [weak self] in self?.pointerEntered() }
        relay.onExit = { [weak self] in self?.pointerExited() }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                            owner: relay, userInfo: nil))
        hoverRelay = relay

        // Right-click / control-click anywhere on the panel → the panel menu.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                self.showContextMenu(event)
                return nil
            }
            return event
        }

        panel = p
        hosting = view
        observers.append(PanelObserver { [weak self] in self?.targetedChanged() })
    }

    private func wireModel() {
        model.onMeasure = { [weak self] mode, height in self?.didMeasure(mode, height) }
        model.onTabDrag = { [weak self] phase in
            switch phase {
            case .changed: self?.tabDragChanged()
            case .ended: self?.tabDragEnded()
            }
        }
        model.onCollapse = { [weak self] in self?.collapse() }
        model.onOpenPaper = { [weak self] id in
            self?.collapse()
            self?.state.router.showPaper(id)
        }
        model.onOpenToday = { [weak self] in
            self?.collapse()
            self?.state.router.showToday()
        }
    }

    // MARK: Mode + geometry

    private func setMode(_ mode: Mode, animated: Bool = true) {
        guard model.mode != mode else {
            relayout(animated: animated)
            return
        }
        // The tab (and its drag gesture) is about to disappear: settle a drag in progress.
        if tabDrag != nil { endTabDrag(isClick: false) }
        hoverTask?.cancel()
        leaveTask?.cancel()
        expandedTop = nil
        withAnimation(.easeOut(duration: 0.15)) { model.mode = mode }
        hosting?.layoutSubtreeIfNeeded()
        relayout(animated: animated)
        switch mode {
        case .collapsed:
            removeDragEventMonitor()
            watchdogTask?.cancel()
            settleTask?.cancel()
        case .processing:
            startSettleWatch()
        case .armed, .targeted:
            if armReason == .drag { startArmWatch() }
        case .peek:
            startPeekWatch()
        }
        updateAlpha()
    }

    private func dockScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let id = PanelPrefs.screenID, let screen = screens.first(where: { $0.panelStableID == id }) { return screen }
        return screens.first
    }

    private func size(for mode: Mode) -> NSSize {
        switch mode {
        case .collapsed: return DropPanelMetrics.tabSize
        case .peek: return NSSize(width: DropPanelMetrics.peekWidth, height: measured[.peek] ?? 220)
        case .armed, .targeted: return DropPanelMetrics.armedSize
        case .processing: return NSSize(width: DropPanelMetrics.processingWidth, height: measured[.processing] ?? 140)
        }
    }

    /// Flush with the docked edge; centred on the tab's saved position, clamped to the
    /// visible frame. Lists that grow (peek / processing) keep their top edge.
    private func targetFrame(on screen: NSScreen) -> NSRect {
        let mode = model.mode
        let vf = screen.visibleFrame
        let margin = Self.screenMargin
        let size = size(for: mode)
        let height = min(size.height, vf.height - 2 * margin)
        let x = model.edge == .right ? vf.maxX - size.width : vf.minX
        let centerY = vf.minY + CGFloat(PanelPrefs.edgeYFraction) * vf.height
        let growsDown = mode == .peek || mode == .processing
        var top = (growsDown ? expandedTop : nil) ?? centerY + height / 2
        top = min(top, vf.maxY - margin)
        top = max(top, vf.minY + margin + height)
        if growsDown { expandedTop = top }
        return NSRect(x: x, y: top - height, width: size.width, height: height).integral
    }

    private func relayout(animated: Bool) {
        guard let panel, tabDrag?.moved != true, let screen = dockScreen() else { return }
        let target = targetFrame(on: screen)
        guard target != panel.frame else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // NSWindow's own frame animation: an animator() group with an overshooting timing
        // function silently leaves the frame unchanged on macOS 26.
        panel.setFrame(target, display: true, animate: animated && !reduceMotion && panel.isVisible)
        panel.invalidateShadow()
    }

    private func didMeasure(_ mode: Mode, _ height: CGFloat) {
        let rounded = ceil(height)
        guard rounded > 20, measured[mode] != rounded else { return }
        measured[mode] = rounded
        if model.mode == mode { relayout(animated: true) }
    }

    private func updateAlpha() {
        guard let panel else { return }
        let idle = model.mode == .collapsed && !pointerOverPanel && tabDrag == nil
        let alpha = CGFloat(idle ? PanelPrefs.idleOpacity : 1)
        guard abs(panel.alphaValue - alpha) > 0.001 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = alpha
        }
    }

    private func collapse() {
        cancelTransientTasks()
        awaitTask?.cancel()
        model.awaitingDrop = false
        armReason = .drag
        setMode(.collapsed)
        if shownTemporarily && !PanelPrefs.visible {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.model.mode == .collapsed else { return }
                self.shownTemporarily = false
                self.hidePanel()
            }
        }
    }

    private func cancelTransientTasks() {
        for task in [hoverTask, leaveTask, armCollapseTask, armDeadlineTask, watchdogTask] { task?.cancel() }
    }

    // MARK: Tab drag / click

    private func tabDragChanged() {
        guard let panel, model.mode == .collapsed else { return }
        let mouse = NSEvent.mouseLocation
        if tabDrag == nil {
            tabDrag = (mouse, panel.frame.origin, false)
            hoverTask?.cancel()
            updateAlpha()
        }
        guard var drag = tabDrag else { return }
        let dx = mouse.x - drag.mouse.x, dy = mouse.y - drag.mouse.y
        if !drag.moved {
            guard hypot(dx, dy) >= 3 else { return }
            drag.moved = true
            tabDrag = drag
        }
        panel.setFrameOrigin(NSPoint(x: drag.origin.x + dx, y: drag.origin.y + dy))
    }

    private func tabDragEnded() { endTabDrag(isClick: true) }

    /// Click → 主窗口 ▸ 今天. Drag → snap to the nearer vertical edge of the screen under the tab.
    private func endTabDrag(isClick: Bool) {
        let drag = tabDrag
        tabDrag = nil
        guard let drag, drag.moved, let panel else {
            updateAlpha()
            if isClick { state.router.showToday() }
            return
        }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? dockScreen() else { return }
        let vf = screen.visibleFrame
        let edge: PanelPrefs.Edge = center.x < vf.midX ? .left : .right
        let fraction = Double((center.y - vf.minY) / max(vf.height, 1))
        persist {
            PanelPrefs.edge = edge
            PanelPrefs.edgeYFraction = fraction
            PanelPrefs.screenID = screen.panelStableID
        }
        model.edge = edge
        relayout(animated: true)
        updateAlpha()
    }

    /// Writes prefs without the defaults-change observer re-applying them mid-animation.
    private func persist(_ write: () -> Void) {
        isPersisting = true
        write()
        isPersisting = false
        appliedPrefs = .current
    }

    // MARK: Hover → peek

    private func pointerEntered() {
        updateAlpha()
        guard model.mode == .collapsed, PanelPrefs.showTodayOnHover, tabDrag == nil, !dragMonitor.isDragging else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.pointerOverPanel, self.model.mode == .collapsed,
                  self.tabDrag == nil, NSEvent.pressedMouseButtons == 0 else { return }
            self.setMode(.peek)
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        updateAlpha()
    }

    /// Peek closes 600 ms after the pointer leaves it. Opened from the context menu
    /// (pointer elsewhere), it waits a few seconds for the pointer to arrive first.
    private func startPeekWatch() {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            var seenInside = self?.pointerOverPanel ?? false
            var outsideSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.model.mode == .peek else { return }
                if self.pointerOverPanel || self.tabDrag != nil {
                    seenInside = true
                    outsideSince = nil
                    continue
                }
                let since = outsideSince ?? Date()
                outsideSince = since
                if Date().timeIntervalSince(since) >= (seenInside ? 0.6 : 4) {
                    self.collapse()
                    return
                }
            }
        }
    }

    // MARK: Drag session → armed / targeted

    private func dragBegan() {
        guard isOnScreen, PanelPrefs.expandOnDrag else { return }
        lastDragEvent = Date()
        switch model.mode {
        case .collapsed, .peek:
            armReason = .drag
            armCollapseTask?.cancel()
            setMode(.armed)
        case .armed, .targeted, .processing:
            break
        }
    }

    private func dragEnded() {
        guard model.mode == .armed || model.mode == .targeted else { return }
        if dropLikelyLanded() {
            beginAwaitingDrop()
            return
        }
        guard armReason == .drag else { return }
        scheduleArmCollapse()
    }

    private func scheduleArmCollapse() {
        armCollapseTask?.cancel()
        armCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.model.mode == .armed,
                  self.hosting?.dropState.isTargeted != true else { return }
            self.collapse()
        }
    }

    /// Armed by a drag: collapse after 1.5 s without drag events once the button is up
    /// (covers a missed global mouse-up, e.g. a drag cancelled with Esc).
    private func startArmWatch() {
        installDragEventMonitor()
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard self.model.mode == .armed || self.model.mode == .targeted else { return }
                if self.model.mode == .targeted || self.hosting?.dropState.isTargeted == true { continue }
                let idle = Date().timeIntervalSince(self.lastDragEvent)
                if idle > 1.5 && NSEvent.pressedMouseButtons & 1 == 0 {
                    self.collapse()
                    return
                }
            }
        }
    }

    private func installDragEventMonitor() {
        guard dragEventMonitor == nil else { return }
        dragEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.lastDragEvent = Date()
        }
    }

    private func removeDragEventMonitor() {
        if let monitor = dragEventMonitor { NSEvent.removeMonitor(monitor) }
        dragEventMonitor = nil
    }

    /// DropHostingView flips `isTargeted` on enter/exit and when the drop is performed.
    private func targetedChanged() {
        guard let hosting else { return }
        let targeted = hosting.dropState.isTargeted
        if targeted {
            wasTargeted = true
            lastTargetedAt = Date()
            armCollapseTask?.cancel()
            hoverTask?.cancel()
            leaveTask?.cancel()
            switch model.mode {
            case .collapsed, .peek:
                armReason = .drag
                setMode(.targeted)
            case .armed:
                setMode(.targeted)
            case .targeted, .processing:
                break
            }
            return
        }
        guard wasTargeted else { return }
        wasTargeted = false
        lastTargetedAt = Date()
        guard model.mode == .targeted else { return }
        if dropLikelyLanded() {
            beginAwaitingDrop()
        } else {
            setMode(.armed)
            if armReason == .drag && !dragMonitor.isDragging { scheduleArmCollapse() }
        }
    }

    /// True when the pointer is over the panel right after it stopped being targeted by an
    /// acceptable drag — i.e. the drop was performed here (file promises may still be arriving).
    private func dropLikelyLanded() -> Bool {
        guard let panel, let hosting else { return false }
        let recentlyTargeted = hosting.dropState.isTargeted || Date().timeIntervalSince(lastTargetedAt) < 0.6
        return recentlyTargeted && hosting.dropState.summary.isAcceptable
            && panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func beginAwaitingDrop() {
        guard model.mode != .processing else { return }
        model.awaitingDrop = true
        lastActivity = Date()
        setMode(.processing)
        awaitTask?.cancel()
        awaitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.model.awaitingDrop = false
        }
    }

    private func received(_ items: [IntakeItem], ignored: [String]) {
        awaitTask?.cancel()
        model.awaitingDrop = false
        if items.isEmpty && ignored.isEmpty {
            state.post(Toast(kind: .warning, message: L.panelNothingToImport))
        }
        if !items.isEmpty { GuideActivity.record(.panelDrop) }      // Getting Started ▸ drop strip
        state.ingest(items, origin: .drop, ignoredNames: ignored)
        lastActivity = Date()
        if isOnScreen { setMode(.processing) }
    }

    // MARK: Processing

    /// New import rows (any origin: drop, Open With, menu bar, folder import) open the
    /// processing list; new toasts do too while PaperDeck isn't the active app.
    private func feedbackChanged() {
        let change = activity.update(rows: state.importRows, toasts: state.toasts)
        if change.rowsChanged || change.newToasts { lastActivity = Date() }
        guard isOnScreen else { return }
        let wantsList = change.newRows || (change.newToasts && !NSApp.isActive)
        guard wantsList else { return }
        switch model.mode {
        case .collapsed, .peek:
            setMode(.processing)
        case .armed:
            if change.newRows { setMode(.processing) }
        case .targeted, .processing:
            break
        }
    }

    private func startSettleWatch() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.model.mode == .processing else { return }
                if self.canLeaveProcessing() {
                    self.collapse()
                    return
                }
            }
        }
    }

    /// §8: all rows terminal ∧ no error/decision toast ∧ the last success toast expired —
    /// plus a short dwell, and never while the pointer rests on the panel.
    private func canLeaveProcessing() -> Bool {
        PanelFeedback.isSettled(state)
            && !model.awaitingDrop
            && hosting?.dropState.isTargeted != true
            && !pointerOverPanel
            && Date().timeIntervalSince(lastActivity) >= 1.5
    }

    // MARK: Context menu

    private func showContextMenu(_ event: NSEvent) {
        guard let hosting else { return }
        hoverTask?.cancel()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(L.panelOpenLibrary, #selector(menuOpenLibrary), symbol: "books.vertical"))
        menu.addItem(menuItem(L.panelShowToday, #selector(menuShowToday), symbol: "list.bullet.rectangle"))
        menu.addItem(.separator())

        let dock = NSMenuItem(title: L.panelDock, action: nil, keyEquivalent: "")
        dock.image = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: nil)
        let dockMenu = NSMenu()
        for (edge, title) in [(PanelPrefs.Edge.left, L.panelDockLeft), (.right, L.panelDockRight)] {
            let item = menuItem(title, #selector(menuDock(_:)))
            item.representedObject = edge.rawValue
            item.state = model.edge == edge ? .on : .off
            dockMenu.addItem(item)
        }
        dock.submenu = dockMenu
        menu.addItem(dock)

        let opacity = NSMenuItem(title: L.panelOpacity, action: nil, keyEquivalent: "")
        opacity.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let opacityMenu = NSMenu()
        let current = PanelPrefs.idleOpacity
        for value in PanelPrefs.opacityChoices {
            let item = menuItem("\(Int((value * 100).rounded()))%", #selector(menuOpacity(_:)))
            item.representedObject = value
            item.state = abs(value - current) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)

        let expand = menuItem(L.panelExpandOnDrag, #selector(menuToggleExpandOnDrag))
        expand.state = PanelPrefs.expandOnDrag ? .on : .off
        menu.addItem(expand)
        let hover = menuItem(L.panelHoverToday, #selector(menuToggleHoverToday))
        hover.state = PanelPrefs.showTodayOnHover ? .on : .off
        menu.addItem(hover)
        menu.addItem(.separator())
        menu.addItem(menuItem(L.panelHide, #selector(menuHide), symbol: "eye.slash"))
        NSMenu.popUpContextMenu(menu, with: event, for: hosting)
        // Menu tracking may have swallowed the pointer's exit: re-arm the peek watcher.
        if model.mode == .peek { startPeekWatch() }
    }

    private func menuItem(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func menuOpenLibrary() {
        collapse()
        state.router.showLibrary()
    }

    @objc private func menuShowToday() {
        setMode(.peek)
    }

    @objc private func menuDock(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = PanelPrefs.Edge(rawValue: raw) else { return }
        let screenID = dockScreen()?.panelStableID
        persist {
            PanelPrefs.edge = edge
            if PanelPrefs.screenID == nil { PanelPrefs.screenID = screenID }
        }
        model.edge = edge
        relayout(animated: true)
    }

    @objc private func menuOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        persist { PanelPrefs.idleOpacity = value }
        updateAlpha()
    }

    @objc private func menuToggleExpandOnDrag() { PanelPrefs.expandOnDrag.toggle() }
    @objc private func menuToggleHoverToday() { PanelPrefs.showTodayOnHover.toggle() }

    @objc private func menuHide() {
        PanelPrefs.visible = false
        applySettings()
        state.post(Toast(id: "panel-hidden-hint", kind: .info, message: L.panelHiddenHint))
    }
}
