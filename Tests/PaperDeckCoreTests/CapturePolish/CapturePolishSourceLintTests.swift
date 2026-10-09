import Foundation
import Testing

/// The App wiring of the capture polish, checked in the sources (the test target doesn't link the
/// app; the work itself is Core's `ExplainImageCrop` / `ExplainFocusResolver.read`, tested in this
/// folder): the overlay's main thread no longer crops, checks or encodes (CUX-7) and closing it
/// cancels the work; a blank capture says so in English and Chinese (CUX-8); a click that reads
/// beyond its band has every window of the read area checked; the pipeline reads the band first.
@Suite("Capture polish: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct CapturePolishSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let overlay = "Sources/PaperDeck/Explain/CaptureOverlayController.swift"
    static let job = "Sources/PaperDeckCore/Explain/ExplainImageCrop.swift"

    /// From `marker` to `end` (exclusive).
    static func slice(_ s: String, from marker: String, to end: String) throws -> String {
        let a = try #require(s.range(of: marker), "\(marker)")
        let b = try #require(s.range(of: end, range: a.upperBound..<s.endIndex), "\(end)")
        return String(s[a.lowerBound..<b.lowerBound])
    }

    @Test func theOverlaysMainThreadNeitherCropsNorEncodes() throws {               // CUX-7
        let o = try Self.text(Self.overlay)
        let finish = try Self.slice(o, from: "    private func finish(_ choice: Choice,", to: "/// The overlay's observable state.")
        for heavy in ["ExplainImageEncoder.encode(", "CaptureClickPlan.plan(", "isBlank(", "CaptureGeometry.crop(", "InkMap(",
                      ".cropping(to:"] {
            #expect(!finish.contains(heavy), "the main thread: \(heavy)")
        }
        #expect(finish.contains("let outcome = await ExplainImageCrop.run(choice, window: window?.bounds, frozen: frozen)"))
        #expect(finish.components(separatedBy: "WindowTitleReader.window(at:").count == 2, "the window under the capture is read once")
        // Only after the work: still open (not cancelled), then the panel.
        let after = try #require(finish.range(of: "guard !Task.isCancelled, let self, self.isShown else { return }"))
        let deliver = try #require(finish.range(of: "self.deliver(outcome,"))
        #expect(after.upperBound < deliver.lowerBound)
        // Closing the overlay cancels it; a gesture meanwhile is ignored (one capture at a time).
        let dismiss = try Self.slice(o, from: "    func dismiss() {", to: "    func toggleMode()")
        #expect(dismiss.contains("finishTask?.cancel()") && dismiss.contains("finishTask = nil"))
        #expect(o.contains("    private func choose(_ choice: Choice, lens: Bool) {\n        guard coordinator != nil, finishTask == nil else { return }"))
        #expect(finish.contains("guard coordinator != nil, finishTask == nil else { return }"))
        // Core's work runs off the caller's actor.
        let j = try Self.text(Self.job)
        #expect(j.contains("    @concurrent\n    package static func run(_ gesture: Gesture, window: CGRect?, frozen: FrozenScreens) async -> Outcome {"))
        #expect(j.contains("prepare(gesture, window: window, frozen: frozen) { Task.isCancelled }"))
        #expect(j.contains("let ocrImage = copyFreesTheStill(read, of: frozen.display(readArea.displayID)) ? (ExplainImage.detached(read) ?? read) : read"),
                "the still isn't kept by the OCR copy")
    }

    @Test func aBlankCaptureSaysSoInBothLanguages() throws {                         // CUX-8
        let o = try Self.text(Self.overlay)
        #expect(o.contains("case .blank:\n            say(.blankCapture)\n            return"))
        #expect(o.contains("case .nothingLegible:\n            say(.nothingLegible)\n            return"))
        let re = try NSRegularExpression(pattern: #"L\.lang == \.zh \? "((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
        let ns = o as NSString
        let pairs = re.matches(in: o, range: NSRange(location: 0, length: ns.length)).map {
            (zh: ns.substring(with: $0.range(at: 1)), en: ns.substring(with: $0.range(at: 2)))
        }
        let blank = try #require(pairs.first { $0.en.contains("came back blank") }, "\(pairs)")
        #expect(blank.en.contains("Nothing was sent") && blank.en.contains("DRM") && blank.en.contains("sleeping display"))
        #expect(blank.zh.contains("空白") && blank.zh.contains("未发送"))
        #expect(blank.zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        #expect(!blank.en.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        // The chip shows the notice's own text, not always "nothing legible".
        let view = try Self.text("Sources/PaperDeck/Explain/CaptureOverlayView.swift")
        #expect(view.contains("Label(notice.text, systemImage: notice.symbol)"))
        #expect(!view.contains("Label(L.ExplainUX.nothingLegible"))
        // The safeguard is ExplainImage.isBlank, before anything is encoded.
        let j = try Self.text(Self.job)
        let check = try #require(j.range(of: "if focus == nil, ExplainImage.isBlank(crop) { return .blank }"))
        let encode = try #require(j.range(of: "guard let image = ExplainImageEncoder.encode(crop) else { return .failed }"))
        #expect(check.upperBound < encode.lowerBound)
    }

    @Test func aClickReadingBeyondItsBandHasEveryWindowOfItChecked() throws {          // CUX-8, F1
        let o = try Self.text(Self.overlay)
        let deliver = try Self.slice(o, from: "    private func deliver(", to: "/// The overlay's observable state.")
        let surroundings = try #require(deliver.range(of: "if p.readsBeyondRegion, let area = CaptureGeometry.global(p.readArea, in: frozen) {"))
        #expect(deliver.contains("capture.surroundings = WindowTitleReader.surroundings(region: area, point: point, excluding: Set(coordinator.ownWindowIDs),"))
        #expect(deliver.contains("own: ExplainOwnWindows.roles(state: coordinator.app))"))
        // Read while the overlay's windows are still listed (and left out), before the panel opens.
        let dismiss = try #require(deliver.range(of: "        dismiss()\n"))
        let begin = try #require(deliver.range(of: "coordinator.begin(capture: capture, ticket: ticket, anchor: nil, kind: p.kind, near: place.near"))
        #expect(surroundings.upperBound < dismiss.lowerBound && dismiss.upperBound < begin.lowerBound)
        // The panel still opens beside the band (`region`), not the larger read area.
        #expect(deliver.contains("CaptureGeometry.placement(p.region, click: p.click, in: frozen, mainHeight: mainHeight)"))
    }

    @Test func thePipelineReadsTheBandFirst() throws {                               // CUX-8
        let p = try Self.text("Sources/PaperDeck/Explain/ExplainPipeline.swift")
        #expect(p.contains("let hit = await ExplainFocusResolver.read(focus, imageSize: size) { rect in await Self.recognize(cg, in: rect) }"))
        // A box still reads the whole crop once.
        #expect(p.contains("let ocr = try? await OCREngine.recognize(cg, languages: Self.ocrLanguages, customWords: [])"))
        #expect(p.components(separatedBy: "OCREngine.recognize(").count == 3, "the box's read and the click's parts")
    }

    @Test func theUnusedGeometryHelpersAreGone() throws {
        let g = try Self.text("Sources/PaperDeckCore/Explain/CaptureGeometry.swift")
        for gone in ["func expand(", "func cropPixel(", "func region(dragFrom", "lensExpansion", "func displayLocal("] {
            #expect(!g.contains(gone), "\(gone)")
        }
        #expect(try LintRepo.grep(#"CaptureGeometry\.(expand|cropPixel|displayLocal)\(|region\(dragFrom"#).isEmpty)
    }
}
