import AppKit
import SwiftUI
import PaperDeckCore

/// Portability fix round 2 checks of `--selftest app-rules` (verifier regression #6, mutation A2):
/// the inspector draws the whole 「让 AI 分析」 explanation — its question on the view, not only in
/// a tooltip — for an email awaiting consent, while an unselected list card stays one line. Both
/// are drawn offscreen and read back (`drawnText`), so an inspector passing `compact: true` is
/// caught, not only the rule (`MailCardView.compactConsent`). A scratch engine that is never
/// started (no sync, no AI) and a hand-made inbox snapshot; scratch defaults.
extension SelfTestAppRules {
    static func runPF2(scratch: URL, _ c: Checker) async {
        await inspectorConsentDrawn(scratch: scratch, c)
    }

    private static func inspectorConsentDrawn(scratch: URL, _ c: Checker) async {
        let lang = LangStore.shared.lang
        let root = scratch.appendingPathComponent("consent-drawn", isDirectory: true)
        guard let engine = try? await mailEngine(root, lang: Shared(lang), mail: MailSettings(), sources: [:]) else {
            c.check("consent drawn: engine fixture", false)
            return
        }
        let suite = scratch.appendingPathComponent("defaults-consent/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else {
            c.check("consent drawn: scratch defaults", false)
            await close(engine)
            return
        }
        let savedLang = LangStore.shared.lang, savedProvider = LangStore.shared.provider
        let store = SettingsStore(defaults: defaults)
        store.language = lang
        let state = AppState(engine: engine, settings: store)
        let message = MailMessage(accountID: "manual", internetMessageID: "<pf2-consent@lab.example.edu>",
                                  fromAddress: "pi@lab.example.edu", fromName: "Prof. Smith", senderKind: .advisor,
                                  subject: "Paper for Friday", receivedAt: Date(), snippet: "Please read this before Friday.",
                                  triageState: .awaitingConsent)
        let card = MailCard(message: message, items: [], rule: nil, account: nil)
        state.mailSnapshot = MailSnapshot(groups: [.pending: [card]], counts: MailCounts(pending: 1, awaitingConsent: 1),
                                          accounts: [], triageUsage: MailTriageUsage(day: LocalDate.today(), used: 0, limit: 30),
                                          triageQueued: 0, enabled: true, aiMode: .ai, generatedAt: Date())
        // The question of the full box (`L.Mail.consentTitle`), squeezed: two fragments (text
        // recognition keeps the words, not always the spaces or the punctuation).
        let (question, tail) = lang == .zh ? ("只用本地规则整理过", "分析吗") : ("sortedbylocalrulesonly", "analyzeit")
        func squeezed(_ lines: [String]) -> String { lines.joined().filter { !$0.isWhitespace }.lowercased() }
        func asks(_ lines: [String]) -> Bool { squeezed(lines).contains(question) && squeezed(lines).contains(tail) }
        let button = L.Mail.analyzeWithAI.filter { !$0.isWhitespace }.lowercased()

        state.selectedMailID = card.id
        let inspector = await drawnText(MailDetailView(state: state, id: card.id, loadsFullCard: false)
                                            .environment(LibraryChrome()).frame(height: 640), width: 380)
        state.selectedMailID = nil
        let listCard = await drawnText(MailCardView(state: state, card: card, aiMode: .ai), width: 820)
        c.check("consent drawn: the inspector shows the whole explanation (\(lang.rawValue))",
                card.canRequestAI && asks(inspector) && squeezed(inspector).contains(button), ["inspector": inspector])
        c.check("consent drawn: an unselected list card keeps it to one line (\(lang.rawValue))",
                !asks(listCard) && squeezed(listCard).contains(button), ["card": listCard])

        defaults.removePersistentDomain(forName: suite)
        LangStore.shared.lang = savedLang
        LangStore.shared.provider = savedProvider
        await close(engine)
    }
}
