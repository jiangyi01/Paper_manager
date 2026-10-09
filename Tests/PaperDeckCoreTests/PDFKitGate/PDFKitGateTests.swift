import CoreGraphics
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import PaperDeckCore

/// `PDFKitGate`: one thread at a time, re-entrant, and every PaperDeck PDFKit helper goes through it.
@Suite struct PDFKitGateTests {

    @Test func oneThreadAtATime() {
        let gate = PDFKitGate()
        let probe = GateProbe()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            for _ in 0..<150 {
                gate.run {
                    probe.enter()
                    for _ in 0..<200 { _ = UUID() }          // a little work while inside
                    probe.leave()
                }
            }
        }
        #expect(probe.maxActive == 1, "\(probe.maxActive) threads were inside at once")
        #expect(gate.maxInside == 1)
        #expect(gate.entryCount == 12 * 150)
    }

    @Test func nestedCallsOnOneThreadGoStraightIn() {
        let gate = PDFKitGate()
        #expect(!gate.isHeldByCurrentThread)
        // On its own thread, so a gate that isn't re-entrant fails the test instead of hanging it.
        let probe = GateProbe()
        let done = DispatchSemaphore(value: 0)
        PDFKitGateKit.onThread {
            let depth = gate.run { () -> Int in
                if !gate.isHeldByCurrentThread { probe.note("not held inside") }
                return gate.run { gate.run { gate.isHeldByCurrentThread ? 3 : 0 } }
            }
            if depth != 3 { probe.note("depth \(depth)") }
            if gate.isHeldByCurrentThread { probe.note("still held after") }
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            Issue.record("a nested call deadlocked")
            return
        }
        #expect(probe.allNotes.isEmpty, "\(probe.allNotes)")
        #expect(gate.entryCount == 1, "nested calls count as one entry")

        // Another thread doesn't see itself as the holder while this one holds the gate.
        let other = DispatchSemaphore(value: 0)
        gate.run {
            PDFKitGateKit.onThread {
                if gate.isHeldByCurrentThread { probe.note("other thread thinks it holds the gate") }
                other.signal()
            }
            other.wait()
        }
        #expect(probe.allNotes.isEmpty, "\(probe.allNotes)")
    }

    @Test func aThrowingBodyLetsTheGateGo() {
        struct Boom: Error {}
        let gate = PDFKitGate()
        #expect(throws: Boom.self) { try gate.run { () throws -> Void in throw Boom() } }
        #expect(!gate.isHeldByCurrentThread)
        let other = DispatchSemaphore(value: 0)
        PDFKitGateKit.onThread { _ = gate.run { other.signal() } }
        #expect(other.wait(timeout: .now() + 10) == .success, "the gate stayed closed after a throw")
    }

    /// The document is opened, used and released inside the gate: three entries, and the body runs
    /// holding it.
    @Test func aGatedDocumentLivesInsideTheGate() {
        let gate = PDFKitGate()
        let data = PDFKitGateKit.pdf(fonts: ["Helvetica"])
        do {
            let doc = GatedPDFDocument(data: data, gate: gate)
            #expect(doc != nil)
            #expect(gate.entryCount == 1, "opened outside the gate")
            let pages = doc?.with { d -> Int in
                #expect(gate.isHeldByCurrentThread)
                return d.pageCount
            }
            #expect(pages == 2)
            #expect(gate.entryCount == 2)
        }
        #expect(gate.entryCount == 3, "released outside the gate")
        #expect(GatedPDFDocument(data: Data("not a pdf".utf8), gate: gate) == nil)
    }

    /// Gated helpers call each other (the extractor runs the title heuristic inside its own gate;
    /// the reader runs the quote finder inside one): holding the gate, every helper still finishes.
    @Test func gatedHelpersNestWithoutDeadlock() async throws {
        let dir = try PDFKitGateKit.tempDir("nest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = PDFKitGateKit.pdf(fonts: ["Helvetica", "Times-Roman"])
        let url = dir.appending(path: "nest.pdf")
        try data.write(to: url)
        let probe = GateProbe()
        PDFKitGateKit.onThread {
            PDFKitGate.shared.run {
                guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { probe.note("no document"); return }
                if TitleHeuristic.title(of: page) != PDFKitGateKit.title { probe.note("title") }
                if ReaderPDF.labels(of: doc).count != 2 { probe.note("labels") }
                if ReaderQuoteFinder.locate(PDFKitGateKit.quote, near: 2, in: doc)?.page != 2 { probe.note("quote") }
                if ReaderPDF.renderRegion(CGRect(x: 40, y: 600, width: 300, height: 150), of: page) == nil { probe.note("region") }
                if PDFExtractor.cardThumbnailJPEG(page: page) == nil { probe.note("thumbnail") }
                _ = PDFExtractor.topLevelOutline(doc)
                if (try? PDFExtractor.extractBlocking(url: url, fileName: "nest.pdf"))?.fontTitle != PDFKitGateKit.title { probe.note("extract") }
                if QAPageLabels.pageText(pdf: url).components(separatedBy: "\u{0C}").count != 2 { probe.note("page text") }
                _ = QAPageLabels.labels(pdf: url, pages: [1, 2])
                guard case .opened = ReaderDocumentLoader.opened(data) else { probe.note("opened"); return }
                var batches = 0
                ReaderFindSearch.run("cortex", data: data, limit: 50, observePage: nil) { _ in batches += 1 }
                if batches == 0 { probe.note("find") }
            }
            probe.finish("nested")
        }
        let finished = await PDFKitGateKit.eventually(timeout: .seconds(30)) { probe.finishedAt["nested"] != nil }
        #expect(finished, "a gated helper deadlocked inside the gate")
        #expect(probe.allNotes.isEmpty, "\(probe.allNotes)")
    }

    /// While another thread holds the gate, none of the PDFKit helpers gets anywhere: each one waits
    /// at the gate and finishes only after it opens.
    @Test func everyPDFKitHelperWaitsForTheGate() async throws {
        let dir = try PDFKitGateKit.tempDir("wait")
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = PDFKitGateKit.pdf(fonts: ["Helvetica", "Courier"])
        let url = dir.appending(path: "wait.pdf")
        try data.write(to: url)
        let doc = try #require(PDFDocument(data: data))
        let box = PDFKitBox(doc)
        let page = PDFKitBox(try #require(doc.page(at: 0)))
        let ref = PDFKitBox(try #require(page.value.pageRef))

        let helpers: [(String, @Sendable () -> Void)] = [
            ("PDFExtractor.extractBlocking", { _ = try? PDFExtractor.extractBlocking(url: url, fileName: "wait.pdf") }),
            ("PDFExtractor.cardThumbnailJPEG", { _ = PDFExtractor.cardThumbnailJPEG(page: page.value) }),
            ("PDFExtractor.topLevelOutline", { _ = PDFExtractor.topLevelOutline(box.value) }),
            ("TitleHeuristic.title", { _ = TitleHeuristic.title(of: page.value) }),
            ("QAPageLabels.labels", { _ = QAPageLabels.labels(pdf: url, pages: [1, 2]) }),
            ("QAPageLabels.pageText", { _ = QAPageLabels.pageText(pdf: url) }),
            ("ReaderDocumentLoader.opened", { _ = ReaderDocumentLoader.opened(data) }),
            ("ReaderFindSearch.run", { ReaderFindSearch.run("cortex", data: data, limit: 50, observePage: nil) { _ in } }),
            ("ReaderPDF.labels", { _ = ReaderPDF.labels(of: box.value) }),
            ("ReaderPDF.renderRegion(page)", { _ = ReaderPDF.renderRegion(CGRect(x: 40, y: 600, width: 200, height: 100), of: page.value) }),
            ("ReaderPDF.renderRegion(ref)", {
                _ = ReaderPDF.renderRegion(CGRect(x: 40, y: 600, width: 200, height: 100), of: ref.value,
                                           cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
            }),
            ("ReaderQuoteFinder.locate", { _ = ReaderQuoteFinder.locate(PDFKitGateKit.quote, near: 2, in: box.value) }),
            ("GatedPDFDocument(url:)", { _ = GatedPDFDocument(url: url) }),
            ("GatedPDFDocument(data:)", { _ = GatedPDFDocument(data: data) }),
        ]
        let probe = GateProbe()
        let release = DispatchSemaphore(value: 0)
        let releasedAt = PDFKitBox(ReleaseClock())
        PDFKitGateKit.onThread {
            PDFKitGate.shared.run {
                probe.finish("holder")
                release.wait()
                releasedAt.value.mark()
            }
        }
        #expect(await PDFKitGateKit.eventually(timeout: .seconds(30)) { probe.finishedAt["holder"] != nil })
        let count = helpers.count
        for (name, body) in helpers {
            PDFKitGateKit.onThread {
                probe.note(name)
                body()
                probe.finish(name)
            }
        }
        // Every helper has started; give an ungated one time to finish before the gate opens.
        _ = await PDFKitGateKit.eventually(timeout: .seconds(10)) { probe.allNotes.count == count }
        try await Task.sleep(for: .milliseconds(400))
        let early = probe.finishedAt.keys.filter { $0 != "holder" }.sorted()
        release.signal()
        let all = await PDFKitGateKit.eventually(timeout: .seconds(30)) { probe.finishedAt.count == count + 1 }
        #expect(early.isEmpty, "finished while another thread held the gate: \(early)")
        #expect(all, "unfinished: \(Set(helpers.map(\.0)).subtracting(probe.finishedAt.keys).sorted())")
        if let opened = releasedAt.value.instant {
            let before = probe.finishedAt.filter { $0.key != "holder" && $0.value < opened }.keys.sorted()
            #expect(before.isEmpty, "finished before the gate opened: \(before)")
        }
        withExtendedLifetime((doc, page, ref)) {}
    }

    private final class ReleaseClock: @unchecked Sendable {
        private let lock = NSLock()
        private var at: ContinuousClock.Instant?
        func mark() { lock.withLock { at = .now } }
        var instant: ContinuousClock.Instant? { lock.withLock { at } }
    }
}
