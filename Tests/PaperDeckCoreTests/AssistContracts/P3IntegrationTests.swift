import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Phase 3 integration (Lead): the warm Claude process pre-started when the Explain shortcut arms
/// it is exactly the one the panel's first turn asks for (R-UI-9: same model, effort and system
/// prompt, so the turn reuses it instead of starting another), the daily housekeeping prunes reader
/// anchors of explanations that are gone (R-UI-7), and Explain's settings travel with the right
/// guards (R-UI-8: "Ask before every send" off is looser, a longer history is looser). Mock only:
/// nothing here starts a process.
@Suite(.serialized) struct P3IntegrationTests {
    // MARK: R-UI-9 — the pre-started process matches the first turn

    @MainActor
    static func firstTurnSpec(_ settings: AssistSettings, reader: String, depth: AssistSettings.Depth? = nil) -> ClaudeAssistSession.Spec {
        let d = depth ?? settings.explainDepth
        let options = ExplainPrompt.Options(settings: settings, depth: d, reader: reader, session: .reuse(threadKey: "explain-x"))
        let base = ExplainPrompt.request(kind: .explain, language: .zh, level: settings.explainLevel, context: ExplainContext(),
                                         selection: "We regularize the attention weights.", image: nil, options: options)
        let prepared = ExplainPrepared(selection: "We regularize the attention weights.", image: nil, content: .text, match: nil)
        let spec = ExplainTurnSpec(kind: .explain, language: .zh, depth: d, level: settings.explainLevel, sendImage: false,
                                   threadKey: "explain-x", turnIndex: 0, history: [], prepared: prepared)
        return ClaudeAssistSession.Spec(ExplainEngineServices.finish(base, spec: spec, settings: settings))
    }

    @MainActor
    @Test func thePrestartedProcessIsTheOneExplainsFirstTurnAsksFor() throws {
        var s = AssistSettings(mode: .claude)
        let reader = "a PhD student in computational biology"
        let warm = try #require(AssistBackendFactory.explainPrewarmSpec(s, reader: reader))
        #expect(warm == Self.firstTurnSpec(s, reader: reader))
        #expect(warm.model == "haiku" && warm.effort == "low")
        // Thorough by default: the larger model, and still the same spec as the turn.
        s.explainDepth = .thorough
        let thorough = try #require(AssistBackendFactory.explainPrewarmSpec(s, reader: reader))
        #expect(thorough == Self.firstTurnSpec(s, reader: reader) && thorough.model == "sonnet" && thorough.effort == "medium")
        // A turn the user asked deeper (⌥) than the default doesn't match: it starts its own process.
        s.explainDepth = .quick
        #expect(AssistBackendFactory.explainPrewarmSpec(s, reader: reader) != Self.firstTurnSpec(s, reader: reader, depth: .thorough))
        // The models the user set are the ones pre-started; the reader is in the system prompt.
        s.models[.claude, default: [:]][.quick] = "claude-custom-quick"
        let custom = try #require(AssistBackendFactory.explainPrewarmSpec(s, reader: reader))
        #expect(custom.model == "claude-custom-quick" && custom == Self.firstTurnSpec(s, reader: reader))
        #expect(custom.systemPrompt.contains(reader))
        // Whatever the mode says (the backend is Claude's), the spec is Claude's.
        var codex = AssistSettings(mode: .codex)
        codex.keepWarmSeconds = 180
        #expect(AssistBackendFactory.explainPrewarmSpec(codex, reader: "")?.model == "haiku")
    }

    @Test func keepClaudeReadyOffPrestartsNothing() {
        var s = AssistSettings(mode: .claude)
        s.keepWarmSeconds = 0
        #expect(AssistBackendFactory.explainPrewarmSpec(s, reader: "") == nil)
    }

    /// The backend pre-starts with the factory's spec and the first turn of that spec reuses the
    /// process (a fake launcher: nothing is spawned — `ClaudeAssistBackendTests` covers the spawn
    /// itself); with the factory's flag the idle process is allowed at all.
    @Test func theFactoryAllowsTheIdleProcessOnlyThroughTheGate() throws {
        let source = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/Assist/AssistBackendFactory.swift"), encoding: .utf8)
        #expect(source.contains("prewarmSpec: { explainPrewarmSpec(load().assist, reader: reader()) },"))
        #expect(source.contains("idleSpawnOnPrewarm: true))"))
        let lane = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/Assist/AssistLane.swift"), encoding: .utf8)
        let prewarm = try #require(lane.range(of: "package func prewarm(_ arming: ArmingToken) async {"))
        #expect(lane[prewarm.upperBound...].prefix(400).contains("guard gate.checkSpawn(p, arming: arming, now: now()) else { return }"))
        let engine = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/Engine/Engine.swift"), encoding: .utf8)
        #expect(engine.contains("reader: { [loadCardProfile = deps.loadCardProfile] in loadCardProfile().reader }))"))
    }

    // MARK: R-UI-7 — the daily housekeeping prunes stale reader anchors

    @Test func theDailyHousekeepingDropsTheAnchorsOfExplanationsThatAreGone() async throws {
        try await OpsTestKit.run { env in
            let p = try await OpsTestKit.addPaper(env, title: "Anchored")
            let anchor = ReaderAnchor(paperID: p.id, kind: .selection, page: 2, rect: CGRect(x: 10, y: 10, width: 50, height: 20),
                                      pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: "x")
            let meta = AssistMeta(provider: "mock", model: "mock")
            let now = env.engine.ctx.now()
            let kept = try await env.engine.saveExplanation(ExplanationRecord(paperID: p.id, threadID: "explain-a", source: .reader,
                                                                                action: "explain", lang: .en, excerpt: "x",
                                                                                answer: "Kept.", meta: meta, createdAt: now))
            let gone = try await env.engine.saveExplanation(ExplanationRecord(paperID: p.id, threadID: "explain-b", source: .reader,
                                                                                action: "explain", lang: .en, excerpt: "y",
                                                                                answer: "Gone.", meta: meta, createdAt: now))
            await env.engine.saveExplanationReaderAnchor(anchor, explanationID: kept.id)
            await env.engine.saveExplanationReaderAnchor(anchor, explanationID: gone.id)
            try await env.engine.deleteExplanation(id: gone.id)
            let report = try await env.engine.maintenance.assistRetention()
            #expect(report.prunedReaderAnchors == 1)
            #expect(await env.engine.explanationReaderAnchor(id: kept.id) == anchor)
            #expect(await env.engine.explanationReaderAnchor(id: gone.id) == nil)
            #expect(try await env.engine.maintenance.assistRetention().prunedReaderAnchors == 0)
        }
    }

    // MARK: R-UI-8 — Explain's settings travel, guarded

    @Test func explainsSettingsTravelAndAnImportNeverLoosensTheGuardsSilently() throws {
        for key in [AssistSettings.Keys.explainLang, AssistSettings.Keys.explainDepth, AssistSettings.Keys.explainHotkey,
                    AssistSettings.Keys.explainDefaultMode, AssistSettings.Keys.explainAskBeforeSend,
                    AssistSettings.Keys.explainHistoryDays, AssistSettings.Keys.keepWarm, AssistSettings.Keys.dailySoftCap] {
            let e = try #require(SettingsRegistry.entry(key), "\(key)")
            #expect(e.keyClass == .export && e.section == .ai, "\(key)")
            #expect(SettingsRegistry.isTransferable(key), "\(key)")
        }
        // The switch and its consent still never travel.
        #expect(SettingsRegistry.entry(AssistSettings.Keys.mode)?.keyClass == .never)
        #expect(SettingsRegistry.entry(AssistSettings.Keys.consentVersion)?.keyClass == .never)
        // "Ask before every send": turning it off is looser; on, or the same, isn't.
        let ask = try #require(SettingsRegistry.entry(AssistSettings.Keys.explainAskBeforeSend)?.sensitivity)
        #expect(ask.isLooser(.bool(false), than: NSNumber(value: true)))
        #expect(!ask.isLooser(.bool(true), than: NSNumber(value: false)))
        #expect(!ask.isLooser(.bool(false), than: nil), "absent = the default (off): off is no looser")
        #expect(!ask.isLooser(.bool(true), than: NSNumber(value: true)))
        #expect(ask.isLooser(.string("no"), than: NSNumber(value: true)), "the wrong type counts as looser")
        #expect(ask.isLooser(.number(0), than: NSNumber(value: true)))
        #expect(ask.effective(nil) == .bool(false))
        // More turns before "Continue?", a longer history, the larger model: looser.
        let cap = try #require(SettingsRegistry.entry(AssistSettings.Keys.dailySoftCap)?.sensitivity)
        #expect(cap.isLooser(.number(80), than: nil) && !cap.isLooser(.number(20), than: nil))
        let days = try #require(SettingsRegistry.entry(AssistSettings.Keys.explainHistoryDays)?.sensitivity)
        #expect(days.isLooser(.number(365), than: nil) && !days.isLooser(.number(30), than: nil))
        let depth = try #require(SettingsRegistry.entry(AssistSettings.Keys.explainDepth)?.sensitivity)
        #expect(depth.isLooser(.string("thorough"), than: nil) && !depth.isLooser(.string("quick"), than: "thorough"))
        // Out-of-range values are dropped on import, never written.
        #expect(SettingsRegistry.valueRules[AssistSettings.Keys.keepWarm]?.validated(.number(99_999)) == nil)
        #expect(SettingsRegistry.valueRules[AssistSettings.Keys.dailySoftCap]?.validated(.number(0)) == nil)
        #expect(SettingsRegistry.valueRules[AssistSettings.Keys.explainHistoryDays]?.validated(.number(90)) == .number(90))
    }

    /// An imported shortcut goes through the loader and `HotKeySpec.validate`: garbage never
    /// reaches Carbon (an unknown key or a ⌥-only combination is refused before registering).
    @Test func anImportedShortcutIsCheckedBeforeItIsRegistered() {
        let scratch = ScratchDefaults("p3-hotkey")
        defer { scratch.drop() }
        scratch.defaults.set(["keyCode": 9_999_999, "modifiers": -1], forKey: AssistSettings.Keys.explainHotkey)
        let odd = AssistSettings.load(from: scratch.defaults).explainHotKey
        #expect(HotKeySpec.validate(odd) != nil)
        scratch.defaults.set(["keyCode": 0x0E, "modifiers": HotKeySpec.Carbon.option], forKey: AssistSettings.Keys.explainHotkey)
        #expect(HotKeySpec.validate(AssistSettings.load(from: scratch.defaults).explainHotKey) == .needsControlOrCommand)
        scratch.defaults.set(["keyCode": 0x0E, "modifiers": HotKeySpec.Carbon.control | HotKeySpec.Carbon.command],
                             forKey: AssistSettings.Keys.explainHotkey)
        let fine = AssistSettings.load(from: scratch.defaults).explainHotKey
        #expect(HotKeySpec.validate(fine) == nil && HotKeySpec.display(fine) == "⌃⌘E")
    }
}
