import Foundation
import Testing
@testable import PaperDeckCore

/// The resolution engine (DQ §4.1, dive-dedupe §6.2): each of the four choices × {parked new
/// file, held new paper, earlier paper in Recently Deleted, removed paper's tombstone}, with the
/// files (`.replaced` backup, PDF swapped), ids (the newer version's DOI adopted, the old one an
/// alias, never a `ux_doi` conflict), checklist and reading cycles, `dup_pair`, provenance —
/// and undo within the window.
@Suite(.serialized) struct DupResolutionTests {
    static let preprintDOI = "10.1101/2024.03.01.582345"
    static let journalDOI = "10.1038/s41586-025-01234-5"
    static let title = "Molecular dynamics of the developing human neocortex"

    /// bioRxiv says the preprint was published as `journalDOI`.
    static let fetcher = DedupeKit.Fetcher(routes: [
        ("https://api.biorxiv.org/details/biorxiv/\(preprintDOI)", 200, """
        {"collection":[{"title":"\(title)","authors":"Wang, L.; Lovelace, A.","doi":"\(preprintDOI)","date":"2024-03-01",
         "version":"2","server":"bioRxiv","published":"\(journalDOI)","abstract":"Cells of the developing cortex."}]}
        """),
    ])

    static func lookupOn() -> EngineSettings { DedupeKit.settings(lookup: true) }

    /// The preprint (finished, with the user's checklist work and notes) in the library, then the
    /// journal PDF dropped: parked with a "newer version" review.
    static func parked(_ env: DedupeKit.Env, done: Bool = true) async throws -> (e: Paper, review: DupReview) {
        let id = try #require(await env.ingest([try env.pdf("preprint.pdf", title: title, doi: preprintDOI)]).added.first)
        _ = try await env.engine.addChecklistItem(paperID: id, text: "My own step", minutes: 10)
        _ = try await env.engine.setNotes(paperID: id, "my notes")
        if done { _ = try await env.engine.setStatus(paperID: id, .done) }
        let e = try await env.paper(id)
        #expect(e.ids.publishedDOI == journalDOI)
        _ = await env.ingest([try env.pdf("s41586-025-01234-5.pdf", title: title, doi: journalDOI)])
        let review = try await env.onlyOpenReview()
        #expect(review.isParked && review.relation == .newerVersion && review.newerSide == .new)
        return (e, review)
    }

    /// The same text arriving twice without identifiers: the second is held.
    static func held(_ env: DedupeKit.Env, newDOI: String? = nil, existingDOI: String? = nil) async throws -> (e: Paper, n: Paper, review: DupReview) {
        let body = DedupeKit.body(seed: "held pair")
        let eid = try #require(await env.ingest([try env.pdf("earlier.pdf", title: title, doi: existingDOI, body: body)]).added.first)
        _ = try await env.engine.setNotes(paperID: eid, "earlier notes")
        let nid = try #require(await env.ingest([try env.pdf("later.pdf", title: title, doi: newDOI, body: body)]).added.first)
        let review = try await env.onlyOpenReview()
        #expect(review.holdsNewPaper && review.newPaperID == nid)
        return (try await env.paper(eid), try await env.paper(nid), review)
    }

    static func replacedEntries(_ env: DedupeKit.Env) -> [String] {
        let root = ReplacedPDFs.root(env.engine.paths)
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    // MARK: Parked new file

    @Test func parkedKeepNewSwapsTheFileAdoptsTheJournalDOIAndUndoes() async throws {
        try await DedupeKit.run(Self.lookupOn(), fetcher: Self.fetcher) { env in
            let (e, review) = try await Self.parked(env)
            let detail = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(detail.defaultChoice == .keepNew && detail.explanation.headline == "Same paper, newer version")
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            await env.settle()
            let kept = try await env.paper(e.id)
            #expect(r.keptPaperID == e.id && kept.pk == e.pk && kept.sha256 != e.sha256)
            #expect(kept.ids.doi == Self.journalDOI)                      // the journal's DOI now
            let keys = try await env.db.dupKeys(paperPK: e.pk)
            #expect(keys.contains(DupKey(kind: .preprintDOI, value: DupKeys.doiToken(Self.preprintDOI)!, source: .merge)))
            #expect(try await env.db.checklist(paperPK: e.pk).contains { $0.text == "My own step" })
            #expect(kept.notes == "my notes" && kept.status == .done)
            #expect(Self.replacedEntries(env).count == 1)
            #expect(try await env.db.dupReview(id: review.id)?.state == .resolved)
            #expect(try await env.db.dupReview(id: review.id)?.choice == "keep_new")
            #expect(try await env.db.livePapers().count == 1)
            // Undo: the preprint's file and ids are back, the journal PDF waits again.
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let back = try await env.paper(e.id)
            #expect(back.sha256 == e.sha256 && back.ids.doi == Self.preprintDOI)
            #expect(await env.engine.intake.pendingIDs().count == 1)
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
            #expect(!(try await env.db.dupKeys(paperPK: e.pk)).contains { $0.source == .merge })
            // The token is single-use.
            #expect(!(try await env.engine.undoDuplicateResolution(token: r.undoToken!)))
        }
    }

    @Test func parkedRereadEarlierReopensAndUndoes() async throws {
        try await DedupeKit.run(Self.lookupOn(), fetcher: Self.fetcher) { env in
            let (e, review) = try await Self.parked(env)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id,
                                                          .rereadEarlier(checklist: .uncheckAll, deadline: .auto, useNewFile: false))
            let p = try await env.paper(e.id)
            #expect(p.status == .toRead && p.doneAt == nil && p.sha256 == e.sha256 && p.deadline != nil)
            let cycles = try await env.db.readingCycles(paperPK: e.pk)
            #expect(cycles.map(\.n) == [1, 2] && cycles[0].doneAt != nil && cycles[1].reason == "reread")
            #expect(try await env.db.checklist(paperPK: e.pk).allSatisfy { $0.doneAt == nil })
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let back = try await env.paper(e.id)
            #expect(back.status == .done && back.doneAt != nil)
            // Exactly as before: no reading cycle was recorded then.
            #expect(try await env.db.readingCycles(paperPK: e.pk).isEmpty)
            #expect(await env.engine.intake.pendingIDs().count == 1)
        }
    }

    @Test func parkedKeepBothCommitsTheOtherVersionAndRemembers() async throws {
        try await DedupeKit.run(Self.lookupOn(), fetcher: Self.fetcher) { env in
            let (e, review) = try await Self.parked(env)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepBoth(linkAsRelated: false))
            let newID = try #require(r.keptPaperID)
            let n = try await env.paper(newID)
            let earlier = try await env.paper(e.id)
            #expect(n.ids.doi == Self.journalDOI && n.isLive && earlier.isLive)
            #expect(try await env.db.dupPair(e.pk, n.pk)?.decision == "distinct")
            #expect(r.undoToken == nil)
            // Never asked again about this pair.
            let check = try await env.engine.checkDuplicates()
            #expect(check.opened.isEmpty)
        }
    }

    @Test func parkedSkipKeepsTheCopyForTheUndoWindow() async throws {
        try await DedupeKit.run(Self.lookupOn(), fetcher: Self.fetcher) { env in
            let (_, review) = try await Self.parked(env, done: false)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let pending = await env.engine.intake.pendingIDs()
            #expect(pending.count == 1 && pending.first == review.pendingID)
            // The re-parked file can still be applied.
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            #expect(try await env.db.livePapers().first?.ids.doi == Self.journalDOI)
        }
    }

    @Test func choicesThatDontApplyAreRefused() async throws {
        try await DedupeKit.run(Self.lookupOn(), fetcher: Self.fetcher) { env in
            let (_, review) = try await Self.parked(env)
            await #expect(throws: DupResolutionError.choiceUnavailable("add_again")) {
                _ = try await env.engine.resolveDuplicate(reviewID: review.id, .addAgain)
            }
            await #expect(throws: DupResolutionError.reviewNotFound("nope")) {
                _ = try await env.engine.resolveDuplicate(reviewID: "nope", .skip)
            }
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            await #expect(throws: DupResolutionError.reviewClosed(review.id)) {
                _ = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            }
        }
    }

    // MARK: Held new paper

    @Test func heldKeepNewMergesIntoTheEarlierPaperAndUndoes() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env, newDOI: Self.journalDOI, existingDOI: Self.preprintDOI)
            _ = try await env.engine.addChecklistItem(paperID: n.id, text: "Step I wrote on the copy", minutes: 5)
            _ = try await env.engine.setNotes(paperID: n.id, "copy notes")
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            await env.settle()
            let kept = try await env.paper(e.id)
            #expect(kept.sha256 == n.sha256 && kept.ids.doi == Self.journalDOI)           // ux_doi safe
            #expect(try await env.db.paper(id: n.id) == nil)
            #expect(kept.notes.contains("earlier notes") && kept.notes.contains("copy notes"))
            #expect(try await env.db.checklist(paperPK: e.pk).contains { $0.text == "Step I wrote on the copy" })
            #expect(Self.replacedEntries(env).count == 2)       // the earlier PDF + the copy's folder
            let resolved = try #require(try await env.db.dupReview(id: review.id))
            #expect(resolved.state == .resolved && resolved.newPaperPK == nil)
            #expect(try await env.db.livePapers().count == 1)
            // Undo: both papers again, each with its own file; the review is open again.
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            await env.settle()
            let backE = try await env.paper(e.id), backN = try await env.paper(n.id)
            #expect(backE.sha256 == e.sha256 && backE.ids.doi == Self.preprintDOI && backE.notes == "earlier notes")
            #expect(backN.sha256 == n.sha256 && backN.ids.doi == Self.journalDOI && backN.notes == "copy notes")
            #expect(FileManager.default.fileExists(atPath: env.ctx.pdfURL(backN).path))
            #expect(FileManager.default.fileExists(atPath: env.ctx.pdfURL(backE).path))
            #expect(try FileOps.sha256(of: env.ctx.pdfURL(backE)) == e.sha256)
            #expect(try FileOps.sha256(of: env.ctx.pdfURL(backN)) == n.sha256)
            let reopened = try #require(try await env.db.dupReview(id: review.id))
            #expect(reopened.state == .open && reopened.newPaperPK == backN.pk)
        }
    }

    @Test func heldRereadEarlierRemovesTheCopy() async throws {
        try await DedupeKit.run { env in
            let (unread, n, review) = try await Self.held(env)
            // "Re-read" is offered only for a paper that was finished.
            #expect(try await !env.engine.duplicateReviewDetail(id: review.id).choices.contains(.rereadEarlier))
            await #expect(throws: DupResolutionError.choiceUnavailable("reread_earlier")) {
                _ = try await env.engine.resolveDuplicate(reviewID: review.id, .rereadEarlier(checklist: .keepProgress,
                                                                                              deadline: .auto, useNewFile: false))
            }
            #expect(try await env.paper(n.id).isLive)
            #expect(try await env.paper(unread.id).status == .toRead)
            let e = try await env.engine.setStatus(paperID: unread.id, .done)
            #expect(try await env.engine.duplicateReviewDetail(id: review.id).defaultChoice == .rereadEarlier)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id,
                                                          .rereadEarlier(checklist: .keepProgress, deadline: .unscheduled, useNewFile: false))
            #expect(r.removedPaperID == n.id && r.keptPaperID == e.id)
            #expect(try await env.paper(n.id).isDeleted)
            let p = try await env.paper(e.id)
            #expect(p.status == .toRead && p.scheduleMode == .none)
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            #expect(try await env.paper(n.id).isLive)
            let back = try await env.paper(e.id)
            #expect(back.status == e.status && back.scheduleMode == e.scheduleMode && back.deadline == e.deadline)
            #expect(try await env.db.readingCycles(paperPK: e.pk).isEmpty)
        }
    }

    @Test func heldKeepBothReleasesTheHoldAndRemembers() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env)
            #expect(n.scheduleMode == .none && n.aiState == .held)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepBoth(linkAsRelated: false))
            let released = try await env.paper(n.id)
            #expect(released.scheduleMode == .auto && released.deadline != nil)
            #expect(released.aiState == .queued)
            #expect(try await env.db.dupPair(e.pk, n.pk)?.decision == "distinct")
            #expect(try await env.engine.checkDuplicates().opened.isEmpty)
            // Undo: held again, the pair forgotten.
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let again = try await env.paper(n.id)
            #expect(again.scheduleMode == .none && again.deadline == nil && again.aiState == .held)
            #expect(try await env.db.dupPair(e.pk, n.pk) == nil)
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
        }
    }

    @Test func heldSkipMovesTheCopyToRecentlyDeleted() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.held(env)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            #expect(r.removedPaperID == n.id && r.keptPaperID == e.id)
            #expect(try await env.paper(n.id).isDeleted)
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            #expect(try await env.paper(n.id).isLive)
        }
    }

    // MARK: Earlier paper in Recently Deleted

    @Test func deletedEarlierPaperRestoreChoices() async throws {
        for choice in [DupChoice.keepNew(reread: false), .rereadEarlier(checklist: .keepProgress, deadline: .auto, useNewFile: false),
                       .keepBoth(linkAsRelated: false), .skip] {
            try await DedupeKit.run { env in
                let eid = try #require(await env.ingest([try env.pdf("first.pdf", title: Self.title, doi: Self.journalDOI)]).added.first)
                let e = try await env.paper(eid)
                try await env.engine.softDelete(paperID: eid)
                _ = await env.ingest([try env.pdf("second.pdf", title: Self.title, doi: Self.journalDOI)])
                let review = try await env.onlyOpenReview()
                let detail = try await env.engine.duplicateReviewDetail(id: review.id)
                #expect(detail.existing.deletedAt != nil && detail.defaultChoice == .rereadEarlier)
                let r = try await env.engine.resolveDuplicate(reviewID: review.id, choice)
                let p = try await env.paper(eid)
                switch choice.kind {
                case .keepNew:
                    #expect(p.isLive && p.sha256 != e.sha256)
                case .rereadEarlier:
                    #expect(p.isLive && p.sha256 == e.sha256 && p.status == .toRead)
                    #expect(await env.engine.intake.pendingIDs().isEmpty)
                case .keepBoth:
                    #expect(p.isDeleted)
                    #expect(try await env.db.livePapers().map(\.id) == [r.keptPaperID])
                case .skip:
                    let live = try await env.db.livePapers()
                    #expect(p.isDeleted && live.isEmpty)
                default: break
                }
                if let token = r.undoToken {
                    #expect(try await env.engine.undoDuplicateResolution(token: token))
                    #expect(try await env.paper(eid).isDeleted, "\(choice)")
                    #expect(await env.engine.intake.pendingIDs().count == 1, "\(choice)")
                }
            }
        }
    }

    // MARK: A removed paper's tombstone

    @Test func tombstoneAddAgainAndSkip() async throws {
        for addAgain in [true, false] {
            try await DedupeKit.run { env in
                let url = try env.pdf("read.pdf", title: Self.title, doi: Self.journalDOI)
                let bytes = try Data(contentsOf: url)
                let id = try #require(await env.ingest([url]).added.first)
                _ = try await env.engine.setStatus(paperID: id, .done)
                try await env.engine.softDelete(paperID: id)
                _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
                let again = env.downloads.appendingPathComponent("again.pdf")
                try bytes.write(to: again)
                let newID = try #require(await env.ingest([again]).added.first)
                let review = try await env.onlyOpenReview()
                let r = try await env.engine.resolveDuplicate(reviewID: review.id, addAgain ? .addAgain : .skip)
                let p = try await env.paper(newID)
                if addAgain {
                    #expect(p.isLive && p.scheduleMode == .auto && p.deadline != nil)
                    #expect(try await env.db.readingCycles(paperPK: p.pk).map(\.n) == [2])
                } else {
                    #expect(p.isDeleted && r.removedPaperID == newID)
                }
                #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
                let undone = try await env.paper(newID)
                #expect(undone.isLive && undone.scheduleMode == .none)
                #expect(try await env.db.readingCycles(paperPK: undone.pk).isEmpty)
            }
        }
    }

    // MARK: Lifecycle

    /// A parked file doesn't survive a relaunch: its review expires visibly.
    @Test func lostParkedReviewsExpire() async throws {
        try await DedupeKit.run { env in
            let id = try #require(await env.ingest([try env.pdf("a.pdf", title: Self.title, doi: Self.journalDOI)]).added.first)
            let e = try await env.paper(id)
            let orphan = DupReview(newPaperID: nil, existingPaperID: id, band: .certain, score: 1, createdAt: DedupeKit.start,
                                   existingPaperPK: e.pk, relation: .sameWork, pendingID: "lost-with-relaunch", stagedName: "x.pdf")
            try await env.db.insertDupReview(orphan)
            let state = await env.engine.prepareDuplicateReviews()
            #expect(state == (open: 0, expired: 1))
            #expect(try await env.db.dupReview(id: orphan.id)?.state == .expired)
            await #expect(throws: DupResolutionError.reviewClosed(orphan.id)) {
                _ = try await env.engine.resolveDuplicate(reviewID: orphan.id, .skip)
            }
        }
    }

    /// A merge undone after its window passed is refused (the token expired).
    @Test func undoWindowIsThirtySeconds() async throws {
        try await DedupeKit.run { env in
            let (_, _, review) = try await Self.held(env)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            env.clock.now = env.clock.now.addingTimeInterval(UndoToken.lifetime + 1)
            #expect(!(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken))))
        }
    }

    /// Library ▸ Check for Duplicates…: opens reviews for new pairs among committed papers, and
    /// never twice for a pair.
    @Test func checkTheLibrary() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            let body = DedupeKit.body(seed: "scan")
            _ = await env.ingest([try env.pdf("a.pdf", title: Self.title, body: body)])
            _ = await env.ingest([try env.pdf("b.pdf", title: Self.title, body: body)])
            _ = await env.ingest([try env.pdf("c.pdf", title: "An unrelated study of zebrafish fins")])
            #expect(try await env.db.dupReviews(state: .open).isEmpty)       // the check was off at import
            env.settings.value.dedupe.enabled = true
            let first = try await env.engine.checkDuplicates()
            #expect(first.checked == 3 && first.opened.count == 1)
            let review = try await env.onlyOpenReview()
            #expect(review.origin == .scan && review.band == .likely)
            let second = try await env.engine.checkDuplicates()
            #expect(second.opened.isEmpty && second.known >= 1)
            let report = try await env.engine.dedupeReport()
            #expect(report.count == 1 && report[0].known)
        }
    }
}
