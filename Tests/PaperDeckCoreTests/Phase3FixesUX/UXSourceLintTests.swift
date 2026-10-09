import Foundation
import Testing

/// The App wiring of the capture / panel fixes, checked in the sources (the test target doesn't link
/// the app; the decisions themselves are Core types tested in this folder): the overlay plans clicks
/// with `CaptureClickPlan` and refuses blank crops, follows the system (CUX-3), uses the pure key
/// rules (CUX-10) and the HUD rules (CUX-14); the panel shows exactly what is sent (F3), grows with
/// `PanelPlacement.refit` on its side (CUX-5), offers "Not this paper" / Change… (CUX-6); the
/// shortcut line is live (CUX-9); every new string has English and Chinese.
@Suite("Phase 3 fixes (UX): sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct UXSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let explain = "Sources/PaperDeck/Explain"

    static func body(_ source: String, after marker: String, length: Int = 2_400) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker)")
        return String(source[start.upperBound...].prefix(length))
    }

    @Test func aClickIsPlannedFromThePixelsAndABlankCropIsNeverSent() throws {      // F3, CUX-8
        let o = try Self.text("\(Self.explain)/CaptureOverlayController.swift")
        let finish = try Self.body(o, after: "    private func finish(_ choice: Choice,", length: 5_000)
        // The window under the capture bounds a click's band; the plan, the crop, the blank check and the
        // encoding are Core's `ExplainImageCrop`, run off the main thread (capture-polish CUX-7).
        #expect(finish.contains("let window = WindowTitleReader.window(at: point)"))
        #expect(finish.contains("let outcome = await ExplainImageCrop.run(choice, window: window?.bounds, frozen: frozen)"))
        #expect(finish.contains("case .nothingLegible:\n            say(.nothingLegible)\n            return"))
        let blank = try #require(finish.range(of: "case .blank:\n            say(.blankCapture)\n            return"))
        let begin = try #require(finish.range(of: "coordinator.begin(capture: capture"))
        #expect(blank.upperBound < begin.lowerBound)
        let job = try Self.text("Sources/PaperDeckCore/Explain/ExplainImageCrop.swift")
        #expect(job.contains("CaptureClickPlan.plan(click: p, displaySize: d.frame.size, window: under, term: term, figure: figure, crop: crop)"))
        #expect(job.contains("let under = window.map { $0.standardized.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY) }"))
        #expect(job.contains("case .figure(let rect)?:") && job.contains("return flat ? .blank : .nothingLegible"))
        let check = try #require(job.range(of: "if focus == nil, ExplainImage.isBlank(crop) { return .blank }"))
        let encode = try #require(job.range(of: "ExplainImageEncoder.encode(crop)"))
        #expect(check.upperBound < encode.lowerBound)
        // No path sends the band with no focus any more (the old `focus = figure ? nil : …` on the band).
        #expect(!o.contains("let focus = figure ? nil : ExplainFocus(local: local, in: band, term: term)"))
        #expect(!o.contains("CaptureGeometry.band(around:"), "the band comes from CaptureClickPlan only")
    }

    @Test func theOverlayFollowsTheSystemAndThePureKeyRules() throws {                // CUX-3, CUX-10
        let o = try Self.text("\(Self.explain)/CaptureOverlayController.swift")
        for name in ["NSWorkspace.activeSpaceDidChangeNotification", "NSWorkspace.screensDidSleepNotification",
                     "NSWorkspace.sessionDidResignActiveNotification", "NSApplication.didChangeScreenParametersNotification"] {
            #expect(o.contains(name), "\(name)")
        }
        #expect(o.contains("guard isShown, CaptureOverlayLifecycle.reaction(to: event) == .dismiss else { return }"))
        let show = try Self.body(o, after: "    func show(mode: AssistSettings.OverlayMode) {", length: 3_200)
        #expect(show.contains("openedDisplays = Self.displays()") && show.contains("observeSystem()"))
        let dismiss = try Self.body(o, after: "    func dismiss() {", length: 200)
        #expect(dismiss.hasPrefix("\n        stopObservingSystem()"))
        // Keys: the Core rules, with Tab from the language in effect.
        #expect(o.contains("switch CaptureOverlayKeys.action(keyCode: Int(e.keyCode), isRepeat: e.isARepeat) {"))
        #expect(o.contains("CaptureOverlayKeys.language(afterTab: model.language, setting: assist.explainLanguage, ui: L.lang)"))
        #expect(!o.contains("ExplainLanguageToggle.toggled(model.language ?? .zh)"))
    }

    @Test func theHUDStepsAsideAndHidesWhileDrawing() throws {                        // CUX-14
        let v = try Self.text("\(Self.explain)/CaptureOverlayView.swift")
        #expect(v.contains("if model.hudEdge == .top { hudSlot }") && v.contains("if model.hudEdge == .bottom { hudSlot }"))
        #expect(v.contains("let shown = CaptureHUD.isShown(dragging: model.dragging)") && v.contains(".allowsHitTesting(shown)"))
        #expect(!v.contains(".padding(.top, 36)"))
        let layer = try Self.text("\(Self.explain)/CaptureLayerView.swift")
        #expect(layer.contains("controller?.pointerMoved(p, on: layer.displayID)"))
        #expect(layer.contains("controller?.dragChanged(layerModel?.box != nil)"))
        let o = try Self.text("\(Self.explain)/CaptureOverlayController.swift")
        #expect(o.contains("let edge = CaptureHUD.edge(current: model.hudEdge, cursor: local, displaySize: size, topInset: model.hudTopInset)"))
    }

    @Test func thePanelShowsWhatIsSentAndGrowsOnItsSide() throws {                    // F3, CUX-5, CUX-14
        let v = try Self.text("\(Self.explain)/ExplainPanelView.swift")
        #expect(v.contains("if let image = Self.shownImage(state), let ns = ExplainImages.thumbnail(image) {"))
        #expect(!v.contains("state.capture.image ?? state.prepared?.image"), "the band was shown as if it were sent")
        #expect(v.contains("if let p = state.prepared { return p.image ?? (state.capture.focus == nil ? state.capture.image : nil) }"))
        #expect(v.contains("L.ExplainUX.willBeSent : L.ExplainUX.textOnlySent"))
        let c = try Self.text("\(Self.explain)/ExplainPanelController.swift")
        #expect(c.contains("placement = (anchor, placed.side, vf)"))
        #expect(c.contains("let next = PanelPlacement.refit(f, side: p.side, anchor: p.anchor, height: h, visibleFrame: p.visibleFrame)"))
        #expect(!c.contains("f.origin.y += f.height - h"), "the old top-fixed growth that covered the selection")
    }

    @Test func aWrongPaperCanBeCorrectedFromThePanel() throws {                       // CUX-6
        let v = try Self.text("\(Self.explain)/ExplainPanelView.swift")
        #expect(v.contains("ExplainMatchLine(state: state, app: app) {\n                            actions.explainAgain(ConsentTicket.mint(.retry, surface: .explain))"))
        let m = try Self.text("\(Self.explain)/ExplainPanelView+Match.swift")
        #expect(m.contains("PaperMatchCorrections.shared.reject(id, windowTitle: state.capture.windowTitle, excerpt: state.excerpt,"))
        #expect(m.contains("PaperMatchCorrections.shared.choose(id, windowTitle: state.capture.windowTitle, excerpt: state.excerpt,"))
        #expect(m.contains("Task { try? await app.engine.assignExplanation(id: id, paperID: paperID) }"))
        #expect(!m.contains("ConsentTicket"), "the match line never mints; the panel view's click does")
        let c = try Self.text("\(Self.explain)/ExplainPanelController.swift")
        #expect(c.contains("explainAgain: { [weak self] ticket in self?.explainAgain(ticket: ticket) })"))
        #expect(c.contains("coordinator.begin(capture: s.capture, ticket: ticket, anchor: nil,"))
    }

    @Test func theShortcutLineIsLive() throws {                                      // CUX-9
        let rec = try Self.text("\(Self.explain)/HotKeyRecorderView.swift")
        #expect(rec.contains("private var status: HotKeyRegistration? { Self.previewStatus ?? ExplainBootstrap.coordinator?.hotKeyStatus }"))
        #expect(!rec.contains("@State private var status"), "a copy taken on appear went stale when the switch flipped")
        #expect(!rec.contains("status = "), "nothing caches the status")
    }

    @Test func everyNewStringHasDistinctEnglishAndChinese() throws {
        let source = try Self.text("\(Self.explain)/ExplainPanelView+Strings.swift")
        let pairs = ReaderSourceLintTests.pairs(source)
        #expect(pairs.count >= 15, "\(pairs.count) pairs")
        for p in pairs {
            #expect(!p.zh.isEmpty && !p.en.isEmpty && p.zh != p.en, "\(p)")
            #expect(p.zh.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }, "\(p.zh)")
            #expect(!p.en.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(p.en)")
        }
        let accessors = source.components(separatedBy: "\n").filter { $0.contains("static var ") || $0.contains("static func ") }
            .filter { !$0.contains("private static var zh") && !$0.contains("static var all: [String]") }
        for line in accessors where !line.contains("zh ?") {
            let start = try #require(source.range(of: line))
            #expect(source[start.upperBound...].prefix(300).contains("zh ?"), "\(line)")
        }
        // Every string the new views use comes from here (no inline English).
        for file in ["ExplainPanelView+Match.swift", "CaptureOverlayView.swift"] {
            let s = try Self.text("\(Self.explain)/\(file)")
            #expect(s.range(of: #"Text\("[A-Za-z]"#, options: .regularExpression) == nil, "\(file)")
            #expect(s.range(of: #"Button\("[A-Za-z]"#, options: .regularExpression) == nil, "\(file)")
        }
    }
}
