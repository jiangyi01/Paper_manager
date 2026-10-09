import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes QA-5 (verifier v17), QA-7 (v19) and QA-13: a citation of a page that wasn't sent
/// is invalid and `.notSent` (never shown as checked); an unlabelled citation among several papers
/// is `.ambiguous` (never silently P1); an invalid paper label is `.unknownPaper`, a page beyond
/// the PDF `.pageMissing` — the chip's help names exactly that.
@Suite(.timeLimit(.minutes(2))) struct QAFixCitationTests {
    private typealias Kit = QATestKit

    // MARK: QA-5 pages that weren't sent

    @Test func aPageThatWasNotSentIsMarkedNotSent() {
        let sent: [[Int: String]] = [[1: "one", 2: "two"], [5: "five"]]
        let cites = [QACitation(paper: 1, page: 2), QACitation(paper: 1, page: 11), QACitation(paper: 1, page: 2, endPage: 4),
                     QACitation(paper: 1, page: 9, endPage: 12), QACitation(paper: 2, page: 5), QACitation(paper: 2, page: 1),
                     QACitation(paper: 2, page: nil), QACitation(paper: 1, page: 40, valid: false, problem: .pageMissing)]
        let out = QACitations.markUnsent(cites, sent: sent)
        #expect(out.map(\.valid) == [true, false, true, false, true, false, true, false])
        #expect(out.map(\.problem) == [nil, .notSent, nil, .notSent, nil, .notSent, nil, .pageMissing])
        // Never shown as checked.
        var withQuote = QACitation(page: 11, quote: "stale", quoteFound: true)
        withQuote = QACitations.markUnsent([withQuote], sent: [[1: "one"]])[0]
        #expect(withQuote.quote == nil && withQuote.quoteFound == nil && !withQuote.valid)
        // Cards only: nothing was sent, every page citation is unsent; a card citation stays valid.
        let cards = QACitations.markUnsent([QACitation(paper: 2, page: 3), QACitation(paper: 2, page: nil)], sent: [[:], [:]])
        #expect(cards.map(\.problem) == [.notSent, nil])
    }

    /// v17: the budget leaves page 11 out; the answer cites it.
    @Test func theServiceMarksACitationOfAnOmittedPage() async throws {
        let scripted = ScriptedBackend(mode: .mock, scripts: [ScriptedBackend.answer(
            "Measurements describe buffers [p. 11]. Measurements reported on page 1 describe the sample preparation [p. 1].")])
        try await Kit.run(backends: [scripted]) { env in
            env.settings.value.assist.qaTextBudget = 700           // a few pages only
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let answer = try #require(Kit.completed(await Kit.ask(env, qa, t.id, "Buffers?")))
            let sent = answer.context?.pages.first ?? []
            #expect(!sent.contains(11) && sent.contains(1), "\(sent)")
            try #require(answer.citations.count == 2)
            #expect(answer.citations[0].page == 11 && !answer.citations[0].valid && answer.citations[0].problem == .notSent)
            #expect(answer.citations[0].quoteFound == nil)
            #expect(answer.citations[1].page == 1 && answer.citations[1].valid && answer.citations[1].problem == nil)
            // Stored as such (and read back from the database).
            let stored = try #require(await qa.messages(threadID: t.id).last)
            #expect(stored.citations == answer.citations)
        }
    }

    // MARK: QA-7 unlabelled citations among several papers

    @Test func anUnlabelledCitationAmongSeveralPapersIsAmbiguous() throws {
        let cites = QACitations.parse("X holds [P2 p. 3]. Y also holds [p. 5].", pageCounts: [10, 10])
        try #require(cites.count == 2)
        #expect(cites[0] == QACitation(paper: 2, page: 3))
        #expect(!cites[1].valid && cites[1].problem == .ambiguous && cites[1].paper == 0 && cites[1].page == 5)
        // The chip and the notes don't pretend it is P1's.
        #expect(QACitations.display(cites[1], multi: true) == "p. 5")
        #expect(QACitations.plain("Y also holds [p. 5].", multi: true) == "Y also holds (p. 5).")
        // With exactly one paper an unlabelled citation is that paper's.
        #expect(QACitations.parse("Holds [p. 5].", pageCounts: [10]) == [QACitation(paper: 1, page: 5)])
        #expect(QACitations.parse("Holds [p. 5].", pageCounts: []) == [QACitation(paper: 1, page: 5)])
        // Ambiguous citations get no supporting sentence (whose page would it be?).
        let quoted = QACitations.attachQuotes("Measurements describe the buffers clearly [p. 5].", pageCounts: [10, 10]) { _, _ in
            "Measurements describe the buffers clearly and at length."
        }
        #expect(quoted.first?.problem == .ambiguous && quoted.first?.quoteFound == nil)
    }

    @Test func anInlineMarkerResolvesToItsStoredCitation() {
        let stored = [QACitation(paper: 1, page: 5, label: "1205", quote: "The sentence.", quoteFound: true)]
        let marker = QACitations.tokens(in: "Holds [p. 5].").first?.citations.first ?? QACitation(page: nil)
        #expect(marker.paper == 0)                                  // as written: no label
        #expect(QACitations.resolve(marker, stored: stored, pageCounts: [12]) == stored[0])
        let ambiguous = QACitations.resolve(marker, stored: [], pageCounts: [12, 12])
        #expect(ambiguous.problem == .ambiguous && !ambiguous.valid)
    }

    // MARK: QA-13 the reason an invalid citation gives

    @Test func theProblemOfAnInvalidCitation() {
        let three: [Int?] = [10, 10, 10]
        let p5 = QACitations.parse("[P5 p. 3]", pageCounts: three)
        #expect(p5.first?.problem == .unknownPaper && p5.first?.valid == false)
        #expect(QACitations.parse("[P5]", pageCounts: three).first?.problem == .unknownPaper)
        #expect(QACitations.parse("[P2 p. 40]", pageCounts: three).first?.problem == .pageMissing)
        #expect(QACitations.parse("[p. 0]", pageCounts: [12]).first?.problem == .pageMissing)
        #expect(QACitations.parse("[pp. 11–14]", pageCounts: [12]).first?.problem == .pageMissing)
        #expect(QACitations.parse("[P2 p. 3]", pageCounts: three).first?.problem == nil)
        for c in QACitations.parse("[P5 p. 3] [P2 p. 40] [p. 2] [P2]", pageCounts: three) {
            #expect(QACitations.problem(of: c, paperCount: 3) == c.problem)
        }
        // Answers stored before `problem` existed: derived from the thread's paper count.
        #expect(QACitations.problem(of: QACitation(paper: 5, page: 3, valid: false), paperCount: 3) == .unknownPaper)
        #expect(QACitations.problem(of: QACitation(paper: 2, page: 40, valid: false), paperCount: 3) == .pageMissing)
        #expect(QACitations.problem(of: QACitation(paper: 4, page: nil, valid: false), paperCount: 3) == .unknownPaper)
        #expect(QACitations.problem(of: QACitation(paper: 2, page: 4), paperCount: 3) == nil)
        // Re-validating doesn't keep a stale reason.
        let fixed = QACitations.validate(QACitation(paper: 2, page: 4, valid: false, problem: .pageMissing), pageCounts: three)
        #expect(fixed.valid && fixed.problem == nil)
    }

    /// The new field is optional in JSON: answers and `qa.json` files written before it still read.
    @Test func citationsWithoutAProblemStillDecode() throws {
        let old = #"[{"paper":1,"page":3,"valid":true,"quoteFound":false}]"#
        let decoded = try JSONDecoder().decode([QACitation].self, from: Data(old.utf8))
        #expect(decoded == [QACitation(page: 3, quoteFound: false)])
        let encoded = String(decoding: try JSONEncoder().encode([QACitation(page: 3)]), as: UTF8.self)
        #expect(!encoded.contains("problem"))
    }
}
