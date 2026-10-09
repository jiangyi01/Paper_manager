import Foundation
import Testing
@testable import PaperDeckCore

/// What happens around a review over time (Slice B): the enrichment linking a journal article to
/// its preprint (Crossref has-preprint) and the merge that follows; the earlier paper purged or
/// the history cleared while a new paper is held (never held for nothing); answered pairs not
/// asked again; the classic toasts worded from their review; the library check's progress.
@Suite(.serialized) struct DupLifecycleTests {
    static let title = "Molecular dynamics of the developing human neocortex"
    static let preprintDOI = "10.1101/2023.11.11.566789"
    static let journalDOI = "10.1016/j.cell.2024.05.001"

    /// bioRxiv knows no published version yet; Crossref's journal record says it has that preprint.
    static let fetcher = DedupeKit.Fetcher(routes: [
        ("https://api.biorxiv.org/details/biorxiv/\(preprintDOI)", 200, """
        {"collection":[{"title":"Lineage tracing of organoid progenitors at scale","authors":"Wang, L.; Lovelace, A.",
         "doi":"\(preprintDOI)","date":"2023-11-11","version":"1","server":"bioRxiv","published":"NA"}]}
        """),
        ("https://api.crossref.org/works/\(journalDOI)", 200,
         DedupeKit.crossref(doi: journalDOI, title: "Lineage tracing at scale", authors: ["Li Wang", "Ada Lovelace"],
                            year: 2024, venue: "Cell", relation: ["has-preprint": [preprintDOI]])),
    ])

    /// A held copy of the same text (likely), the earlier paper finished.
    static func held(_ env: DedupeKit.Env) async throws -> (e: Paper, n: Paper, review: DupReview) {
        let body = DedupeKit.body(seed: "lifecycle")
        let eid = try #require(await env.ingest([try env.pdf("earlier.pdf", title: title, body: body)]).added.first)
        _ = try await env.engine.setStatus(paperID: eid, .done)
        let nid = try #require(await env.ingest([try env.pdf("later.pdf", title: title, body: body)]).added.first)
        let review = try await env.onlyOpenReview()
        #expect(review.holdsNewPaper && review.newPaperID == nid)
        return (try await env.paper(eid), try await env.paper(nid), review)
    }

    // MARK: Enrichment

    @Test func theJournalRecordLinksItsPreprintAndKeepNewMergesThem() async throws {
        try await DedupeKit.run(DedupeKit.settings(lookup: true), fetcher: Self.fetcher) { env in
            let pid = try #require(await env.ingest([try env.pdf("preprint.pdf", title: "Lineage tracing of organoid progenitors at scale",
                                                                 doi: Self.preprintDOI)]).added.first)
            _ = try await env.engine.setNotes(paperID: pid, "preprint notes")
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            env.events.clear()
            let jid = try #require(await env.ingest([try env.pdf("journal.pdf", title: "Lineage tracing at scale",
                                                                 doi: Self.journalDOI)]).added.first)
            let review = try await env.onlyOpenReview()
            #expect(review.origin == .enrich && review.band == .certain && review.relation == .newerVersion)
            #expect(review.newPaperID == jid && review.existingPaperID == pid)
            #expect(review.evidence.contains { $0.code == .preprintLink })
            // The journal paper keeps its DDL; its AI reading waits for the decision.
            let j = try await env.paper(jid)
            #expect(j.scheduleMode != .none && j.aiState == .held)
            #expect(try await env.db.dupKeys(paperPK: j.pk).contains { $0.kind == .preprintDOI && $0.source == .crossref })
            // The lookalike toast isn't duplicated; the review's own toast offers [Review…].
            #expect(env.events.toasts.contains { $0.buttons.first?.action == .openDuplicateReview(id: review.id) })

            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            await env.settle()
            let kept = try await env.paper(pid)
            #expect(r.keptPaperID == pid && kept.ids.doi == Self.journalDOI && kept.sha256 == j.sha256)
            #expect(kept.notes == "preprint notes")
            #expect(try await env.db.paper(id: jid) == nil)
            let keys = try await env.db.dupKeys(paperPK: kept.pk)
            #expect(keys.contains { $0.kind == .preprintDOI && $0.value == DupKeys.doiToken(Self.preprintDOI) })
            // A later refresh of the kept paper never reopens a question.
            _ = await env.engine.enrich.refreshMetadata(pk: kept.pk)
            await env.settle()
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
        }
    }

    /// A later "refresh metadata" never opens a question on a paper already in the library (its
    /// own paper would be held for it): only the import's first enrichment checks.
    @Test func aRefreshNeverOpensAQuestion() async throws {
        try await DedupeKit.run(DedupeKit.settings(lookup: false), fetcher: Self.fetcher) { env in
            _ = await env.ingest([try env.pdf("preprint.pdf", title: "Lineage tracing of organoid progenitors at scale",
                                              doi: Self.preprintDOI)])
            let jid = try #require(await env.ingest([try env.pdf("journal.pdf", title: "Lineage tracing at scale",
                                                                 doi: Self.journalDOI)]).added.first)
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            env.settings.value.metadataLookup = true
            _ = await env.engine.enrich.refreshMetadata(pk: try await env.paper(jid).pk)
            await env.settle()
            #expect(try await env.paper(jid).metaSource == .crossref)        // the refresh did run
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
        }
    }

    // MARK: Parked keep-new + back to To Read

    @Test func parkedKeepNewAndMoveBackUndoesBothParts() async throws {
        try await DedupeKit.run { env in
            let eid = try #require(await env.ingest([try env.pdf("2401.01234v1.pdf", title: Self.title)]).added.first)
            _ = try await env.engine.setStatus(paperID: eid, .done)
            let e = try await env.paper(eid)
            _ = await env.ingest([try env.pdf("2401.01234v3.pdf", title: Self.title)])
            let review = try await env.onlyOpenReview()
            #expect(review.isParked && review.relation == .newerVersion)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: true))
            let p = try await env.paper(eid)
            #expect(p.sha256 != e.sha256 && p.status == .toRead && p.doneAt == nil && p.ids.arxivVersion == 3)
            #expect(try await env.db.readingCycles(paperPK: e.pk).map(\.n) == [1, 2])
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let back = try await env.paper(eid)
            #expect(back.sha256 == e.sha256 && back.status == .done && back.doneAt != nil && back.ids.arxivVersion == 1)
            #expect(try FileOps.sha256(of: env.ctx.pdfURL(back)) == e.sha256)
            #expect(try await env.db.readingCycles(paperPK: e.pk).isEmpty)
            #expect(await env.engine.intake.pendingIDs() == [review.pendingID].compactMap { $0 })
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
        }
    }

    // MARK: Never held for nothing

    @Test func purgingTheEarlierPaperKeepsTheQuestionOnItsTombstone() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env)
            try await env.engine.softDelete(paperID: e.id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            let moved = try #require(try await env.db.dupReview(id: review.id))
            #expect(moved.state == .open && moved.existingPaperPK == nil && moved.historyPK != nil && moved.matchesHistory)
            let detail = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(detail.choices == [.addAgain, .skip] && detail.existing.purgedAt != nil)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .addAgain)
            let released = try await env.paper(n.id)
            #expect(released.scheduleMode == .auto && released.deadline != nil)
        }
    }

    @Test func purgingWithoutHistoryEndsTheQuestionAndReleasesThePaper() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(history: false))) { env in
            let (e, n, review) = try await Self.held(env)
            #expect(n.scheduleMode == .none && n.aiState == .held)
            try await env.engine.softDelete(paperID: e.id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            let after = try await env.db.dupReview(id: review.id)
            #expect(after == nil || after?.state != .open)
            let released = try await env.paper(n.id)
            #expect(released.scheduleMode == .auto && released.deadline != nil)
            #expect(released.aiState == .queued)
            #expect(try await env.db.historyCount() == 0)
        }
    }

    @Test func clearingTheHistoryReleasesWhatItHeld() async throws {
        try await DedupeKit.run { env in
            let url = try env.pdf("read.pdf", title: Self.title, doi: "10.1038/s41586-025-01234-5")
            let bytes = try Data(contentsOf: url)
            let id = try #require(await env.ingest([url]).added.first)
            _ = try await env.engine.setStatus(paperID: id, .done)
            try await env.engine.softDelete(paperID: id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            let again = env.downloads.appendingPathComponent("again.pdf")
            try bytes.write(to: again)
            let newID = try #require(await env.ingest([again]).added.first)
            let review = try await env.onlyOpenReview()
            #expect(review.matchesHistory && review.holdsNewPaper)
            env.events.clear()
            #expect(try await env.engine.clearDuplicateHistory() == 1)
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            let p = try await env.paper(newID)
            #expect(p.scheduleMode == .auto && p.deadline != nil)
            await env.events.drain()
            #expect(env.events.notices.contains(.reviewClosed(reviewID: review.id)))
        }
    }

    // MARK: Asked once

    @Test func anAnsweredPairIsNotAskedAgain() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            #expect(try await env.db.decidedPairs(involving: [e.pk]).contains([min(e.pk, n.pk), max(e.pk, n.pk)]))
            // The earlier paper checked again: the skipped copy (in Recently Deleted) isn't proposed.
            let subject = await DedupeIndex.subject(for: e, ctx: env.ctx)
            let m = await DedupeIndex.match(subject, ids: e.ids, excluding: e.pk, settings: DedupeSettings(), ctx: env.ctx)
            #expect(m?.existing?.id != n.id)
        }
    }

    /// Reviews that compared another paper with the one merged away now compare it with the one kept.
    @Test func aMergeRetargetsOtherQuestions() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env)
            let mid = try #require(await env.ingest([try env.pdf("other.pdf", title: "A study of zebrafish fin regeneration")]).added.first)
            let m = try await env.paper(mid)
            let other = DupReview(newPaperID: mid, existingPaperID: n.id, band: .possible, score: 0.7, createdAt: DedupeKit.start,
                                  newPaperPK: m.pk, existingPaperPK: n.pk, relation: .sameWork, origin: .scan)
            try await env.db.insertDupReview(other)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let moved = try #require(try await env.db.dupReview(id: other.id))
            #expect(moved.state == .open && moved.existingPaperPK == e.pk)
        }
    }

    // MARK: Toasts worded from their review

    @Test func classicToastsAreWordedFromTheirReview() async throws {
        try await DedupeKit.run { env in
            _ = await env.ingest([try env.pdf("2401.01234v1.pdf", title: Self.title)])
            env.events.clear()
            _ = await env.ingest([try env.pdf("2401.01234v3.pdf", title: Self.title)])
            let review = try await env.onlyOpenReview()
            let classic = try #require(env.events.toasts.first { DupExplainer.classicSameWorkPendingID($0) != nil })
            let worded = try #require(await env.engine.duplicateToast(replacing: classic))
            #expect(worded.id == "dup-" + review.id)
            #expect(worded.buttons.map(\.action) == [.openDuplicateReview(id: review.id),
                                                     .replaceKeepingChecklist(pendingID: try #require(review.pendingID))])
            #expect(worded.message.hasPrefix("A newer version of “"))
            // A toast without an open review stays as it is.
            let plain = Toast(kind: .info, message: "x", buttons: [.init(title: "a", action: .replaceKeepingChecklist(pendingID: "nope")),
                                                                    .init(title: "b", action: .ignorePending(pendingID: "nope"))])
            #expect(await env.engine.duplicateToast(replacing: plain) == nil)
        }
    }

    // MARK: Library check

    @Test func theLibraryCheckReportsProgressAndStops() async throws {
        try await DedupeKit.run { env in
            for i in 0..<4 { _ = await env.ingest([try env.pdf("p\(i).pdf", title: "Unrelated study number \(i) of fins")]) }
            final class Seen: @unchecked Sendable {
                private let lock = NSLock()
                private var v: [Int] = []
                func add(_ x: Int) { lock.withLock { v.append(x) } }
                var all: [Int] { lock.withLock { v } }
            }
            let seen = Seen()
            let summary = try await env.engine.checkDuplicates { done, total in
                #expect(total == 4)
                seen.add(done)
            }
            #expect(summary.checked == 4 && seen.all == [1, 2, 3, 4])
            let task = Task { try await env.engine.checkDuplicates() }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    /// An email's attachment of a paper the library has is linked as today (no review, nothing parked).
    @Test func anEmailOfAPaperYouHaveIsLinkedAsToday() async throws {
        try await DedupeKit.run { env in
            let doi = "10.1038/s41586-025-01234-5"
            let id = try #require(await env.ingest([try env.pdf("paper.pdf", title: Self.title, doi: doi)]).added.first)
            let url = try env.pdf("attachment.pdf", title: Self.title, doi: doi)
            let summary = await env.ingest([url], origin: .mail, annotations: [url: ImportAnnotation(sameWorkPolicy: .link)])
            #expect(summary.items.first?.outcome == .sameWork(existingPaperID: id))
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
        }
    }
}
