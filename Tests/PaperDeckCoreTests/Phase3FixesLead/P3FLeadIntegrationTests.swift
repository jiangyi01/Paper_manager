import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Phase-3 fixes, the lead's integration of the requests neither fix lane owned
/// (`scratchpad/p3f-requests.md`): PR-4 (the Screen Recording explainer's Continue never puts System
/// Settings over macOS's own first prompt), PR-5 (the explainer says when the screen is frozen),
/// R-UX-7 (the capture / panel fixes' render states are drawn), the click comment in
/// `LiveExplainServices.prepare`, and a regression of CUX-6 found in verification: "Not this paper"
/// on a refused card sent a never-AI paper's capture with one click (`ExplainCorrectionRules`). The decision is Core's (`ScreenPermissionFlow`) and tested for
/// real; the App wiring and the strings are pinned in the sources (the test target doesn't link the app).
@Suite("Phase 3 fixes: lead integration")
struct P3FLeadIntegrationTests {
    // MARK: PR-4 (F11): one dialog at a time

    @Test func theFirstContinueOnlyAsksMacOS() {
        // macOS's prompt is up and `request()` answered false: nothing else opens.
        #expect(!ScreenPermissionFlow.opensSettings(granted: false, requestedBefore: false))
    }

    @Test func aLaterContinueWithAccessStillOffOpensSystemSettings() {
        #expect(ScreenPermissionFlow.opensSettings(granted: false, requestedBefore: true))
    }

    @Test func grantedNeverOpensSystemSettings() {
        #expect(!ScreenPermissionFlow.opensSettings(granted: true, requestedBefore: false))
        #expect(!ScreenPermissionFlow.opensSettings(granted: true, requestedBefore: true))
    }

    @Test func theRequestMarkerIsNotedOnceAndRemembered() {
        let scratch = ScratchDefaults("p3f-lead-screen-request")
        defer { scratch.drop() }
        #expect(ScreenPermissionFlow.noteRequest(in: scratch.defaults) == false, "the first Continue: never asked before")
        #expect(scratch.defaults.bool(forKey: ScreenPermissionFlow.requestedKey))
        #expect(ScreenPermissionFlow.noteRequest(in: scratch.defaults) == true, "a later Continue: asked before")
        // The first Continue then the second, end to end with the rule.
        let fresh = ScratchDefaults("p3f-lead-screen-request-2")
        defer { fresh.drop() }
        let first = ScreenPermissionFlow.noteRequest(in: fresh.defaults)
        #expect(!ScreenPermissionFlow.opensSettings(granted: false, requestedBefore: first))
        let second = ScreenPermissionFlow.noteRequest(in: fresh.defaults)
        #expect(ScreenPermissionFlow.opensSettings(granted: false, requestedBefore: second))
    }

    @Test func theMarkerIsNeverASettingSoNeverExportedOrImported() {
        #expect(!SettingsRegistry.entries.contains { $0.key == ScreenPermissionFlow.requestedKey })
        #expect(!AssistSettings.Keys.all.contains(ScreenPermissionFlow.requestedKey))
    }

    // MARK: CUX-6 regression: a correction is never the click past a privacy refusal

    @Test func aRefusedCardNeverOffersACorrection() {
        // "Not this paper" / "Change…" explain again at once with the click's ticket: on these cards
        // that click would send a never-AI paper's capture, or skip the confirmation.
        #expect(!ExplainCorrectionRules.canCorrect(.refused(.blocked)))
        #expect(!ExplainCorrectionRules.canCorrect(.refused(.confirmPrivacy([.markedConfidential]))))
        #expect(!ExplainCorrectionRules.canCorrect(.refused(.confirmPrivacy([.messagingHost]))))
        #expect(!ExplainCorrectionRules.canCorrect(.refused(.privacyUnchecked)))
        // Nor while a turn runs.
        for busy in [ExplainPhase.locating, .sending(.starting), .streaming, .capturing] {
            #expect(!ExplainCorrectionRules.canCorrect(busy), "\(busy)")
        }
    }

    @Test func anAnsweredOrOtherwiseHeldCardOffersTheCorrection() {
        for phase in [ExplainPhase.done, .idle, .error(.timeout), .refused(.askBeforeSend), .refused(.softCap(50)),
                      .refused(.emptyCapture), .refused(.expired), .limited(until: nil)] {
            #expect(ExplainCorrectionRules.canCorrect(phase), "\(phase)")
        }
    }
}

/// PaperDeck's own mail inbox (the library's Mail section) is a mail window (found in verification:
/// F2 made PaperDeck's windows part of the lookup, but the library there reported its paper
/// selection, so a box over an e-mail's full text was sent without the mail confirmation).
@MainActor
@Suite("Phase 3 fixes: PaperDeck's own mail inbox asks first", .serialized, .timeLimit(.minutes(1)))
struct P3FLeadOwnMailTests {
    typealias K = ExplainUITestKit
    static let ownPID: Int32 = 100

    @Test func theInboxIsAMailWindow() {
        #expect(CaptureSurroundings.Host(bundleID: "com.yijiang.paperdeck", title: "Mail", shows: .mail).isMessaging)
        #expect(!CaptureSurroundings.Host(bundleID: "com.yijiang.paperdeck", title: "Mail", shows: .papers(["p"])).isMessaging)
        #expect(CaptureSurroundings(hosts: [.init(bundleID: "com.yijiang.paperdeck", shows: .mail)], primary: 0).shownPaperIDs.isEmpty)
    }

    /// A box over the library while it shows an e-mail: the messaging confirmation, nothing sent.
    @Test func aBoxOverTheInboxAsksFirstAndSendsNothing() async throws {
        let library = WindowList.Entry(windowID: 7, ownerPID: Self.ownPID, ownerName: "PaperDeck", title: "Mail",
                                       bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let s = CaptureSurroundings.make(region: CGRect(x: 900, y: 200, width: 400, height: 300), entries: [library], excluding: [],
                                         ownPID: Self.ownPID, ownBundleID: "com.yijiang.paperdeck", own: [7: .mail],
                                         bundleID: { _ in nil })
        #expect(s.showsMessaging)
        let w = try await K.world()
        defer { Task { await w.close() } }
        let capture = ExplainCapture(source: .region, text: K.excerpt, hostBundleID: "com.yijiang.paperdeck", windowTitle: "Mail",
                                     surroundings: s)
        let panel = K.panel(K.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
    }

    /// Text copied (or sent through Services) from the inbox: the front window is the library showing mail.
    @Test func textFromTheInboxAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings.text([.init(bundleID: "com.yijiang.paperdeck", title: "Mail", shows: .mail)])
        let capture = ExplainCapture(source: .clipboard, text: K.excerpt, hostBundleID: "com.yijiang.paperdeck", surroundings: s)
        let panel = K.panel(K.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.clipboard))
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
    }
}

/// The App side of the lead's integration, pinned in the sources.
@Suite("Phase 3 fixes: lead integration wiring (sources)", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P3FLeadIntegrationSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    /// PR-4: Continue notes the request before asking and opens System Settings only by the rule.
    @Test func theExplainersContinueOpensSettingsOnlyByTheRule() throws {
        let s = try Self.text("Sources/PaperDeck/Explain/ScreenPermission.swift")
        let start = try #require(s.range(of: "onContinue: {"))
        let end = try #require(s.range(of: "onCancel: close", range: start.upperBound..<s.endIndex))
        let body = String(s[start.upperBound..<end.lowerBound])
        let note = try #require(body.range(of: "let requestedBefore = ScreenPermissionFlow.noteRequest(in: .standard)"))
        let ask = try #require(body.range(of: "await capturer.request()"))
        let rule = try #require(body.range(of: "if ScreenPermissionFlow.opensSettings(granted: granted, requestedBefore: requestedBefore) {"))
        let open = try #require(body.range(of: "openSystemSettings()"))
        #expect(note.upperBound <= ask.lowerBound && ask.upperBound <= rule.lowerBound && rule.upperBound <= open.lowerBound)
        #expect(body.components(separatedBy: "openSystemSettings()").count == 2, "System Settings opens in one place only")
        #expect(body.range(of: #"if\s*!\s*granted"#, options: .regularExpression) == nil, "the old 'any false opens Settings'")
    }

    /// PR-5: the explainer says the overlay freezes each display when it opens (memory only).
    @Test func theExplainerSaysWhenTheScreenIsFrozen() throws {
        let s = try Self.text("Sources/PaperDeck/App/L10n+explain.swift")
        let start = try #require(s.range(of: "static var explainerCaptured: String {"))
        let end = try #require(s.range(of: "static var explainerSent", range: start.upperBound..<s.endIndex))
        let body = String(s[start.upperBound..<end.lowerBound])
        #expect(!body.contains("only at the moment you draw it"))
        #expect(!body.contains("只在你画框的那一刻"))
        #expect(body.contains("One still of each display while the overlay is open, in memory only; only the part you mark is used."))
        #expect(body.contains("遮罩打开时给每块屏幕定格一张画面，只留在内存里；只用你框选或点到的那部分。"))
    }

    /// R-UX-7: the capture / panel fixes' states are drawn by `--explain-render`, over the fixture still.
    @Test func theRenderToolDrawsTheCaptureFixStates() throws {
        let s = try Self.text("Sources/PaperDeck/CLI/ExplainRenders.swift")
        let block = try #require(s.range(of: "if let still = Fixture.screen(size: screen) {"))
        let hook = try #require(s.range(of: "try await ExplainUXRenders.draw(state: state, paperID: main, excerpt: excerpt, appearance: appearance, png: png)"))
        let explainer = try #require(s.range(of: "ScreenRecordingExplainer()"))
        #expect(block.upperBound <= hook.lowerBound && hook.upperBound <= explainer.lowerBound)
        #expect(s.components(separatedBy: "ExplainUXRenders.draw(").count == 2)
    }

    /// CUX-6 regression: the match line's corrections follow `ExplainCorrectionRules` (both buttons
    /// disabled by it, both handlers guarded by it).
    @Test func theMatchLineCorrectsOnlyWhenTheRuleAllows() throws {
        let m = try Self.text("Sources/PaperDeck/Explain/ExplainPanelView+Match.swift")
        #expect(m.components(separatedBy: ".disabled(!ExplainCorrectionRules.canCorrect(state.phase) || app == nil)").count == 3)
        #expect(!m.contains(".disabled(state.isRunning"), "the old rule let a refused card correct (and send)")
        for handler in ["private func notThisPaper(_ id: String) {", "private func choose(_ id: String) {"] {
            let start = try #require(m.range(of: handler))
            let next = m[start.upperBound...].prefix(120)
            #expect(next.contains("guard let app, ExplainCorrectionRules.canCorrect(state.phase) else { return }"), "\(handler)")
        }
    }

    /// The library window in its Mail section reports `.mail` (before its paper selection).
    @Test func theLibrarysMailSectionIsReportedAsMail() throws {
        let r = try Self.text("Sources/PaperDeck/Explain/Capture/WindowTitleReader.swift")
        let start = try #require(r.range(of: "case ActivationPolicy.library?:"))
        let body = String(r[start.upperBound...].prefix(600))
        let mail = try #require(body.range(of: "if state.sidebar == .mail { return .mail }"))
        let papers = try #require(body.range(of: "return ids.isEmpty ? nil : .papers(ids)"))
        #expect(mail.upperBound <= papers.lowerBound)
    }

    /// Mutation survivors of the verification, pinned: the overlay hands the full-resolution crop to
    /// local OCR (CUX-7: without `ocrImage` OCR reads the ≤1568 px image that may be sent), and
    /// `begin` adds who was on screen to every capture that arrives without it (F1 / F2: an early
    /// return there would send every capture with no mail / reader check).
    @Test func theOverlayHandsOCRTheFullCropAndBeginAlwaysAddsTheSurroundings() throws {
        let o = try Self.text("Sources/PaperDeck/Explain/CaptureOverlayController.swift")
        #expect(o.contains("windowTitle: window?.title, focus: p.focus, ocrImage: p.ocrImage)"))
        // The crop is made off the main thread (CUX-7, capture-polish): Core's `ExplainImageCrop`.
        let job = try Self.text("Sources/PaperDeckCore/Explain/ExplainImageCrop.swift")
        #expect(job.contains("guard let crop = CaptureGeometry.crop(frozen, region) else {"))
        let c = try Self.text("Sources/PaperDeck/Explain/ExplainCoordinator.swift")
        let start = try #require(c.range(of: "private func withSurroundings(_ capture: ExplainCapture, near rect: CGRect?) -> ExplainCapture {\n"))
        let first = c[start.upperBound...].prefix { $0 != "\n" }
        #expect(first.trimmingCharacters(in: .whitespaces) == "guard capture.surroundings == nil else { return capture }", "\(first)")
        #expect(c.components(separatedBy: "return capture").count == 2, "one early return (a capture that already has them)")
    }

    /// The click comment in `prepare` names what is sent now (F3), not "the band as a figure".
    @Test func thePrepareCommentNamesWhatAClickSends() throws {
        let s = try Self.text("Sources/PaperDeck/Explain/ExplainPipeline.swift")
        #expect(!s.contains("the band as a figure"))
        // Nothing readable under the click → the fallback (`ExplainFocusResolver.unresolved`, now inside
        // Core's two-pass `read`, capture-polish CUX-8).
        #expect(s.contains("(`ExplainFocusResolver.unresolved`), never the whole band."))
        #expect(s.contains("let hit = await ExplainFocusResolver.read(focus, imageSize: size) { rect in await Self.recognize(cg, in: rect) }"))
    }
}
