import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

// Regressions of the duplicate check's verification round (v1 D1–D16), through the engine: temp
// libraries, generated PDFs, mock providers, no network.

@Suite(.serialized) struct DedupeFixesEngineTests {
    static let title = "Molecular dynamics of the developing human neocortex"
    static let preprintDOI = "10.1101/2024.03.01.582345"
    static let journalDOI = "10.1038/s41586-025-01234-5"

    /// The earlier paper (a bioRxiv preprint) and a held copy of the same text without an identifier.
    static func heldCopy(_ env: DedupeKit.Env, seed: String = "privacy pair") async throws -> (e: Paper, n: Paper, review: DupReview) {
        let body = DedupeKit.body(seed: seed)
        let eid = try #require(await env.ingest([try env.pdf("earlier.pdf", title: title, doi: preprintDOI, body: body)]).added.first)
        let nid = try #require(await env.ingest([try env.pdf("revision.pdf", title: title, doi: nil, body: body)]).added.first)
        let review = try await env.onlyOpenReview()
        #expect(review.newPaperID == nid && review.holdsNewPaper)
        return (try await env.paper(eid), try await env.paper(nid), review)
    }

    // MARK: D1 — the privacy floor follows the file

    @Test(arguments: [DupChoice.keepNew(reread: false), .rereadEarlier(checklist: .keepProgress, deadline: .auto, useNewFile: true)])
    func theCopysPrivacyMarksFollowItsFile(_ choice: DupChoice) async throws {
        try await DedupeKit.run { env in
            let pair = try await Self.heldCopy(env)
            let n = pair.n, review = pair.review
            let e = choice.kind == .rereadEarlier ? try await env.engine.setStatus(paperID: pair.e.id, .done) : pair.e
            _ = try await env.engine.setPaperPolicy(paperID: n.id, confidential: true, neverAI: true)
            _ = try await env.db.modifyPaper(pk: n.pk, now: env.clock.now) {
                $0.aiNote = ImportAnnotation.unpublishedHoldNote
                $0.flags.insert(.titleLookupHeld)
            }
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, choice)
            let kept = try await env.paper(e.id)
            #expect(kept.sha256 == n.sha256)                                      // the copy's file
            let policy = try #require(try await env.engine.paperPolicy(paperID: e.id))
            #expect(policy.confidential && policy.neverAI && policy.setBy == .merge)
            #expect(kept.aiNote == ImportAnnotation.unpublishedHoldNote && kept.flags.contains(.titleLookupHeld))
            #expect(try await env.engine.assistPrivacy(paperID: e.id, hostBundleID: nil) == .blocked)
            // The card says so too.
            await env.ctx.sidecars.flush()
            let card = try CardSidecar.decoded(from: Data(contentsOf: env.ctx.folderURL(kept).appendingPathComponent(CardSidecar.fileName)))
            #expect(card.policy?.neverAI == true)

            // Undo: the kept paper's own (no) marks; the copy back with its own.
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            await env.settle()
            let back = try await env.paper(e.id)
            #expect(try await env.engine.paperPolicy(paperID: e.id) == nil)
            #expect(back.aiNote == e.aiNote && !back.flags.contains(.titleLookupHeld) && back.sha256 == e.sha256)
            let copy = try await env.paper(n.id)
            let copyPolicy = try #require(try await env.engine.paperPolicy(paperID: n.id))
            #expect(copyPolicy.confidential && copyPolicy.neverAI)
            #expect(copy.aiNote == ImportAnnotation.unpublishedHoldNote && copy.flags.contains(.titleLookupHeld))
        }
    }

    /// The kept paper without a reading job (none queued, nothing to hold): its file still carries
    /// the copy's "possibly unpublished" note.
    @Test func theUnpublishedNoteFollowsTheFileWithoutAQueuedReading() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.heldCopy(env, seed: "no job kept")
            await env.engine.agents.cancel(paperPK: e.pk)
            #expect(try await env.db.activeJob(paperPK: e.pk) == nil)
            _ = try await env.db.modifyPaper(pk: n.pk, now: env.clock.now) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let kept = try await env.paper(e.id)
            #expect(kept.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: e.pk) == nil)
            #expect(try await env.engine.assistPrivacy(paperID: e.id, hostBundleID: nil) == .confirm([.mailUnpublished]))
        }
    }

    /// A stricter kept paper keeps its marks; the merge never loosens them.
    @Test func aMergeNeverLoosensTheKeptPapersMarks() async throws {
        try await DedupeKit.run { env in
            let (e, _, review) = try await Self.heldCopy(env, seed: "stricter kept")
            _ = try await env.engine.setPaperPolicy(paperID: e.id, confidential: true, neverAI: false)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let policy = try #require(try await env.engine.paperPolicy(paperID: e.id))
            #expect(policy.confidential && !policy.neverAI && policy.setBy == .user)
            #expect(Engine.mergedPolicy(kept: policy, copy: PaperPolicy(confidential: true), now: DedupeKit.start) == nil)
            #expect(Engine.mergedPolicy(kept: nil, copy: nil, now: DedupeKit.start) == nil)
        }
    }

    /// A reading of the kept paper still waiting in the queue would read the unpublished copy: it
    /// waits for confirmation instead; undo puts it back in the queue, and the copy's held reading back.
    @Test func aQueuedReadingOfTheKeptPaperWaitsForConfirmation() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await Self.heldCopy(env, seed: "queued kept")
            #expect(try await env.db.activeJob(paperPK: e.pk)?.state == .queued)
            #expect(try await env.db.activeJob(paperPK: n.pk)?.state == .held)
            _ = try await env.db.modifyPaper(pk: n.pk, now: env.clock.now) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let kept = try await env.paper(e.id)
            #expect(try await env.db.activeJob(paperPK: e.pk)?.state == .held)
            #expect(kept.aiState == .held && kept.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.engine.assistPrivacy(paperID: e.id, hostBundleID: nil) == .confirm([.mailUnpublished]))
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            await env.settle()
            let back = try await env.paper(e.id)
            #expect(try await env.db.activeJob(paperPK: e.pk)?.state == .queued && back.aiNote == nil)
            let copy = try await env.paper(n.id)
            #expect(try await env.db.activeJob(paperPK: copy.pk)?.state == .held)
            #expect(copy.aiState == .held && copy.aiNote == ImportAnnotation.unpublishedHoldNote)
        }
    }

    /// A parked file with an email's annotation brings its provenance and its held titles along.
    @Test func aParkedFileKeepsItsEmailsMarks() async throws {
        try await DedupeKit.run { env in
            let eid = try #require(await env.ingest([try env.pdf("paper.pdf", title: Self.title, doi: Self.journalDOI)]).added.first)
            let url = try env.pdf("attachment.pdf", title: Self.title, doi: Self.journalDOI)
            let source = PaperProvenance(internetMessageID: "<m1@example.org>", fromAddress: "colleague@example.org",
                                         fromName: "A Colleague", subject: "Our paper", addedAt: DedupeKit.start)
            let note = ImportAnnotation(provenance: source, sameWorkPolicy: .prompt, identifierLookupsOnly: true)
            _ = await env.ingest([url], origin: .mail, annotations: [url: note])
            let review = try await env.onlyOpenReview()
            #expect(review.isParked)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let kept = try await env.paper(eid)
            #expect(kept.flags.contains(.titleLookupHeld))
            #expect(try await env.db.paperSources(paperPK: kept.pk).map(\.internetMessageID) == ["<m1@example.org>"])
            #expect(try await env.engine.undoDuplicateResolution(token: try #require(r.undoToken)))
            let back = try await env.paper(eid)
            let sources = try await env.db.paperSources(paperPK: back.pk)
            #expect(!back.flags.contains(.titleLookupHeld) && sources.isEmpty)
        }
    }

    // MARK: D2 — the article after its notice

    @Test func theArticleAfterItsNoticeIsKeptWithItsTitle() async throws {
        try await DedupeKit.run { env in
            let doi = "10.1038/s41586-024-07777-7"
            let nid = try #require(await env.ingest([try env.pdf("notice.pdf", title: "Author Correction: \(Self.title)", doi: doi,
                                                                 pages: 1)]).added.first)
            _ = await env.ingest([try env.pdf("article.pdf", title: Self.title, doi: doi, pages: 12)])
            let review = try await env.onlyOpenReview()
            let d = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(review.isParked && review.relation == .newerVersion && review.newerSide == .new)
            #expect(d.defaultChoice == .keepNew && d.choices.first == .keepNew)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let kept = try await env.paper(nid)
            #expect(kept.title == Self.title && kept.pageCount == 12)
            #expect(try await env.db.livePapers().count == 1)
        }
    }

    // MARK: D4 — tombstones keep nothing private

    @Test func tombstonesKeepNothingPrivate() async throws {
        try await DedupeKit.run { env in
            func purge(_ id: String, alreadyDeleted: Bool = false) async throws {
                if !alreadyDeleted { try await env.engine.softDelete(paperID: id) }
                _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            }
            func add(_ name: String, doi: String? = nil) async throws -> Paper {
                let id = try #require(await env.ingest([try env.pdf(name, title: "Private study \(name) of cortex organoids",
                                                                    doi: doi)]).added.first)
                return try await env.engine.setStatus(paperID: id, .done)
            }
            let confidential = try await add("a.pdf")
            _ = try await env.engine.setPaperPolicy(paperID: confidential.id, confidential: true, neverAI: false)
            try await purge(confidential.id)
            let neverAI = try await add("b.pdf")
            _ = try await env.engine.setPaperPolicy(paperID: neverAI.id, confidential: false, neverAI: true)
            try await purge(neverAI.id)
            let unpublished = try await add("c.pdf")
            _ = try await env.db.modifyPaper(pk: unpublished.pk, now: env.clock.now) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            #expect(try await env.db.activeJob(paperPK: unpublished.pk) != nil)
            try await env.engine.softDelete(paperID: unpublished.id)
            let unpublishedNoteKept = try await env.paper(unpublished.id).aiNote == ImportAnnotation.unpublishedHoldNote
            try await purge(unpublished.id, alreadyDeleted: true)
            // A person's email (its message unknown here: read as a person's), no public identifier.
            let personal = try await add("d.pdf")
            try await env.db.insertPaperSource(paperPK: personal.pk, PaperProvenance(internetMessageID: "<p@example.org>",
                                                                                      addedAt: DedupeKit.start))
            try await purge(personal.id)
            // A manuscript system's email (confidential), even with a DOI.
            let review = try await add("h.pdf", doi: "10.1038/s41586-025-06666-6")
            _ = try await env.db.insertMailMessage(MailMessage(accountID: "acct", internetMessageID: "<ms@example.org>",
                                                               fromAddress: "em@editorialmanager.com", senderKind: .alert,
                                                               subject: "Invitation to review", receivedAt: DedupeKit.start),
                                                   items: [])
            try await env.db.insertPaperSource(paperPK: review.pk, PaperProvenance(internetMessageID: "<ms@example.org>",
                                                                                    addedAt: DedupeKit.start))
            try await purge(review.id)
            #expect(try await env.db.historyCount() == 0)
            // The hold outlived the soft delete (its job was cancelled).
            #expect(unpublishedNoteKept)
            // The same email with a public identifier, and an ordinary paper: remembered.
            let identified = try await add("e.pdf", doi: "10.1038/s41586-025-05555-5")
            try await env.db.insertPaperSource(paperPK: identified.pk, PaperProvenance(internetMessageID: "<q@example.org>",
                                                                                        addedAt: DedupeKit.start))
            try await purge(identified.id)
            try await purge(try await add("f.pdf").id)
            #expect(try await env.db.historyCount() == 2)
            // Delete Permanently forgets the paper (its confirmation says it is removed from PaperDeck).
            let deleted = try await add("g.pdf")
            try await env.engine.deleteNow(paperID: deleted.id, trash: env.trash.function)
            #expect(try await env.db.historyCount() == 2)
            #expect(try await env.db.paper(id: deleted.id) == nil)
        }
    }

    // MARK: D5 — the master switch off is today's behaviour

    @Test func switchOffReplaceKeepsThePapersIdentifiers() async throws {
        let fetcher = DedupeKit.Fetcher(routes: [
            ("https://api.biorxiv.org/details/biorxiv/\(Self.preprintDOI)", 200, """
            {"collection":[{"title":"\(Self.title)","authors":"Wang, L.; Lovelace, A.","doi":"\(Self.preprintDOI)","date":"2024-03-01",
             "version":"2","server":"bioRxiv","published":"\(Self.journalDOI)","abstract":"Cells of the developing cortex."}]}
            """),
        ])
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false), lookup: true), fetcher: fetcher) { env in
            let id = try #require(await env.ingest([try env.pdf("preprint.pdf", title: Self.title, doi: Self.preprintDOI)]).added.first)
            let before = try await env.paper(id)
            _ = await env.ingest([try env.pdf("s41586.pdf", title: Self.title, doi: Self.journalDOI)])
            let toast = try #require(env.events.toasts.last { DupExplainer.classicSameWorkPendingID($0) != nil })
            await env.engine.intake.resolvePending(pendingID: try #require(DupExplainer.classicSameWorkPendingID(toast)), replace: true)
            await env.settle()
            let after = try await env.paper(id)
            #expect(after.sha256 != before.sha256)                                // replaced…
            #expect(after.ids == before.ids && after.metaSource == before.metaSource)   // …keeping its ids
            #expect(try await env.db.dupKeys(paperPK: after.pk).isEmpty)
        }
    }

    /// V17: with the switch off, the enrichment opens no question (a Crossref has-preprint link).
    @Test func switchOffEnrichmentOpensNoQuestion() async throws {
        let preprint = "10.1101/2023.11.11.566789", journal = "10.1016/j.cell.2024.05.001"
        let fetcher = DedupeKit.Fetcher(routes: [
            ("https://api.biorxiv.org/details/biorxiv/\(preprint)", 200, """
            {"collection":[{"title":"Lineage tracing of organoid progenitors at scale","authors":"Wang, L.; Lovelace, A.",
             "doi":"\(preprint)","date":"2023-11-11","version":"1","server":"bioRxiv","published":"NA"}]}
            """),
            ("https://api.crossref.org/works/\(journal)", 200,
             DedupeKit.crossref(doi: journal, title: "Lineage tracing at scale", authors: ["Li Wang", "Ada Lovelace"],
                                year: 2024, venue: "Cell", relation: ["has-preprint": [preprint]])),
        ])
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false), lookup: true), fetcher: fetcher) { env in
            _ = await env.ingest([try env.pdf("preprint.pdf", title: "Lineage tracing of organoid progenitors at scale", doi: preprint)])
            let jid = try #require(await env.ingest([try env.pdf("journal.pdf", title: "Lineage tracing at scale", doi: journal)]).added.first)
            let j = try await env.paper(jid)
            #expect(j.metaSource == .crossref)                                    // the enrichment ran
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            #expect(try await env.db.activeJob(paperPK: j.pk)?.state == .queued)
            #expect(!(try await env.db.dupKeys(paperPK: j.pk)).contains { $0.source == .crossref })
        }
    }

    /// V16: with the switch off, an open review doesn't hold the paper's reading.
    @Test func switchOffReadyStepDoesNotHoldTheReading() async throws {
        try await DedupeKit.run { env in
            let (_, n, _) = try await Self.heldCopy(env, seed: "ready step")
            env.settings.value.dedupe.enabled = false
            await env.engine.agents.cancel(paperPK: n.pk)
            _ = try await env.db.modifyPaper(pk: n.pk, now: env.clock.now) { $0.stage = .filed }
            await env.engine.enrich.submit(pk: n.pk, holdAI: false)
            await env.settle()
            #expect(try await env.db.activeJob(paperPK: n.pk)?.state == .queued)
            #expect(try await env.paper(n.id).aiState == .queued)
        }
    }

    // MARK: D6 — the check inside the commit lock stays cheap

    /// A library imported by an older build (no fingerprints, ~60 kB text caches) with 500
    /// tombstones: `prepare` computes the fingerprints outside the lock; the match inside reads them.
    @Test func theCheckInsideTheCommitLockIsCheap() async throws {
        try await DedupeKit.run { env in
            var files: [URL] = []
            for i in 0..<60 { files.append(try env.pdf("p\(i).pdf", title: "Study number \(i) of synthetic cortex development in organoids")) }
            _ = await env.ingest(files)
            for p in try await env.db.livePapers() {
                var pages: [String] = []
                for k in 0..<12 {
                    pages.append((0..<4).map { DedupeKit.body(seed: p.id + "\(k)-\($0)") }.joined(separator: " "))
                }
                try env.ctx.texts.save(pages.joined(separator: "\u{0C}"), id: p.id)
                try await env.db.deleteDupFingerprint(paperPK: p.pk)
            }
            for i in 0..<500 {
                let t = "Removed paper number \(i) about cortex organoid development"
                try await env.db.insertHistory(DupHistoryRow(paperID: "h\(i)", sha256: nil, doi: nil, arxivID: nil, publishedDOI: nil,
                                                             keys: [], title: t, titleNorm: DedupeText.titleNorm(t), firstSurname: nil,
                                                             year: 2020, page: (0..<128).map { UInt32($0 * 31 + i) }, abstract: nil,
                                                             lastStatus: .done, readCount: 1, doneAt: nil, addedAt: nil,
                                                             purgedAt: DedupeKit.start))
            }
            let probe = env.downloads.appendingPathComponent("probe.pdf")
            try DedupeKit.pdfData(title: "Study of synthetic cortex development in organoids and more", doi: nil,
                                  body: DedupeKit.body(seed: "probe"), pages: 3, tag: "t").write(to: probe)
            let x = try await PDFExtractor().extract(url: probe, fileName: "probe.pdf")
            let s = DedupeIndex.stagedSubject(sha256: "probe", ids: x.ids, title: x.fontTitle ?? "", titleRank: .font,
                                              fileName: "probe.pdf", extracted: x)
            // Outside the lock: the candidates' fingerprints.
            #expect(await DedupeIndex.prepare(s, ids: x.ids, ctx: env.ctx, pages: x.pageTexts) >= 10)
            // 60 ms; load-tolerant in the default gate (`RDPerf`, ENV-1).
            let budget = RDPerf.gate(60)
            let (best, median) = await RDPerf.best(runs: 9, under: budget) {
                _ = await DedupeIndex.match(s, ids: x.ids, excluding: nil, settings: DedupeSettings(), ctx: env.ctx,
                                            pages: x.pageTexts, computeMissing: IntakeActor.signaturesInLock)
            }
            print("dedupe check inside the lock (60 papers, 500 tombstones) median \(String(format: "%.2f", median)) ms, best \(String(format: "%.2f", best)) ms")
            #expect(best < budget, "best \(best) ms, median \(median) ms (budget \(budget) ms)")
            // Nothing left to compute: every candidate has its fingerprint.
            #expect(await DedupeIndex.prepare(s, ids: x.ids, ctx: env.ctx, pages: x.pageTexts) == 0)
        }
    }

    /// An import computes no candidate fingerprint inside the commit lock (they were prepared before).
    @Test func anImportPreparesFingerprintsBeforeTheLock() async throws {
        try await DedupeKit.run { env in
            var files: [URL] = []
            for i in 0..<6 { files.append(try env.pdf("p\(i).pdf", title: "Study number \(i) of synthetic cortex development")) }
            let ids = await env.ingest(files).added
            for id in ids { try await env.db.deleteDupFingerprint(paperPK: try await env.paper(id).pk) }
            _ = await env.ingest([try env.pdf("new.pdf", title: "Study of synthetic cortex development and more")])
            let pks = try await env.db.livePapers().map(\.pk)
            #expect(try await env.db.dupFingerprints(paperPKs: pks).count == 7)
            // Inside the lock the check computes at most a few itself (the rest compared without text).
            for id in ids { try await env.db.deleteDupFingerprint(paperPK: try await env.paper(id).pk) }
            let probe = env.downloads.appendingPathComponent("probe.pdf")
            try DedupeKit.pdfData(title: "Study of synthetic cortex development, once more", doi: nil,
                                  body: DedupeKit.body(seed: "probe"), pages: 3, tag: "t").write(to: probe)
            let x = try await PDFExtractor().extract(url: probe, fileName: "probe.pdf")
            let s = DedupeIndex.stagedSubject(sha256: "probe", ids: x.ids, title: x.fontTitle ?? "", titleRank: .font,
                                              fileName: "probe.pdf", extracted: x)
            _ = await DedupeIndex.match(s, ids: x.ids, excluding: nil, settings: DedupeSettings(), ctx: env.ctx,
                                        pages: x.pageTexts, computeMissing: IntakeActor.signaturesInLock)
            #expect(try await env.db.dupFingerprints(paperPKs: pks).count == 1 + IntakeActor.signaturesInLock)
        }
    }

    // MARK: D8 — a correction is kept linked as related

    @Test func aParkedCorrectionIsKeptLinkedAsRelated() async throws {
        try await DedupeKit.run { env in
            let doi = "10.1038/s41586-024-06666-6"
            let pid = try #require(await env.ingest([try env.pdf("paper.pdf", title: Self.title, doi: doi, pages: 12)]).added.first)
            _ = await env.ingest([try env.pdf("correction.pdf", title: "Author Correction: \(Self.title)", doi: doi, pages: 1)])
            let review = try await env.onlyOpenReview()
            let d = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(review.relation == .correction && d.defaultChoice == .keepBoth)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .keepBoth(linkAsRelated: true))
            let notice = try await env.paper(try #require(r.keptPaperID))
            let paper = try await env.paper(pid)
            #expect(notice.isLive && notice.ids.doi == nil && paper.ids.doi == doi)       // the DOI stays the paper's
            let pair = try #require(try await env.db.dupPair(notice.pk, paper.pk))
            #expect(pair.decision == "related" && pair.relation == "correction")
            // Its fingerprint was computed without the stripped identifier (no "published" rank).
            let rank = try await env.db.transaction { db in
                try db.db.scalarInt("SELECT version_rank FROM paper_fingerprint WHERE paper_pk = ?", [.integer(notice.pk)])
            }
            #expect(rank == Int64(VersionRank(tier: .unknown).code))

            // D16: both cards keep the relation; a rebuild restores it.
            await env.settle()
            let card = try CardSidecar.decoded(from: Data(contentsOf: env.ctx.folderURL(paper).appendingPathComponent(CardSidecar.fileName)))
            #expect(card.distinctFrom == [notice.id] && card.relatedTo == [CardSidecar.RelatedEntry(id: notice.id, relation: "correction")])
            let before = try await env.engine.dumpCanonical()
            #expect(String(decoding: before, as: UTF8.self).contains("\"relatedTo\""))
            _ = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            #expect(try await env.engine.dumpCanonical() == before)
            let rp = try await env.paper(pid), rn = try await env.paper(notice.id)
            let rebuilt = try #require(try await env.db.dupPair(rp.pk, rn.pk))
            #expect(rebuilt.decision == "related" && rebuilt.relation == "correction")
        }
    }

    // MARK: D10 — "Restore the earlier one" of an unread paper records no reading

    @Test func restoringAnUnreadPaperRecordsNoReading() async throws {
        try await DedupeKit.run { env in
            let doi = "10.1038/s41586-024-08888-8"
            let id = try #require(await env.ingest([try env.pdf("a.pdf", title: Self.title, doi: doi)]).added.first)
            try await env.engine.softDelete(paperID: id)
            _ = await env.ingest([try env.pdf("b.pdf", title: Self.title, doi: doi)])
            let r = try await env.onlyOpenReview()
            _ = try await env.engine.resolveDuplicate(reviewID: r.id, .rereadEarlier(checklist: .keepProgress, deadline: .auto,
                                                                                     useNewFile: false))
            let e = try await env.paper(id)
            let cycles = try await env.db.readingCycles(paperPK: e.pk)
            #expect(cycles.map(\.n) == [1] && cycles.allSatisfy { $0.doneAt == nil } && cycles.first?.reason == "first")
            _ = await env.ingest([try env.pdf("c.pdf", title: Self.title, doi: doi)])
            let next = try await env.onlyOpenReview()
            let d = try await env.engine.duplicateReviewDetail(id: next.id)
            #expect(d.existing.readCount == 0 && d.explanation.historyLine?.contains("read 2") != true)
            // Finished now, then re-read: one reading, then two.
            _ = try await env.engine.setStatus(paperID: id, .done)
            #expect(try await env.engine.duplicateReviewDetail(id: next.id).existing.readCount == 1)
            _ = try await env.engine.resolveDuplicate(reviewID: next.id, .rereadEarlier(checklist: .keepProgress, deadline: .auto,
                                                                                        useNewFile: false))
            let again = try await env.db.readingCycles(paperPK: e.pk)
            #expect(again.map(\.n) == [1, 2] && again[0].doneAt != nil && again[1].reason == "reread")
        }
    }

    // MARK: D11 — the classic Replace against a paper moved to Recently Deleted

    @Test func classicReplaceOfAPaperDeletedMeanwhileAddsItOnce() async throws {
        try await DedupeKit.run { env in
            let doi = "10.1038/s41586-024-09999-9"
            let id = try #require(await env.ingest([try env.pdf("a.pdf", title: Self.title, doi: doi)]).added.first)
            _ = await env.ingest([try env.pdf("b.pdf", title: Self.title, doi: doi)])
            let review = try await env.onlyOpenReview()
            try await env.engine.softDelete(paperID: id)
            await env.engine.intake.resolvePending(pendingID: try #require(review.pendingID), replace: true)
            await env.settle()
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            #expect(try await env.db.dupReview(id: review.id)?.state == .expired)
            let live = try await env.db.livePapers()
            #expect(live.count == 1 && live.first?.id != id && live.first?.ids.doi == doi)
        }
    }

    // MARK: D15 — the tombstone before the Trash

    @Test func aTombstoneThatCantBeWrittenTrashesNothing() async throws {
        try await DedupeKit.run { env in
            let id = try #require(await env.ingest([try env.pdf("a.pdf", title: Self.title, doi: Self.journalDOI)]).added.first)
            _ = try await env.engine.setStatus(paperID: id, .done)
            let deleted = try await env.engine.softDelete(paperID: id)
            try await env.db.transaction { db in
                try db.db.exec("CREATE TEMP TRIGGER fail_history BEFORE INSERT ON paper_history BEGIN SELECT RAISE(ABORT, 'seam'); END")
            }
            final class Count: @unchecked Sendable {
                private let lock = NSLock()
                private var n = 0
                func add() { lock.withLock { n += 1 } }
                var value: Int { lock.withLock { n } }
            }
            let trashed = Count()
            await #expect(throws: (any Error).self) {
                _ = try await env.engine.purgeExpired(olderThan: 0, trash: { _ in trashed.add(); return true })
            }
            #expect(trashed.value == 0)
            let still = try #require(try await env.db.paper(id: id))
            #expect(still.isDeleted && FileManager.default.fileExists(atPath: env.ctx.folderURL(deleted).path))
        }
    }

    // MARK: D9, D13 — a library check holds nothing; a selection is checked against the library

    @Test func aLibraryChecksQuestionHoldsNothing() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            let body = DedupeKit.body(seed: "scan pair")
            let first = try #require(await env.ingest([try env.pdf("one.pdf", title: Self.title, body: body)]).added.first)
            env.clock.now = env.clock.now.addingTimeInterval(60)
            let second = try #require(await env.ingest([try env.pdf("two.pdf", title: Self.title, body: body)]).added.first)
            env.settings.value = DedupeKit.settings()
            // Only the earlier paper selected: it is checked against the whole library.
            let summary = try await env.engine.checkDuplicates(paperIDs: [first])
            #expect(summary.opened.count == 1)
            let review = try await env.onlyOpenReview()
            #expect(review.origin == .scan && review.newPaperID == second && review.band == .likely)
            #expect(review.held == nil && review.hold == .none)
            let n = try await env.paper(second)
            #expect(n.scheduleMode == .auto && n.deadline != nil)
        }
    }

    // MARK: D14 — the mutation run's survivors

    /// V11 / V12: with "Remember papers you removed" off, tombstones kept earlier match nothing.
    @Test func historyOffMatchesNoTombstone() async throws {
        try await DedupeKit.run { env in
            let body = DedupeKit.body(seed: "history off")
            let url = try env.pdf("read.pdf", title: Self.title, body: body)
            let bytes = try Data(contentsOf: url)
            let id = try #require(await env.ingest([url]).added.first)
            _ = try await env.engine.setStatus(paperID: id, .done)
            try await env.engine.softDelete(paperID: id)
            _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)
            #expect(try await env.db.historyCount() == 1)
            env.settings.value = DedupeKit.settings(dedupe: DedupeSettings(history: false))
            func addAndRemove(_ url: URL) async throws {
                let id = try #require(await env.ingest([url]).added.first)
                #expect(try await env.db.dupReviews(state: .open).isEmpty, "\(url.lastPathComponent)")
                try await env.engine.softDelete(paperID: id)
                _ = try await env.engine.purgeExpired(olderThan: 0, trash: env.trash.function)   // no tombstone: history off
            }
            let again = env.downloads.appendingPathComponent("again.pdf")
            try bytes.write(to: again)
            try await addAndRemove(again)                                                      // the same bytes
            try await addAndRemove(try env.pdf("copy.pdf", title: Self.title, body: body))     // the same title and text
            #expect(try await env.db.historyCount() == 1)
            // On again: the same text is recognized.
            env.settings.value = DedupeKit.settings()
            _ = await env.ingest([try env.pdf("third.pdf", title: Self.title, body: body)])
            #expect(try await env.onlyOpenReview().matchesHistory)
        }
    }

    /// V13: papers imported before the check (no identity keys) are found by their version family
    /// — here only through `paper_key` (the title was rewritten: no title word in common).
    @Test func papersFromAnOlderBuildAreFoundByTheirKeys() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            let id = try #require(await env.ingest([try env.pdf("elife1.pdf", title: "Chromatin states define progenitor fate",
                                                                doi: "10.7554/eLife.98765.1",
                                                                body: DedupeKit.body(seed: "v1 text"))]).added.first)
            #expect(try await env.db.dupKeys(paperPK: try await env.paper(id).pk).isEmpty)
            env.settings.value = DedupeKit.settings()
            _ = await env.ingest([try env.pdf("elife3.pdf", title: "Epigenetic landscapes of neural precursors",
                                              doi: "10.7554/eLife.98765.3", body: DedupeKit.body(seed: "v3 text"))])
            let review = try await env.onlyOpenReview()
            #expect(review.isParked && review.band == .certain && review.relation == .newerVersion)
            #expect(review.evidence.contains { $0.code == .doiFamily })
        }
    }

    /// V21: a merge never gives the kept paper a DOI another live paper holds (both bioRxiv prefixes count).
    @Test func aMergeNeverTakesADOIAnotherPaperHolds() async throws {
        try await DedupeKit.run { env in
            let body = DedupeKit.body(seed: "merge doi")
            let eid = try #require(await env.ingest([try env.pdf("e.pdf", title: Self.title, body: body)]).added.first)
            let nid = try #require(await env.ingest([try env.pdf("n.pdf", title: Self.title, body: body)]).added.first)
            let review = try await env.onlyOpenReview()
            let xid = try #require(await env.ingest([try env.pdf("x.pdf", title: "An unrelated study of zebrafish fins")]).added.first)
            _ = try await env.db.modifyPaper(pk: try await env.paper(eid).pk, now: env.clock.now) { $0.ids.doi = "10.1101/2024.05.05.999999v1" }
            _ = try await env.db.modifyPaper(pk: try await env.paper(nid).pk, now: env.clock.now) { $0.ids.doi = "10.64898/2024.05.05.999999v2" }
            _ = try await env.db.modifyPaper(pk: try await env.paper(xid).pk, now: env.clock.now) { $0.ids.doi = "10.1101/2024.05.05.999999" }
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            let kept = try await env.paper(eid)
            #expect(kept.ids.doi == "10.1101/2024.05.05.999999v1")
            #expect(try await env.paper(xid).ids.doi == "10.1101/2024.05.05.999999")
        }
    }
}

/// D9, D13: what the UI and the help say matches what the engine does (contract checks on the
/// app's sources and the guide content).
@Suite struct DedupeFixWordingTests {
    static func source(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    /// D9: the ribbon, the chip, the sheet and the list word the review's actual hold, never its band.
    @Test func theUIWordsTheActualHold() throws {
        for file in ["DuplicateRibbon", "DuplicateChip", "DuplicateSheet", "DuplicatesList"] {
            let text = try Self.source("Sources/PaperDeck/Views/Dedupe/\(file).swift")
            #expect(!text.contains("holdsNewPaper"), "\(file) words the band, not the hold")
        }
        let ribbon = try Self.source("Sources/PaperDeck/Views/Dedupe/DuplicateRibbon.swift")
        #expect(ribbon.contains("ribbonHelp(model.review(newPaper: row.id)?.review.hold"))
        let l10n = try Self.source("Sources/PaperDeck/App/L10n+dedupe.swift")
        for decl in ["static func ribbonHelp(_ hold: DupHold)", "static func chipHeldNote(_ hold: DupHold)",
                     "static func heldHint(_ hold: DupHold)"] {
            #expect(l10n.contains(decl), "\(decl)")
        }
    }

    /// D13: the help says which decisions can be undone, and what a selection's check compares.
    @Test func theHelpMatchesTheBehaviour() throws {
        let topic = try #require(GuideCatalog.topic(.duplicates))
        let undo = try #require(topic.steps.first { $0.id == "undo" })
        #expect(undo.text.en.contains("except Keep both") && undo.text.zh.contains("两篇都留"))
        let review = try #require(topic.steps.first { $0.id == "review" })
        #expect(review.text.en.contains("against the rest of your library"))
        let select = try #require(GuideCatalog.topic(.multiSelect)?.steps.first { $0.id == "duplicates" })
        #expect(select.text.en.contains("against your library") && !select.text.en.contains("only the selected"))
        let likely = try #require(topic.steps.first { $0.id == "likely" })
        #expect(likely.text.en.contains("only holds its AI reading"))
        let design = try String(contentsOf: LintRepo.url("docs/DESIGN.md"), encoding: .utf8)
        #expect(design.contains("唯一例外是对仍在等待的新文件选「两篇都留」"))
    }
}
