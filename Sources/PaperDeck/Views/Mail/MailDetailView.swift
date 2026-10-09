import AppKit
import SwiftUI
import PaperDeckCore

/// The inspector for a selected email card (MAIL_DESIGN Part A §3): subject, sender, account and
/// time, the summary with the due-date evidence, every paper row, the full sanitized body
/// (plain text; `[cN]` markers stand for the links), 「发送给 AI 的内容」 and 「在 Gmail 中打开」 /
/// 「在网页版中打开」 when the transport knows a web link. All mail text is untrusted and inert.
///
/// The card's state comes from the list snapshot (refreshed every few seconds while a triage
/// runs); its text only from the full card (`MailFullCard.follow` → `Engine.mailCard(id:)`),
/// loaded when the card is selected and again whenever that email changes. Cards the snapshot
/// doesn't hold (older ones, fresh deep links) are shown from the full card alone.
struct MailDetailView: View {
    let state: AppState
    let id: String
    /// Renders only: never load the full card (shows the body placeholder).
    var loadsFullCard = true

    /// `Engine.mailCard(id:)` of the selected email: the only copy with its text.
    @State private var full: MailCard?
    /// Id of the last completed load (nil while the first load of `id` runs).
    @State private var loadedID: String?

    private var key: String { id.lowercased() }
    private var listCard: MailCard? { state.mailSnapshot?.card(id: id) }
    private var fullCard: MailCard? { full?.id == key ? full : nil }
    private var card: MailCard? { listCard ?? fullCard }

    var body: some View {
        Group {
            if let card {
                MailDetailContent(state: state, card: card, full: fullCard, aiMode: state.mailSnapshot?.aiMode ?? .ai)
                    .id(card.id)
            } else if loadsFullCard, loadedID != key {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(L.Mail.detailEmptyTitle, systemImage: "envelope.open")
                } description: {
                    Text(L.Mail.detailEmptyHint)
                }
            }
        }
        .task(id: key) {
            full = nil
            loadedID = nil
            guard loadsFullCard else { return }
            let engine = state.engine
            let wanted = key
            await MailFullCard.follow(id: wanted, changes: engine.changes.subscribe(),
                                      load: { try? await engine.mailCard(id: $0) },
                                      deliver: { loaded in
                                          full = loaded
                                          loadedID = wanted
                                      })
        }
    }
}

private struct MailDetailContent: View {
    let state: AppState
    let card: MailCard
    /// The same email from `Engine.mailCard(id:)` (with its text), nil until loaded.
    let full: MailCard?
    let aiMode: MailSettings.AIMode

    private var m: MailMessage { card.message }
    private var today: LocalDate { state.snapshot?.today.today ?? LocalDate.today() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                MailTriageStatusView(state: state, card: card, aiMode: aiMode, compact: false)     // the full note, always
                papers
                bodySection
                section(L.Mail.sentTitle, symbol: "paperplane") {
                    // The full card when loaded: the preview starts over whenever it is reloaded.
                    MailSentPreview(state: state, card: full ?? card, aiMode: aiMode)
                }
                facts
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.displaySubject)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            MailSenderLine(message: m)
            DetailFlowLayout(spacing: 6, lineSpacing: 5) {
                MailAccountChip(card: card)
                Text(verbatim: L.Mail.received(m.receivedAt)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if m.authState == .fail {
                    MailChip(text: L.Mail.unverifiedSender, symbol: "exclamationmark.shield.fill", hue: 9, help: L.Mail.unverifiedHelp)
                }
                if let badge = MailInboxRules.requestBadge(m) {
                    MailRequestBadgeView(badge: badge, advisor: m.senderKind == .advisor)
                }
                if let due = card.dueHint(today: today) { MailDueChip(hint: due) }
                if let p = m.triage?.priority { MailPriorityChip(priority: p) }
            }
            HStack(spacing: 10) {
                if MailInboxRules.safeWebURL(m.webLink) != nil {
                    Button {
                        state.openMailOnWeb(card)
                    } label: {
                        Label(L.Mail.openWeb(gmail: card.account?.imapPreset == .gmail), systemImage: "safari")
                    }
                    .controlSize(.small)
                }
                Button {
                    state.copyMailLink(card)
                } label: {
                    Label(L.Mail.copyLink, systemImage: "link")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let text = MailInboxRules.line(m.triage?.summary ?? m.snippet, limit: 400)
        if !text.isEmpty || m.triage?.requester != nil || m.triage?.dueEvidence != nil {
            VStack(alignment: .leading, spacing: 5) {
                if !text.isEmpty {
                    let ai = m.triageSource == .ai
                    Label {
                        Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: ai ? "sparkles" : "wand.and.stars")
                            .foregroundStyle(ai ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .font(.system(size: 12.5))
                    .help(ai ? L.Mail.summaryAI : L.Mail.summaryHeuristic)
                }
                if let who = m.triage?.requester.map({ MailInboxRules.line($0, limit: 80) }), !who.isEmpty {
                    Text(verbatim: L.Mail.requester(who)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if let evidence = card.dueHint(today: today)?.evidence {
                    Text(verbatim: L.Mail.evidence(evidence)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Papers

    private var papers: some View {
        section(L.Mail.papersSection(card.items.count), symbol: "doc.on.doc") {
            if card.items.isEmpty {
                Text(L.Mail.noPapers).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.items) { item in
                        MailItemRow(state: state, card: card, item: item, layout: .stacked)
                    }
                    if card.needsPDFCount > 0, m.isOpen {
                        Text(MailMergeState.remainingText(card.needsPDFCount, L.lang))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: Body

    private var bodySection: some View {
        section(L.Mail.bodyTitle, symbol: "text.alignleft") {
            switch MailBodyDisplay.resolve(list: card.message, full: full?.message) {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L.Mail.bodyLoading).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .purged:
                Text(L.Mail.bodyPurged).font(.system(size: 12)).foregroundStyle(.secondary)
            case .text(let body):
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: body)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if body.range(of: #"\[c\d+"#, options: .regularExpression) != nil {
                        Text(L.Mail.bodyMarkers).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            case .empty:
                Text(L.Mail.bodyEmpty).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Facts

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            fact(L.Mail.from, MailInboxRules.line(m.fromAddress, limit: 120))
            fact(L.Mail.account, MailAccountChip.name(card))
            fact(L.Mail.received, DetailFormat.dayAndTime(m.receivedAt))
            fact(L.Mail.senderRule, card.rule.map { rule in
                let label = MailInboxRules.line(rule.label, limit: 60)
                return label.isEmpty ? rule.pattern : "\(label) (\(rule.pattern))"
            } ?? L.Mail.noRule)
            fact(L.Mail.triageSection, m.triageSource == .ai ? L.Mail.triageByAI : L.Mail.triageByRules)
        }
        .font(.system(size: 11.5))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled).lineLimit(2)
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
