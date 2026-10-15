import Foundation
import PaperDeckCore

/// `--selftest app-rules`, mail privacy fixes: the app side the Core tests can't reach —
/// every privacy reason (a confidential email, a browser page that can't be told) and the batch
/// hold for a confidential email are worded in both languages; Settings ▸ Mail ▸ Reading criteria
/// says "1 paper"; the triage preview judges an Outlook forward with an edited subject on the
/// history it cut, as the capture does. Pure: no library, nothing spawned, nothing posted.
extension SelfTestAppRules {
    static func runPrivacy(_ c: Checker) {
        let saved = LangStore.shared.lang
        defer { LangStore.shared.lang = saved }
        func both<T>(_ f: () -> T) -> (en: T, zh: T) {
            LangStore.shared.lang = .en
            let en = f()
            LangStore.shared.lang = .zh
            return (en, f())
        }

        // Every privacy reason has its own line in each language.
        for reason in AssistPrivacy.Reason.allCases {
            let text = both { L.Policy.reason(reason) }
            c.check("privacy: reason \(reason.rawValue) worded in en and zh",
                    !text.en.isEmpty && !text.zh.isEmpty && text.en != text.zh)
        }
        let browser = both { L.Policy.reason(.unknownBrowserPage) }
        c.check("privacy: unknown browser page names webmail and Screen Recording",
                browser.en.contains("webmail") && browser.en.contains("Screen Recording")
                    && browser.zh.contains("网页邮箱") && browser.zh.contains("屏幕录制"))

        // The batch hold of a paper from a confidential email.
        let held = both { L.Select.rereadHeld([RereadHeld(paperID: "p", reason: .confidentialEmail)]) }
        c.check("privacy: batch hold for a confidential email worded",
                held.en?.contains("from a confidential email") == true && held.zh?.contains("来自保密邮件") == true,
                ["en": held.en, "zh": held.zh])

        // Reading criteria: singular at the stepper's minimum.
        let one = both { L.MailPref.maxAlertPapers(1) }, two = both { L.MailPref.maxAlertPapers(2) }
        c.check("mail settings: at most 1 paper per alert",
                one.en == "At most 1 paper per alert" && two.en == "At most 2 papers per alert" && one.zh == "每封提醒最多 1 篇",
                ["en1": one.en, "en2": two.en])

        // The triage preview decides an edited-subject Outlook forward like the capture: it waits.
        let rule = SenderRule(id: "selftest-advisor", pattern: "advisor@lab.example.edu", label: "Advisor", kind: .advisor,
                              aiPolicy: .always)
        let eml = """
            From: Advisor <advisor@lab.example.edu>\r
            To: me@example.edu\r
            Subject: Could you take this one?\r
            Date: Wed, 30 Sep 2026 09:00:00 -0500\r
            Message-ID: <selftest-forward@lab.example.edu>\r
            MIME-Version: 1.0\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Could you take this one? Thanks.\r
            \r
            ________________________________\r
            From: Neuron Editorial Office <neuron@journal.example.org>\r
            Sent: Monday, September 28, 2026 9:12 AM\r
            To: Advisor <advisor@lab.example.edu>\r
            Subject: Invitation to review manuscript NEURON-D-26-01234\r
            \r
            I would like to invite you to review the attached manuscript for Neuron.\r

            """
        let result = (try? MIMEParser.parse(Data(eml.utf8), maxAttachmentBytes: 1 << 20)).map {
            MailTriagePreview.run(content: $0, rule: rule, settings: MailSettings(senders: [rule]),
                                  engineSettings: EngineSettings(lang: .en), categories: [], frequentTags: [],
                                  now: Date(), calendar: .current)
        }
        c.check("preview: edited-subject forward of an invitation → awaiting consent",
                result?.syncedTriage == .awaitingConsent,
                ["synced": result.map { "\($0.syncedTriage)" } ?? "unparsed"])
    }
}
