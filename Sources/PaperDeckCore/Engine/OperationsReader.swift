import Foundation

// The built-in reader's engine calls (READING_ASSIST_PLAN §6.4 C4). Owned by Slice C (reader). Nothing
// here touches the PDF or the paper's row: opening a paper in the reader is marked through the usual
// `markOpened` by the App, like any other open.
extension Engine {
    /// The page the reader last showed for this paper (physical, 1-based), if any.
    package func readerPage(paperID: String) async -> Int? {
        try? await db.readerPage(paperID: paperID)
    }

    /// Remembers the page the reader shows (debounced by the reader; kept quietly, see Database+Reader).
    package func setReaderPage(paperID: String, page: Int) async {
        guard page >= 1, !paperID.isEmpty else { return }
        try? await db.setReaderPage(paperID: paperID, page: page)
    }

    /// Drops the page memory of purged papers (a maintenance pass may call it; harmless any time).
    @discardableResult
    package func pruneReaderPages() async -> Int {
        (try? await db.pruneReaderPages()) ?? 0
    }
}
