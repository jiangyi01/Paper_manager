import CoreGraphics
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import PaperDeckCore

/// The intermittent "-[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: NSFont)"
/// crash: an uncaught NSException inside PDFKit's `attributedString` (the title heuristic) that
/// killed full test runs under load. It shows when the title is read while other threads open,
/// read, draw or release documents with the same fonts, most often for fonts the process hasn't
/// used yet.
///
/// This test sets that up on purpose. The PDFs name installed fonts without embedding them, two
/// fonts per PDF and each font in one PDF. Every PDF is read by two production paths at once. One
/// is the import's whole extraction (page text, title from fonts, thumbnail, outline). The other
/// reads the card's title and draws its thumbnail, then runs one of: the reader's find; Q&A's page
/// text and labels; the reader window's open, quote, title and region render; or a thumbnail again.
///
/// With only the title read locked (the old design), the full pass (`PAPERDECK_PDFKIT_STRESS=full`:
/// every installed font, 8 threads) crashed the test process in about 1 run in 10. A standalone
/// build of the same pattern crashed in about half its runs. With every path going through
/// `PDFKitGate`, it has to finish. A lighter pass (`PAPERDECK_PDFKIT_STRESS=light`): 160 fonts on 4
/// threads. Bounded either way: one pass over the fonts, and no new work after 10 s (full: 45 s).
///
/// Opt-in, run alone (`PAPERDECK_PDFKIT_STRESS=light ./test.sh --filter PDFKitGateStressTests`):
/// inside a full run it held the gate 14–59 s while the rest of the suite waited on it, tripled the
/// suite's time (23 s → 51–86 s) and made unrelated timing tests flaky (integration, Oct 2026). Under
/// the overnight build guard (background QoS) it didn't catch even a gate that locks nothing, so
/// the lint and unit tests (`PDFKitGateLintTests`, `PDFKitGateAppLintTests`, `PDFKitGateTests`,
/// `PDFKitExceptionTests`) are what guard the gate in a normal run.
@Suite(.serialized) struct PDFKitGateStressTests {
    static let mode = ProcessInfo.processInfo.environment["PAPERDECK_PDFKIT_STRESS"]
    static let full = mode == "full"
    static let enabled = mode == "full" || mode == "light"

    private final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        func take(below limit: Int) -> Int? {
            lock.withLock {
                guard next < limit else { return nil }
                defer { next += 1 }
                return next
            }
        }
    }

    @Test(.enabled(if: PDFKitGateStressTests.enabled, "opt-in: PAPERDECK_PDFKIT_STRESS=light|full"), .timeLimit(.minutes(1)))
    func everyPDFKitPathAtOnceOnFontsNotYetUsed() async throws {
        let installed = PDFKitGateKit.installedFontNames()
        try #require(installed.count >= 20, "only \(installed.count) installed fonts")
        // The light pass spreads its 160 fonts over the whole (sorted) list.
        let step = max(1, installed.count / 160)
        let fonts = Self.full ? installed : stride(from: 0, to: installed.count, by: step).prefix(160).map { installed[$0] }
        let dir = try PDFKitGateKit.tempDir("stress")
        defer { try? FileManager.default.removeItem(at: dir) }
        var built: [(url: URL, data: Data)] = []
        for (i, start) in stride(from: 0, to: fonts.count - 1, by: 2).enumerated() {
            let data = PDFKitGateKit.pdf(fonts: [fonts[start], fonts[start + 1]])
            let url = dir.appending(path: "f\(i).pdf")
            try data.write(to: url)
            built.append((url, data))
        }
        let files = PDFKitBox(built)
        let jobs = built.count * 2
        let cursor = Cursor()
        let probe = GateProbe()
        let titles = GateProbe()
        let deadline = ContinuousClock.now + (Self.full ? .seconds(45) : .seconds(10))
        let threads = Self.full ? 8 : 4
        let extracted = GateProbe()
        let region = CGRect(x: 40, y: 640, width: 400, height: 120)

        for t in 0..<threads {
            PDFKitGateKit.onThread {
                while ContinuousClock.now < deadline, let job = cursor.take(below: jobs) {
                    autoreleasepool {
                        let (url, data) = files.value[job / 2]
                        let name = url.lastPathComponent
                        if job % 2 == 0 {
                            // The import's extraction (page text, title fonts, thumbnail, outline).
                            do {
                                let x = try PDFExtractor.extractBlocking(url: url, fileName: name)
                                if x.pageCount != 2 || x.pageTexts.count != 2 { probe.note("\(name): extracted \(x.pageCount) pages") }
                                extracted.note(name)
                                if x.fontTitle == PDFKitGateKit.title { titles.note(name) }
                            } catch {
                                probe.note("\(name): \(error)")
                            }
                            return
                        }
                        // The card's title and thumbnail from another document, while the extraction
                        // above reads the same fonts.
                        if let doc = GatedPDFDocument(data: data) {
                            _ = doc.with { $0.page(at: 0).flatMap(TitleHeuristic.title(of:)) }
                            if doc.with({ $0.page(at: 0).flatMap(PDFExtractor.cardThumbnailJPEG(page:)) }) == nil {
                                probe.note("\(name): thumbnail")
                            }
                        }
                        switch (job / 2) % 4 {
                        case 0:     // the reader's find
                            var finished = false
                            ReaderFindSearch.run("cortex", data: data, limit: 100, observePage: nil) { finished = finished || $0.finished }
                            if !finished { probe.note("\(name): find didn't finish") }
                        case 1:     // Q&A: page text of an uncached paper, printed labels
                            if QAPageLabels.pageText(pdf: url).components(separatedBy: "\u{0C}").count != 2 { probe.note("\(name): page text") }
                            _ = QAPageLabels.labels(pdf: url, pages: [1, 2])
                        case 2:     // the reader window's steps, inside the gate as on the main actor
                            PDFKitGate.shared.run {
                                guard case .opened(let opened) = ReaderDocumentLoader.opened(data),
                                      let page = opened.document.page(at: 0) else { probe.note("\(name): reader open"); return }
                                if ReaderQuoteFinder.locate(PDFKitGateKit.quote, near: 2, in: opened.document) == nil {
                                    probe.note("\(name): quote")
                                }
                                _ = TitleHeuristic.title(of: page)
                                if ReaderPDF.renderRegion(region, of: page) == nil { probe.note("\(name): region") }
                            }
                        default:    // the thumbnail again, from a fresh document
                            if GatedPDFDocument(data: data)?.with({ $0.page(at: 0).flatMap(PDFExtractor.cardThumbnailJPEG(page:)) }) == nil {
                                probe.note("\(name): thumbnail again")
                            }
                        }
                    }
                }
                // PDFKit's exception, caught by the title read since R-PDFKIT-2, still fails the test.
                let caught = TitleHeuristic.exceptionsCaughtOnThisThread
                if caught > 0 { probe.note("thread \(t): PDFKit threw in the title read \(caught)×") }
                probe.finish("thread \(t)")
            }
        }
        let done = await PDFKitGateKit.eventually(timeout: .seconds(55)) { probe.finishedAt.count == threads }
        #expect(done, "the workers didn't finish")
        #expect(probe.allNotes.isEmpty, "\(probe.allNotes.prefix(10))")
        // The fixture works: the title comes from the font runs for most fonts (not for every one: a
        // symbol or script font can change how its runs are measured).
        #expect(!extracted.allNotes.isEmpty)
        #expect(titles.allNotes.count * 3 >= extracted.allNotes.count,
                "titles found for \(titles.allNotes.count) of \(extracted.allNotes.count) PDFs")
    }
}
