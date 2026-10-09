import Foundation
import Testing
@testable import PaperDeckCore

/// The intake hooks (DQ §3.7): certain → parked + review; likely → committed held (no DDL, AI
/// held) with its review in the insert transaction; possible → normal commit + review; a
/// removed paper read before; the batch toast; supplements; the master switch off.
@Suite(.serialized) struct DupIntakeTests {
    static let nature = "10.1038/s41586-025-01234-5"
    static let title = "Molecular dynamics of the developing human neocortex"

    @Test func identityHitIsParkedWithAReviewAndTheClassicToast() async throws {
        try await DedupeKit.run { env in
            let first = try env.pdf("first.pdf", title: Self.title, doi: Self.nature)
            let a = await env.ingest([first])
            let existingID = try #require(a.added.first)
            env.events.clear()
            let second = try env.pdf("second.pdf", title: Self.title, doi: Self.nature)
            let b = await env.ingest([second])
            #expect(b.added.isEmpty)
            #expect(b.items.first?.outcome == .sameWork(existingPaperID: existingID))
            let pending = await env.engine.intake.pendingIDs()
            #expect(pending.count == 1)
            let review = try await env.onlyOpenReview()
            #expect(review.band == .certain && review.isParked && review.pendingID == pending.first)
            #expect(review.existingPaperID == existingID && review.stagedName == "second.pdf")
            #expect(review.evidence.contains { $0.code == .sharedDOI })
            // The engine's toast is today's (the app words it from the review); the UI hears of the review.
            let toast = try #require(env.events.toasts.first { DupExplainer.classicSameWorkPendingID($0) != nil })
            #expect(toast.buttons.map(\.action) == [.replaceKeepingChecklist(pendingID: pending[0]), .ignorePending(pendingID: pending[0])])
            #expect(env.events.notices.contains(.reviewOpened(reviewID: review.id, paperID: nil)))
            // The toast's answer closes the review.
            await env.engine.intake.resolvePending(pendingID: pending[0], replace: false)
            #expect(try await env.db.dupReview(id: review.id)?.state == .resolved)
            #expect(try await env.db.dupReview(id: review.id)?.choice == "skip")
        }
    }

    @Test func aPaperInRecentlyDeletedIsAskedAboutNotDuplicated() async throws {
        try await DedupeKit.run { env in
            let a = await env.ingest([try env.pdf("first.pdf", title: Self.title, doi: Self.nature)])
            let id = try #require(a.added.first)
            try await env.engine.softDelete(paperID: id)
            let b = await env.ingest([try env.pdf("again.pdf", title: Self.title, doi: Self.nature)])
            #expect(b.added.isEmpty)
            let review = try await env.onlyOpenReview()
            #expect(review.isParked && review.existingPaperID == id)
            #expect(try await env.db.livePapers().isEmpty)
        }
    }

    @Test func likelyMatchIsCommittedHeldWithItsReview() async throws {
        try await DedupeKit.run { env in
            let body = DedupeKit.body(seed: "shared text")
            let a = await env.ingest([try env.pdf("journal.pdf", title: Self.title, body: body)])
            let existingID = try #require(a.added.first)
            env.events.clear()
            // Another copy of the same text (different bytes, no identifier printed on either).
            let b = await env.ingest([try env.pdf("authors-copy.pdf", title: Self.title, body: body)])
            let newID = try #require(b.added.first)
            let held = try await env.paper(newID)
            #expect(held.scheduleMode == .none && held.deadline == nil)
            let review = try await env.onlyOpenReview()
            #expect(review.band == .likely && review.newPaperID == newID && review.existingPaperID == existingID)
            #expect(review.holdsNewPaper && review.held?.scheduleHeld == true && review.held?.placement == "normal")
            #expect(review.evidence.contains { $0.code == .text })
            // AI reading is held while the review is open; the intent is recorded for "keep both".
            #expect(held.aiState == .held)
            #expect(try await env.db.dupReview(id: review.id)?.held?.aiQueue == true)
            // The review's toast replaces 「已添加 · DDL」.
            #expect(env.events.toasts.contains { $0.id == "dup-" + review.id && $0.buttons.first?.action == .openDuplicateReview(id: review.id) })
            #expect(!env.events.toasts.contains { $0.message.hasPrefix("Added: ") })
            #expect(env.events.notices.contains(.reviewOpened(reviewID: review.id, paperID: newID)))
        }
    }

    @Test func anEmailsMergeNeverWaitsOnlyAChip() async throws {
        try await DedupeKit.run { env in
            let body = DedupeKit.body(seed: "mail text")
            _ = await env.ingest([try env.pdf("journal.pdf", title: Self.title, body: body)])
            let url = try env.pdf("attachment.pdf", title: Self.title, body: body)
            let note = ImportAnnotation(sameWorkPolicy: .link)
            let b = await env.ingest([url], origin: .mail, annotations: [url: note])
            let newID = try #require(b.added.first)
            let p = try await env.paper(newID)
            #expect(p.scheduleMode != .none)
            let review = try await env.onlyOpenReview()
            #expect(review.band == .possible && review.origin == .mail && !review.holdsNewPaper)
        }
    }

    @Test func aRemovedPaperYouReadIsRemembered() async throws {
        try await DedupeKit.run { env in
            let url = try env.pdf("read.pdf", title: Self.title, doi: Self.nature)
            let bytes = try Data(contentsOf: url)
            let a = await env.ingest([url])
            let id = try #require(a.added.first)
            _ = try await env.engine.setStatus(paperID: id, .done)
            try await env.engine.softDelete(paperID: id)
            let purged = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            #expect(purged == [id])
            #expect(try await env.db.historyCount() == 1)
            // The same bytes, months later.
            let again = env.downloads.appendingPathComponent("again.pdf")
            try bytes.write(to: again)
            let b = await env.ingest([again])
            let newID = try #require(b.added.first)
            let review = try await env.onlyOpenReview()
            #expect(review.matchesHistory && review.band == .certain && review.newPaperID == newID)
            #expect(try await env.paper(newID).scheduleMode == .none)
            let detail = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(detail.choices == [.addAgain, .skip] && detail.existing.purgedAt != nil && detail.existing.readCount == 1)
            #expect(detail.explanation.historyLine?.contains("you had finished it") == true)
        }
    }

    @Test func aRemovedPaperNeverReadOnlyGetsAChip() async throws {
        try await DedupeKit.run { env in
            let url = try env.pdf("unread.pdf", title: Self.title, doi: Self.nature)
            let bytes = try Data(contentsOf: url)
            let id = try #require(await env.ingest([url]).added.first)
            try await env.engine.softDelete(paperID: id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            let again = env.downloads.appendingPathComponent("again.pdf")
            try bytes.write(to: again)
            let newID = try #require(await env.ingest([again]).added.first)
            let review = try await env.onlyOpenReview()
            #expect(review.band == .possible && !review.holdsNewPaper)
            #expect(try await env.paper(newID).scheduleMode != .none)
        }
    }

    @Test func historyOffWritesNoTombstone() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(history: false))) { env in
            let id = try #require(await env.ingest([try env.pdf("x.pdf", title: Self.title, doi: Self.nature)]).added.first)
            try await env.engine.softDelete(paperID: id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            #expect(try await env.db.historyCount() == 0)
        }
    }

    @Test func aBatchGetsOneReviewToast() async throws {
        try await DedupeKit.run { env in
            let dois = (1...2).map { "10.1038/s41586-025-0000\($0)-1" }
            for (i, doi) in dois.enumerated() { _ = await env.ingest([try env.pdf("lib\(i).pdf", title: "Library paper \(i) on cortex", doi: doi)]) }
            env.events.clear()
            var files: [URL] = []
            for (i, doi) in dois.enumerated() { files.append(try env.pdf("dup\(i).pdf", title: "Library paper \(i) on cortex", doi: doi)) }
            for i in 0..<3 { files.append(try env.pdf("new\(i).pdf", title: "Brand new study number \(i) of retina")) }
            let summary = await env.ingest(files)
            #expect(summary.added.count == 3)
            #expect(!env.events.toasts.contains { DupExplainer.classicSameWorkPendingID($0) != nil })
            let batch = env.events.toasts.filter { $0.id == "dup-batch-" + summary.batchID }
            #expect(batch.count == 1)
            #expect(batch.first?.message == "2 files look like papers you already have")
            let open = try await env.db.dupReviews(state: .open)
            #expect(open.count == 2 && open.allSatisfy { $0.batchID == summary.batchID })
            if case .openDuplicateReview(let first)? = batch.first?.buttons.first?.action {
                #expect(open.map(\.id).contains(first))
            } else { Issue.record("no review button") }
            #expect(env.events.notices.contains(.openCount(2)))
        }
    }

    @Test func aSupplementPrintingThePapersDOIIsNeverReplacedFirst() async throws {
        try await DedupeKit.run { env in
            let paper = try #require(await env.ingest([try env.pdf("paper.pdf", title: Self.title, doi: Self.nature, pages: 12)]).added.first)
            _ = await env.ingest([try env.pdf("mmc1.pdf", title: "Supplementary Information", doi: Self.nature, pages: 2)])
            let review = try await env.onlyOpenReview()
            #expect(review.relation == .supplement && review.isParked)
            let detail = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(detail.defaultChoice == .attachSupplement && detail.choices.first == .attachSupplement)
            #expect(!detail.choices.contains(.keepNew))
            let before = try await env.paper(paper)
            let result = try await env.engine.resolveDuplicate(reviewID: review.id, .attachSupplement)
            #expect(result.keptPaperID == paper)
            let after = try await env.paper(paper)
            #expect(after.sha256 == before.sha256)
            let folder = env.ctx.folderURL(after).appendingPathComponent(IntakeActor.supplementsFolder)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["mmc1.pdf"])
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            // Undo: the file waits again, its review is open again.
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(result.undoToken)))
            #expect(await env.engine.intake.pendingIDs().count == 1)
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
        }
    }

    @Test func masterSwitchOffKeepsTodaysFlow() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            let body = DedupeKit.body(seed: "same")
            _ = await env.ingest([try env.pdf("first.pdf", title: Self.title, doi: Self.nature, body: body)])
            env.events.clear()
            _ = await env.ingest([try env.pdf("second.pdf", title: Self.title, doi: Self.nature, body: body)])
            let pending = await env.engine.intake.pendingIDs()
            let toast = try #require(env.events.toasts.first)
            #expect(toast.buttons.map(\.action) == [.replaceKeepingChecklist(pendingID: pending[0]), .ignorePending(pendingID: pending[0])])
            #expect(toast.message.hasPrefix("Same paper already in your library: Molecular dynamics") && toast.message.hasSuffix(" · new file second.pdf"))
            // A likely copy (no DOI) is simply added, as today.
            let c = await env.ingest([try env.pdf("third.pdf", title: Self.title, body: body)])
            #expect(c.added.count == 1)
            #expect(try await env.paper(c.added[0]).scheduleMode != .none)
            #expect(try await env.db.dupReviews(state: .open).isEmpty && env.events.notices.isEmpty)
            #expect(try await env.db.dupKeys(paperPK: try await env.paper(c.added[0]).pk).isEmpty)
            // No tombstone either.
            try await env.engine.softDelete(paperID: c.added[0])
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            #expect(try await env.db.historyCount() == 0)
        }
    }

    /// The review is written in the same Database call as the held paper: when it can't be,
    /// neither is the paper (a crash can't leave a held paper without its review).
    @Test func heldPaperAndReviewCommitTogether() async throws {
        try await DedupeKit.run { env in
            let body = DedupeKit.body(seed: "seam")
            _ = await env.ingest([try env.pdf("journal.pdf", title: Self.title, body: body)])
            try await env.db.transaction { db in
                try db.db.exec("CREATE TEMP TRIGGER fail_review BEFORE INSERT ON dup_review BEGIN SELECT RAISE(ABORT, 'seam'); END")
            }
            let b = await env.ingest([try env.pdf("copy.pdf", title: Self.title, body: body)])
            #expect(b.added.isEmpty && b.failed == 1)
            #expect(try await env.db.livePapers().count == 1)
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            // No folder of the copy was left behind (the first paper is filed under Papers/).
            let inbox = (try? FileManager.default.contentsOfDirectory(atPath: env.engine.paths.inbox.path)) ?? []
            #expect(inbox.filter { !$0.hasPrefix(".") }.isEmpty)
        }
    }

    /// The check adds little to the ~1 s first card: staged subject + match against 40 papers.
    @Test func intakeCheckIsCheap() async throws {
        try await DedupeKit.run { env in
            var files: [URL] = []
            for i in 0..<40 { files.append(try env.pdf("p\(i).pdf", title: "Study number \(i) of synthetic cortex development")) }
            _ = await env.ingest(files)
            let probe = DedupeKit.pdfData(title: "Study of synthetic cortex development and more", doi: nil,
                                          body: DedupeKit.body(seed: "probe"), pages: 3, tag: "t")
            let url = env.downloads.appendingPathComponent("probe.pdf")
            try probe.write(to: url)
            let x = try await PDFExtractor().extract(url: url, fileName: "probe.pdf")
            // 30 ms; load-tolerant in the default gate (`RDPerf`, ENV-1).
            let budget = RDPerf.gate(30)
            let (best, median) = await RDPerf.best(runs: 15, under: budget) {
                let s = DedupeIndex.stagedSubject(sha256: "probe", ids: x.ids, title: x.fontTitle ?? "", titleRank: .font,
                                                  fileName: "probe.pdf", extracted: x)
                _ = await DedupeIndex.match(s, ids: x.ids, excluding: nil, settings: DedupeSettings(), ctx: env.ctx,
                                            pages: x.pageTexts)
            }
            print("dedupe intake check median \(String(format: "%.2f", median)) ms, best \(String(format: "%.2f", best)) ms")
            #expect(best < budget, "best \(best) ms, median \(median) ms (budget \(budget) ms)")
        }
    }
}
