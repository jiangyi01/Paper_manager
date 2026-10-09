import Foundation
import Testing
@testable import PaperDeckCore

// T13 DateOrderTests and T16 IMAPMessageTests (PORTABILITY_PLAN §5.4), plus the provider-neutral
// folder hints and the queue labels. Pure; the sync test runs a temp-rooted engine with a fake
// transport (no mail server, no CLI).
@Suite struct DateOrderTests {
    typealias K = MailSyncKit
    static let calendar = K.calendar
    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    @Test func slashDatesReadMonthFirstByDefaultAndDayFirstWhenChosen() throws {
        let received = Self.date(2026, 9, 29)
        let text = "Please read the attached paper by 10/3 so we can discuss it."
        let mdy = try #require(MailHeuristics.findDue(in: text, received: received, now: received, calendar: Self.calendar))
        #expect(mdy.date == LocalDate(year: 2026, month: 10, day: 3))
        let explicit = MailHeuristics.findDue(in: text, received: received, now: received, calendar: Self.calendar, dateOrder: .mdy)
        #expect(explicit?.date == mdy.date)
        let dmy = try #require(MailHeuristics.findDue(in: text, received: received, now: received, calendar: Self.calendar,
                                                      dateOrder: .dmy))
        #expect(dmy.date == LocalDate(year: 2027, month: 3, day: 10))
        // A day above 12 reads only one way: day-first, 25/10/2026 is 25 October.
        let late = "Due by 25/10/2026, thanks."
        #expect(MailHeuristics.findDue(in: late, received: received, now: received, calendar: Self.calendar, dateOrder: .dmy)?.date
                == LocalDate(year: 2026, month: 10, day: 25))
        #expect(MailHeuristics.findDue(in: late, received: received, now: received, calendar: Self.calendar)?.date
                != LocalDate(year: 2026, month: 10, day: 25))
        // Month names and ISO dates don't depend on the order.
        for order in SlashDateOrder.allCases {
            #expect(MailHeuristics.findDue(in: "Due by 2026-10-05.", received: received, now: received, calendar: Self.calendar,
                                           dateOrder: order)?.date == LocalDate(year: 2026, month: 10, day: 5))
        }
    }

    @Test func autoFollowsTheRegion() {
        #expect(SlashDateOrder.auto.resolved(locale: Locale(identifier: "en_US")) == .mdy)
        #expect(SlashDateOrder.auto.resolved(locale: Locale(identifier: "en_GB")) == .dmy)
        #expect(SlashDateOrder.auto.resolved(locale: Locale(identifier: "de_DE")) == .dmy)
        #expect(SlashDateOrder.dmy.resolved(locale: Locale(identifier: "en_US")) == .dmy)
    }

    @Test func aMissingKeyLoadsAsMonthFirst() {
        let scratch = ScratchDefaults("date-order-load")
        defer { scratch.drop() }
        #expect(MailSettings.load(from: scratch.defaults).dateOrder == .mdy)
        scratch.defaults.set("auto", forKey: MailSettings.Keys.dateOrder)
        #expect(MailSettings.load(from: scratch.defaults).dateOrder == .auto)
        scratch.defaults.set("sideways", forKey: MailSettings.Keys.dateOrder)
        #expect(MailSettings.load(from: scratch.defaults).dateOrder == .mdy)
    }

    /// The sync reads Settings ▸ Mail's order: the same advisor email gets its deadline either way.
    @Test(arguments: [(SlashDateOrder.mdy, LocalDate(year: 2026, month: 10, day: 3)),
                      (SlashDateOrder.dmy, LocalDate(year: 2027, month: 3, day: 10))])
    func theSyncAppliesTheOrder(_ order: SlashDateOrder, _ expected: LocalDate) async throws {
        var mail = K.mailSettings(senders: [K.advisorRule])
        mail.dateOrder = order
        try await K.run(mail: mail) { env in
            let eml = """
            From: Prof. Smith <jsmith@wustl.edu>\r
            To: me@example.edu\r
            Subject: Journal club paper\r
            Date: Wed, 30 Sep 2026 09:00:00 -0500\r
            Message-ID: <date-order-\(order.rawValue)@example.edu>\r
            MIME-Version: 1.0\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hi, could you please read this paper and present it by 10/3?\r
            https://www.biorxiv.org/content/10.1101/2026.09.21.614121v1\r
            Thanks\r

            """
            await env.source().add("d.eml", Data(eml.utf8))
            await env.sync()
            let m = try await env.message("<date-order-\(order.rawValue)@example.edu>")
            #expect(m.triage?.dueDate == expected, "\(order)")
        }
    }
}

@Suite struct IMAPMessageTests {
    @Test(arguments: ["outlook.office365.com", "imap-mail.outlook.com", "Outlook.Office365.com"])
    func microsoftHostsExplainTheAppPasswordDeadEnd(_ host: String) {
        let en = IMAPError.authenticationFailed("AUTHENTICATE failed.").message(host: host, lang: .en)
        #expect(en.contains("Microsoft doesn't accept app passwords for this mailbox — see Help ▸ Outlook.com"))
        #expect(en.hasSuffix("(Server: AUTHENTICATE failed.)"))
        let zh = IMAPError.authenticationFailed("").message(host: host, lang: .zh)
        #expect(zh.contains("Microsoft 不接受这个邮箱的应用专用密码") && zh.contains("帮助 ▸ Outlook.com"))
    }

    @Test func otherHostsKeepTodaysText() {
        let en = IMAPError.authenticationFailed("").message(host: "imap.gmail.com", lang: .en)
        #expect(en == "imap.gmail.com rejected the sign-in. The app password may have been revoked, or 2-Step Verification was turned off — create a new app password and save it again.")
        let zh = IMAPError.authenticationFailed("x").message(host: "imap.mail.me.com", lang: .zh)
        #expect(zh == "imap.mail.me.com 拒绝登录：应用专用密码可能已被撤销，或两步验证已关闭。请重新生成应用专用密码并保存。（服务器：x）")
        #expect(!IMAPError.isMicrosoftHost("imap.outlook.example.com"))
    }
}

@Suite struct FolderHintTests {
    @Test func aOneDriveFolderKeepsTodaysText() {
        let p = "~/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail"
        #expect(FolderMailSourceError.folderMissing(p).message(lang: .en)
                == "Folder not found: \(p). If it's a OneDrive folder, make sure OneDrive is running and syncing.")
        #expect(FolderMailSourceError.folderMissing(p).message(lang: .zh)
                == "找不到文件夹：\(p)。如果是 OneDrive 文件夹，请确认 OneDrive 正在运行并已同步。")
    }

    @Test func otherProvidersAreNamedAndLocalFoldersGetTheNeutralHint() {
        #expect(FolderMailSourceError.folderMissing("~/Library/CloudStorage/Dropbox/Mail").message(lang: .en)
            .hasSuffix("If it's a Dropbox folder, make sure Dropbox is running and syncing."))
        #expect(FolderMailSourceError.folderMissing("/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/M").message(lang: .en)
            .hasSuffix("If it's a Google Drive folder, make sure Google Drive is running and syncing."))
        let local = FolderMailSourceError.folderMissing("~/Mail/PaperDeck").message(lang: .en)
        #expect(local.hasSuffix("If it's in a cloud folder (OneDrive, Dropbox, Google Drive, iCloud Drive), make sure that app is running and syncing."))
        #expect(!FolderMailSourceError.folderMissing("~/Mail/PaperDeck").message(lang: .zh).isEmpty)
    }

    @Test func providerNamesComeFromThePathShape() {
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Library/CloudStorage/OneDrive-Contoso/x") == "OneDrive")
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Library/CloudStorage/Box-Box/x") == "Box")
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Library/CloudStorage/Dropbox (Personal)/x") == "Dropbox")
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/x") == "iCloud Drive")
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Documents/x") == nil)
        #expect(CloudPathHint.providerName(forPath: "/Users/a/Library/CloudStorage") == nil)
    }

}
