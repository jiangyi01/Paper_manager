import Foundation
import PaperDeckCore

/// `--selftest qa [--lang en|zh]`: the Ask surfaces' app-side rules, pure — every `L.QA` string in
/// both languages (distinct, none empty, no institution literal), the failure → notice mapping and
/// which notices offer Try Again / Continue, the gesture each click's ticket is minted with, the
/// estimate line, the inline citation links (only `paperdeck-cite://` survives), the streaming
/// buffer's coalescing. No engine, no library, nothing spawned, nothing stored. Owned by Slice C.
enum SelfTestQA {
    static func run(_ args: CLIArgs) -> Int32 {
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let previous = LangStore.shared.lang
        defer { LangStore.shared.lang = previous }

        var ok = true
        func check(_ name: String, _ pass: Bool, _ extra: [String: Any?] = [:]) {
            var line: [String: Any?] = ["check": name, "ok": pass]
            line.merge(extra) { a, _ in a }
            CLIRunner.line(line)
            if !pass { ok = false }
        }

        // 1. Strings.
        LangStore.shared.lang = .en
        let en = L.QA.all + L.Assist.all            // Settings ▸ Explain & Ask's shared switch with it
        LangStore.shared.lang = .zh
        let zh = L.QA.all + L.Assist.all
        LangStore.shared.lang = lang
        let same = zip(en, zh).filter { $0 == $1 }.map(\.0)
        check("strings: en and zh differ", en.count == zh.count && same.isEmpty, ["same": same])
        check("strings: none empty", !(en + zh).contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let institution = ["wash" + "u", "wus" + "tl", "washing" + "ton university"]
        check("strings: no institution literal", !(en + zh).contains { s in institution.contains { s.lowercased().contains($0) } })
        check("strings: the translation request names its language",
              L.QA.translateRequest(.zh).contains("中文") && L.QA.translateRequest(.en).contains("English"))

        // 2. Failures → notices.
        let refusals: [(AssistGate.Verdict, AskNotice)] = [
            (.disabled, .off), (.wrongProvider, .off), (.consentMissing, .expired), (.consentReused, .expired),
            (.consentExpired, .expired), (.burst, .burst), (.dailySoftCap(50), .softCap(50)), (.dailyHardCap(150), .hardCap(150)),
            (.budgetExhausted, .budget), (.policyBlocked, .blocked),
        ]
        check("notice: every refusal", refusals.allSatisfy { AskNotice.from(.refused($0.0)) == $0.1 })
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        check("notice: a usage limit and a pause both show the reset time",
              AskNotice.from(.usageLimit(resetsAt: until)) == .limited(until: until)
                  && AskNotice.from(.refused(.paused(until: until))) == .limited(until: until))
        check("notice: a stop shows no notice", AskNotice.from(.cancelled) == nil)
        check("notice: not signed in keeps the reason", AskNotice.from(.notLoggedIn(.loggedOut)) == .notLoggedIn(.loggedOut))
        check("notice: Try Again only where another click can help",
              AskNotice.timeout.canRetry && AskNotice.limited(until: nil).canRetry && AskNotice.expired.canRetry
                  && !AskNotice.off.canRetry && !AskNotice.blocked.canRetry && !AskNotice.hardCap(1).canRetry
                  && !AskNotice.softCap(1).canRetry && !AskNotice.budget.canRetry)
        // Phase 2 fixes (QA-3, QA-11): an unreadable privacy setting refuses and offers Try Again; a cut-off
        // answer is kept, so it shows no notice.
        check("notice: privacy settings that couldn't be read refuse, with Try Again",
              AskNotice.from(.generic(QAService.privacyUncheckedCode)) == .privacyUnchecked && AskNotice.privacyUnchecked.canRetry)
        check("notice: a cut-off answer shows no notice",
              AskNotice.from(.invalidOutput(QAService.outputCapKind)) == nil && AskNotice.from(.invalidOutput("schema")) == .failed)
        LangStore.shared.lang = .en
        let fixStrings = [L.QA.ambiguousPaper(5), L.QA.notSent(11), L.QA.questionTooLong(1_000), L.QA.cutOff,
                          L.QA.privacyUnchecked, L.QA.privacyUncheckedHint]
        let listed = fixStrings.allSatisfy(L.QA.all.contains)
        LangStore.shared.lang = .zh
        let zhFix = [L.QA.ambiguousPaper(5), L.QA.notSent(11), L.QA.questionTooLong(1_000), L.QA.cutOff,
                     L.QA.privacyUnchecked, L.QA.privacyUncheckedHint]
        LangStore.shared.lang = lang
        check("strings: the citation, length, cut-off and privacy notices are listed in both languages",
              listed && zip(fixStrings, zhFix).allSatisfy { $0 != $1 })

        // 3. The gesture a click's ticket is minted with.
        let session = AskSession(paperIDs: ["p"], state: nil, settings: AssistSettings())
        check("gesture: the first question", session.gesture(for: .ask("q")) == .ask)
        session.messages = [QAMessage(threadID: "t", role: .user, text: "q", createdAt: Date())]
        check("gesture: a follow-up", session.gesture(for: .ask("q2")) == .followUp)
        check("gesture: Try Again / Continue / Send Anyway / Thorough / translate",
              session.gesture(for: .retry) == .retry && session.gesture(for: .continuePastCap) == .capOverride
                  && session.gesture(for: .confirmPrivacy) == .action && session.gesture(for: .thorough(messageID: "m")) == .action
                  && session.gesture(for: .translate(.zh)) == .action)
        check("defaults: Quick, Auto, full text for one paper",
              session.depth == .quick && session.language == .auto && session.mode == .fullText && session.options == QAOptions())
        let four = AskSession(paperIDs: ["a", "b", "c", "d"], state: nil, settings: AssistSettings())
        check("defaults: excerpts above three papers", four.mode == .excerpts)
        four.setMode(.fullText)
        check("mode: no full text above three papers", four.mode == .excerpts)

        // 4. The streaming buffer: deltas wait for one flush; the blocks are parsed there.
        session.streaming = AskSession.Streaming(question: "q", startedAt: Date())
        session.append("Hello ")
        session.append("**world** [p. 2]")
        check("stream: nothing drawn before the flush", session.streaming?.text == "")
        session.flush()
        check("stream: one flush, in order", session.streaming?.text == "Hello **world** [p. 2]"
              && session.streaming?.blocks == [.paragraph("Hello **world** [p. 2]")] && session.streaming?.phase == .streaming)
        check("stream: at most ~30 redraws a second", AskSession.flushInterval == .milliseconds(33))

        // 5. Inline citations: only our own links survive.
        let text = "See [p. 3] and [the site](https://example.org) <https://evil.example>."
        let attributed = AskMarkdown.attributed(text, multi: false)
        let links = attributed.runs.compactMap(\.link)
        check("links: only citation links", links.count == 1 && links.first?.scheme == QACitations.linkScheme,
              ["links": links.map(\.absoluteString)])
        check("links: the marker index", links.first.flatMap(AskMarkdown.index(of:)) == 0)
        check("copy: citations as (p. N)", AskMarkdown.plain("A [p. 3].", multi: false) == "A (p. 3).")

        let cal = Calendar.current
        let today = cal.date(bySettingHour: 15, minute: 45, second: 0, of: Date()) ?? Date()
        check("notice: a reset today reads like the provider pill", AskNoticeView.time(today, now: today) == "15:45")
        let later = cal.date(byAdding: .day, value: 1, to: today) ?? today
        let c = cal.dateComponents([.month, .day], from: later)
        check("notice: a later reset names the day", AskNoticeView.time(later, now: today) == "\(c.month ?? 0)/\(c.day ?? 0) 15:45")

        // 6. The estimate line.
        LangStore.shared.lang = .en
        let est = QAEstimate(chars: 12_000, estimatedTokens: 3_200, pages: Array(1...12), omitted: 0, model: "haiku",
                             provider: "claude", latency: 5...15, mode: .fullText, fullText: true, papers: 1)
        let status = AssistStatus(mode: .claude, todayCount: 4, softCap: 50)
        check("estimate: full text", AskEstimateLine.text(estimate: est, multi: false, status: status, mode: .claude)
              == "≈ 3.2k tokens · all 12 pages · haiku · ~5–15 s · today 4/50")
        var some = est
        some.pages = [1, 2, 9]
        some.omitted = 27
        some.fullText = false
        check("estimate: best pages", AskEstimateLine.text(estimate: some, multi: false, status: status, mode: .claude)
              .contains("3 of 30 pages (best matches)"))
        var multi = est
        multi.papers = 4
        multi.mode = .excerpts
        check("estimate: several papers", AskEstimateLine.text(estimate: multi, multi: true, status: status, mode: .claude)
              .contains("4 papers · excerpts"))
        check("estimate: no count for the mock", !AskEstimateLine.text(estimate: est, multi: false, status: status, mode: .mock)
              .contains("today"))
        LangStore.shared.lang = lang

        CLIRunner.line(["selftest": "qa", "ok": ok])
        return ok ? 0 : 1
    }
}
