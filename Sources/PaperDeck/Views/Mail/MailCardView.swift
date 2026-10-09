import AppKit
import SwiftUI
import PaperDeckCore

/// One email card of the inbox (MAIL_DESIGN Part A §3):
///
///     ● Prof. X <x@example.edu> [Work] · 9/29 14:05   [导师请求] [邮件 DDL ≈10/3] [高]      ⋯
///       papers for Thursday's journal club
///       ✦ Asks you to read two neocortex papers before Thursday's lab meeting…  (wand = local rules)
///       [✦ 让 AI 分析] ⓘ (until the user consents; the selected card shows the full privacy note)
///       ┌ rows (MailItemRow) … 「其余 12 篇」 for alert digests
///       还差 1 篇需要 PDF          [全部合并 (2)]  [忽略]  [稍后 ▾ 明天/下周一/自定义]
///
/// Everything from the email is untrusted text: `Text(verbatim:)`, clipped, no links, no actions.
/// The card is a drop zone too: PDFs dropped on it (not on a row) are matched to its rows.
struct MailCardView: View {
    let state: AppState
    let card: MailCard
    let aiMode: MailSettings.AIMode

    @State private var expanded = false
    @State private var showMergeAll = false
    @State private var showCustomSnooze = false
    @State private var hovering = false

    private var message: MailMessage { card.message }
    private var selected: Bool { state.selectedMailID == card.id }
    private var busy: Bool { state.mailBusy.contains(card.id) }
    private var today: LocalDate { state.snapshot?.today.today ?? LocalDate.today() }
    private var zone: DropTargetRegistry.Target? {
        message.isOpen && card.items.contains(where: { MailInboxRules.actions($0).contains(.acceptsDrop) && $0.status == .pending })
            ? .mailCard(messageID: card.id) : nil
    }
    private var targeted: Bool { zone != nil && state.dropTargets.hovered == zone }

    /// Only the list's other cards get the one-line 「让 AI 分析」 ⓘ; the selected card (like the
    /// inspector) shows the whole explanation with the institution's note (`--selftest app-rules`).
    static func compactConsent(selected: Bool) -> Bool { !selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Text(verbatim: card.displaySubject)
                .font(.system(size: 14.5, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            summary
            // The list keeps 「让 AI 分析」 to one compact line (its privacy note behind ⓘ); the
            // selected card — and the inspector — show the whole explanation.
            MailTriageStatusView(state: state, card: card, aiMode: aiMode, compact: Self.compactConsent(selected: selected))
            rows
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.08),
                          lineWidth: selected ? 2 : 0.75))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 5 : 2, y: 1)
        .mailDropHighlight(targeted, caption: L.Mail.cardDropRelease, cornerRadius: 12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { state.selectedMailID = card.id }
        .onHover { hovering = $0 }
        .contextMenu { cardMenu }
        .dropZone(zone)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: L.Mail.showEmail) { state.selectedMailID = card.id }
    }

    // MARK: Header

    /// Sender, account, time, the request / DDL / priority chips and ⋯ — on one line when they all
    /// fit; else the chips wrap onto a second line (the inspector is open: ~660 pt); in a narrow
    /// column the sender keeps the first line to itself and account, time and chips wrap below.
    /// The sender's name is never squeezed out by the chips.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                senderLine
                MailAccountChip(card: card)
                receivedText
                Spacer(minLength: 6)
                chips
                moreMenu
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    senderLine
                    MailAccountChip(card: card)
                    receivedText
                    Spacer(minLength: 6)
                    moreMenu
                }
                if hasChips {
                    DetailFlowLayout(spacing: 5, lineSpacing: 4) { chipViews }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    senderLine
                    Spacer(minLength: 6)
                    moreMenu
                }
                DetailFlowLayout(spacing: 5, lineSpacing: 4) {
                    MailAccountChip(card: card)
                    receivedText
                    chipViews
                }
            }
        }
    }

    /// Unread dot (a new reading request from a person) + sender name and address.
    private var senderLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if message.state == .pending, !message.userTouched, message.triage?.hasReadingRequest == true,
               message.senderKind == .advisor || message.senderKind == .person {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            MailSenderLine(message: message)
        }
        .layoutPriority(1)
    }

    private var receivedText: some View {
        Text(verbatim: "· " + L.Mail.received(message.receivedAt))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var hasChips: Bool {
        message.authState == .fail || MailInboxRules.requestBadge(message) != nil
            || card.dueHint(today: today) != nil || (message.triage?.priority).map { $0 != .normal } == true
    }

    private var chips: some View {
        HStack(spacing: 5) { chipViews }
            .fixedSize()
    }

    @ViewBuilder private var chipViews: some View {
        if message.authState == .fail {
            MailChip(text: L.Mail.unverifiedSender, symbol: "exclamationmark.shield.fill", hue: 9,
                     help: L.Mail.unverifiedHelp)
        }
        if let badge = MailInboxRules.requestBadge(message) {
            MailRequestBadgeView(badge: badge, advisor: message.senderKind == .advisor)
        }
        if let due = card.dueHint(today: today) {
            MailDueChip(hint: due)
        }
        if let p = message.triage?.priority, p != .normal {
            MailPriorityChip(priority: p)
        }
    }

    private var moreMenu: some View {
        Menu {
            cardMenu
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L.Mail.moreActions)
        .accessibilityLabel(L.Mail.moreActions)
    }

    @ViewBuilder private var cardMenu: some View {
        Button(L.Mail.showEmail) { state.selectedMailID = card.id }
        if MailInboxRules.safeWebURL(message.webLink) != nil {
            Button(L.Mail.openWeb(gmail: card.account?.imapPreset == .gmail)) { state.openMailOnWeb(card) }
        }
        Button(L.Mail.copyLink) { state.copyMailLink(card) }
        if aiMode == .ai, card.canRequestAI, card.displayTriageState != .awaitingConsent {
            Divider()
            Button(message.triageSource == .ai ? L.Mail.analyzeAgain : L.Mail.analyzeWithAI) { state.requestMailAI(card) }
        }
        Divider()
        switch message.state {
        case .pending:
            snoozeButtons
            Button(L.Mail.dismiss) { state.dismissMail(card) }
        case .snoozed:
            Button(L.Mail.unsnooze) { state.reopenMail(card) }
            Button(L.Mail.dismiss) { state.dismissMail(card) }
        case .merged, .dismissed, .noRequest:
            Button(L.Mail.reopen) { state.reopenMail(card) }
            if message.state == .noRequest { Button(L.Mail.dismiss) { state.dismissMail(card) } }
        }
    }

    @ViewBuilder private var snoozeButtons: some View {
        let now = state.engine.ctx.now()
        let calendar = Calendar.current
        Button(L.Mail.later + " · " + L.Mail.snoozeTomorrow) {
            state.snoozeMail(card, until: MailInboxRules.snoozeTomorrow(now: now, calendar: calendar))
        }
        Button(L.Mail.later + " · " + L.Mail.snoozeNextMonday) {
            state.snoozeMail(card, until: MailInboxRules.snoozeNextMonday(now: now, calendar: calendar))
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        let text = MailInboxRules.line(message.triage?.summary ?? message.snippet, limit: 400)
        if !text.isEmpty {
            let ai = message.triageSource == .ai
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ai ? "sparkles" : "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundStyle(ai ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(ai ? L.Mail.summaryAI : L.Mail.summaryHeuristic)
                    .accessibilityLabel(ai ? L.Mail.summaryAI : L.Mail.summaryHeuristic)
                Text(verbatim: text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var rows: some View {
        if card.items.isEmpty {
            Label(L.Mail.noPapers, systemImage: "doc.questionmark")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            let parts = MailInboxRules.partition(card.items, digest: MailInboxRules.isDigest(message))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(parts.shown) { item in
                    MailItemRow(state: state, card: card, item: item)
                }
                if !parts.rest.isEmpty {
                    if expanded {
                        ForEach(parts.rest) { item in
                            MailItemRow(state: state, card: card, item: item)
                        }
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? L.Mail.showFewer : L.Mail.rest(parts.rest.count),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: Footer

    /// The note wraps; the buttons keep their size (never truncated in a narrow column).
    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            footerNote
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            HStack(spacing: 8) { footerButtons }
                .fixedSize()
        }
        .font(.system(size: 12))
    }

    @ViewBuilder private var footerNote: some View {
        switch message.state {
        case .pending:
            let remaining = MailMergeState.remaining(card.items)
            if card.needsPDFCount > 0, remaining > 0 {
                Label(MailMergeState.remainingText(min(remaining, card.needsPDFCount), L.lang), systemImage: "doc.badge.plus")
                    .foregroundStyle(.orange)
            }
        case .snoozed:
            if let until = message.snoozedUntil {
                Label(L.Mail.snoozedUntil(L.Mail.when(until)), systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
            }
        case .merged:
            Label(L.Mail.handledOn(L.Mail.received(message.handledAt ?? message.updatedAt)), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .dismissed:
            Label(L.Mail.dismissedNote, systemImage: "eye.slash").foregroundStyle(.secondary)
        case .noRequest:
            Label(L.Mail.noRequestNote, systemImage: "tray").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        switch message.state {
        case .pending:
            let targets = MailInboxRules.mergeAllItems(card.items)
            if !targets.isEmpty {
                Button(L.Mail.mergeAll(targets.count)) { showMergeAll = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy)
                    .popover(isPresented: $showMergeAll, arrowEdge: .bottom) {
                        MailMergePopover(state: state, card: card, items: targets,
                                         onConfirm: { options in
                                             showMergeAll = false
                                             state.mergeAllMail(card, options: options)
                                         },
                                         onCancel: { showMergeAll = false })
                    }
            }
            Button(L.Mail.dismiss) { state.dismissMail(card) }
                .controlSize(.small)
                .disabled(busy)
            snoozeMenu
        case .snoozed:
            Button(L.Mail.unsnooze) { state.reopenMail(card) }.controlSize(.small).disabled(busy)
            Button(L.Mail.dismiss) { state.dismissMail(card) }.controlSize(.small).disabled(busy)
        case .merged, .dismissed:
            Button(L.Mail.reopen) { state.reopenMail(card) }.controlSize(.small).disabled(busy)
        case .noRequest:
            Button(L.Mail.reopen) { state.reopenMail(card) }.controlSize(.small).disabled(busy)
            Button(L.Mail.dismiss) { state.dismissMail(card) }.controlSize(.small).disabled(busy)
        }
    }

    private var snoozeMenu: some View {
        Menu(L.Mail.later) {
            snoozeButtonsShort
            Divider()
            Button(L.Mail.snoozeCustom) { showCustomSnooze = true }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(busy)
        .popover(isPresented: $showCustomSnooze, arrowEdge: .bottom) {
            MailSnoozePicker(now: state.engine.ctx.now()) { date in
                showCustomSnooze = false
                if let date { state.snoozeMail(card, until: date) }
            }
        }
    }

    @ViewBuilder private var snoozeButtonsShort: some View {
        let now = state.engine.ctx.now()
        let calendar = Calendar.current
        let tomorrow = MailInboxRules.snoozeTomorrow(now: now, calendar: calendar)
        let monday = MailInboxRules.snoozeNextMonday(now: now, calendar: calendar)
        Button(L.Mail.snoozeTomorrow + " · " + L.Mail.when(tomorrow, now: now)) { state.snoozeMail(card, until: tomorrow) }
        Button(L.Mail.snoozeNextMonday + " · " + L.Mail.when(monday, now: now)) { state.snoozeMail(card, until: monday) }
    }
}

// MARK: - Triage state

/// What the AI triage is doing for this card: 「让 AI 分析」 with the privacy note (person senders
/// until they consent), a spinner while queued / running, or the held / limited / needs-login /
/// failed note (`triageError` is already worded in the UI language).
///
/// `compact` (the inbox list, every card but the selected one): 「让 AI 分析」 is one small button
/// plus ⓘ — the question and the privacy note (the institution's guidance) are its tooltip and
/// popover — instead of the explanation box on every card.
struct MailTriageStatusView: View {
    let state: AppState
    let card: MailCard
    let aiMode: MailSettings.AIMode
    var compact = false
    @State private var showInfo = false

    var body: some View {
        let m = card.message
        let requested = state.mailAIRequested.contains(card.id)
        let ai = aiMode == .ai
        Group {
            if requested || (ai && card.displayTriageState == .queued) {
                progress(L.Mail.triageQueuedOne)
            } else if ai && card.displayTriageState == .running {
                progress(L.Mail.triageRunning)
            } else if !card.message.isOpen {
                EmptyView()
            } else if card.displayTriageState == .awaitingConsent {
                if ai && card.canRequestAI {
                    if compact { compactConsent } else { consent }
                } else {
                    EmptyView()
                }
            } else if ai {
                switch card.displayTriageState {
                case .held:
                    note(m.triageError ?? L.Mail.triageHeld, symbol: "pause.circle", tint: .secondary,
                         action: card.canRequestAI ? (L.Mail.analyzeWithAI, { state.requestMailAI(card) }) : nil)
                case .limited:
                    note(m.triageError ?? L.Mail.triageLimited, symbol: "hourglass", tint: .orange, action: nil)
                case .needsLogin:
                    note(m.triageError ?? L.Mail.triageNeedsLogin, symbol: "person.crop.circle.badge.exclamationmark",
                         tint: .orange, action: (L.Mail.openAISettings, { state.router.showSettings("ai") }))
                case .failed:
                    note(m.triageError ?? L.Mail.triageFailed, symbol: "exclamationmark.triangle", tint: .orange,
                         action: card.canRequestAI ? (L.retry, { state.requestMailAI(card) }) : nil)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var consent: some View {
        let provider = card.triageProviderName(state)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    state.requestMailAI(card)
                } label: {
                    Label(L.Mail.analyzeWithAI, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(state.mailBusy.contains(card.id))
                Text(L.Mail.consentTitle(provider))
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(L.Mail.consentNote(provider), systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.75))
    }

    /// One line: [✦ 让 AI 分析] ⓘ. The button's tooltip asks the question; ⓘ shows the privacy note
    /// (hover: tooltip; click: popover).
    private var compactConsent: some View {
        let provider = card.triageProviderName(state)
        let title = L.Mail.consentTitle(provider)
        let note = L.Mail.consentNote(provider)
        return HStack(spacing: 6) {
            Button {
                state.requestMailAI(card)
            } label: {
                Label(L.Mail.analyzeWithAI, systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .controlSize(.small)
            .disabled(state.mailBusy.contains(card.id))
            .help(title)
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(title + "\n" + note)
            .accessibilityLabel(L.Mail.consentInfo)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label(note, systemImage: "lock.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(width: 320, alignment: .leading)
            }
        }
    }

    private func note(_ text: String, symbol: String, tint: Color, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 8) {
            Label { Text(verbatim: MailInboxRules.line(text, limit: 240)) } icon: { Image(systemName: symbol) }
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Custom snooze

/// 「稍后 ▾ 自定义…」: date + time, in the future only.
struct MailSnoozePicker: View {
    let now: Date
    let onDone: (Date?) -> Void
    @State private var date: Date

    init(now: Date, onDone: @escaping (Date?) -> Void) {
        self.now = now
        self.onDone = onDone
        _date = State(initialValue: MailInboxRules.snoozeTomorrow(now: now, calendar: .current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Mail.snoozeTitle).font(.headline)
            DatePicker(L.Mail.snoozeTitle, selection: $date, in: now.addingTimeInterval(60)...,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L.Mail.snoozeConfirm) { onDone(date) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!MailInboxRules.validSnooze(date, now: Date()))
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
