import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-11 (a ⇧-click term on Chinese text is a whole word), CUX-12 (window titles with full-width
/// page counters and Edge's "and N more pages" before a profile name) and CUX-13 (the surviving
/// mutations: the window list's layer filter, the punctuation trim on clicked words, and the overlay's
/// geometry moved into Core).
@Suite struct TextAndTitleTests {
    // MARK: CUX-11

    static let zh = "注意力机制使模型关注重要的位置"

    /// One line of `text` across 0…`width` px with no word boxes (the fallback request's shape).
    static func line(_ text: String, width: CGFloat = 1500, words: [OCRWord] = []) -> OCRResult {
        let l = OCRLine(text: text, box: CGRect(x: 0, y: 0, width: width, height: 30), confidence: 0.9, words: words)
        return OCRResult(lines: [l], paragraphs: [OCRParagraph(text: text, box: l.box, lineIndices: [0])], text: text,
                         meanConfidence: 0.9)
    }

    /// The x of character `i`'s centre on a line of `n` characters `width` px wide.
    static func x(_ i: Int, of n: Int, width: CGFloat = 1500) -> CGFloat { (CGFloat(i) + 0.5) * width / CGFloat(n) }

    @Test func probeP8bAClickOnAChineseLineTakesAWholeWord() throws {
        let n = Self.zh.count
        // 机 is character 3: probe P8b got 力机制使 (a fixed window across two words).
        let word = try #require(OCRPostProcess.word(at: CGPoint(x: Self.x(3, of: n), y: 15), in: Self.line(Self.zh)))
        #expect(word != "力机制使")
        #expect(["机制", "注意力机制"].contains(word), "\(word)")
        // Every pick is a whole word of the line, holding the clicked character.
        let chars = Array(Self.zh)
        for i in 0..<n {
            let w = try #require(OCRPostProcess.word(at: CGPoint(x: Self.x(i, of: n), y: 15), in: Self.line(Self.zh)), "\(i)")
            #expect(Self.zh.contains(w) && w.contains(chars[i]), "\(i): \(w)")
        }
        // 位置 at the end, 模型 in the middle.
        #expect(OCRPostProcess.word(at: CGPoint(x: Self.x(13, of: n), y: 15), in: Self.line(Self.zh)) == "位置")
        #expect(OCRPostProcess.word(at: CGPoint(x: Self.x(6, of: n), y: 15), in: Self.line(Self.zh)) == "模型")
    }

    @Test func aChineseRunInOneWordBoxIsSegmentedToo() throws {
        // A document request may give a whole Chinese run as one "word".
        let run = OCRWord(text: Self.zh, box: CGRect(x: 100, y: 0, width: 1500, height: 30))
        let ocr = Self.line("Transformer " + Self.zh, width: 1600,
                            words: [OCRWord(text: "Transformer", box: CGRect(x: 0, y: 0, width: 90, height: 30)), run])
        let w = try #require(OCRPostProcess.word(at: CGPoint(x: 100 + Self.x(6, of: Self.zh.count), y: 15), in: ocr))
        #expect(w == "模型", "\(w)")
        #expect(OCRPostProcess.word(at: CGPoint(x: 40, y: 15), in: ocr) == "Transformer")
        // Mixed text without word boxes: the Latin word stays whole.
        let mixed = "我们使用Transformer模型"
        let m = try #require(OCRPostProcess.word(at: CGPoint(x: Self.x(6, of: mixed.count), y: 15), in: Self.line(mixed)))
        #expect(m == "Transformer", "\(m)")
        #expect(OCRPostProcess.cjkWord(in: Self.zh, at: 99) == nil)
    }

    // MARK: CUX-12

    @Test func probeP9FullWidthPageCountersAndEdgeTabGroups() {
        let cjk = WindowTitle.parse("注意力机制综述.pdf（第 2 页，共 9 页）")
        #expect(cjk.cleaned == "注意力机制综述" && cjk.fileName == "注意力机制综述.pdf" && cjk.page == 2, "\(cjk)")
        let ascii = WindowTitle.parse("注意力机制综述.pdf (第 2 页，共 9 页)")
        #expect(ascii.fileName == "注意力机制综述.pdf" && ascii.page == 2)
        let lone = WindowTitle.parse("注意力机制综述.pdf（第 3 页）")
        #expect(lone.fileName == "注意力机制综述.pdf" && lone.page == 3, "\(lone)")
        #expect(WindowTitle.normalize("Title and 3 more pages - Work - Microsoft Edge") == "Title")
        #expect(WindowTitle.normalize("Attention Is All You Need and 1 more page - Personal - Microsoft\u{200B} Edge")
                == "Attention Is All You Need")
        #expect(WindowTitle.normalize("Attention Is All You Need and 12 more pages - Microsoft Edge") == "Attention Is All You Need")
        #expect(WindowTitle.normalize("注意力机制综述 和另外 3 个页面 - 个人 - Microsoft Edge") == "注意力机制综述")
        // Unchanged: a plain Edge title and one whose own text has "more".
        #expect(WindowTitle.normalize("Learning More with Less Data - Microsoft Edge") == "Learning More with Less Data")
    }

    // MARK: CUX-13

    @Test func aPointUnderTheMenuBarStillFindsTheWindowBelowIt() {
        let entries = [
            WindowList.Entry(windowID: 1, ownerPID: 50, ownerName: "SystemUIServer", title: "Menubar",
                             bounds: CGRect(x: 0, y: 0, width: 1440, height: 25), layer: 25),
            WindowList.Entry(windowID: 2, ownerPID: 60, ownerName: "Dock", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 20),
            WindowList.Entry(windowID: 3, ownerPID: 70, ownerName: "Preview", title: "paper.pdf",
                             bounds: CGRect(x: 0, y: 0, width: 900, height: 700)),
        ]
        #expect(WindowList.window(at: CGPoint(x: 100, y: 10), in: entries, excludingPID: 99)?.windowID == 3)
        // Off every normal window: nothing (the Dock's full-screen layer doesn't count).
        #expect(WindowList.window(at: CGPoint(x: 1200, y: 800), in: entries, excludingPID: 99) == nil)
        #expect(WindowList.frontmostWindow(ofPID: 70, in: entries)?.windowID == 3)
    }

    @Test func aClickedWordLosesItsTrailingPunctuation() {
        let words = [OCRWord(text: "the", box: CGRect(x: 0, y: 0, width: 40, height: 30)),
                     OCRWord(text: "softmax", box: CGRect(x: 50, y: 0, width: 110, height: 30)),
                     OCRWord(text: "becomes.", box: CGRect(x: 170, y: 0, width: 120, height: 30)),
                     OCRWord(text: "(tau),", box: CGRect(x: 300, y: 0, width: 80, height: 30))]
        let ocr = Self.line("the softmax becomes. (tau),", width: 400, words: words)
        #expect(OCRPostProcess.word(at: CGPoint(x: 200, y: 15), in: ocr) == "becomes")
        #expect(OCRPostProcess.word(at: CGPoint(x: 330, y: 15), in: ocr) == "tau")
        #expect(OCRPostProcess.word(at: CGPoint(x: 100, y: 15), in: ocr) == "softmax")
    }

    @Test func theOverlaysGeometryIsPureAndRight() throws {
        let still = try #require(UXKit.display(CGSize(width: 10, height: 10)))
        // A secondary display left of and above the main one (Quartz: negative origin).
        let screens = FrozenScreens(displays: [
            FrozenDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, image: still),
            FrozenDisplay(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1, image: still),
        ])
        let box = CaptureRegion(displayID: 2, rect: CGRect(x: 100, y: 50, width: 300, height: 200))
        let p = try #require(CaptureGeometry.placement(box, click: nil, in: screens, mainHeight: 900))
        #expect(p.global == CGRect(x: -1820, y: -150, width: 300, height: 200))
        #expect(p.probe == CGPoint(x: -1670, y: -50))                         // the box's centre
        #expect(p.near == CGRect(x: -1820, y: 850, width: 300, height: 200))  // Cocoa: 900 − (−150 + 200)
        // A click probes the click, not the centre of its band.
        let click = try #require(CaptureGeometry.placement(box, click: CGPoint(x: 120, y: 60), in: screens, mainHeight: 900))
        #expect(click.probe == CGPoint(x: -1800, y: -140))
        #expect(CaptureGeometry.placement(CaptureRegion(displayID: 7, rect: .zero), click: nil, in: screens, mainHeight: 900) == nil)
    }
}
