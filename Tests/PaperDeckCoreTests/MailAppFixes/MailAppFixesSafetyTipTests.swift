import Foundation
import Testing
@testable import PaperDeckCore

/// Outlook's first-contact safety tip ("You don't often get email from …") that Power Automate's
/// Export email keeps at the top of a message never becomes the card's summary or AI text.
@Suite struct MailAppFixesSafetyTipTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml",
                                                 subdirectory: "Fixtures/mail/mail-fixes"))
        return try Data(contentsOf: url)
    }

    @Test func outlookExportDropsTheTip() throws {
        let content = try MIMEParser.parse(try Self.fixture("outlook-export"), maxAttachmentBytes: 5_000_000)
        let x = MailExtractor.extract(content, senderKind: .advisor, bodyCap: 12_000)
        #expect(!x.bodyText.localizedCaseInsensitiveContains("often get email"))
        #expect(!x.bodyText.contains("aka.ms"))
        #expect(x.bodyText.contains("Please read the attached manuscript"))
        #expect(!x.snippet.localizedCaseInsensitiveContains("often get email"))
    }

    @Test func onlyTheTipLineGoes() {
        let tip = "You don’t often get email from jsmith@wustl.edu. Learn why this is important <https://aka.ms/LearnAboutSenderIdentification>\nHi,\nPlease read this.\n"
        #expect(MailExtractor.dropSafetyTip(tip) == "Hi,\nPlease read this.\n")
        let zh = "你通常不会收到来自 a@b.edu 的电子邮件。了解这一点为什么很重要\n请读一下附件。"
        #expect(MailExtractor.dropSafetyTip(zh) == "请读一下附件。")
        // A sentence that merely quotes it further down stays.
        let quoted = String(repeating: "Body text. ", count: 250) + "\nYou don't often get email from x. Learn why this is important\n"
        #expect(MailExtractor.dropSafetyTip(quoted) == quoted)
        #expect(MailExtractor.dropSafetyTip("Hi,\nNothing to drop.") == "Hi,\nNothing to drop.")
    }
}
