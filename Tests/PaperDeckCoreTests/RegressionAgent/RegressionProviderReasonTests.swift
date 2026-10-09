import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckShared

/// Finding 8: provider states were English free text, so "logged out" and "logged in with a
/// non-subscription method" were indistinguishable and the zh UI could not explain them. The
/// enum shapes stay; the String is now a stable reason code with zh/en `reasonText`.
@Suite struct RegressionProviderReasonTests {
    @Test func codesRoundTrip() {
        let reasons: [ProviderReason] = [.loggedOut, .nonSubscription(method: "api_key"),
                                         .missingFlags(["--json-schema", "--tools"]), .timeout, .agentCwdUnavailable,
                                         .other("something else")]
        for r in reasons { #expect(ProviderReason(code: r.code) == r, "\(r.code)") }
        #expect(ProviderReason.loggedOut.code == "logged_out")
        #expect(ProviderReason.nonSubscription(method: "apiKeyHelper").code == "non_subscription:apiKeyHelper")
        #expect(ProviderReason.missingFlags(["--a", "--b"]).code == "missing_flags:--a,--b")
        #expect(ProviderReason(code: "non_subscription:") == .nonSubscription(method: "unknown"))
    }

    @Test func providerStatusTextsInBothLanguages() {
        let nonSub = ProviderStatus.notLoggedIn("non_subscription:api_key")
        #expect(nonSub.reasonText(.zh) == "PaperDeck 只使用订阅登录（当前：api_key）")
        #expect(nonSub.reasonText(.en) == "PaperDeck only uses subscription login (current: api_key)")
        let out = ProviderStatus.notLoggedIn("logged_out")
        #expect(out.reasonText(.zh) == "需登录 Claude" && out.reasonText(.en) == "Sign in to Claude")
        #expect(out.reasonText(.zh) != nonSub.reasonText(.zh))
        #expect(ProviderStatus.unsupported("missing_flags:--json-schema").reasonText(.zh).contains("--json-schema"))
        #expect(ProviderStatus.unsupported("timeout").reasonText(.en).contains("timed out"))
        #expect(ProviderStatus.notInstalled.reasonText(.zh) == "未找到 Claude Code")
        #expect(ProviderStatus.ready(plan: "max", version: "2.1.284", path: "/x").reasonText(.zh)
                == "已登录（max） · Claude Code 2.1.284")
        // Unknown (older free-text) values still read sensibly.
        #expect(ProviderStatus.notLoggedIn("mock provider: not logged in").reasonText(.zh) == "需登录 Claude")
        #expect(ProviderStatus.unsupported("weird").reasonText(.en) == "Unsupported Claude Code version")
    }

    @Test func queueStatusProviderTexts() {
        typealias P = AgentQueueStatus.Provider
        #expect(P.notLoggedIn("non_subscription:apiKeyHelper").reasonText(.zh) == "PaperDeck 只使用订阅登录（当前：apiKeyHelper）")
        #expect(P.notLoggedIn("logged_out").reason == .loggedOut)
        #expect(P.unsupported("missing_flags:--tools").reason == .missingFlags(["--tools"]))
        #expect(P.ready(plan: nil, version: "2.1.284").reasonText(.en) == "Signed in · Claude Code 2.1.284")
        #expect(P.notInstalled.reasonText(.en) == "Claude Code not found")
        #expect(P.unknown.reason == nil && P.disabled.reason == nil)
        #expect(!P.unknown.reasonText(.zh).isEmpty && !P.disabled.reasonText(.en).isEmpty)
    }

    @Test func mockAndDetectEmitCodesNotProse() async throws {
        #expect(await MockAgentProvider(behavior: .notLoggedIn).detect() == .notLoggedIn("logged_out"))
        let root = try RAQueueHarness.newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try RAFakeCLI(auth: "auth-status-api-key")
        let provider = ClaudeCodeProvider(locator: RAFakeCLI.locator(), agentCwd: root.appendingPathComponent("cwd"),
                                          runner: cli.runner, parentEnvironment: { [:] })
        #expect(await provider.detect() == .notLoggedIn("non_subscription:api_key"))
        try cli.setAuth("auth-status-logged-out", exit: 1)
        #expect(await provider.detect() == .notLoggedIn("logged_out"))
        cli.setAuthResult(.init(exitCode: 130, signal: SIGINT, timedOut: true))
        #expect(await provider.detect() == .unsupported("timeout"))
    }

    /// The needs_login badge note tells the two cases apart (zh and en).
    @Test func needsLoginNoteNamesTheReason() async throws {
        for (lang, expected) in [(UILang.zh, "PaperDeck 只使用订阅登录（当前：api_key）"),
                                 (.en, "PaperDeck only uses subscription login (current: api_key)")] {
            let fake = RAScriptedProvider(status: .notLoggedIn("non_subscription:api_key"))
            let h = try await RAQueueHarness.make(mode: .claude, claude: fake, adjust: { $0.lang = lang })
            let p = try await h.insertPaper()
            await h.queue.enqueue(paperPK: p.pk, hold: false)
            await h.queue.start()
            #expect(await raEventually { try await h.paper(p.pk).aiState == .needsLogin })
            #expect(try await h.paper(p.pk).aiNote == expected)
            #expect(await fake.generateCalls == 0)
            await h.finish()
        }
        let fake = RAScriptedProvider(status: .notLoggedIn("logged_out"))
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { try await h.paper(p.pk).aiState == .needsLogin })
        #expect(try await h.paper(p.pk).aiNote == "需登录 Claude")
        await h.finish()
    }
}
