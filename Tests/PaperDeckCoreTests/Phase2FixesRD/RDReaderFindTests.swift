import Darwin
import Foundation
import PDFKit
import Testing
@testable import PaperDeckCore

/// Phase 2 fix RD-1: the reader's find runs off the main actor, page by page on its own document,
/// with the cap applied to plain ranges before any `PDFSelection` exists, and results in batches.
/// (`PDFDocument.findString` held the main thread 5.5 s and built ~682k selections, 1.8 GB, for one
/// letter in a 2000-page PDF.)
@Suite("Phase 2 fixes RD: reader find", .serialized)
struct RDReaderFindTests {
    /// A long text PDF: `pages` pages of 24 lines; "cortex" twice on every `every`-th page, and
    /// "hippocampal sclerosis" once on the last page only.
    static func longPDF(pages: Int, every: Int = 1) -> Data {
        let filler = "the progenitor lineage atlas shows neuron chromatin spatial cluster organoid trajectory signal"
        let list = (1...pages).map { n -> ReaderFixturePDF.Page in
            var lines: [(String, CGFloat)] = (0..<24).map { ("\(filler) line \($0)", 10) }
            if n % every == 0 {
                lines[3] = ("Cortex development in page \(n) and the cortex again", 10)
            }
            if n == pages { lines[20] = ("a rare finding: hippocampal sclerosis", 10) }
            return ReaderFixturePDF.Page(lines: lines)
        }
        return ReaderFixturePDF.make(pages: list)
    }

    /// Counts the pages searched and whether any was searched on the main thread.
    final class PageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var pages = 0
        private var onMain = 0
        func record() { lock.withLock { pages += 1; if pthread_main_np() != 0 { onMain += 1 } } }
        var searched: Int { lock.withLock { pages } }
        var searchedOnMain: Int { lock.withLock { onMain } }
    }

    static func collect(_ stream: AsyncStream<ReaderFindBatch>) async -> [ReaderFindBatch] {
        var out: [ReaderFindBatch] = []
        for await b in stream { out.append(b) }
        return out
    }

    /// One letter-like query on a long PDF: exactly `limit` matches are delivered, `capped` is set,
    /// and the search stops right there (it never reads the rest of the document).
    @MainActor @Test func theCapIsAppliedBeforeAnythingElseAndStopsTheSearch() async throws {
        let data = Self.longPDF(pages: 600)
        let log = PageLog()
        let batches = await Self.collect(ReaderFindSearch.search("cortex", data: data, limit: 500) { _ in log.record() })
        let matches = batches.flatMap(\.matches)
        #expect(matches.count == 500)
        let last = try #require(batches.last)
        #expect(last.finished && last.capped)
        #expect(batches.dropLast().allSatisfy { !$0.finished })
        // Two matches a page: page 250 holds the 499th and 500th; page 251's first is the 501st.
        #expect(matches.last?.page == 250)
        #expect(log.searched == 251, "searched \(log.searched) pages for 500 matches")
        #expect(log.searchedOnMain == 0)
        // Document order, and the ranges are the page text's own (what PDFPage.selection takes).
        #expect(matches.map(\.page) == matches.map(\.page).sorted())
        let doc = try #require(PDFDocument(data: data))
        let first = try #require(matches.first)
        let sel = try #require(doc.page(at: first.page - 1)?.selection(for: first.range))
        #expect(sel.string?.lowercased() == "cortex")
    }

    /// A rare query on a long PDF arrives in several batches (progress along the way) and the only
    /// match, on the last page, comes with the final one.
    @Test func resultsArriveIncrementally() async throws {
        let data = Self.longPDF(pages: 300, every: 7)
        let batches = await Self.collect(ReaderFindSearch.search("hippocampal  sclerosis", data: data, limit: 500))
        #expect(batches.count >= 300 / ReaderFindSearch.batchPages, "\(batches.count) batches")
        #expect(batches.map(\.searchedPages) == batches.map(\.searchedPages).sorted())
        let last = try #require(batches.last)
        #expect(last.finished && !last.capped && last.searchedPages == 300 && last.pageCount == 300)
        #expect(batches.flatMap(\.matches).map(\.page) == [300])
        // Every 7th page: 42 pages × 2 — the cap not reached, nothing dropped.
        let all = await Self.collect(ReaderFindSearch.search("CORTEX", data: data, limit: 500)).flatMap(\.matches)
        #expect(all.count == (300 / 7) * 2)
    }

    /// Ending the stream (a new query, Done, the window closing) stops the search at the next page.
    @Test func endingTheStreamStopsTheSearch() async throws {
        let data = Self.longPDF(pages: 1_500, every: 50)
        let log = PageLog()
        let consumer = Task {
            // The stream lives in this task only: returning from the loop drops it, which ends it.
            let stream = ReaderFindSearch.search("hippocampal sclerosis", data: data, limit: 500) { _ in log.record() }
            for await batch in stream where batch.searchedPages > 0 { return batch.searchedPages }
            return 0
        }
        let firstBatch = await consumer.value              // returning ends the iteration: the stream terminates
        #expect(firstBatch > 0 && firstBatch < 1_500)
        try await Task.sleep(for: .milliseconds(300))
        let stoppedAt = log.searched
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.searched == stoppedAt, "the search kept going after its stream ended")
        #expect(stoppedAt < 1_500, "searched \(stoppedAt) of 1500 pages")
    }

    /// Whitespace-, ligature- and case-tolerant like the quote finder; nothing for an empty query
    /// or a locked / unreadable file.
    @Test func matchingRulesAndEdgeCases() async throws {
        #expect(ReaderFindSearch.ranges(of: "atlas  shows", inPageText: "the atlas\nshows it", limit: 10)
                == [NSRange(location: 4, length: 11)])
        #expect(ReaderFindSearch.ranges(of: "find", inPageText: "we \u{FB01}nd it", limit: 10).count == 1)
        #expect(ReaderFindSearch.ranges(of: "x", inPageText: "x x x x", limit: 2).count == 2)
        #expect(ReaderFindSearch.ranges(of: "x", inPageText: "x", limit: 0).isEmpty)
        let empty = await Self.collect(ReaderFindSearch.search("   ", data: Self.longPDF(pages: 2), limit: 500))
        #expect(empty.count == 1 && empty[0].finished && empty[0].matches.isEmpty)
        let junk = await Self.collect(ReaderFindSearch.search("cortex", data: Data("not a pdf".utf8), limit: 500))
        #expect(junk.count == 1 && junk[0].finished && junk[0].matches.isEmpty)
    }

    /// The find bar's cursor over incremental results: the first match on or after the page read
    /// once one arrived; until then none (Return takes the first); the end wraps to the first.
    @Test func theCursorFollowsIncrementalResults() {
        var c = ReaderFindCursor(matchPages: [], startingAt: nil)
        c.append([1, 2], startingAt: 5)
        #expect(c.count == 2 && c.index == nil)
        c.append([4, 6, 7], startingAt: 5)
        #expect(c.index == 3 && c.matchPages[3] == 6)
        c.append([9], startingAt: 5)
        #expect(c.index == 3, "the current match stays when more arrive")
        c.next()
        #expect(c.index == 4)
        var none = ReaderFindCursor(matchPages: [], startingAt: nil)
        none.append([1, 2], startingAt: 9)
        none.finish()
        #expect(none.index == 0, "no match after the page read: the first one")
        var early = ReaderFindCursor(matchPages: [], startingAt: nil)
        early.append([1, 2], startingAt: 9)
        early.next()
        #expect(early.index == 0)
        var back = ReaderFindCursor(matchPages: [], startingAt: nil)
        back.append([1, 2, 3], startingAt: 9)
        back.previous()
        #expect(back.index == 2)
        var noPage = ReaderFindCursor(matchPages: [], startingAt: nil)
        noPage.append([3], startingAt: nil)
        #expect(noPage.index == 0)
        // The complete-list initializer is unchanged.
        #expect(ReaderFindCursor(matchPages: [1, 5, 9], startingAt: 4).index == 1)
    }

    /// The 2000-page case of the verifier, timed (printed): no page is searched on the main thread,
    /// the first batch arrives early, and only the cap's ranges are delivered.
    @MainActor @Test(.enabled(if: RDPerf.probes, "a timing probe: PAPERDECK_PERF_PROBES=1"))
    func aLongPDFIsSearchedOffTheMainThread() async throws {
        let data = Self.longPDF(pages: 2_000, every: 9)
        let log = PageLog()
        let t0 = ContinuousClock.now
        var first: Duration?
        var total = 0
        for await batch in ReaderFindSearch.search("hippocampal sclerosis", data: data, limit: 500, observePage: { _ in log.record() }) {
            if first == nil { first = ContinuousClock.now - t0 }
            total += batch.matches.count
        }
        let elapsed = ContinuousClock.now - t0
        print("PROBE RD-1 2000-page find: first batch after \(first.map { "\($0)" } ?? "-"), done after \(elapsed), \(log.searched) pages, \(total) match(es), \(log.searchedOnMain) on the main thread")
        #expect(log.searched == 2_000 && total == 1 && log.searchedOnMain == 0)
        let letter = await Self.collect(ReaderFindSearch.search("e", data: data, limit: 500)).flatMap(\.matches)
        #expect(letter.count == 500)
    }
}
