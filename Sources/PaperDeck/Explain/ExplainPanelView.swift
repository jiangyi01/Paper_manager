import AppKit
import SwiftUI
import PaperDeckCore

/// What the panel's window-level buttons do (the controller supplies them; renders pass no-ops).
struct ExplainPanelActions {
    var close: () -> Void = {}
    var setPinned: (Bool) -> Void = { _ in }
    var canPinMore: () -> Bool = { true }
    var showHistory: () -> Void = {}
    /// PaperDeck wrote the pasteboard (the clipboard offer ignores it).
    var copied: () -> Void = {}
    /// The content's natural height (the panel grows to it).
    var idealHeight: (CGFloat) -> Void = { _ in }
    /// The same capture explained again with this click's ticket (after "Not this paper" / a picked paper).
    var explainAgain: (ConsentTicket) -> Void = { _ in }
}

/// The explanation panel's content (LN §7.2, dive-ui §4): the paper / source chip, EN | 中, pin and
/// close; the quote of what was explained (or its image, with "Send as image"); the answer streaming
/// in, follow-ups and chip turns under it; the notice of a refusal or failure with the one button
/// that helps; the action chips (⌘1–⌘5); the follow-up field; the footer (model · time · today N,
/// Stop / Regenerate, Copy, Save to Notes, History). Fully keyboard-driven; Esc closes.
///
/// Every button that sends mints its `ConsentTicket` here, in its own action — a chip (`.action`),
/// the follow-up's Return (`.followUp`, or `.ask` for the first question), Try Again / Regenerate
/// (`.retry`), Send Anyway / Send (`.action`), Continue past the soft cap (`.capOverride`). Turning
/// Explain & Ask on from the off card sends nothing.
struct ExplainPanelView: View {
    @Bindable var state: ExplainPanelState
    let app: AppState?
    let focus: ExplainPanelFocus
    var actions = ExplainPanelActions()
    var style: PanelChromeStyle = .glass
    /// `--explain-render`: a fixed clock for the elapsed chip.
    var previewNow: Date?

    @FocusState private var fieldFocused: Bool
    @State private var quoteExpanded = false
    @State private var copiedFlash = false
    @State private var savedFlash = false

    /// Header + chips + field + footer, around the scrolling content.
    static let chromeHeight: CGFloat = 178

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ExplainMatchLine(state: state, app: app) {
                            actions.explainAgain(ConsentTicket.mint(.retry, surface: .explain))
                        }
                        quote
                        transcript
                        notice
                        Color.clear.frame(height: 1).id(Self.endID)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        actions.idealHeight(h + Self.chromeHeight)
                    }
                }
                .onChange(of: state.current?.text) { _, _ in
                    if state.phase == .streaming { proxy.scrollTo(Self.endID, anchor: .bottom) }
                }
            }
            if !state.chips.isEmpty, hasSubject { chipRow }
            followUpField
            footer
        }
        .frame(minWidth: 340, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .background(shortcuts)
        .onExitCommand { actions.close() }
        .onChange(of: focus.followUpRequest) { _, _ in fieldFocused = true }
        .onAppear { if focus.followUpRequest > 0 { fieldFocused = true } }
    }

    private static let endID = "explain-end"

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            subjectChip
            Spacer(minLength: 4)
            Picker(selection: $state.language) {
                ForEach(ExplainLanguageToggle.labels, id: \.0) { lang, label in Text(verbatim: label).tag(lang) }
            } label: {
                Text(L.Explain.languageHelp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            .help(L.Explain.languageHelp)
            headerButton(state.pinned ? L.Explain.unpin : L.Explain.pin, state.pinned ? "pin.fill" : "pin",
                         help: state.pinned || actions.canPinMore() ? L.Explain.pinHelp : L.Explain.pinLimit) {
                actions.setPinned(!state.pinned)
            }
            .keyboardShortcut("p", modifiers: .command)
            headerButton(L.Explain.close, "xmark", help: L.Explain.close) { actions.close() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func headerButton(_ title: String, _ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        if style == .glass {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(.glass)
                .help(help)
                .accessibilityLabel(title)
        } else {
            Button(action: action) { Image(systemName: symbol) }
                .buttonStyle(.borderless)
                .help(help)
                .accessibilityLabel(title)
        }
    }

    /// The paper and page (opens the reader there), or where the capture came from.
    private var subjectChip: some View {
        let row = state.paperID.flatMap { app?.snapshot?.row(id: $0) }
        let page = state.page.map(L.Explain.page)
        let title = row?.paper.title ?? (state.prepared == nil ? L.Explain.source(state.capture.source) : L.Explain.notFromLibrary)
        return Button {
            if let app { ExplainOpen.paper(app: app, paperID: state.paperID, page: state.page, anchor: state.anchor, quote: state.excerpt) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: row == nil ? Self.sourceSymbol(state.capture.source) : "doc.text")
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                if let page { Text(verbatim: "· " + page).foregroundStyle(.secondary).fixedSize() }
            }
            .font(.callout)
        }
        .buttonStyle(.borderless)
        .disabled(row == nil)
        .help(page.map { L.Explain.openAt($0) } ?? (row == nil ? L.Explain.notFromLibrary : L.Explain.openPaper))
    }

    /// The thumbnail: the prepared image (what is sent), else — for a box, a drop, a screenshot —
    /// the capture itself; a click's band is never shown as if it were sent.
    static func shownImage(_ state: ExplainPanelState) -> AssistImage? {
        if let p = state.prepared { return p.image ?? (state.capture.focus == nil ? state.capture.image : nil) }
        return state.capture.focus == nil ? state.capture.image : nil
    }

    /// Whether the next turn sends the image (the user's toggle, else the capture's kind).
    static func sendsImage(_ state: ExplainPanelState, prepared: ExplainPrepared) -> Bool {
        let kind = state.pending ?? state.current?.kind ?? .explain
        return ExplainPanelState.sendsImage(kind, prepared: prepared, override: state.imageOverride)
    }

    static func sourceSymbol(_ s: ExplainSource) -> String {
        switch s {
        case .services: return "contextualmenu.and.cursorarrow"
        case .clipboard: return "doc.on.clipboard"
        case .screenshot: return "camera.viewfinder"
        case .region: return "rectangle.dashed"
        case .lens: return "magnifyingglass"
        case .reader: return "book"
        case .drop: return "photo"
        }
    }

    // MARK: Quote

    private var hasSubject: Bool { state.excerpt != nil || state.hasImage }

    @ViewBuilder
    private var quote: some View {
        // Exactly what goes with the request (F3, CUX-14): the prepared crop (a click's paragraph or
        // figure), never the band it was read from; nothing while a click is still being read.
        if let image = Self.shownImage(state), let ns = ExplainImages.thumbnail(image) {
            let aspect = image.pixelSize.height > 0 ? image.pixelSize.width / image.pixelSize.height : 1
            VStack(alignment: .leading, spacing: 3) {
                Image(nsImage: ns)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: min(360, 80 * aspect), height: min(80, 360 / max(aspect, 0.01)))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
                    .accessibilityLabel(L.Explain.source(state.capture.source))
                if let p = state.prepared {
                    Label(Self.sendsImage(state, prepared: p) ? L.ExplainUX.willBeSent : L.ExplainUX.textOnlySent,
                          systemImage: Self.sendsImage(state, prepared: p) ? "arrow.up.circle" : "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let excerpt = state.excerpt {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "quote.opening").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: quoteExpanded ? excerpt : ClipboardOffer.preview(excerpt, limit: 220))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(quoteExpanded ? nil : 2)
                        .textSelection(.enabled)
                    if excerpt.count > 140 {
                        Button(quoteExpanded ? L.Explain.collapseQuote : L.Explain.expandQuote) { quoteExpanded.toggle() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        if state.hasImage, state.excerpt != nil, let prepared = state.prepared {
            Toggle(isOn: Binding(get: { state.imageOverride ?? ExplainPanelState.sendsImage(.explain, prepared: prepared, override: nil) },
                                 set: { state.imageOverride = $0 })) {
                Label(L.Explain.sendImage, systemImage: "photo")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(L.Explain.sendImageHelp)
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        ForEach(state.turns) { turn in
            VStack(alignment: .leading, spacing: 4) {
                if let q = turn.kind.question {
                    Text(verbatim: L.Explain.question(q))
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                } else if turn.index > 0 {
                    Text(verbatim: L.Explain.action(turn.kind.actionCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ExplainAnswerView(text: turn.text, streaming: turn.id == state.current?.id && state.phase == .streaming)
                if turn.stopped {
                    Label(L.Explain.stopped, systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                }
                if turn.cutOff {
                    Label(L.Explain.cutOff, systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        switch state.phase {
        case .idle where state.turns.isEmpty:
            Text(L.Explain.idleHint).font(.callout).foregroundStyle(.secondary)
        case .locating:
            progress(L.Explain.locating, since: nil)
        case .sending(let wait):
            progress(waitText(wait), since: state.current?.startedAt)
            if state.app(app).mode == .codex { Text(L.Explain.codexWhole).font(.caption).foregroundStyle(.tertiary) }
        default:
            EmptyView()
        }
    }

    private func waitText(_ w: ExplainWait) -> String {
        switch w {
        case .starting: return L.Explain.starting(ai)
        case .waiting: return L.Explain.waiting(ai)
        case .stillWaiting: return L.Explain.stillWaiting(ai)
        }
    }

    private func progress(_ text: String, since start: Date?) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).font(.callout).foregroundStyle(.secondary)
            if let start {
                if let previewNow {
                    Text(verbatim: L.Explain.seconds(max(0, Int(previewNow.timeIntervalSince(start)))))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(verbatim: L.Explain.seconds(max(0, Int(ctx.date.timeIntervalSince(start)))))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notice: some View {
        switch state.phase {
        case .refused(.off):
            if state.app(app).mode == .off {
                ExplainEnableCard(app: app)
            } else {
                noticeCard(L.Explain.nowOn, icon: "sparkles", tint: .accentColor, detail: nil) {
                    Button(L.Explain.explainNow) { state.retry(ticket: ConsentTicket.mint(.action, surface: .explain)) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .refused(.confirmPrivacy(let reasons)):
            noticeCard(L.Explain.confirmTitle(ai), icon: "lock.shield", tint: .orange,
                       detail: AssistPolicyText.confirmation(reasons)) {
                Button(L.cancel) { actions.close() }
                Button(L.Explain.sendAnyway) { state.confirm(ticket: ConsentTicket.mint(.action, surface: .explain)) }
                    .buttonStyle(.borderedProminent)
            }
        case .refused(.askBeforeSend):
            noticeCard(L.Explain.askBeforeSendTitle(ai), icon: "paperplane", tint: .accentColor,
                       detail: L.ExplainConsent.heldDetail(state.heldFor)) {
                Button(L.cancel) { actions.close() }
                Button(L.Explain.send) { state.confirm(ticket: ConsentTicket.mint(.action, surface: .explain)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .refused(.softCap(let n)):
            noticeCard(L.Explain.softCap(n), icon: "gauge.with.dots.needle.67percent", tint: .orange, detail: nil) {
                Button(L.Explain.continueAnyway) { state.confirm(ticket: ConsentTicket.mint(.capOverride, surface: .explain)) }
                    .buttonStyle(.borderedProminent)
            }
        case .refused(let r):
            noticeCard(Self.refusalText(r), icon: r == .blocked ? "hand.raised" : "exclamationmark.triangle",
                       tint: Self.isStop(r) ? .red : .secondary,
                       detail: r == .blocked ? L.QA.blockedHint : nil) {
                if state.phase.canRetry { retryButton }
            }
        case .error(.outputCap):
            EmptyView()                                    // the kept answer says it was cut off
        case .error(let p):
            noticeCard(errorText(p), icon: "exclamationmark.triangle", tint: .secondary, detail: nil) {
                if p.canRetry { retryButton }
            }
        case .limited(let until):
            noticeCard(L.Explain.limited(ai, until.map { AskNoticeView.time($0) }), icon: "gauge.with.dots.needle.100percent",
                       tint: .orange, detail: nil) { retryButton }
        case .needsLogin(let reason):
            noticeCard(reason.text(L.lang, loginProblem: true, provider: provider), icon: "person.crop.circle.badge.exclamationmark",
                       tint: .orange, detail: L.QA.loginHint(provider)) { retryButton }
        default:
            EmptyView()
        }
    }

    private var retryButton: some View {
        Button(L.Explain.retry) {
            state.retry(ticket: ConsentTicket.mint(.retry, surface: .explain), depth: Self.optionDepth)
        }
    }

    /// A refusal nothing on this panel can lift (red).
    static func isStop(_ r: ExplainRefusal) -> Bool {
        switch r {
        case .blocked, .hardCap: return true
        default: return false
        }
    }

    static func refusalText(_ r: ExplainRefusal) -> String {
        switch r {
        case .off: return L.Explain.offTitle
        case .blocked: return L.Policy.blocked
        case .confirmPrivacy: return L.Explain.confirmTitle("AI")
        case .askBeforeSend: return L.Explain.askBeforeSendHint
        case .softCap(let n): return L.Explain.softCap(n)
        case .hardCap(let n): return L.Explain.hardCap(n)
        case .burst: return L.Explain.burst
        case .budget: return L.Explain.budget
        case .expired: return L.Explain.expired
        case .emptyCapture: return L.Explain.emptyCapture
        case .privacyUnchecked: return L.Explain.privacyUnchecked
        }
    }

    private func errorText(_ p: ExplainProblem) -> String {
        switch p {
        case .timeout: return L.Explain.timeout
        case .overloaded: return L.Explain.overloaded(ai)
        case .invalidOutput: return L.Explain.invalidOutput
        case .notInstalled: return L.Explain.notInstalled(provider.cliName)
        case .unsupported: return L.Explain.unsupported(ai)
        case .failed: return L.Explain.failed
        case .outputCap: return L.Explain.cutOff
        }
    }

    private func noticeCard<Buttons: View>(_ title: String, icon: String, tint: Color, detail: String?,
                                           @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                buttons()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.22)))
    }

    // MARK: Chips, follow-up, footer

    private var chipRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .done = state.phase, let current = state.current, current.language != state.language {
                Button {
                    state.run(current.kind, ticket: ConsentTicket.mint(.action, surface: .explain), depth: Self.optionDepth)
                } label: {
                    Label(L.Explain.reexplain(in: state.language), systemImage: "character.bubble").font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            // Titled chips when they fit the panel's width, else short titles, else their symbols (the
            // titles as tooltips).
            ViewThatFits(in: .horizontal) {
                chips(.full)
                chips(.short)
                chips(.icon)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private enum ChipStyle { case full, short, icon }

    private func chips(_ style: ChipStyle) -> some View {
        HStack(spacing: 6) {
            ForEach(state.chips, id: \.self) { chip in
                Button {
                    state.run(chip.kind, ticket: ConsentTicket.mint(.action, surface: .explain), depth: Self.optionDepth)
                } label: {
                    switch style {
                    case .full: Label(L.Explain.chip(chip), systemImage: chip.symbol).font(.caption)
                    case .short: Text(L.Explain.chipShort(chip)).font(.caption)
                    case .icon: Image(systemName: chip.symbol)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(KeyEquivalent(chip.keyDigit), modifiers: .command)
                .help(L.Explain.chip(chip) + " · " + L.Explain.chipHelp(chip.keyDigit))
                .accessibilityLabel(L.Explain.chip(chip))
                .disabled(state.phase == .locating)
            }
        }
        .fixedSize()
    }

    private var followUpField: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble").foregroundStyle(.secondary)
            TextField(state.turns.isEmpty ? L.Explain.questionPlaceholder : L.Explain.followUpPlaceholder, text: $state.followUp)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    let ticket = ConsentTicket.mint(state.turns.isEmpty ? .ask : .followUp, surface: .explain)
                    state.askFollowUp(ticket: ticket, depth: Self.optionDepth)
                }
                .onExitCommand { actions.close() }
            Button {
                let ticket = ConsentTicket.mint(state.turns.isEmpty ? .ask : .followUp, surface: .explain)
                state.askFollowUp(ticket: ticket, depth: Self.optionDepth)
            } label: {
                Image(systemName: "return")
            }
            .buttonStyle(.borderless)
            .help(L.Explain.send)
            .accessibilityLabel(L.Explain.send)
            .disabled(state.followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text(verbatim: modelLine).lineLimit(1)
            Text(verbatim: "·").foregroundStyle(.tertiary)
            Text(verbatim: L.Explain.today(todayCount))
                .help(L.Explain.todayHelp(state.app(app).dailySoftCap))
            Spacer(minLength: 4)
            if state.isRunning {
                Button(L.Explain.stop) { Task { await state.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .help(L.Explain.stopHelp)
            } else if state.current != nil {
                footerIcon(L.Explain.regenerate, "arrow.clockwise", help: L.Explain.regenerateHelp) {
                    state.retry(ticket: ConsentTicket.mint(.retry, surface: .explain), depth: Self.optionDepth)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            footerIcon(copiedFlash ? L.Explain.copied : L.Explain.copy, copiedFlash ? "checkmark" : "doc.on.doc",
                       help: L.Explain.copyHelp) { copyAnswer() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(state.answerText.isEmpty)
            footerIcon(savedFlash ? L.Explain.saved : L.Explain.saveToNotes, savedFlash ? "checkmark" : "square.and.arrow.down",
                       help: state.paperID == nil ? L.Explain.saveNeedsPaper : L.Explain.saveHelp) { saveToNotes() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!state.canSaveToNotes)
            footerIcon(L.Explain.history, "clock", help: L.Explain.historyHelp) { actions.showHistory() }
                .keyboardShortcut("y", modifiers: .command)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func footerIcon(_ title: String, _ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(title)
    }

    /// Keys without a visible button: ⌘L language, ⌘K the field, ⌘I send as image, ⌥⌘R Thorough.
    private var shortcuts: some View {
        ZStack {
            Button("") { state.language = ExplainLanguageToggle.toggled(state.language) }.keyboardShortcut("l", modifiers: .command)
            Button("") { fieldFocused = true }.keyboardShortcut("k", modifiers: .command)
            Button("") {
                if let p = state.prepared, state.hasImage {
                    state.imageOverride = !(state.imageOverride ?? ExplainPanelState.sendsImage(.explain, prepared: p, override: nil))
                }
            }
            .keyboardShortcut("i", modifiers: .command)
            Button("") {
                guard !state.isRunning, state.current != nil else { return }
                state.retry(ticket: ConsentTicket.mint(.retry, surface: .explain), depth: .thorough)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    /// ⌥ held while clicking: the Thorough model for that turn.
    static var optionDepth: AssistSettings.Depth? {
        NSEvent.modifierFlags.contains(.option) ? .thorough : nil
    }

    private var provider: AIProviderKind { state.app(app).mode.providerKind ?? app?.settings.agentProvider ?? .claude }

    private var ai: String {
        switch state.app(app).mode {
        case .local: return L.Explain.onDevice
        case .mock: return "Mock"
        default: return provider.shortName
        }
    }

    private var todayCount: Int { app?.assist.status.todayCount ?? 0 }

    /// "Claude haiku · 6.2 s" for the answer shown; the model the next turn uses otherwise.
    private var modelLine: String {
        if let meta = state.current?.meta {
            let who = AIProviderKind(rawValue: meta.provider)?.shortName ?? ai
            let secs = meta.totalMs > 0 ? " · " + String(format: "%.1f s", Double(meta.totalMs) / 1000) : ""
            return [who, meta.model].filter { !$0.isEmpty }.joined(separator: " ") + secs
        }
        let model = ExplainModelChoice.model(state.app(app), depth: state.depth).model
        return state.app(app).mode.providerKind == nil ? ai : "\(ai) \(model)"
    }

    private func copyAnswer() {
        let text = state.answerText
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        actions.copied()
        flash($copiedFlash)
    }

    private func saveToNotes() {
        Task {
            do {
                try await state.saveToNotes()
                flash($savedFlash)
            } catch {
                app?.report(error)
            }
        }
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            flag.wrappedValue = false
        }
    }
}

extension ExplainPanelState {
    /// The assist settings the panel reads (the app's store; defaults without an app).
    func app(_ app: AppState?) -> AssistSettings { app?.settings.assist ?? AssistSettings() }
}

/// An answer: paragraphs, lists and quotes with inline Markdown (links are shown as text, never
/// followed); a soft caret while it streams.
struct ExplainAnswerView: View {
    let text: String
    var streaming = false

    var body: some View {
        let blocks = QAAnswerFormat.blocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                row(block, last: i == blocks.count - 1)
            }
            if blocks.isEmpty, streaming { Text(verbatim: "▍").foregroundStyle(.purple) }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ block: QAAnswerFormat.Block, last: Bool) -> some View {
        let caret = streaming && last ? " ▍" : ""
        switch block {
        case .paragraph(let s):
            Text(Self.inline(s + caret)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(Self.inline(s + caret)).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(n).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(s + caret)).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let s):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 2)
                Text(Self.inline(s + caret)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Inline Markdown without links (the lane already made the final answer's links inert; a
    /// streamed fragment must not become clickable either).
    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var out = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in out.runs where run.link != nil { out[run.range].link = nil }
        return out
    }
}

/// Explain & Ask is off: one button per subscription (turning it on sends nothing), then the panel's
/// own [Regenerate] sends with a fresh click.
struct ExplainEnableCard: View {
    let app: AppState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.Explain.offTitle, systemImage: "sparkles").font(.callout.weight(.semibold))
            Text(L.Explain.offBody).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(providers, id: \.self) { kind in
                    if kind == providers.first {
                        Button(L.Explain.useProvider(kind.shortName)) { enable(kind) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(L.Explain.useProvider(kind.shortName)) { enable(kind) }.buttonStyle(.bordered)
                    }
                }
                Spacer()
                Button(L.Explain.openSettings) { app?.router.showSettings("assist") }.buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18)))
    }

    private var providers: [AIProviderKind] {
        let first = app?.settings.agentProvider ?? .claude
        return [first] + AIProviderKind.allCases.filter { $0 != first }
    }

    /// The same switch as Settings ▸ Explain & Ask (and the Ask tab's card): sends nothing.
    private func enable(_ kind: AIProviderKind) {
        guard let app else { return }
        var a = app.settings.assist
        a.mode = kind.assistMode
        a.consentVersion = max(a.consentVersion, AssistSwitchSection.consentVersion)
        app.settings.assist = a
    }
}

/// Opening an explanation's paper: the reader at the exact anchor (A4), else the page with the
/// excerpt highlighted, else the paper with the user's opener.
enum ExplainOpen {
    static func paper(app: AppState, paperID: String?, page: Int?, anchor: ReaderAnchor?, quote: String?) {
        guard let paperID, let row = app.snapshot?.row(id: paperID) else { return }
        if let anchor, ReaderRouter.isAvailable {
            ReaderRouter(state: app).openReader(row, anchor: anchor)
        } else {
            app.openPDF(row, page: page, quote: quote)
        }
    }
}
