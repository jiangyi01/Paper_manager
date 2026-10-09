import AppKit
import PaperDeckCore

/// 「有新的阅读请求时通知我」 (Settings ▸ Mail ▸ Merge & reminders, off by default): one local
/// notification per newly captured email card that is a reading request from a person —
/// title 「新的论文阅读请求」, body = sender display name + subject (≤ 80 characters). Never body
/// text, never an address. A click opens `paperdeck://mail/<id>` (ReminderService routes it).
///
/// Fed by every inbox snapshot (`AppState.onMailSnapshot`; renders and the CLI never install it).
/// The 11:00 reminder's mail line is separate and unchanged.
///
/// Privacy: logs carry counts only.
final class MailRequestNotifier {
    private let state: AppState
    private let reminders: ReminderService
    /// Cards decided this launch (announced, or not eligible): later snapshots skip them.
    private var decided: Set<String> = []

    init(state: AppState, reminders: ReminderService) {
        self.state = state
        self.reminders = reminders
    }

    func start() {
        state.onMailSnapshot = { [weak self] snap in self?.consider(snap) }
        if let snap = state.mailSnapshot { consider(snap) }
    }

    func stop() {
        state.onMailSnapshot = nil
    }

    private func consider(_ snap: MailSnapshot) {
        let settings = state.settings
        var book = settings.mailNotifyBook
        let configs = Dictionary(settings.mailAccounts.map { ($0.id, MailRequestNotifyRules.fingerprint($0)) },
                                 uniquingKeysWith: { a, _ in a })
        let notes = MailRequestNotifyRules.evaluate(cards: snap.cards(.pending), accounts: snap.accounts, configs: configs,
                                                    enabled: settings.mailNotifyNewRequests,
                                                    book: &book, decided: &decided, now: Date())
        if book != settings.mailNotifyBook { settings.mailNotifyBook = book }
        guard !notes.isEmpty else { return }
        Log.app.info("mail: announcing \(notes.count, privacy: .public) new reading request(s)")
        let reminders = self.reminders
        for card in notes {
            let note = MailRequestNotifyRules.content(card)
            Task {
                await reminders.postNotice(id: note.id, title: note.title, body: note.body, url: note.url,
                                           thread: MailRequestNotifyRules.threadIdentifier)
            }
        }
    }
}

/// Which cards 「有新的阅读请求时通知我」 announces, and with what text (kept apart from the
/// notifier so `--selftest mail-notify` checks the exact rules offline).
enum MailRequestNotifyRules {
    /// Persisted in the app's defaults (`SettingsStore.mailNotifyBook`).
    struct Book: Equatable {
        /// When the switch went on: cards captured earlier are never announced.
        var since: Date?
        /// `<account id>|<fingerprint>` → when its first successful sync was seen. Until then (the
        /// first backfill of a newly added account) nothing of that account is announced; afterwards
        /// only emails received later. A changed folder / server / mailbox starts over (its own
        /// backfill is silent too).
        var armed: [String: Date]
        /// Message ids already announced (newest last, at most `maxSent`).
        var sent: [String]
    }

    struct Note: Equatable {
        var id: String
        var title: String
        var body: String
        var url: URL
    }

    static let idPrefix = "mail-request-"
    static let threadIdentifier = "mail"
    static let maxSent = 300
    static let subjectLimit = 80
    /// A card captured longer ago than this is not "new" any more (relaunch after days away).
    static let maxAge: TimeInterval = 3 * 86_400

    /// What makes an account "the same" for arming: where its mail comes from.
    static func fingerprint(_ a: MailAccount) -> String {
        switch a.kind {
        case .folder: return "folder:" + (a.folderPath ?? "")
        case .imap: return "imap:" + [a.host ?? "", a.port.map(String.init) ?? "", a.username ?? "", a.mailbox ?? ""].joined(separator: ":")
        }
    }

    /// Arms accounts once a successful sync is seen (at `now`: whatever that sync captured is older),
    /// then returns the pending cards to announce now (and records them in `book.sent`). Cards whose
    /// AI triage is still queued or running are decided later; everything else is decided once per
    /// launch (`decided`). `configs`: account id → `fingerprint` of Settings ▸ Mail's accounts.
    static func evaluate(cards: [MailCard], accounts: [MailAccountSyncInfo], configs: [String: String], enabled: Bool,
                         book: inout Book, decided: inout Set<String>, now: Date) -> [MailCard] {
        func key(_ id: String) -> String? { configs[id].map { id + "|" + $0 } }
        for info in accounts where info.lastSuccessAt != nil {
            if let k = key(info.id), book.armed[k] == nil { book.armed[k] = now }
        }
        let current = Set(configs.keys.compactMap(key))
        book.armed = book.armed.filter { current.contains($0.key) }
        guard enabled else { return [] }
        if book.since == nil { book.since = now }
        let since = book.since ?? now
        var out: [MailCard] = []
        for card in cards where !decided.contains(card.id) {
            let m = card.message
            guard m.createdAt > since, now.timeIntervalSince(m.createdAt) < maxAge,
                  m.accountID != MailSyncActor.manualAccountID,          // a dropped .eml is the user's own action
                  let armed = key(m.accountID).flatMap({ book.armed[$0] }),
                  m.createdAt > armed, m.receivedAt > armed,              // not the account's first backfill
                  m.state == .pending, !m.userTouched else {
                decided.insert(card.id)
                continue
            }
            guard isSettled(card) else { continue }
            decided.insert(card.id)
            guard isRequest(m), !book.sent.contains(m.id) else { continue }
            out.append(card)
            book.sent.append(m.id)
        }
        if book.sent.count > maxSent { book.sent.removeFirst(book.sent.count - maxSent) }
        return out
    }

    /// A reading request from a person (advisor / colleague) — the menu bar's 「N 封请求」 rule.
    static func isRequest(_ m: MailMessage) -> Bool {
        (m.senderKind == .advisor || m.senderKind == .person) && m.triage?.hasReadingRequest == true
    }

    /// The AI triage has finished or won't run now (local rules decided, awaiting consent, held…).
    static func isSettled(_ card: MailCard) -> Bool {
        card.displayTriageState != .queued && card.displayTriageState != .running
    }

    /// Display name (or the sender rule's label) — never an address; subject ≤ 80 characters.
    static func content(_ card: MailCard) -> Note {
        let m = card.message
        var name = MailInboxRules.line(m.fromName, limit: 60)
        if name.isEmpty || name.contains("@") { name = MailInboxRules.line(card.rule?.label, limit: 60) }
        if name.contains("@") { name = "" }
        let subject = MailInboxRules.line(m.subject, limit: subjectLimit)
        return Note(id: idPrefix + m.id, title: L.Mail.notifyTitle,
                    body: L.Mail.notifyBody(name: name, subject: subject.isEmpty ? L.Mail.noSubject : subject),
                    url: DeepLink.mail(id: m.id).url)
    }
}
