import AppKit
import SwiftUI
import PaperDeckCore

/// The conversation of one Ask surface (the detail inspector's Ask tab, the Ask window): thread
/// picker, Quick / Thorough and EN / 中 / Auto toggles, the messages with streaming Markdown and
/// citation chips, the notices (AI off, sign-in, usage limit, caps, privacy), suggested questions
/// and the composer with its estimate line (READING_ASSIST_PLAN §7 "Ask message", DQ §6.6).
///
/// It never starts a turn itself: every click that sends calls `perform`, which the hosting view
/// (`AskTab`, `AskWindowView`) implements by minting a `ConsentTicket` in that action handler.
struct AskThreadView: View {
    let state: AppState
    @Bindable var session: AskSession
    /// P1…Pn titles (one in the Ask tab).
    let titles: [String]
    let perform: (AskIntent) -> Void

    @FocusState private var composerFocused: Bool

    private var settings: AssistSettings { state.settings.assist }
    private var modeOff: Bool { settings.mode == .off }
    private var blocked: Bool { session.privacy == .blocked }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let banner = privacyBanner { banner }
            messages
            Divider()
            composer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            threadMenu
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Quick / Thorough and EN / 中 / Auto: they apply to the next question.
    private var toggles: some View {
        HStack(spacing: 8) {
            Picker(selection: Binding(get: { session.depth }, set: { session.depth = $0; session.scheduleEstimate() })) {
                Text(L.QA.depthQuick).tag(AssistSettings.Depth.quick)
                Text(L.QA.depthThorough).tag(AssistSettings.Depth.thorough)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L.QA.depthHelp)
            Picker(selection: Binding(get: { session.language }, set: { session.setLanguage($0) })) {
                Text(L.QA.langAuto).tag(AssistSettings.AnswerLanguage.auto)
                Text(verbatim: L.QA.langEN).tag(AssistSettings.AnswerLanguage.en)
                Text(verbatim: L.QA.langZH).tag(AssistSettings.AnswerLanguage.zh)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L.QA.langHelp)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var threadMenu: some View {
        Menu {
            ForEach(session.threads) { t in
                Button { session.select(threadID: t.id) } label: {
                    if t.id == session.thread?.id { Label(t.title, systemImage: "checkmark") } else { Text(verbatim: t.title) }
                }
            }
            if !session.threads.isEmpty { Divider() }
            Button(L.QA.newThread) { session.newThread() }
                .disabled(session.isRunning || session.messages.isEmpty)
            Button(L.QA.deleteThread, role: .destructive) { session.deleteThread() }
                .disabled(session.isRunning || session.thread?.persisted != true)
        } label: {
            Label(threadTitle, systemImage: "bubble.left.and.text.bubble.right")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help(L.QA.threadHelp)
    }

    private var threadTitle: String {
        guard let t = session.thread, t.persisted, !t.title.isEmpty else { return L.QA.untitledThread }
        return t.title
    }

    // MARK: Banners

    private var privacyBanner: AnyView? {
        if session.privacyUnchecked {
            return AnyView(AskBanner(icon: "exclamationmark.triangle", tint: .orange, title: L.QA.privacyUnchecked,
                                     detail: L.QA.privacyUncheckedHint))
        }
        if session.isMulti, session.paperPrivacy.count == session.paperIDs.count {
            let blocked = session.labels { $0 == .blocked }
            if !blocked.isEmpty {
                let removable = session.paperIDs.count - blocked.count >= 2
                return AnyView(VStack(alignment: .leading, spacing: 6) {
                    AskBanner(icon: "hand.raised", tint: .red, title: L.QA.blockedPapers(blocked),
                              detail: removable ? L.QA.blockedPapersHint : L.QA.blockedHint)
                    if removable {
                        HStack {
                            ForEach(blocked, id: \.self) { label in
                                Button(L.QA.removeLabel(label)) { removePaper(label) }
                            }
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }.background(Color.red.opacity(0.08)))
            }
            let asking = session.labels { if case .confirm = $0 { return true }; return false }
            if !asking.isEmpty, case .confirm(let reasons) = session.privacy {
                return AnyView(AskBanner(icon: "lock.shield", tint: .orange, title: L.QA.privacyNotePapers(asking),
                                         detail: reasons.map(L.Policy.reason).joined(separator: "\n")))
            }
            return nil
        }
        switch session.privacy {
        case .ok: return nil
        case .blocked:
            return AnyView(AskBanner(icon: "hand.raised", tint: .red, title: L.Policy.blocked, detail: L.QA.blockedHint))
        case .confirm(let reasons):
            return AnyView(AskBanner(icon: "lock.shield", tint: .orange, title: L.QA.privacyNote,
                                     detail: reasons.map(L.Policy.reason).joined(separator: "\n")))
        }
    }

    /// "Remove P4" in the Ask window's never-AI banner.
    private func removePaper(_ label: String) {
        guard let n = Int(label.dropFirst()), session.paperIDs.indices.contains(n - 1) else { return }
        let id = session.paperIDs[n - 1]
        session.setPapers(session.paperIDs.filter { $0 != id })
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if modeOff, session.notice == nil { AskEnableCard(state: state) }
                    if session.messages.isEmpty && session.streamingHere == nil && session.notice == nil && !blocked {
                        suggestions
                    }
                    ForEach(shownMessages) { m in
                        if m.role == .user {
                            AskQuestionBubble(text: m.text)
                        } else {
                            AskAnswerRow(state: state, session: session, message: m, perform: perform)
                        }
                    }
                    if let s = session.streamingHere {
                        if session.messages.last?.role != .user || session.messages.last?.text != s.question {
                            AskQuestionBubble(text: s.question)
                        }
                        AskStreamingRow(state: state, session: session, streaming: s)
                    }
                    if let notice = session.notice {
                        AskNoticeView(state: state, session: session, notice: notice, perform: perform)
                    } else if !session.isRunning, session.trailingQuestion != nil, !modeOff, !blocked {
                        Button(L.QA.retry) { perform(.retry) }
                            .controlSize(.small)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.streaming?.text.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// Stored messages; the answer streaming in is drawn live instead of its stored row.
    private var shownMessages: [QAMessage] {
        guard session.streamingHere != nil else { return session.messages }
        return session.messages.filter { $0.state != .streaming }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.QA.tryAsking).font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(suggestionList, id: \.self) { s in
                    Button { session.draft = s; composerFocused = true; session.scheduleEstimate() } label: {
                        Text(verbatim: s)
                            .font(.callout)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Suggested questions (built locally, no quota): they fill the composer; Ask sends.
    private var suggestionList: [String] {
        if session.isMulti { return [L.QA.suggestCompare, L.QA.suggestAgree, L.QA.suggestStrongest] }
        var out = [L.QA.suggestMain, L.QA.suggestMethod, L.QA.suggestLimits, L.QA.suggestReproduce]
        if let id = session.paperIDs.first, let term = state.snapshot?.row(id: id)?.paper.card?.keyTerms.first?.term,
           !term.isEmpty, term.count <= 40 {
            out.insert(L.QA.suggestTerm(term), at: 1)
        }
        return out
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $session.draft, prompt: Text(placeholder), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
                    .disabled(blocked)
                    .onChange(of: session.draft) { session.scheduleEstimate() }
                if session.streamingHere != nil {
                    Button { session.stop() } label: { Label(L.QA.stop, systemImage: "stop.fill") }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                } else {
                    Button { perform(.ask(session.draft)) } label: { Label(L.QA.send, systemImage: "arrow.up.circle.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSend)
                        .help(L.QA.sendHelp)
                }
            }
            if QAContextBuilder.questionIsCut(session.draft) {
                Label(L.QA.questionTooLong(QAContextBuilder.questionLimit), systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            toggles
            AskEstimateLine(state: state, session: session)
        }
        .padding(12)
    }

    private var canSend: Bool {
        !modeOff && !blocked && !session.isRunning && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        session.isMulti ? L.QA.placeholderMulti(session.paperIDs.count) : L.QA.placeholder
    }
}

// MARK: - Rows

struct AskQuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(verbatim: text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.13)))
                .accessibilityLabel(L.QA.you + ": " + text)
        }
    }
}

/// A stored answer: text, state caption, citation chips, actions.
struct AskAnswerRow: View {
    let state: AppState
    let session: AskSession
    let message: QAMessage
    let perform: (AskIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !message.text.isEmpty {
                AnswerBlocksView(blocks: QAAnswerFormat.blocks(message.text), multi: session.isMulti) { k in openMarker(k) }
            }
            if let caption {
                Label(caption, systemImage: message.state == .failed ? "exclamationmark.triangle"
                      : message.errorKind == QAService.outputCapKind ? "scissors" : "stop.circle")
                    .font(.caption)
                    .foregroundStyle(message.state == .failed ? Color.orange : Color.secondary)
            }
            CitationChipRow(citations: message.citations, multi: session.isMulti, paperCount: session.paperIDs.count) { c in
                AskCitationRouting.open(c, paperIDs: session.paperIDs, state: state)
            }
            if message.state == .done || !message.text.isEmpty { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L.QA.copy) { copy() }
            Button(L.QA.delete, role: .destructive) { session.delete(messageID: message.id) }
        }
    }

    private var caption: String? {
        switch message.state {
        case .done, .streaming: return nil
        case .cancelled:
            switch message.errorKind {
            case "interrupted": return L.QA.interrupted
            case QAService.outputCapKind: return L.QA.cutOff
            default: return L.QA.stopped
            }
        case .failed: return L.QA.didNotFinish
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { copy() } label: { Label(L.QA.copy, systemImage: "doc.on.doc") }
            if session.isMulti {
                Menu {
                    Button(L.QA.allPapers(session.paperIDs.count)) { session.saveToNotes(messageID: message.id) }
                    Divider()
                    ForEach(Array(session.paperIDs.enumerated()), id: \.offset) { i, id in
                        Button("P\(i + 1) · " + (state.snapshot?.row(id: id)?.paper.title ?? id)) {
                            session.saveToNotes(messageID: message.id, paperIDs: [id])
                        }
                    }
                } label: {
                    Label(L.QA.saveToNotesOf, systemImage: "note.text.badge.plus").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
            } else {
                Button { session.saveToNotes(messageID: message.id) } label: {
                    Label(L.QA.saveToNotes, systemImage: "note.text.badge.plus")
                }
            }
            Menu {
                if message.depth != .thorough {
                    Button(L.QA.askThoroughly) { perform(.thorough(messageID: message.id)) }
                }
                Button(L.QA.answerIn(otherLanguage)) { perform(.translate(otherLanguage, messageID: message.id)) }
                Divider()
                Button(L.QA.delete, role: .destructive) { session.delete(messageID: message.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .disabled(session.isRunning)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var otherLanguage: UILang { message.language == "zh" ? .en : .zh }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AskMarkdown.plain(message.text, multi: session.isMulti), forType: .string)
    }

    /// An inline marker: its stored citation (validity, label, sentence) when there is one.
    private func openMarker(_ k: Int) {
        let tokens = QACitations.tokens(in: message.text)
        guard tokens.indices.contains(k), let first = tokens[k].citations.first else { return }
        let counts = session.paperIDs.map { state.snapshot?.row(id: $0)?.paper.pageCount }
        AskCitationRouting.open(QACitations.resolve(first, stored: message.citations, pageCounts: counts),
                                paperIDs: session.paperIDs, state: state)
    }
}

/// The answer streaming in: the phase while waiting, then the text (≤ 30 redraws a second).
struct AskStreamingRow: View {
    let state: AppState
    let session: AskSession
    let streaming: AskSession.Streaming

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !streaming.blocks.isEmpty {
                AnswerBlocksView(blocks: streaming.blocks, multi: session.isMulti) { k in openMarker(k) }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(phaseText)
                TimelineView(.periodic(from: streaming.startedAt, by: 1)) { context in
                    Text(verbatim: Self.elapsed(from: streaming.startedAt, to: context.date)).monospacedDigit()
                }
                .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phaseText: String {
        let ai = AskTexts.ai(state)
        switch streaming.phase {
        case .preparing: return L.QA.preparing
        case .starting: return L.QA.starting(ai)
        case .waiting: return L.QA.reading(ai)
        case .stillWaiting: return L.QA.stillWaiting
        case .streaming: return L.QA.answering(ai)
        }
    }

    static func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func openMarker(_ k: Int) {
        let tokens = QACitations.tokens(in: streaming.text)
        guard tokens.indices.contains(k), let first = tokens[k].citations.first else { return }
        let counts = session.paperIDs.map { state.snapshot?.row(id: $0)?.paper.pageCount }
        AskCitationRouting.open(QACitations.validate(first, pageCounts: counts), paperIDs: session.paperIDs, state: state)
    }
}

/// The line under the composer: what a question sends, on which model, how long, today's count.
struct AskEstimateLine: View {
    let state: AppState
    let session: AskSession

    var body: some View {
        let line = Self.text(estimate: session.estimate, multi: session.isMulti, status: state.assist.status,
                             mode: state.settings.assist.mode)
        VStack(alignment: .leading, spacing: 2) {
            if !line.isEmpty {
                Text(verbatim: line).monospacedDigit()
            }
            Text(state.settings.assist.mode == .mock ? L.QA.mockAssistant : L.QA.usesSubscription(AskTexts.ai(state)))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    /// "≈ 3.2k tokens · all 12 pages · haiku · ~5–15 s · today 4/50".
    static func text(estimate e: QAEstimate?, multi: Bool, status: AssistStatus, mode: AssistMode) -> String {
        var parts: [String] = []
        if let e {
            parts.append(L.QA.estimateTokens(QAEstimator.compact(e.estimatedTokens)))
            if multi {
                parts.append(L.QA.papersCount(e.papers) + " · " + L.QA.modeName(e.mode).lowercased())
            } else if e.mode == .cards {
                parts.append(L.QA.cardsOnly)
            } else if e.pages.isEmpty {
                parts.append(L.QA.noText)
            } else if e.fullText {
                parts.append(L.QA.pagesAll(e.pages.count))
            } else {
                parts.append(L.QA.pagesSome(e.pages.count, e.pages.count + e.omitted))
            }
            if let m = e.model, mode != .off { parts.append(m) }
            if let l = e.latency, mode != .off { parts.append(L.QA.latency(l)) }
        }
        if mode.usesQuota, status.mode == mode { parts.append(L.QA.today(status.todayCount, status.softCap)) }
        return parts.joined(separator: " · ")
    }
}

/// Small tinted banner (privacy, never-AI).
struct AskBanner: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(tint.opacity(0.08))
    }
}

/// Provider names for the Ask strings.
enum AskTexts {
    static func ai(_ state: AppState) -> String { ai(state.settings.assist.mode) }

    static func ai(_ mode: AssistMode) -> String {
        switch mode {
        case .claude: return AIProviderKind.claude.shortName
        case .codex: return AIProviderKind.codex.shortName
        case .mock: return "Mock"
        case .local: return L.lang == .zh ? "本机模型" : "On-device model"
        case .off: return L.ai
        }
    }
}
