import Foundation
import Testing
@testable import PaperDeckCore

/// The reader's page arithmetic (READING_ASSIST_PLAN §6.4 C4): physical pages (what checklist items,
/// `[[p. N]]` citations and the page memory count) against the PDF's printed labels.
@Suite("Reader: pages, labels, memory")
struct ReaderPagesTests {
    /// A 14-page reprint of pp. 1201–1214 after two roman front-matter pages would be "i", "ii",
    /// "1201"…; this one: i, ii, 1201…1212.
    static let reprint: [String?] = ["i", "ii"] + (1201...1212).map { String($0) }

    @Test func clampKeepsPagesInsideTheDocument() {
        #expect(ReaderPages.clamp(0, pageCount: 14) == 1)
        #expect(ReaderPages.clamp(-3, pageCount: 14) == 1)
        #expect(ReaderPages.clamp(7, pageCount: 14) == 7)
        #expect(ReaderPages.clamp(99, pageCount: 14) == 14)
        #expect(ReaderPages.clamp(1, pageCount: 0) == nil)
    }

    @Test func aPrintedLabelIsShownOnlyWhenItSaysSomethingElse() {
        #expect(ReaderPages.printedLabel(physical: 3, label: "1201") == "1201")
        #expect(ReaderPages.printedLabel(physical: 2, label: "ii") == "ii")
        #expect(ReaderPages.printedLabel(physical: 7, label: "7") == nil)
        #expect(ReaderPages.printedLabel(physical: 7, label: " 7 ") == nil)
        #expect(ReaderPages.printedLabel(physical: 7, label: "07") == nil, "the same number, zero-padded")
        #expect(ReaderPages.printedLabel(physical: 7, label: nil) == nil)
        #expect(ReaderPages.printedLabel(physical: 7, label: "  ") == nil)
        #expect(ReaderPages.printedLabel(physical: 1, label: "S1") == "S1")
        #expect(ReaderPages.hasPrintedLabels(Self.reprint))
        #expect(!ReaderPages.hasPrintedLabels(["1", "2", "3", nil]))
        #expect(!ReaderPages.hasPrintedLabels([]))
    }

    @Test func thePageFieldReadsPhysicalNumbersFirstThenLabels() {
        let labels = Self.reprint
        // Within 1...pageCount a number is physical (the field shows physical numbers)…
        #expect(ReaderPages.resolve("5", labels: labels, pageCount: 14) == 5)
        #expect(ReaderPages.resolve("14", labels: labels, pageCount: 14) == 14)
        // …outside it, a printed label: "p. 1205" of the reprint is the 7th page of the file.
        #expect(ReaderPages.resolve("1205", labels: labels, pageCount: 14) == 7)
        #expect(ReaderPages.resolve("ii", labels: labels, pageCount: 14) == 2)
        #expect(ReaderPages.resolve("II", labels: labels, pageCount: 14) == 2, "labels compare case-insensitively")
        #expect(ReaderPages.resolve("  3 ", labels: labels, pageCount: 14) == 3)
        for prefixed in ["p. 4", "p.4", "p4", "P 4", "page 4", "Page4"] {
            #expect(ReaderPages.resolve(prefixed, labels: labels, pageCount: 14) == 4, "\(prefixed)")
        }
        // Nothing to go to: the field falls back to the current page.
        for bad in ["", "0", "-2", "15", "1300", "xiv", "p.", "3a", "1e3", "٣"] {
            #expect(ReaderPages.resolve(bad, labels: labels, pageCount: 14) == nil, "\(bad)")
        }
        #expect(ReaderPages.resolve("1", labels: [], pageCount: 0) == nil)
        // A label that is also an in-range number: the number is physical (the 3rd page of the file,
        // not the page printed "3", which is the 5th).
        let front: [String?] = ["i", "ii", "1", "2", "3", "4"]
        #expect(ReaderPages.resolve("3", labels: front, pageCount: 6) == 3)
        #expect(ReaderPages.resolve("iI", labels: front, pageCount: 6) == 2)
        // Supplement labels work too.
        #expect(ReaderPages.resolve("S2", labels: ["S1", "S2", "S3"], pageCount: 3) == 2)
    }

    @Test func thePageMemoryStoresAPositivePagePerPaper() {
        let id = "8B0C4E6A-1111-4222-8333-944455556666"
        #expect(ReaderPageMemory.key(paperID: id) == "reader.page.8b0c4e6a-1111-4222-8333-944455556666")
        #expect(ReaderPageMemory.encode(page: 12) == "12")
        #expect(ReaderPageMemory.encode(page: 0) == "1")
        #expect(ReaderPageMemory.decode("12") == 12)
        #expect(ReaderPageMemory.decode(" 3") == 3)
        for bad: String? in [nil, "", "0", "-1", "twelve", "1.5"] { #expect(ReaderPageMemory.decode(bad) == nil, "\(String(describing: bad))") }
    }

    @Test func anExplicitPageWinsOverTheMemoryAndBothAreClamped() {
        #expect(ReaderPageMemory.startPage(requested: 3, remembered: 9, pageCount: 14) == 3)
        #expect(ReaderPageMemory.startPage(requested: nil, remembered: 9, pageCount: 14) == 9)
        #expect(ReaderPageMemory.startPage(requested: nil, remembered: nil, pageCount: 14) == 1)
        // A replaced, shorter PDF: the remembered page is clamped, never past the end.
        #expect(ReaderPageMemory.startPage(requested: nil, remembered: 30, pageCount: 14) == 14)
        #expect(ReaderPageMemory.startPage(requested: 40, remembered: 2, pageCount: 14) == 14)
        #expect(ReaderPageMemory.startPage(requested: 0, remembered: 2, pageCount: 14) == 1)
        #expect(ReaderPageMemory.startPage(requested: 2, remembered: nil, pageCount: 0) == 1)
    }
}

/// "Open this PDF": Preview stays the default; a page always opens the reader.
@Suite("Reader: routing")
struct ReaderRouteTests {
    @Test func withoutAPageTheUsersOpenerDecides() {
        #expect(ReaderRoute.decide(opener: "preview", page: nil, quote: nil, readerAvailable: true) == .preview)
        #expect(ReaderRoute.decide(opener: "default", page: nil, quote: nil, readerAvailable: true) == .defaultApp)
        #expect(ReaderRoute.decide(opener: "paperdeck", page: nil, quote: nil, readerAvailable: true) == .reader(page: nil, quote: nil))
        // A value this build doesn't know means the default app, as before the reader.
        #expect(ReaderRoute.decide(opener: "skim", page: nil, quote: nil, readerAvailable: true) == .defaultApp)
        #expect(ReaderRoute.decide(opener: "", page: nil, quote: nil, readerAvailable: true) == .defaultApp)
    }

    @Test func aPageOpensTheReaderWhateverTheOpener() {
        for opener in ["preview", "default", "paperdeck", "other"] {
            #expect(ReaderRoute.decide(opener: opener, page: 7, quote: "a quote", readerAvailable: true)
                    == .reader(page: 7, quote: "a quote"), "\(opener)")
        }
        #expect(ReaderRoute.decide(opener: "preview", page: 0, quote: nil, readerAvailable: true) == .reader(page: 1, quote: nil))
        #expect(ReaderRoute.decide(opener: "preview", page: 3, quote: "   ", readerAvailable: true) == .reader(page: 3, quote: nil),
                "a blank quote is no quote")
    }

    @Test func withoutTheReaderNothingChanges() {
        #expect(ReaderRoute.decide(opener: "preview", page: 7, quote: "q", readerAvailable: false) == .preview)
        #expect(ReaderRoute.decide(opener: "default", page: 7, quote: nil, readerAvailable: false) == .defaultApp)
        #expect(ReaderRoute.decide(opener: "paperdeck", page: nil, quote: nil, readerAvailable: false) == .preview,
                "a reader setting from another build falls back to the default opener")
    }

    @Test func theOpenerValuesMatchTheSettingsPicker() {
        #expect(ReaderRoute.Opener.preview == "preview")
        #expect(ReaderRoute.Opener.defaultApp == "default")
        #expect(ReaderRoute.Opener.paperDeck == "paperdeck")
    }
}
