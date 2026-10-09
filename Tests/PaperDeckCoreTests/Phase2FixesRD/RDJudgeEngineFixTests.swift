import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes B3-3, B3-5 and T-1 (the judge's surviving mutations): the privacy floor on the
/// judge's extra candidates (2–3), the import's enrichment never undoing a band the judge moved
/// (and dropping a verdict it outdates), the judge's daily count across a relaunch, and the judge
/// refused while the duplicate check is off.
@Suite("Phase 2 fixes RD: judge through the engine", .serialized)
struct RDJudgeEngineFixTests {
    static let marker = "XYZZY-THIRD-PAPER-ABSTRACT"

    /// Two library papers (A, C) and a new copy (B) of one text and title; C carries a unique
    /// abstract so the prompt shows whether it was sent. Returns the open review and C.
    static func threePapers(_ env: DedupeKit.Env) async throws -> (review: DupReview, third: Paper) {
        let body = DedupeKit.body(seed: "three copies")
        let title = DupJudgeEngineTests.title
        env.settings.value.dedupe.enabled = false           // A and C go in without a review between them
        let a = try #require(await env.ingest([try env.pdf("a.pdf", title: title, body: body)]).added.first)
        let c = try #require(await env.ingest([try env.pdf("c.pdf", title: title, body: body)]).added.first)
        env.settings.value.dedupe.enabled = true
        _ = await env.ingest([try env.pdf("b.pdf", title: title, body: body)])
        let review = try await env.onlyOpenReview()
        let thirdID = review.existingPaperID == a ? c : a
        let third = try await env.paper(thirdID)
        _ = try await env.db.modifyPaper(pk: third.pk, now: env.clock.now) { $0.abstract = Self.marker + " of the third copy." }
        return (review, try await env.paper(thirdID))
    }

    /// B3-3: a third library paper that matches is sent as candidate 2 — unless it is confidential,
    /// never-AI or held as possibly unpublished: then nothing of it (title, abstract, first page)
    /// goes into the prompt. (Mutation V1, the privacy check removed, survived every suite before.)
    @Test func aPrivateThirdPaperIsNeverACandidate() async throws {
        let mock = MockAssistBackend(behavior: DupJudgeEngineTests.answer("same_work", 0.5))
        try await DedupeKit.run(DupJudgeEngineTests.settings(), assist: mock) { env in
            let (review, third) = try await Self.threePapers(env)
            try await env.engine.setDuplicateJudgeEnabled(true)
            // Control: an ordinary third paper is candidate 2 (the setup really yields one).
            _ = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            let open = try #require(await mock.lastRequest).turnText
            #expect(open.contains("<candidate n=\"2\">") && open.contains(Self.marker), "\(open)")

            let policies: [(String, PaperPolicy?, String?)] = [
                ("confidential", PaperPolicy(confidential: true, setBy: .user, setAt: env.clock.now), nil),
                ("never-AI", PaperPolicy(neverAI: true, setBy: .user, setAt: env.clock.now), nil),
                ("possibly unpublished", nil, ImportAnnotation.unpublishedHoldNote),
            ]
            for (name, policy, note) in policies {
                if let policy { try await env.db.setPaperPolicy(paperPK: third.pk, policy) }
                if let note { _ = try await env.db.modifyPaper(pk: third.pk, now: env.clock.now) { $0.aiNote = note } }
                let before = await mock.turns
                _ = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
                #expect(await mock.turns == before + 1)
                let sent = try #require(await mock.lastRequest).turnText
                #expect(!sent.contains("<candidate n=\"2\">"), "\(name): the private paper went to the judge")
                #expect(!sent.contains(Self.marker), "\(name): its abstract went to the judge")
                #expect(sent.contains("<candidate n=\"1\">"))
                try await env.db.setPaperPolicy(paperPK: third.pk, PaperPolicy())
                _ = try await env.db.modifyPaper(pk: third.pk, now: env.clock.now) { $0.aiNote = nil }
            }
        }
    }

    /// T-1 (V8): with the duplicate check off, an open review's [Ask AI] is refused (`.dedupeOff`),
    /// and nothing is sent or counted.
    @Test func theJudgeIsRefusedWithTheDuplicateCheckOff() async throws {
        let mock = MockAssistBackend(behavior: DupJudgeEngineTests.answer("different", 0.9))
        try await DedupeKit.run(DupJudgeEngineTests.settings(), assist: mock) { env in
            let review = try await DupJudgeEngineTests.likelyReview(env)
            try await env.engine.setDuplicateJudgeEnabled(true)
            env.settings.value.dedupe.enabled = false
            #expect(await env.engine.duplicateJudgeStatus(reviewID: review.id).block == .dedupeOff)
            await #expect(throws: DupJudgeError.blocked(.dedupeOff)) {
                _ = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            }
            #expect(await mock.turns == 0 && env.engine.dedupeJudgeCounter.count(at: env.clock.now) == 0)
            #expect(try await env.db.dupReview(id: review.id) == review)
        }
    }

    /// T-1 (V4): the judge's count of the day is restored when the library opens again (else every
    /// launch would reset the daily cap).
    @Test func theDailyCountSurvivesARelaunch() async throws {
        let mock = MockAssistBackend(behavior: DupJudgeEngineTests.answer("different", 0.9))
        let env = try await DedupeKit.make(DupJudgeEngineTests.settings(), assist: mock)
        let root = env.root
        defer { try? FileManager.default.removeItem(at: root) }
        let now = env.clock.now
        let key = env.engine.dedupeJudgeCounter.key(day: env.engine.dedupeJudgeCounter.day(now), provider: nil)
        do {
            let review = try await DupJudgeEngineTests.likelyReview(env)
            try await env.engine.setDuplicateJudgeEnabled(true)
            _ = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            #expect(env.engine.dedupeJudgeCounter.count(at: now) == 1)
            // The count is written to the library's kv (off the gate's lock): wait for it.
            var stored: String?
            for _ in 0..<200 {
                stored = try await env.db.kv(key)
                if stored == "1" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(stored == "1")
        }
        await env.engine.shutdown()
        await env.db.close()

        let reopened = try await OpsTestKit.make(DupJudgeEngineTests.settings(), root: root, now: now)
        #expect(reopened.engine.dedupeJudgeCounter.count(at: now) == 0)      // nothing read before start()
        await reopened.engine.start()
        #expect(reopened.engine.dedupeJudgeCounter.count(at: now) == 1, "the judge's daily count was reset by the relaunch")
        await reopened.engine.shutdown()
        await reopened.engine.db.close()
    }
}

/// B3-5: the import's enrichment re-matching a paper whose review the judge already answered.
@Suite("Phase 2 fixes RD: enrichment after a judge answer")
struct RDEnrichAfterJudgeTests {
    static func paper(_ pk: Int64) -> Paper {
        Paper(pk: pk, sha256: "s\(pk)", fileSize: 1, ids: PaperIDs(), title: "T", folder: "Papers/T\(pk)", pdfName: "T.pdf",
              originalName: "t.pdf", status: .toRead)
    }

    static func match(_ band: DupBand, existing: Int64 = 2) -> DupMatch {
        DupMatch(candidate: DupCandidate(band: band, relation: .sameWork, score: 0.9, evidence: [DupEvidence(.title, percent: 99)],
                                         newerSide: nil),
                 existing: paper(existing), history: nil)
    }

    /// A likely review the judge moved to possible (confident "different").
    static var judgedDown: DupReview {
        var r = DupReview(newPaperID: "n", existingPaperID: paper(2).id, band: .possible, score: 0.7,
                          createdAt: Date(timeIntervalSince1970: 0), newPaperPK: 1, existingPaperPK: 2,
                          relation: .sameWork, evidence: [], newerSide: nil, origin: .intake)
        r.aiState = DupJudge.answeredState
        r.aiVerdict = DupAIVerdict(verdict: .different, confidence: 0.9, reason: "Different cohorts.", bandBefore: .likely,
                                   bandAfter: .possible, provider: "mock", model: "m", at: Date(timeIntervalSince1970: 0))
        return r
    }

    @Test func aBandTheJudgeMovedIsNotUndoneByTheSameEvidence() {
        // Enrichment finds the same likely match again: the judge's answer stands, verdict kept.
        #expect(EnrichActor.upgraded(Self.judgedDown, by: Self.match(.likely)) == nil)
        // An identifier (certain) is new, harder evidence the judge can't weigh: re-banded, and the
        // answer — about the earlier evidence — is dropped (no "moved to possibly" on a certain review).
        let certain = EnrichActor.upgraded(Self.judgedDown, by: Self.match(.certain))
        #expect(certain?.band == .certain && certain?.aiVerdict == nil && certain?.aiState == DupJudge.unansweredState)
    }

    @Test func anUnsureAnswerNeverBlocksAnUpgradeButIsDroppedWithIt() {
        var unsure = Self.judgedDown
        unsure.band = .possible
        unsure.aiVerdict?.confidence = 0.5
        unsure.aiVerdict?.bandBefore = .possible
        unsure.aiVerdict?.bandAfter = .possible                // it moved nothing
        let up = EnrichActor.upgraded(unsure, by: Self.match(.likely))
        #expect(up?.band == .likely && up?.aiVerdict == nil && up?.aiState == DupJudge.unansweredState)
        #expect(up?.held != nil)                               // a likely review holds the new paper
        // Without any answer: the upgrade as before; nothing to drop.
        var plain = unsure
        plain.aiVerdict = nil
        plain.aiState = DupJudge.unansweredState
        #expect(EnrichActor.upgraded(plain, by: Self.match(.likely))?.band == .likely)
        // Not stronger: unchanged.
        #expect(EnrichActor.upgraded(plain, by: Self.match(.possible)) == nil)
    }

    /// A judge answer that moved the band up (possible → likely) isn't undone either, and a
    /// certain match still replaces it.
    @Test func anUpwardAnswerStandsUntilAnIdentifier() {
        var up = Self.judgedDown
        up.band = .likely
        up.aiVerdict?.verdict = .sameWork
        up.aiVerdict?.bandBefore = .possible
        up.aiVerdict?.bandAfter = .likely
        #expect(EnrichActor.upgraded(up, by: Self.match(.likely)) == nil)
        #expect(EnrichActor.upgraded(up, by: Self.match(.certain))?.band == .certain)
    }
}

/// B3-5 through the engine: the import's enrichment finishes *after* the user's [Ask AI] (the
/// metadata record is held back until the judge answered) and re-matches the same likely pair.
@Suite("Phase 2 fixes RD: enrichment after a judge answer (engine)", .serialized)
struct RDEnrichAfterJudgeEngineTests {
    static let doi = "10.1016/j.neuron.2025.07.012"

    /// Scripted metadata transport whose `gated` URL waits until `release()`.
    final class GatedFetcher: HTTPFetching, @unchecked Sendable {
        let routes: [(prefix: String, status: Int, body: String)]
        let gated: String
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var calls = 0

        init(routes: [(prefix: String, status: Int, body: String)], gated: String) { self.routes = routes; self.gated = gated }

        var gatedCalls: Int { lock.withLock { calls } }

        func release() {
            let w: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            w.forEach { $0.resume() }
        }

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            let s = url.absoluteString
            if s.hasPrefix(gated) {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let go: Bool = lock.withLock {
                        calls += 1
                        if isOpen { return true }
                        waiting.append(cont)
                        return false
                    }
                    if go { cont.resume() }
                }
            }
            for r in routes where s.hasPrefix(r.prefix) { return HTTPResult(status: r.status, body: Data(r.body.utf8)) }
            return HTTPResult(status: 404, body: Data())
        }
    }

    @Test func aLateEnrichmentKeepsTheJudgesBandAndVerdict() async throws {
        let record = "https://api.crossref.org/works/\(Self.doi)"
        let fetcher = GatedFetcher(routes: [(record, 200, DedupeKit.crossref(doi: Self.doi, title: DupJudgeEngineTests.title))],
                                   gated: record)
        defer { fetcher.release() }
        var settings = DedupeKit.settings(dedupe: DedupeSettings(aiDailyCap: 10), lookup: true)
        settings.assist.mode = .mock
        let mock = MockAssistBackend(behavior: DupJudgeEngineTests.answer("different", 0.9))
        try await DedupeKit.run(settings, fetcher: fetcher, assist: mock) { env in
            let body = DedupeKit.body(seed: "enrich after the judge")
            _ = await env.ingest([try env.pdf("a.pdf", title: DupJudgeEngineTests.title, body: body)])
            // The copy prints a DOI: its enrichment fetches the record — held back for now.
            let url = try env.pdf("b.pdf", title: DupJudgeEngineTests.title, doi: Self.doi, body: body)
            _ = await env.engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
            for _ in 0..<1_000 where fetcher.gatedCalls == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(fetcher.gatedCalls > 0, "the copy's enrichment never asked for its record")
            let review = try await env.onlyOpenReview()
            #expect(review.band == .likely)
            try await env.engine.setDuplicateJudgeEnabled(true)
            let judged = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            #expect(judged.band == .possible && judged.aiVerdict?.bandAfter == .possible)
            fetcher.release()
            await env.settle()
            let after = try #require(try await env.db.dupReview(id: review.id))
            #expect(after.state == .open)
            #expect(after.band == .possible, "the enrichment undid the judge's band")
            #expect(after.aiVerdict == judged.aiVerdict && after.aiState == DupJudge.answeredState)
        }
    }
}
