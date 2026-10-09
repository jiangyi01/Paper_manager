import Foundation
import PaperDeckCore

/// `--selftest mail-notify [--lang en|zh]`: the rules of 「有新的阅读请求时通知我」
/// (`MailRequestNotifyRules`) on synthetic cards — which cards are announced (new account's first
/// backfill, switch-on time, duplicates, triage still running, manual drops, non-requests) and the
/// exact title / body / link. Offline: no engine, no library, nothing posted, nothing stored.
enum SelfTestMailNotify {
    static func run(_ args: CLIArgs) -> Int32 {
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let previous = LangStore.shared.lang
        LangStore.shared.lang = lang
        defer { LangStore.shared.lang = previous }

        let now = Date()
        var ok = true
        func check(_ name: String, _ pass: Bool, _ extra: [String: Any?] = [:]) {
            var line: [String: Any?] = ["check": name, "ok": pass]
            line.merge(extra) { a, _ in a }
            CLIRunner.line(line)
            if !pass { ok = false }
        }
        let advisor = SenderRule(id: "r-advisor", pattern: "jsmith@example.edu", label: "Prof. Jane Smith", kind: .advisor)
        func card(_ n: Int, account: String = "acct", kind: SenderKind = .advisor, request: Bool = true,
                  created: TimeInterval, received: TimeInterval, triage: MailTriageState = .awaitingConsent,
                  state: MailState = .pending, touched: Bool = false, fromName: String? = "Smith, Jane",
                  subject: String = "Paper for Friday's meeting") -> MailCard {
            let m = MailMessage(pk: Int64(n), id: String(format: "00000000-0000-4000-8000-%012d", n), accountID: account,
                                internetMessageID: "<\(n)@example.org>", fromAddress: "jsmith@example.edu", fromName: fromName,
                                ruleID: advisor.id, senderKind: kind, subject: subject,
                                receivedAt: now.addingTimeInterval(received), state: state, userTouched: touched,
                                triageState: triage, triageSource: .heuristic,
                                triage: MailTriage(hasReadingRequest: request, requestKind: request ? .advisorRequest : .fyi,
                                                   summary: "Read the attached paper."),
                                createdAt: now.addingTimeInterval(created))
            return MailCard(message: m, items: [], rule: advisor, account: nil)
        }
        func info(_ id: String = "acct", lastSuccess: TimeInterval?) -> MailAccountSyncInfo {
            MailAccountSyncInfo(id: id, displayName: "Work (Power Automate)", kind: .folder, enabled: true,
                                lastSuccessAt: lastSuccess.map { now.addingTimeInterval($0) })
        }
        func ids(_ cards: [MailCard]) -> [Int] { cards.map { Int($0.message.pk) } }

        // Times are relative to `now`; the account's first sync ends at -600 s and is seen at -590 s.
        let folder = MailAccount(id: "acct", kind: .folder, displayName: "Work (Power Automate)",
                                 folderPath: "/tmp/OneDrive-Test/PaperDeck Mail")
        var configs = ["acct": MailRequestNotifyRules.fingerprint(folder)]
        let key = "acct|" + MailRequestNotifyRules.fingerprint(folder)
        var book = MailRequestNotifyRules.Book(since: now.addingTimeInterval(-86_400), armed: [:], sent: [])
        var decided = Set<String>()
        func evaluate(_ cards: [MailCard], _ infos: [MailAccountSyncInfo], at t: TimeInterval = 0,
                      enabled: Bool = true, book b: inout MailRequestNotifyRules.Book,
                      decided d: inout Set<String>) -> [MailCard] {
            MailRequestNotifyRules.evaluate(cards: cards, accounts: infos, configs: configs, enabled: enabled,
                                            book: &b, decided: &d, now: now.addingTimeInterval(t))
        }

        // 1. A newly added account syncing for the first time: its backfill is never announced.
        let backfill = [card(1, created: -700, received: -5 * 86_400), card(12, created: -650, received: -660)]
        var out = evaluate(backfill, [info(lastSuccess: nil)], at: -640, book: &book, decided: &decided)
        check("first backfill is silent", out.isEmpty && book.armed.isEmpty, ["announced": ids(out)])

        // 2. The first successful sync is seen: armed then. Older mail (a backfill continuing) stays
        //    silent; a request received afterwards rings.
        out = evaluate(backfill, [info(lastSuccess: -600)], at: -590, book: &book, decided: &decided)
        check("armed after first sync", out.isEmpty && book.armed[key] != nil)
        let later = backfill + [card(2, created: -10, received: -60), card(3, created: -5, received: -3 * 86_400)]
        out = evaluate(later, [info(lastSuccess: -300)], book: &book, decided: &decided)
        check("only the new request", ids(out) == [2], ["announced": ids(out)])

        // 3. Relaunch (fresh `decided`): what was announced is not announced again.
        var relaunch = Set<String>()
        out = evaluate(later, [info(lastSuccess: nil)], book: &book, decided: &relaunch)
        check("no duplicate after relaunch", out.isEmpty, ["announced": ids(out)])

        // 4. AI triage still queued → decided later, announced once it settles.
        out = evaluate([card(4, created: -4, received: -40, triage: .queued)], [info(lastSuccess: -300)],
                       book: &book, decided: &decided)
        check("waits for running triage", out.isEmpty && !decided.contains(card(4, created: 0, received: 0).id))
        out = evaluate([card(4, created: -4, received: -40, triage: .done)], [info(lastSuccess: -300)],
                       book: &book, decided: &decided)
        check("announced after triage", ids(out) == [4], ["announced": ids(out)])

        // 5. Not announced: no request, an alert, a dropped .eml, a card the user already touched,
        //    one captured before the switch went on, and anything while the switch is off.
        let quiet = [card(5, request: false, created: -3, received: -30),
                     card(6, kind: .alert, created: -3, received: -30),
                     card(7, account: MailSyncActor.manualAccountID, created: -3, received: -30),
                     card(8, created: -3, received: -30, touched: true)]
        out = evaluate(quiet, [info(lastSuccess: -300)], book: &book, decided: &decided)
        check("non-requests stay silent", out.isEmpty, ["announced": ids(out)])
        var offBook = MailRequestNotifyRules.Book(since: nil, armed: [key: now.addingTimeInterval(-600)], sent: [])
        var offDecided = Set<String>()
        out = evaluate([card(9, created: -3, received: -30)], [info(lastSuccess: -300)], enabled: false,
                       book: &offBook, decided: &offDecided)
        check("switch off is silent", out.isEmpty && offBook.since == nil)
        var lateBook = MailRequestNotifyRules.Book(since: now.addingTimeInterval(-1), armed: [key: now.addingTimeInterval(-600)], sent: [])
        out = evaluate([card(10, created: -3, received: -30)], [info(lastSuccess: -300)], book: &lateBook, decided: &offDecided)
        check("captured before switch-on is silent", out.isEmpty)

        // 6. A changed folder starts over: its backfill (older mail) is silent; removed accounts are forgotten.
        var moved = folder
        moved.folderPath = "/tmp/OneDrive-Test/Other Mail"
        configs["acct"] = MailRequestNotifyRules.fingerprint(moved)
        var movedDecided = Set<String>()
        out = evaluate([card(13, created: 5, received: -3600)], [info(lastSuccess: -300)], at: 10,
                       book: &book, decided: &movedDecided)
        check("changed folder re-arms", out.isEmpty && book.armed[key] == nil && book.armed.count == 1, ["announced": ids(out)])
        configs = ["other": MailRequestNotifyRules.fingerprint(folder)]
        _ = evaluate([], [info("other", lastSuccess: -60)], book: &book, decided: &decided)
        check("removed account forgotten", book.armed.keys.allSatisfy { $0.hasPrefix("other|") } && book.armed.count == 1)

        // 7. Text: display name + subject (≤ 80 characters), never an address; the link selects the card.
        let note = MailRequestNotifyRules.content(card(2, created: 0, received: 0))
        check("title", note.title == (lang == .zh ? "新的论文阅读请求" : "New reading request"), ["title": note.title])
        check("body", note.body == "Smith, Jane — Paper for Friday's meeting", ["body": note.body])
        check("link", note.url.absoluteString == "paperdeck://mail/00000000-0000-4000-8000-000000000002"
              && note.id == "mail-request-00000000-0000-4000-8000-000000000002", ["url": note.url.absoluteString])
        let long = MailRequestNotifyRules.content(card(11, created: 0, received: 0, fromName: "jsmith@example.edu",
                                                       subject: String(repeating: "Spatial transcriptomics ", count: 8)))
        let subject = long.body.components(separatedBy: " — ").last ?? ""
        check("address never shown", !long.body.contains("@") && long.body.hasPrefix("Prof. Jane Smith — "), ["body": long.body])
        check("subject capped", subject.count <= MailRequestNotifyRules.subjectLimit, ["chars": subject.count])

        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok ? 0 : 1
    }
}
