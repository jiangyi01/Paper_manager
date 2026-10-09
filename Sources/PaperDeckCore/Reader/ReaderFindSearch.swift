import Foundation
import PDFKit

/// One find match: the physical page (1-based) and the range in that page's text (`PDFPage.string`,
/// UTF-16) — `PDFPage.selection(for:)` turns it into a highlight on the reader's own document.
package struct ReaderFindMatch: Sendable, Equatable {
    package var page: Int
    package var range: NSRange

    package init(page: Int, range: NSRange) { self.page = page; self.range = range }
}

/// What a running find has delivered: the matches found since the previous batch (document order)
/// and how far it got.
package struct ReaderFindBatch: Sendable, Equatable {
    package var matches: [ReaderFindMatch]
    /// Pages searched so far (of `pageCount`).
    package var searchedPages: Int
    package var pageCount: Int
    /// The search is over: every page was searched, or the cap was reached.
    package var finished: Bool
    /// There are more matches than the cap (only the first `limit` are delivered).
    package var capped: Bool

    package init(matches: [ReaderFindMatch], searchedPages: Int, pageCount: Int, finished: Bool, capped: Bool) {
        self.matches = matches; self.searchedPages = searchedPages; self.pageCount = pageCount
        self.finished = finished; self.capped = capped
    }
}

/// The reader's find (RD-1), off the main actor: page by page on the search's own document (made
/// from the same bytes as the window's, never the one the view draws; each page's text is read
/// inside `PDFKitGate`, the matching runs outside it), whitespace-, ligature-,
/// case- and diacritic-tolerant (`ReaderTextIndex`), with the cap applied to the ranges before
/// anything else exists — the window turns at most `limit` of them into `PDFSelection`s. Results come
/// in batches (incremental), and ending the stream (a new query, Done, the window closing) stops the
/// search at the next page. `PDFDocument.findString` instead ran on the main thread and built a
/// selection for every match first (5.5 s and 1.8 GB for one letter in a 2000-page PDF). Owned by
/// Slice C (reader).
package enum ReaderFindSearch {
    /// Pages per batch (a batch also goes out after `batchInterval` with something new).
    package static let batchPages = 40
    package static let batchInterval: Duration = .milliseconds(150)

    /// The ranges of `query` in one page's text, at most `limit` (UTF-16, in the original text).
    package static func ranges(of query: String, inPageText text: String, limit: Int) -> [NSRange] {
        guard limit > 0, !text.isEmpty else { return [] }
        return ReaderTextIndex(text, joinHyphens: false).findAll(query, limit: limit)
    }

    /// Searches the PDF in `data` for `query`. Every batch is delivered in document order; the last
    /// one has `finished`. `limit + 1` matches are looked for so `capped` is exact; only `limit` are
    /// delivered. `observePage` (tests) is called on the search's thread after each page.
    package static func search(_ query: String, data: Data, limit: Int,
                               observePage: (@Sendable (_ page: Int) -> Void)? = nil) -> AsyncStream<ReaderFindBatch> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (stream, continuation) = AsyncStream<ReaderFindBatch>.makeStream(bufferingPolicy: .unbounded)
        let worker = Task.detached(priority: .userInitiated) {
            run(q, data: data, limit: max(0, limit), observePage: observePage) { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }

    /// The search loop (synchronous: it runs on the detached task's thread, never the main actor).
    static func run(_ query: String, data: Data, limit: Int, observePage: (@Sendable (Int) -> Void)?,
                    deliver: (ReaderFindBatch) -> Void) {
        guard !query.isEmpty, let document = GatedPDFDocument(data: data),
              let count = document.with({ $0.isLocked ? nil : $0.pageCount }) else {
            deliver(ReaderFindBatch(matches: [], searchedPages: 0, pageCount: 0, finished: true, capped: false))
            return
        }
        var pending: [ReaderFindMatch] = []
        var delivered = 0
        var pagesSinceBatch = 0
        var lastBatch = ContinuousClock.now
        var capped = false
        var searched = 0
        for i in 0..<count {
            if Task.isCancelled { return }
            let text = document.with { $0.page(at: i)?.string }
            // One more than still fits: then it is known that the cap was reached.
            let found: [NSRange] = autoreleasepool {
                text.map { ranges(of: query, inPageText: $0, limit: limit - delivered - pending.count + 1) } ?? []
            }
            searched = i + 1
            observePage?(searched)
            for r in found {
                if delivered + pending.count < limit { pending.append(ReaderFindMatch(page: i + 1, range: r)) } else { capped = true }
            }
            if capped { break }
            pagesSinceBatch += 1
            let due = pagesSinceBatch >= batchPages || (!pending.isEmpty && ContinuousClock.now - lastBatch >= batchInterval)
            if due, searched < count {
                deliver(ReaderFindBatch(matches: pending, searchedPages: searched, pageCount: count, finished: false, capped: false))
                delivered += pending.count
                pending = []
                pagesSinceBatch = 0
                lastBatch = .now
            }
        }
        if Task.isCancelled { return }
        deliver(ReaderFindBatch(matches: pending, searchedPages: searched, pageCount: count, finished: true, capped: capped))
    }
}
