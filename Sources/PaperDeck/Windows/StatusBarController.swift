import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// Menu-bar item (§8 菜单栏): `books.vertical` + today's count (red with a filled
/// icon when something is overdue, pulsing while Claude reads), a drop target on
/// the button, and a menu rebuilt on every open. While the floating panel is
/// hidden, import feedback and toasts appear in a popover under the item.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var dropView: StatusDropView?
    private var observers: [PanelObserver] = []
    private var activity = FeedbackActivity()
    private var popover: NSPopover?
    private var popoverSettleTask: Task<Void, Never>?
    private var lastActivity = Date.distantPast
    private var isPulsing = false
    private var isMenuOpen = false
    private var reopenPopoverAfterMenu = false

    private static let pulseKey = "paperdeck.pulse"
    private static let maxRows = 7
    private static let titleLimit = 42

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        PanelPrefs.registerDefaults()
        statusItem.autosaveName = "\(BuildIdentity.current.bundleID).status"     // the menu-bar position
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.wantsLayer = true
            let drop = StatusDropView(button: button)
            let engine = state.engine
            drop.incomingDirectory = { engine.paths.incoming }
            drop.onDrop = { [weak self] items, ignored in self?.received(items, ignored: ignored) }
            button.addSubview(drop)
            dropView = drop
        }
        observers.append(PanelObserver { [weak self] in self?.render() })
        observers.append(PanelObserver { [weak self] in self?.feedbackChanged() })
        // The tour's [Show Me] for the menu-bar icon.
        state.router.showMenuBarMenu = { [weak self] in self?.statusItem.button?.performClick(nil) }
    }

    // MARK: Button

    private func render() {
        guard let button = statusItem.button else { return }
        let plan = state.snapshot?.today
        let count = plan?.count ?? 0
        let overdue = plan?.overdue.count ?? 0
        let reading = state.agentStatus.runningPaperID != nil
        let showCount = state.settings.showMenuBarCount && count > 0

        // Overdue: filled icon + red number (never colour alone).
        let image = NSImage(systemSymbolName: overdue > 0 ? "books.vertical.fill" : "books.vertical",
                            accessibilityDescription: "PaperDeck")
        image?.isTemplate = true
        button.image = image
        if showCount {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: overdue > 0 ? NSColor.systemRed : NSColor.labelColor,
            ]
            button.attributedTitle = NSAttributedString(string: "\(count)", attributes: attributes)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        let tooltip = L.menuBarTooltip(count: count, overdue: overdue, reading: reading,
                                       analyzingEmail: state.agentStatus.triageRunning)
        button.toolTip = tooltip
        dropView?.toolTip = tooltip       // the drop overlay sits on top of the button
        button.setAccessibilityLabel(tooltip)
        setPulsing(reading && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// 0.8 s opacity cycle while Claude is reading.
    private func setPulsing(_ on: Bool) {
        guard on != isPulsing, let button = statusItem.button else { return }
        isPulsing = on
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        if on {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        } else {
            layer.removeAnimation(forKey: Self.pulseKey)
        }
    }

    // MARK: Drops on the icon

    private func received(_ items: [IntakeItem], ignored: [String]) {
        if items.isEmpty && ignored.isEmpty {
            state.post(Toast(kind: .warning, message: L.panelNothingToImport))
        }
        if !items.isEmpty { GuideActivity.record(.menuBarDrop) }
        state.ingest(items, origin: .menuBar, ignoredNames: ignored)
    }

    // MARK: Feedback popover (panel hidden)

    private func feedbackChanged() {
        let change = activity.update(rows: state.importRows, toasts: state.toasts)
        if change.rowsChanged || change.newToasts { lastActivity = Date() }
        if PanelPrefs.panelOnScreen {
            closePopover()
            return
        }
        if change.newRows || (change.newToasts && !NSApp.isActive) { showPopover() }
    }

    private func showPopover() {
        guard !isMenuOpen, let button = statusItem.button, button.window != nil else { return }
        guard !PanelFeedback.isSettled(state) else { return }
        let popover = self.popover ?? makePopover()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        startPopoverSettleWatch()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        let view = StatusFeedbackView(
            state: state,
            onClose: { [weak self] in self?.closePopover() },
            onOpenPaper: { [weak self] id in
                self?.closePopover()
                self?.state.router.showPaper(id)
            },
            onSize: { [weak popover] size in
                guard let popover, size.width > 10, size.height > 10 else { return }
                if popover.contentSize != size { popover.contentSize = size }
            })
        let host = PanelFirstMouseHostingView(rootView: view)
        let controller = NSViewController(nibName: nil, bundle: nil)
        controller.view = host
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: DropPanelMetrics.processingWidth, height: 120)
        self.popover = popover
        return popover
    }

    private func closePopover() {
        popoverSettleTask?.cancel()
        if popover?.isShown == true { popover?.performClose(nil) }
    }

    /// Same rule as the panel: close once rows are terminal and toasts are gone.
    private func startPopoverSettleWatch() {
        popoverSettleTask?.cancel()
        popoverSettleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.popover?.isShown == true else { return }
                if PanelFeedback.isSettled(self.state) && Date().timeIntervalSince(self.lastActivity) >= 1.5 {
                    self.closePopover()
                    return
                }
            }
        }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        reopenPopoverAfterMenu = popover?.isShown == true && PanelFeedback.needsAttention(state)
        closePopover()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        if reopenPopoverAfterMenu && !PanelPrefs.panelOnScreen && PanelFeedback.needsAttention(state) {
            reopenPopoverAfterMenu = false
            Task { [weak self] in self?.showPopover() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let lang = L.lang
        if let snapshot = state.snapshot {
            let plan = snapshot.today
            menu.addItem(NSMenuItem.sectionHeader(title: plan.isEmpty
                ? L.menuBarHeaderEmpty(backlog: plan.backlogTotal)
                : L.menuBarHeader(count: plan.count, minutes: plan.todayMinutes, backlog: plan.backlogTotal)))
            let rows = snapshot.todayRows
            for row in rows.prefix(Self.maxRows) {
                menu.addItem(paperItem(row, today: plan.today, lang: lang))
            }
            if rows.count > Self.maxRows {
                menu.addItem(item(L.menuBarSeeAllToday(rows.count), #selector(showToday)))
            } else if plan.backlogTotal > 0 {
                menu.addItem(item(L.menuBarSeeAll(plan.backlogTotal), #selector(showToRead)))
            }
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: L.menuBarLoading))
        }
        if let mail = mailItem() {
            menu.addItem(.separator())
            menu.addItem(mail)
        }
        menu.addItem(.separator())
        menu.addItem(claudeItem(state.agentStatus))
        menu.addItem(.separator())
        menu.addItem(item(L.menuBarAddPDF, #selector(addPDF), key: "n", symbol: "plus"))
        menu.addItem(item(L.openLibrary, #selector(openLibrary), key: "l", symbol: "books.vertical"))
        let panelVisible = PanelPrefs.visible
        menu.addItem(item(panelVisible ? L.panelHide : L.panelShow, #selector(togglePanel),
                          symbol: panelVisible ? "eye.slash" : "rectangle.righthalf.inset.filled"))
        let skip = item(L.menuBarSkipToday, #selector(skipToday), symbol: "forward.end")
        skip.isEnabled = state.snapshot?.today.isEmpty == false
        menu.addItem(skip)
        ReadingAssistMenus.appendAssistItems(to: menu, state: state)
        menu.addItem(.separator())
        if let checklist = gettingStartedItem() { menu.addItem(checklist) }
        menu.addItem(helpItem())
        menu.addItem(item(L.settings, #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item(L.quit, #selector(quit), key: "q", symbol: "power"))
    }

    /// `[逾期2天] Title… 2/6` with 打开详情 / 打开 PDF / 标记已读 / 推迟一天.
    private func paperItem(_ row: PaperRow, today: LocalDate, lang: UILang) -> NSMenuItem {
        let paper = row.paper
        let (label, color) = Self.dayLabel(paper, row: row, today: today, lang: lang)
        let title = paper.title.count > Self.titleLimit ? String(paper.title.prefix(Self.titleLimit)) + "…" : paper.title
        let progress = row.totalCount > 0 ? "\(row.doneCount)/\(row.totalCount)" : ""

        let font = NSFont.menuFont(ofSize: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 400)]
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "[\(label)] ", attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
            .foregroundColor: color, .paragraphStyle: paragraph,
        ]))
        text.append(NSAttributedString(string: title, attributes: [.font: font, .paragraphStyle: paragraph]))
        if !progress.isEmpty {
            text.append(NSAttributedString(string: "\t" + progress, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }

        let entry = NSMenuItem(title: "[\(label)] \(title) \(progress)", action: nil, keyEquivalent: "")
        entry.attributedTitle = text
        entry.toolTip = paper.title
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item(L.menuBarOpenDetails, #selector(openDetails(_:)), paperID: row.id, symbol: "info.circle"))
        submenu.addItem(item(L.menuBarOpenPDF, #selector(openPDF(_:)), paperID: row.id, symbol: "doc.richtext"))
        submenu.addItem(.separator())
        submenu.addItem(item(L.menuBarMarkDone, #selector(markDone(_:)), paperID: row.id, symbol: "checkmark.circle"))
        let postpone = item(L.menuBarPostpone, #selector(postpone(_:)), paperID: row.id, symbol: "calendar.badge.clock")
        postpone.isEnabled = paper.deadline != nil && paper.scheduleMode != .none
        submenu.addItem(postpone)
        entry.submenu = submenu
        return entry
    }

    private static func dayLabel(_ paper: Paper, row: PaperRow, today: LocalDate, lang: UILang) -> (String, NSColor) {
        guard let deadline = paper.deadline, paper.scheduleMode != .none else {
            return (SharedStrings.unscheduled(lang), .secondaryLabelColor)
        }
        let delta = deadline.days(from: today)
        if delta < 0 { return (SharedStrings.overdueCompact(-delta, lang), .systemRed) }
        if delta == 0 { return (SharedStrings.today(lang), .systemOrange) }
        let chip = DeadlineLabel.chip(deadline: deadline, done: false, doneAt: nil,
                                      pinned: paper.scheduleMode == .pinned,
                                      provisional: paper.provisional && paper.scheduleMode == .auto,
                                      atRisk: row.atRisk, today: today, lang: lang)
        return (chip.text, delta == 1 ? .systemOrange : .secondaryLabelColor)
    }

    /// 「Help & Setup ▸」: PaperDeck Help, Getting Started (fresh installs), Setup Assistant…, Troubleshooting.
    private func helpItem() -> NSMenuItem {
        let entry = NSMenuItem(title: L.Help.helpAndSetup, action: nil, keyEquivalent: "")
        entry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(item(L.Help.paperDeckHelp, #selector(openHelp), symbol: "book"))
        if let count = gettingStartedProgress() {
            sub.addItem(item(L.Help.gettingStartedCount(count.done, count.total), #selector(openGettingStarted), symbol: "checklist"))
        }
        sub.addItem(item(L.Help.setupAssistantMenu, #selector(openSetup), symbol: "wand.and.stars"))
        sub.addItem(item(L.Help.troubleshootingMenu, #selector(openTroubleshooting), symbol: "wrench.and.screwdriver"))
        entry.submenu = sub
        return entry
    }

    /// 「Getting Started (2 of 7)…」 while the Today card shows (fresh installs only).
    private func gettingStartedItem() -> NSMenuItem? {
        guard let count = gettingStartedProgress() else { return nil }
        return item(L.Help.gettingStartedCount(count.done, count.total), #selector(openGettingStarted), symbol: "checklist")
    }

    private func gettingStartedProgress() -> (done: Int, total: Int)? {
        guard let facts = state.facts, GettingStartedCard.isShown(facts) else { return nil }
        return GettingStarted.progress(GettingStartedRows.items(facts))
    }

    /// 「邮件待处理 3 封（1 封请求）→」 → Library ▸ 邮件 (nil when nothing is pending). The icon's
    /// count stays today's papers.
    private func mailItem() -> NSMenuItem? {
        guard let counts = state.mailSnapshot?.counts,
              let title = L.Mail.menuLine(total: counts.pending, requests: counts.requests) else { return nil }
        let entry = item(title, #selector(openMail), symbol: counts.requests > 0 ? "envelope.badge" : "envelope")
        if counts.requests > 0 {
            let font = NSFont.menuFont(ofSize: 0)
            entry.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
            ])
        }
        return entry
    }

    /// AI status line (§8): what Claude / ChatGPT is running, why it isn't, and a way to fix it.
    private func claudeItem(_ s: AgentQueueStatus) -> NSMenuItem {
        let line = Self.claudeLine(s, lang: L.lang)
        let action: Selector? = switch line.action {
        case .aiSettings: #selector(openAISettings)
        case .library: #selector(openLibrary)
        case .mail: #selector(openMail)
        case nil: nil
        }
        let item = NSMenuItem(title: line.title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: s.shownKind.shortName)
        return item
    }

    enum ClaudeLineAction { case aiSettings, library, mail }

    /// The AI status line's text and where a click goes (nil: informational). Mail triage shares
    /// the one AI slot: 「正在分析邮件…」 / 「2 封邮件待 AI 分析」 (→ Mail), or appended to the paper line.
    static func claudeLine(_ s: AgentQueueStatus, lang: UILang, now: Date = Date()) -> (title: String, action: ClaudeLineAction?) {
        let mock = s.mode == .mock ? L.menuBarClaudeMock : ""
        let running = s.runningPaperID != nil ? 1 : 0
        let kind = s.shownKind
        let real = s.mode.providerKind != nil
        let waiting = s.triageQueued > 0 ? " · " + L.Mail.triageWaitingShort(s.triageQueued) : ""
        switch (s.mode, s.shownProvider) {
        case (.off, _), (_, .disabled):
            return (L.menuBarClaudeOff, .aiSettings)
        case (_, .notLoggedIn) where real:
            return (L.menuBarClaudeNeedsLogin(kind), .aiSettings)
        case (_, .notInstalled) where real:
            return (L.menuBarClaudeNotInstalled(kind), .aiSettings)
        case (_, .unsupported) where real:
            return (L.menuBarClaudeUnavailable(kind), .aiSettings)
        default:
            if let until = s.pausedUntil, until > now {
                return (L.menuBarClaudePaused(kind, Self.clock(until, lang: lang)), nil)
            } else if running > 0 {
                return (L.menuBarClaudeReading(kind, running: running, queued: s.queued) + waiting + mock, nil)
            } else if s.triageRunning, let triage = s.triageText(lang) {
                return (L.menuBarTriage(triage, queuedPapers: s.queued) + mock, .mail)
            } else if s.queued > 0 {
                return (L.menuBarClaudeReading(kind, running: 0, queued: s.queued) + waiting + mock, nil)
            } else if let triage = s.triageText(lang) {
                return (triage + mock, .mail)
            } else if s.held > 0 {
                return (L.menuBarClaudeHeld(s.held), .library)
            } else if real, case .unknown = s.shownProvider {
                return (L.menuBarClaudeChecking(kind), nil)
            } else {
                return (L.menuBarClaudeIdle(kind) + mock, nil)
            }
        }
    }

    /// `15:45`, `明天 15:45`, or `周五 15:45`.
    private static func clock(_ date: Date, lang: UILang) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return SharedStrings.tomorrow(lang) + " " + time }
        return SharedStrings.weekday(calendar.component(.weekday, from: date), lang) + " " + time
    }

    private func item(_ title: String, _ action: Selector, key: String = "", paperID: String? = nil,
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = paperID
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    // MARK: Actions

    @objc private func showToday() { state.router.showToday() }

    @objc private func showToRead() {
        state.sidebar = .toRead
        state.router.showLibrary()
    }

    @objc private func openDetails(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        state.router.showPaper(id)
    }

    @objc private func openPDF(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let row = state.snapshot?.row(id: id) else { return }
        state.openPDF(row)
    }

    @objc private func markDone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let state = self.state
        state.perform {
            let paper = try await state.engine.setStatus(paperID: id, .done)
            state.post(Toast(id: "done-\(id)", kind: .success, message: L.markedDone(paper.title)))
        }
    }

    @objc private func postpone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let state = self.state
        state.perform {
            let paper = try await state.engine.postponeDay(paperID: id)
            let lang = L.lang
            let today = state.snapshot?.today.today ?? LocalDate.today()
            let chip = paper.deadline.map { SharedStrings.relativeDay($0, today: today, lang: lang) }
                ?? SharedStrings.unscheduled(lang)
            state.post(Toast(kind: .success, message: L.menuBarPostponed(title: paper.title, chip: chip)))
        }
    }

    @objc private func openAISettings() { state.router.showSettings("ai") }
    @objc private func openMail() { state.router.showMail(nil) }
    @objc private func addPDF() { state.router.pickAndImportFiles() }
    @objc private func openLibrary() { state.router.showLibrary() }
    @objc private func skipToday() { state.skipToday() }
    @objc private func openSettings() { state.router.showSettings(nil) }
    @objc private func openHelp() { HelpCenter.openTopic(nil) }
    @objc private func openGettingStarted() { HelpCenter.openTopic(.gettingStarted) }
    @objc private func openSetup() { HelpCenter.openSetup(nil) }
    @objc private func openTroubleshooting() { HelpCenter.openTopic(HelpCenterModel.troubleshootingID) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func togglePanel() {
        let hide = PanelPrefs.visible
        PanelPrefs.visible = !hide
        guard hide else { return }
        // After the panel has processed the change, point at where to bring it back.
        let state = self.state
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            state.post(Toast(id: "panel-hidden-hint", kind: .info, message: L.panelHiddenHint))
        }
    }
}

/// Popover content while the floating panel is hidden: import rows + toasts.
private struct StatusFeedbackView: View {
    let state: AppState
    let onClose: () -> Void
    let onOpenPaper: (String) -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill").foregroundStyle(.secondary)
                Text(PanelFeedback.title(state)).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L.toastDismiss)
                .accessibilityLabel(L.toastDismiss)
            }
            if !state.importRows.isEmpty {
                ImportProgressList(state: state, maxRows: 5, onOpenPaper: onOpenPaper)
            }
            ToastStack(state: state, maxVisible: 3)
        }
        .padding(14)
        .frame(width: DropPanelMetrics.processingWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}

/// Buttons in a popover of an inactive (accessory) app must work on the first click.
final class PanelFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
