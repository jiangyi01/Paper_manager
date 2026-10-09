import Foundation
import Testing
@testable import PaperDeckCore

/// Seams between the review fixes: texts one fix stores that another fix rewords.
@Suite struct MailIntegrationTests {

    /// runtime-7 × safety-3 / integrity-6: the download notes added for the download policy and
    /// for papers in Recently Deleted are stored on mail rows, so a language switch rewords them
    /// like every other stored machine text.
    @Test func newDownloadNotesFollowTheCurrentLanguage() {
        let producers: [(UILang) -> String] = [
            { MailOpsText.privateAddress($0) }, { MailOpsText.notAutomatic($0) },
            { MailOpsText.inRecentlyDeleted($0) }, { MailOpsText.restoreFailed($0) },
        ]
        for p in producers {
            let en = p(.en), zh = p(.zh)
            #expect(en != zh)
            #expect(MailMachineText.localized(en, .zh) == zh, "\(en)")
            #expect(MailMachineText.localized(zh, .en) == en, "\(zh)")
            #expect(MailMachineText.localized(en, .en) == en)
            #expect(MailMachineText.localized(zh, .zh) == zh)
        }
        let row = MailItem(ord: 1, cand: "c1", origin: .link, title: "A paper",
                           downloadError: MailOpsText.inRecentlyDeleted(.en))
        #expect(MailMachineText.localized([row], .zh).first?.downloadError == MailOpsText.inRecentlyDeleted(.zh))
    }
}
