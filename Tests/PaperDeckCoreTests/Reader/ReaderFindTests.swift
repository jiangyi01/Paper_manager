import Foundation
import Testing
@testable import PaperDeckCore

/// The find bar's cursor and the tolerant quote search behind "go to page N with the quote highlighted".
@Suite("Reader: find and quotes")
struct ReaderFindTests {
    @Test func aSearchStartsAtTheFirstMatchOnOrAfterThePageBeingRead() {
        let pages = [1, 2, 5, 5, 6]
        #expect(ReaderFindCursor(matchPages: pages, startingAt: 1).index == 0)
        #expect(ReaderFindCursor(matchPages: pages, startingAt: 3).index == 2)
        #expect(ReaderFindCursor(matchPages: pages, startingAt: 6).index == 4)
        #expect(ReaderFindCursor(matchPages: pages, startingAt: 7).index == 0, "past the last match: wraps to the first")
        #expect(ReaderFindCursor(matchPages: pages, startingAt: nil).index == 0)
        let none = ReaderFindCursor(matchPages: [], startingAt: 3)
        #expect(none.index == nil && none.count == 0 && none.position == nil)
    }

    @Test func nextAndPreviousWrapAround() {
        var c = ReaderFindCursor(matchPages: [2, 4, 9], startingAt: 9)
        #expect(c.position == 3)
        c.next()
        #expect(c.position == 1)
        c.previous()
        #expect(c.position == 3)
        c.previous(); c.previous(); c.previous()
        #expect(c.position == 3)
        var empty = ReaderFindCursor(matchPages: [], startingAt: nil)
        empty.next(); empty.previous()
        #expect(empty.index == nil)
    }

    @Test func aQuoteIsSearchedWholeThenByRunsOfItsWords() {
        let q = "“We regularize the attention weights by a sparsity prior and report the effect in Figure 1.”"
        let c = ReaderQuote.candidates(q)
        #expect(c.first == "We regularize the attention weights by a sparsity prior and report the effect in Figure 1.")
        #expect(c.contains("We regularize the attention weights by a sparsity prior and report the"), "first 12 words")
        #expect(c.contains("We regularize the attention weights by"), "first 6 words")
        #expect(c.contains("report the effect in Figure 1."), "last 6 words")
        #expect(Set(c).count == c.count, "no duplicates")
        // Whitespace collapses; quote marks and ellipses at the ends go.
        #expect(ReaderQuote.candidates("  ...the   attention\nweights…  ") == ["the attention weights"])
        // An ellipsis inside: the longest part stands for the quote.
        let gap = ReaderQuote.candidates("We show … that sparse attention priors improve calibration on long documents")
        #expect(gap.first == "We show … that sparse attention priors improve calibration on long documents")
        #expect(gap.contains("that sparse attention priors improve calibration on long documents"))
        // Too short to mean anything.
        #expect(ReaderQuote.candidates("“a”").isEmpty)
        #expect(ReaderQuote.candidates("   ").isEmpty)
        #expect(ReaderQuote.candidates("Short phrase") == ["Short phrase"])
    }

    @Test func theMatchShownIsOnTheTargetPageElseTheNearestNeighbour() {
        #expect(ReaderQuote.pick(matchPages: [2, 5, 7], target: 5) == 1)
        #expect(ReaderQuote.pick(matchPages: [2, 4, 6], target: 5) == 1, "a tie goes to the earlier page")
        #expect(ReaderQuote.pick(matchPages: [6, 9], target: 5) == 0)
        #expect(ReaderQuote.pick(matchPages: [2, 9], target: 5) == nil, "too far: no highlight, just the page")
        #expect(ReaderQuote.pick(matchPages: [2, 9], target: 5, tolerance: 3) == 0)
        #expect(ReaderQuote.pick(matchPages: [3, 1], target: nil) == 0)
        #expect(ReaderQuote.pick(matchPages: [], target: 2) == nil)
        #expect(ReaderQuote.pick(matchPages: [], target: nil) == nil)
    }

    @Test func thePageTextIndexJoinsLinesHyphensAndLigatures() throws {
        let page = "To keep the model honest, we regularize the atten-\ntion weights by a sparsity\n  prior. The ﬁnal “state-of-the-art” model…"
        let ns = page as NSString
        let joined = ReaderTextIndex(page, joinHyphens: true)
        let r = try #require(joined.find("we regularize the attention weights by a sparsity prior"))
        #expect(ns.substring(with: r) == "we regularize the atten-\ntion weights by a sparsity\n  prior")
        let caseless = try #require(joined.find("WE REGULARIZE"))
        #expect(ns.substring(with: caseless) == "we regularize")
        let lig = try #require(joined.find("the final"))
        #expect(ns.substring(with: lig) == "The ﬁnal", "the ligature maps back to its one character")
        let quoted = try #require(joined.find("\"state-of-the-art\""))
        #expect(ns.substring(with: quoted) == "“state-of-the-art”")
        // Without joining, the hyphenated word is two words (the second search pass).
        let plain = ReaderTextIndex(page, joinHyphens: false)
        #expect(plain.find("attention weights") == nil)
        #expect(plain.find("atten- tion weights") != nil)
        #expect(joined.find("nowhere in the text") == nil)
        #expect(joined.find("") == nil)
    }

    @Test func aHyphenIsJoinedOnlyAtALineEndBeforeALowercaseLetter() {
        let text = "a well-\nknown result; Fig. 3-\nB shows it; state-of-the-art"
        let joined = ReaderTextIndex(text, joinHyphens: true).normalized
        #expect(joined == "a wellknown result; Fig. 3- B shows it; state-of-the-art")
        // A capital after the break is a name pair, not a broken word.
        #expect(ReaderTextIndex("the Hodgkin-\nHuxley model", joinHyphens: true).normalized == "the Hodgkin- Huxley model")
        #expect(ReaderTextIndex("  leading and   trailing  ", joinHyphens: true).normalized == "leading and trailing")
        #expect(ReaderTextIndex("cr\r\nlf", joinHyphens: true).normalized == "cr lf")
    }

    @Test func everyMatchIsListedInOrder() {
        let text = "Attention here; attention there;\nATTENTION everywhere."
        let ns = text as NSString
        let all = ReaderTextIndex(text, joinHyphens: true).findAll("attention")
        #expect(all.map { ns.substring(with: $0) } == ["Attention", "attention", "ATTENTION"])
        #expect(ReaderTextIndex(text, joinHyphens: true).findAll("attention", limit: 2).count == 2)
    }
}
