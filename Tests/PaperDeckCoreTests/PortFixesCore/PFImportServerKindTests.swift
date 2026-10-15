import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Settings import, lane 2 (hunt findings):
/// - mail-ai-privacy-2: an IMAP account the file keeps under this Mac's id (or mailbox) but points
///   at another server (host, port or address) used to keep the id — so the app password saved
///   here (`<id>.imap`) was sent to the file's server. It now keeps this Mac's server ("Kept
///   stricter", `ImportEntryField.server`); accepted, it takes the file's server under a new id,
///   so the old keychain item is never read for it.
/// - mail-ai-privacy-4: an import silently turned a person's / advisor's sender into an alert
///   (same id, same pattern, or a new more specific alert rule) — `ImportEntryField.kind`.
/// - portability-cli-11: re-importing this Mac's own backup warned that every IMAP account needs
///   its app password again, although the keychain item is found again.
/// Pure: synthetic domains and an in-memory secret store (never the keychain).
@Suite struct PFImportServerKindTests {
    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func bundle(senders: [SenderRule] = [], accounts: [MailAccount] = [], addresses: Bool) -> SettingsBundle {
        var d: [String: Any] = [:]
        if !senders.isEmpty { d[MailSettings.Keys.senders] = MailSettings.encode(senders) }
        if !accounts.isEmpty { d[MailSettings.Keys.accounts] = MailSettings.encode(accounts) }
        return SettingsExporter.export(PersistedDomain(d), sections: Set(SettingsSection.allCases), includePersonal: false,
                                       includeAddresses: addresses, home: home, roots: [], app: "PaperDeck 1.0 (27)", now: now)
    }

    static func plan(_ b: SettingsBundle, accounts: [MailAccount] = [], senders: [SenderRule] = [],
                     accept: LooserAcceptance = .none) -> ImportPlan {
        var d: [String: Any] = [:]
        if !accounts.isEmpty { d[MailSettings.Keys.accounts] = MailSettings.encode(accounts) }
        if !senders.isEmpty { d[MailSettings.Keys.senders] = MailSettings.encode(senders) }
        return SettingsImporter.plan(b, current: PersistedDomain(d), sections: Set(SettingsSection.allCases),
                                     keepPeopleAlways: false, acceptReaderDescription: false, acceptLooser: accept,
                                     home: home, roots: [])
    }

    static func written(_ p: ImportPlan) -> [MailAccount] {
        MailSettings.list(p.writes[MailSettings.Keys.accounts]?.stringValue, MailAccount.self, what: "a")
    }

    static func writtenSenders(_ p: ImportPlan) -> [SenderRule] {
        MailSettings.list(p.writes[MailSettings.Keys.senders]?.stringValue, SenderRule.self, what: "s")
    }

    static func appPasswordWarnings(_ p: ImportPlan) -> [String] {
        p.warnings.compactMap { if case .needsAppPassword(let a) = $0 { a } else { nil } }
    }

    /// This Mac's Gmail account; its app password is saved as "acct-x.imap".
    static let gmail = MailAccount(id: "acct-x", kind: .imap, displayName: "Gmail — me@example.com", imapPreset: .gmail,
                                   host: "imap.gmail.com", port: 993, username: "me@example.com", mailbox: "PaperDeck",
                                   source: "imap.gmail")
    /// The file's copy of the same account (same id), pointed at another server.
    static var elsewhere: MailAccount {
        var a = gmail
        a.displayName = "Mail — me@example.com"
        a.imapPreset = .custom
        a.host = "imap.other.example"
        a.mailbox = "INBOX"
        a.source = "imap.custom"
        a.lookbackDays = 7
        return a
    }

    // MARK: mail-ai-privacy-2 — the saved app password never goes to another server

    @Test func anAccountPointedAtAnotherServerKeepsThisMacsServer() async throws {
        let secrets = InMemoryMailSecretStore([Self.gmail.secretKey: "app-password-for-gmail"])
        // A default export leaves the address in; one without addresses has none — both are caught.
        for addresses in [true, false] {
            let p = Self.plan(Self.bundle(accounts: [Self.elsewhere], addresses: addresses), accounts: [Self.gmail])
            let merged = try #require(Self.written(p).first)
            #expect(Self.written(p).count == 1)
            // This Mac's server, address, mailbox and name stay; the file's other values import.
            #expect(merged.id == "acct-x" && merged.host == "imap.gmail.com" && merged.port == 993
                    && merged.imapPreset == .gmail && merged.username == "me@example.com" && merged.mailbox == "PaperDeck"
                    && merged.source == "imap.gmail" && merged.displayName == Self.gmail.displayName && merged.lookbackDays == 7)
            #expect(MailAccount.mayReuseSavedPassword(original: Self.gmail, edited: merged))
            #expect(await secrets.secret(for: merged.secretKey) == "app-password-for-gmail")
            // Listed as kept stricter, worded with both servers.
            let item = try #require(p.keptStricter.first { $0.id == ImportLoosening.accountID("acct-x", .server) })
            // (Without addresses, the file's account name has its address left out too.)
            #expect(item.field == .server && item.key == MailSettings.Keys.accounts
                    && item.subject == (addresses ? "Mail — me@example.com" : "Mail"))
            #expect(item.mine == .string("me@example.com · imap.gmail.com:993"))
            #expect(item.theirs == .string("me@example.com · imap.other.example:993"))
            // The password saved here still fits this server: no "needs its app password" warning.
            #expect(Self.appPasswordWarnings(p).isEmpty, "\(p.warnings)")
        }
    }

    @Test func acceptingTheServerGivesTheAccountANewIDSoTheOldPasswordIsNeverRead() async throws {
        let secrets = InMemoryMailSecretStore([Self.gmail.secretKey: "app-password-for-gmail"])
        let id = ImportLoosening.accountID("acct-x", .server)
        let p = Self.plan(Self.bundle(accounts: [Self.elsewhere], addresses: false), accounts: [Self.gmail],
                          accept: .only([id]))
        let merged = try #require(Self.written(p).first)
        #expect(Self.written(p).count == 1)
        #expect(merged.host == "imap.other.example" && merged.imapPreset == .custom && merged.mailbox == "INBOX")
        #expect(merged.id == SettingsImporter.movedAccountID("acct-x") && merged.id != "acct-x")
        #expect(merged.username == "me@example.com")          // the address this Mac had, as for any merged account
        // The keychain item of the old server is never found under the new id.
        #expect(await secrets.secret(for: merged.secretKey) == nil)
        #expect(!MailAccount.mayReuseSavedPassword(original: Self.gmail, edited: merged))
        // … so the warning is now true, and the sheet sees a replacement, not a removal.
        #expect(Self.appPasswordWarnings(p) == ["Mail"])
        #expect(p.loosenings.first { $0.id == id }?.accepted == true)
        let merge = try #require(p.merges[MailSettings.Keys.accounts])
        #expect(merge.newIDs == ["acct-x": merged.id] && merge.replaced == ["Mail"] && merge.kept.isEmpty)
        // --accept-looser does the same.
        #expect(Self.written(Self.plan(Self.bundle(accounts: [Self.elsewhere], addresses: false), accounts: [Self.gmail],
                                       accept: .all)).first?.id == merged.id)
    }

    @Test func importingTheSameFileAgainFindsTheMovedAccount() async throws {
        let file = Self.bundle(accounts: [Self.elsewhere], addresses: false)
        let first = Self.written(Self.plan(file, accounts: [Self.gmail], accept: .all))
        let moved = try #require(first.first)
        // The old id isn't added back (its keychain item, the old server's password, would be read
        // for the file's server): the file's account is the moved one.
        let again = Self.plan(file, accounts: first)
        let written = Self.written(again)
        #expect(again.writes[MailSettings.Keys.accounts] == nil || written.map(\.id) == [moved.id], "\(written.map(\.id))")
        #expect(!written.contains { $0.id == "acct-x" })
        #expect(again.loosenings.isEmpty && Self.appPasswordWarnings(again).isEmpty)
        // An older file that still has the first server: this Mac's (moved) server stays unless accepted.
        let older = Self.plan(Self.bundle(accounts: [Self.gmail], addresses: true), accounts: first)
        // (Everything else of that account is kept stricter or the same: nothing to write.)
        #expect(older.writes[MailSettings.Keys.accounts] == nil, "\(Self.written(older))")
        let olderMerged = SettingsImporter.mergeAccounts(current: first, imported: [Self.gmail])
        #expect(olderMerged.accounts.map(\.id) == [moved.id] && olderMerged.accounts.first?.host == "imap.other.example")
        #expect(older.keptStricter.map(\.id).contains(ImportLoosening.accountID(moved.id, .server)), "\(older.keptStricter.map(\.id))")
        let secrets = InMemoryMailSecretStore([Self.gmail.secretKey: "app-password-for-gmail"])
        let back = try #require(Self.written(Self.plan(Self.bundle(accounts: [Self.gmail], addresses: true),
                                                         accounts: first, accept: .all)).first)
        #expect(back.host == "imap.gmail.com" && back.id != "acct-x" && back.id != moved.id)
        #expect(await secrets.secret(for: back.secretKey) == nil)
    }

    @Test func aChangedPortOrAddressIsAnotherServerTooButSpellingIsNot() {
        func items(_ edit: (inout MailAccount) -> Void) -> [String] {
            var a = Self.gmail
            edit(&a)
            return SettingsImporter.mergeAccounts(current: [Self.gmail], imported: [a]).loosened.map(\.id)
        }
        let server = [ImportLoosening.accountID("acct-x", .server)]
        #expect(items { $0.port = 143 } == server)
        #expect(items { $0.username = "someone.else@example.com" } == server)
        #expect(items { $0.host = "imap.gmai1.com" } == server)
        #expect(items { $0.host = "  IMAP.Gmail.com. "; $0.username = "Me@Example.com" }.isEmpty)
        #expect(items { $0.host = nil }.isEmpty)                         // the preset's host
        #expect(items { $0.displayName = "Mine"; $0.mailbox = "INBOX" }.isEmpty)
        // The same mailbox under another id (matched by host and address) on another port: guarded.
        var otherID = Self.gmail
        otherID.id = "old-mac-id"
        otherID.port = 143
        let m = SettingsImporter.mergeAccounts(current: [Self.gmail], imported: [otherID])
        #expect(m.loosened.map(\.id) == server && m.accounts.first?.port == 993 && m.accounts.first?.id == "acct-x")
    }

    @Test func anEntryOfAnotherKindUnderThisMacsIDIsAddedUnderANewID() throws {
        let folder = MailAccount(id: "acct-x", kind: .folder, displayName: "Saved emails", folderPath: "/Users/example/Mail Drop")
        let m = SettingsImporter.mergeAccounts(current: [folder], imported: [Self.elsewhere])
        #expect(m.accounts.count == 2 && m.accounts[0] == folder)
        let added = try #require(m.accounts.last)
        #expect(added.kind == .imap && added.id == SettingsImporter.movedAccountID("acct-x"))
        #expect(m.merge.added == ["Mail — me@example.com"] && m.merge.kept == ["Saved emails"])
        #expect(m.existingMailboxes.isEmpty && m.sameAccounts.isEmpty)
    }

    @Test func movedIDsAreStableAndUUIDShaped() {
        let a = SettingsImporter.movedAccountID("acct-x")
        #expect(a == SettingsImporter.movedAccountID("acct-x") && a != SettingsImporter.movedAccountID("acct-y"))
        #expect(UUID(uuidString: a) != nil && a == a.lowercased())
        #expect(SettingsImporter.movedAccountIDs(of: "acct-x").first == a)
    }

    // MARK: portability-cli-11 — a same-Mac re-import doesn't ask for app passwords

    @Test func reimportingThisMacsOwnBackupNeedsNoAppPasswordAgain() {
        var changed = Self.gmail
        changed.lookbackDays = 30
        let added = MailAccount(id: "yahoo", kind: .imap, displayName: "Yahoo", imapPreset: .yahoo,
                                host: "imap.mail.yahoo.com", port: 993, username: "me@example.org")
        for addresses in [true, false] {
            let p = Self.plan(Self.bundle(accounts: [changed, added], addresses: addresses), accounts: [Self.gmail])
            // The same id on the same server: its keychain item is found again. The added one needs one.
            #expect(Self.appPasswordWarnings(p) == ["Yahoo"], "\(p.warnings)")
            #expect(Self.written(p).first { $0.id == "acct-x" }?.lookbackDays == 14)     // a longer look-back is kept stricter
        }
        let m = SettingsImporter.mergeAccounts(current: [Self.gmail], imported: [changed, added])
        #expect(m.sameAccounts == [0] && m.existingMailboxes.isEmpty)
    }

    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theSheetSaysAnImportNeverTurnsAIOrMailOn() throws {
        let l10n = try String(contentsOf: LintRepo.url("Sources/PaperDeck/App/L10n+settings.swift"), encoding: .utf8)
        for gone in ["AI reading and Mail stay off", "AI 解读和邮件保持关闭", "AI reading and Mail stay off until you turn them on"] {
            #expect(!l10n.contains(gone), "\(gone)")
        }
        #expect(l10n.contains("An import never turns AI reading or Mail on; they stay as they are on this Mac."))
        #expect(l10n.contains("导入不会打开 AI 解读或邮件；它们保持这台 Mac 上的现状。"))
        // What the sentence rests on: the import never writes those switches.
        #expect(SettingsImporter.neverWritten.isSuperset(of: ["agent.mode", MailSettings.Keys.enabled]))
    }

    // MARK: mail-ai-privacy-4 — a person's sender never silently becomes an alert

    static let advisor = SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .ask)

    @Test func aPersonsSenderKeepsItsTypeUnlessAccepted() throws {
        var sameID = SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI newsletter", kind: .alert, aiPolicy: .ask)
        sameID.defaultCategory = "Lab"
        var samePattern = sameID
        samePattern.id = "file-id"
        samePattern.pattern = "PI@Lab.Example.edu"
        for theirs in [sameID, samePattern] {
            let m = SettingsImporter.mergeSenders(current: [Self.advisor], imported: [theirs], keepPeopleAlways: false)
            #expect(m.rules.count == 1 && m.rules[0].id == "pi")
            #expect(m.rules[0].kind == .advisor && m.rules[0].aiPolicy == .ask && m.rules[0].defaultCategory == "Lab")
            let item = try #require(m.loosened.first)
            #expect(m.loosened.count == 1 && item.id == ImportLoosening.senderID("pi", .kind) && item.field == .kind)
            #expect(item.mine == .string("advisor") && item.theirs == .string("alert") && !item.accepted)
            let accepted = SettingsImporter.mergeSenders(current: [Self.advisor], imported: [theirs], keepPeopleAlways: false,
                                                         acceptLooser: .only([item.id]))
            #expect(accepted.rules[0].kind == .alert && accepted.loosened.allSatisfy(\.accepted))
        }
        // Through the plan: listed under Kept stricter, the person's type is written.
        let p = Self.plan(Self.bundle(senders: [sameID], addresses: true), senders: [Self.advisor])
        #expect(p.keptStricter.map(\.id) == [ImportLoosening.senderID("pi", .kind)])
        #expect(Self.writtenSenders(p).first?.kind == .advisor)
    }

    @Test func keepingThePersonsTypeNeverSendsMoreToAIThanTheFile() {
        // The file's alert "Always" (its mailing-list mail only) is, for a person, at most "Ask".
        let theirs = SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .alert, aiPolicy: .always)
        let m = SettingsImporter.mergeSenders(current: [Self.advisor], imported: [theirs], keepPeopleAlways: false)
        #expect(m.rules[0].kind == .advisor && m.rules[0].aiPolicy == .ask)
        #expect(m.loosened.map(\.id) == [ImportLoosening.senderID("pi", .kind)])
        // Both ticked: the file's alert with "Always".
        let all = SettingsImporter.mergeSenders(current: [Self.advisor], imported: [theirs], keepPeopleAlways: false,
                                                acceptLooser: .all)
        #expect(all.rules[0].kind == .alert && all.rules[0].aiPolicy == .always)
        #expect(all.loosened.map(\.id) == [ImportLoosening.senderID("pi", .kind), ImportLoosening.senderID("pi")])
        // An alert made a person's is stricter for its mail: imported as usual (its "Always" is still guarded).
        let alert = SenderRule(id: "a", pattern: "@news.example.org", label: "News", kind: .alert, aiPolicy: .ask)
        var person = alert
        person.kind = .person
        let n = SettingsImporter.mergeSenders(current: [alert], imported: [person], keepPeopleAlways: false)
        #expect(n.rules[0].kind == .person && n.loosened.isEmpty)
    }

    @Test func aNewAlertRuleOverAPersonsDomainRuleKeepsThePersonsType() throws {
        let lab = SenderRule(id: "lab", pattern: "@lab.example.edu", label: "Lab", kind: .person, aiPolicy: .ask)
        let digest = SenderRule(id: "digest", pattern: "pi@lab.example.edu", label: "PI digest", kind: .alert, aiPolicy: .ask,
                                autoDownload: false)
        let m = SettingsImporter.mergeSenders(current: [lab], imported: [digest], keepPeopleAlways: false)
        let added = try #require(m.rules.first { $0.id == "digest" })
        #expect(added.kind == .person && added.aiPolicy == .ask)
        #expect(m.loosened.map(\.id) == [ImportLoosening.newSenderID("digest", .kind)])
        #expect(m.loosened.first?.overrides == "Lab")
        let accepted = SettingsImporter.mergeSenders(current: [lab], imported: [digest], keepPeopleAlways: false,
                                                     acceptLooser: .only([ImportLoosening.newSenderID("digest", .kind)]))
        #expect(accepted.rules.first { $0.id == "digest" }?.kind == .alert)
    }
}
