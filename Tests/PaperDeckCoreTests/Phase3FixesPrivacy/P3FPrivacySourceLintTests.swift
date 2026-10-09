import Foundation
import Testing

/// Phase-3 fixes, privacy & consent lane: the App wiring the test target can't run (it doesn't link
/// the app), pinned in the sources. The decisions themselves are Core's and tested for real
/// (`P3FPrivacyRulesTests`, `P3FPrivacyPanelFlowTests`); these check the App only acts on them:
/// the shortcut alone never sends (F4 / F5 A2), the overlay's opening never sends (A7), ⏎ reads only
/// the offered clipboard (A1), the shortcut is registered only behind the switch (A6), Services
/// never send by themselves (F10), every capture gets its surroundings (F1 / F2), OCR reads the
/// full-resolution crop (CUX-7), and the new strings answer in both languages.
@Suite("Phase 3 fixes: privacy and consent wiring (sources)", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P3FPrivacySourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let coordinator = "Sources/PaperDeck/Explain/ExplainCoordinator.swift"
    static let overlay = "Sources/PaperDeck/Explain/CaptureOverlayController.swift"

    /// The body of the function declared by `signature` (up to its closing brace at the same indent).
    static func body(_ source: String, _ signature: String) throws -> String {
        let start = try #require(source.range(of: signature), "\(signature)")
        let lineStart = source[..<start.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let indent = String(source[lineStart..<start.lowerBound].prefix { $0 == " " })
        let end = try #require(source.range(of: "\n" + indent + "}\n", range: start.upperBound..<source.endIndex), "\(signature) end")
        return String(source[start.lowerBound..<end.upperBound])
    }

    @Test func theShortcutAloneNeverSends() throws {
        let c = try Self.text(Self.coordinator)
        let press = try Self.body(c, "func hotKeyPressed() {")
        #expect(press.contains("switch ExplainTriggerRules.onHotKey(overlayShown: overlay.isShown, lastPress: lastHotKeyPress, now: now,"))
        #expect(press.contains("overlay.model.offer = ExplainTriggerRules.offerOnDoubleTap(changeCount: pb.changeCount,"))
        for forbidden in [#"explainOffer"#, #"explainClipboard"#, #"\bbegin\("#, #"\bmint\b"#, #"\.run\("#, #"holdForSend"#, #"string\(forType"#] {
            #expect(press.range(of: forbidden, options: .regularExpression) == nil, "the shortcut's handler: \(forbidden)")
        }
        // Nothing calls the overlay's old "double tap sends" path.
        let calls = try LintRepo.grep(#"explainClipboardOnDoubleTap\("#).filter { !$0.text.contains("func explainClipboardOnDoubleTap") }
        #expect(calls.isEmpty, "\(calls)")
        #expect(!c.contains("static let doubleTap"), "the double tap's window is Core's (ExplainTriggerRules.doubleTap)")
    }

    @Test func theOverlayOpeningSendsNothingAndReturnReadsOnlyTheOfferedClipboard() throws {
        let o = try Self.text(Self.overlay)
        let show = try Self.body(o, "func show(mode: AssistSettings.OverlayMode) {")
        for forbidden in [#"\bmint\b"#, #"\bbegin\("#, #"\bexplainOffer\("#, #"\bstart\("#, #"string\(forType"#, #"ExplainClipboard\.read"#] {
            #expect(show.range(of: forbidden, options: .regularExpression) == nil, "show(mode:): \(forbidden)")
        }
        let offer = try Self.body(o, "func explainOffer() -> Bool {")
        #expect(offer.contains("NSPasteboard.general.changeCount == offer.changeCount")
                    || offer.contains("ExplainTriggerRules.offerIsCurrent(model.offer, changeCount: NSPasteboard.general.changeCount)"),
                "⏎ sends only the clipboard that was offered")
    }

    @Test func theShortcutIsRegisteredOnlyBehindTheSwitch() throws {
        let c = try Self.text(Self.coordinator)
        let register = try Self.body(c, "func registerHotKey() {")
        let guardRange = try #require(register.range(of: "guard settings.mode != .off else {"))
        let call = try #require(register.range(of: "hotKeys.register("))
        #expect(guardRange.upperBound <= call.lowerBound)
        #expect(c.components(separatedBy: "hotKeys.register(").count == 2, "registered in one place")
        let initBody = try Self.body(c, "init(state: AppState?, services:")
        #expect(!initBody.contains("registerHotKey") && !initBody.contains(".register("))
        // No other file registers the Explain shortcut.
        let hits = try LintRepo.grep(#"hotKeys\.register\(|HotKeyCenter[^(]*\.register\(|\.register\([^)]*explainHotKey"#, under: "Sources/PaperDeck")
        #expect(hits.allSatisfy { $0.path == Self.coordinator }, "\(hits)")
        let boot = try Self.text("Sources/PaperDeck/Explain/ExplainBootstrap.swift")
        let install = try Self.body(boot, "static func install(_ state: AppState) {")
        #expect(install.contains("coordinator.registerHotKey()") && !install.contains(".register("))
        // The warm process starts only by Core's rule.
        #expect(try Self.body(c, "private func prewarm() {").contains("ExplainTriggerRules.prewarms(settings)"))
    }

    @Test func servicesOpenTheirPanelHeldAndNeverSendByThemselves() throws {
        let p = try Self.text("Sources/PaperDeck/Explain/ExplainServiceProvider.swift")
        #expect(p.range(of: #"\bmint\b"#, options: .regularExpression) == nil, "no ticket from a Services call")
        #expect(!p.contains("coordinator.begin("))
        #expect(p.contains("case .explain(let capture, let kind):\n            coordinator.holdForSend(capture: capture, kind: kind)"))
        #expect(p.contains("let window = WindowTitleReader.frontmostWindow()"), "the calling window's title (webmail) goes with it")
        let c = try Self.text(Self.coordinator)
        let begin = try Self.body(c, "func begin(capture: ExplainCapture, ticket: ConsentTicket, anchor: ReaderAnchor?,")
        #expect(begin.contains("debounce.allow(at: Date(), interval: ExplainTriggerRules.debounce(for: capture))"))
        #expect(begin.contains("switch ExplainTriggerRules.start(for: ticket.gesture) {"))
        #expect(begin.contains("case .holdForSend: panelState.holdForSend(kind)"))
        let hold = try Self.body(c, "func holdForSend(capture: ExplainCapture, kind: ExplainTurnKind) {")
        #expect(hold.contains("panelState.holdForSend(kind)") && !hold.contains(".run(") && !hold.contains("ticket"))
    }

    @Test func everyCaptureGetsWhoWasOnScreenUnderIt() throws {
        let c = try Self.text(Self.coordinator)
        for fn in ["func begin(capture: ExplainCapture, ticket: ConsentTicket, anchor: ReaderAnchor?,",
                   "func holdForSend(capture: ExplainCapture, kind: ExplainTurnKind) {", "func openForQuestion(capture: ExplainCapture) {"] {
            #expect(try Self.body(c, fn).contains("makeState(capture: withSurroundings(capture, near:"), "\(fn)")
        }
        let with = try Self.body(c, "private func withSurroundings(_ capture: ExplainCapture, near rect: CGRect?) -> ExplainCapture {")
        #expect(with.contains("let own = ExplainOwnWindows.roles(state: state)"))
        #expect(with.contains("switch ExplainTriggerRules.surroundings(for: capture.source) {"))
        #expect(with.contains("WindowTitleReader.surroundings(region: region, point: ExplainTriggerRules.point(in: region, focus: c.focus),"))
        #expect(with.contains("excluding: Set(ownWindowIDs), own: own)"))
        #expect(with.contains("let source = clipboardSources.source(of: NSPasteboard.general.changeCount)?.bundleID"))
        #expect(c.contains("forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main)"))
        // The window lookup keeps PaperDeck's reader and library (F2): only Explain's own ids are skipped.
        let reader = try Self.text("Sources/PaperDeck/Explain/Capture/WindowTitleReader.swift")
        #expect(reader.contains("let entries = WindowList.entries(from: list()).filter { !excluding.contains($0.windowID) }"))
        #expect(reader.contains("return WindowList.window(at: point, in: entries, excludingPID: noOwner).map(make)"))
        #expect(reader.contains("static let noOwner: Int32 = -1"), "no PaperDeck window is skipped wholesale")
        #expect(!reader.contains("excludingPID: ProcessInfo"), "no PaperDeck window is skipped wholesale")
        #expect(reader.contains("return .reader(paperID: reader.model.paperID, page: reader.model.page)"))
        #expect(!reader.contains("app.processIdentifier != ProcessInfo.processInfo.processIdentifier"),
                "Services from PaperDeck's own reader see that reader")
    }

    @Test func thePipelineReadsTheFullCropKnowsTheReadersPaperAndKeepsTheSentWindows() throws {
        let p = try Self.text("Sources/PaperDeck/Explain/ExplainPipeline.swift")
        #expect(p.contains("let cg = capture.ocrImage ?? ExplainImages.cgImage(captured)"))
        #expect(p.contains("if let known = ExplainPreparation.knownMatch(anchor: anchor, surroundings: capture.surroundings) {"))
        #expect(p.contains("sentUnit = ExplainPreparation.unit(crop, of: size)"))
        #expect(p.contains("surroundings: ExplainPreparation.sentSurroundings(capture.surroundings, sentUnit: sentUnit))"))
        #expect(!p.contains("it never captures until the user draws a box"), "F11: the overlay freezes the screens when it opens")
        let state = try Self.text("Sources/PaperDeckCore/ExplainUI/ExplainPanelState.swift")
        #expect(state.contains("let surroundings = prepared.surroundings ?? capture.surroundings"))
        #expect(state.contains("ExplainPrivacyRules.combine(verdicts, messaging: ExplainPrivacyRules.showsMessaging(capture, surroundings: surroundings))"))
    }

    @Test func theConsentStringsAnswerInBothLanguages() throws {
        let file = "Sources/PaperDeck/App/L10n+explainConsent.swift"
        let source = try Self.text(file)
        // `zh ? "…" : "…"`, on one line or two.
        let re = try NSRegularExpression(pattern: #"zh \? "((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
        let ns = source as NSString
        let pairs = re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            (zh: ns.substring(with: $0.range(at: 1)), en: ns.substring(with: $0.range(at: 2)))
        }
        #expect(pairs.count == source.components(separatedBy: "zh ? ").count - 1 && pairs.count >= 1, "\(pairs.count) pairs")
        for p in pairs {
            #expect(!p.zh.isEmpty && !p.en.isEmpty && p.zh != p.en, "\(p)")
            #expect(p.zh.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }, "\(p.zh)")
            #expect(!p.en.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(p.en)")
        }
        #expect(source.contains("case .setting: return L.Explain.askBeforeSendHint") && source.contains("case .service: return serviceHeldHint"))
        #expect(source.range(of: InstitutionLintTests.pattern, options: [.regularExpression, .caseInsensitive]) == nil)
    }
}
