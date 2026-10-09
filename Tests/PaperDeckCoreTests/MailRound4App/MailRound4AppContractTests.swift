import Foundation
import Testing
@testable import PaperDeckCore

/// What the app side of round 4 (a4-1) relies on from Core — the app code itself (the
/// skipped-emails notice in Settings ▸ Mail ▸ Accounts and the inbox, the status line without the
/// repeated sentence) is checked by `PaperDeck --selftest app-rules`, which these tests can't reach:
/// - `accountSyncInfo(lang:)` carries `skippedHint` in the language asked for (the account's
///   look-back in it), nil once nothing is skipped; the inbox snapshot carries it in the UI language;
/// - a pass that gets through while emails stay skipped ends its ready status with
///   `" · " + skippedHint` — the suffix `MailAccountNotice.shownStatus` leaves to the notice.
/// Fakes only: no mail server, no keychain, agent mode off.
@Suite(.serialized) struct MailRound4AppContractTests {
    @Test func theSkippedHintAndTheStatusSuffixTheAppRelyOn() async throws {
        let source = RFB.LedgerSource(accountID: "acct-k")
        let account = RFB.fakeIMAPAccount("acct-k")
        let env = try await RFB.make(mail: RFB.settings(accounts: [account], syncMinutes: 60),
                                     sources: { $0.id == "acct-k" ? source : nil }, start: false)
        do {
            // The count a pass stored (retry list full) — read again at the next pass.
            try await env.db.setMailCursor(accountID: MailSyncActor.skippedKey("acct-k"), MailCursor("3"))
            _ = await env.engine.start()                       // the timer's first pass: due, not a re-list
            let synced = await RFB.eventually {
                await env.engine.mail.accountSyncInfo(lang: .en).first?.lastSuccessAt != nil
            }
            #expect(synced)
            for lang in [UILang.en, .zh] {
                let info = try #require(await env.engine.mail.accountSyncInfo(lang: lang).first)
                let hint = MailSyncText.skippedByCap(3, lookbackDays: account.lookbackDays, lang)
                #expect(info.skipped == 3)
                #expect(info.skippedHint == hint)
                guard case .unavailable(let text)? = info.status else {
                    Issue.record("status \(String(describing: info.status))")
                    continue
                }
                #expect(text == "ledger ready · " + hint)
            }
            env.settings.value.lang = .zh
            let snap = try await env.engine.mailSnapshot()
            #expect(snap.accounts.first?.skippedHint == MailSyncText.skippedByCap(3, lookbackDays: account.lookbackDays, .zh))
            #expect(snap.accounts.first?.enabled == true)

            // 立即同步 lists the look-back again and gets through: nothing skipped, no hint, ready.
            await env.sync()
            let after = try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
            #expect(after.skipped == 0 && after.skippedHint == nil)
            guard case .ready? = after.status else {
                Issue.record("status \(String(describing: after.status))")
                await env.close()
                return
            }
        } catch {
            await env.close()
            throw error
        }
        await env.close()
    }
}
