import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-7 (capture polish): a full-screen capture of a 5K display keeps the overlay's main thread
/// within a frame. Before, `finish` cropped, checked, downscaled and PNG-encoded on the main thread;
/// now the main thread only finds the probe point (and the App reads the window under it), and after
/// the off-main `ExplainImageCrop.run` places the panel and builds the capture. Synthetic stills only.
/// `PAPERDECK_MEASURE=1` also times the old main-thread sequence and the off-main work and prints them.
@Suite struct MainThreadBudgetTests {
    static let frame: Duration = .milliseconds(16)

    static func median(_ runs: Int = 5, _ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<runs { times.append(clock.measure(body)) }
        return times.sorted()[runs / 2]
    }

    static func ms(_ d: Duration) -> String {
        String(format: "%.2f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    /// What the main thread does now around the off-main work for `gesture` (the App adds one window
    /// lookup before and, for a click that reads beyond its band, the windows of the read area after).
    static func mainThreadPart(_ gesture: ExplainImageCrop.Gesture, _ prepared: ExplainImageCrop.Prepared, in s: FrozenScreens) {
        let point = ExplainImageCrop.probe(gesture, in: s)
        let place = CaptureGeometry.placement(prepared.region, click: prepared.click, in: s, mainHeight: 1440)
        let capture = ExplainCapture(source: .region, image: prepared.image, hostBundleID: "com.example.viewer",
                                     windowTitle: "A paper.pdf", focus: prepared.focus, ocrImage: prepared.ocrImage)
        precondition(point != nil && place != nil && capture.image != nil)
    }

    /// The old `finish` on the main thread (build 31): plan (a click), crop, blank check, encode, placement.
    static func oldMainThread(_ gesture: ExplainImageCrop.Gesture, in s: FrozenScreens) {
        switch gesture {
        case .box(let r, _):
            _ = CaptureGeometry.placement(r, click: nil, in: s, mainHeight: 1440)
            guard let crop = CaptureGeometry.crop(s, r), !CaptureFigure.isBlank(crop) else { return }
            _ = ExplainImageEncoder.encode(crop)
            _ = CaptureGeometry.placement(r, click: nil, in: s, mainHeight: 1440)
        case .click(let p, let id, let term, let figure):
            let size = s.display(id)!.frame.size
            let plan = CaptureClickPlan.plan(click: p, displaySize: size, window: nil, term: term, figure: figure) {
                CaptureGeometry.crop(s, CaptureRegion(displayID: id, rect: $0))
            }
            guard case .paragraph(let band, _)? = plan, let crop = CaptureGeometry.crop(s, CaptureRegion(displayID: id, rect: band)) else { return }
            _ = ExplainImageEncoder.encode(crop)
            _ = CaptureGeometry.placement(CaptureRegion(displayID: id, rect: band), click: p, in: s, mainHeight: 1440)
        }
    }

    @Test func aFullScreen5KCaptureKeepsTheMainThreadWithinAFrame() throws {
        let s = PolishKit.screens(try #require(PolishKit.fiveKPage()), size: PolishKit.fiveK)
        let gestures: [(String, ExplainImageCrop.Gesture)] = [
            ("full-screen box", .box(CaptureRegion(displayID: 1, rect: CGRect(origin: .zero, size: PolishKit.fiveK)), figure: false)),
            ("click on text", .click(CGPoint(x: 600, y: 700), displayID: 1, term: false, figure: false)),
        ]
        let measure = ProcessInfo.processInfo.environment["PAPERDECK_MEASURE"] == "1"
        for (name, gesture) in gestures {
            guard case .ready(let prepared) = ExplainImageCrop.prepare(gesture, window: nil, frozen: s) else {
                Issue.record("\(name): not ready")
                continue
            }
            let main = Self.median { Self.mainThreadPart(gesture, prepared, in: s) }
            #expect(main < Self.frame, "\(name): \(Self.ms(main)) on the main thread")
            if measure {
                let old = Self.median(3) { Self.oldMainThread(gesture, in: s) }
                let job = Self.median(3) { _ = ExplainImageCrop.prepare(gesture, window: nil, frozen: s) }
                let read = CaptureGeometry.crop(s, prepared.readArea)!
                let copy = Self.median(3) { _ = ExplainImage.detached(read) }
                print("CUX-7 \(name) 5K: main thread before \(Self.ms(old)), after \(Self.ms(main)); off-main work \(Self.ms(job))"
                      + " (of which an OCR copy of \(read.width)×\(read.height) would take \(Self.ms(copy)))")
            }
        }
    }
}
