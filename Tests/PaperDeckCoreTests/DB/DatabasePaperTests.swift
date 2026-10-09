import Foundation
import Testing
@testable import PaperDeckCore

/// Minimal valid paper; `n` keeps sha256/id unique.
fileprivate func makePaper(_ n: Int, title: String? = nil, doi: String? = nil, arxiv: String? = nil,
                           publishedDOI: String? = nil) -> Paper {
    Paper(sha256: String(format: "%064x", n), fileSize: Int64(1000 + n),
          ids: PaperIDs(doi: doi, arxivID: arxiv, publishedDOI: publishedDOI),
          title: title ?? "Paper \(n)", folder: "Papers/_Inbox/\(n)", pdfName: "p\(n).pdf", originalName: "p\(n).pdf")
}

fileprivate func fullCard() -> ReadingCard {
    ReadingCard(
        extractedMetadata: .init(title: "Card title", authors: ["A. B"], year: 2024, venue: "Nature", doi: "10.1/c"),
        tldr: "Atlas of the developing neocortex.", summary: "A long summary.", contributions: ["c1", "c2"],
        method: "snRNA-seq and MERFISH", results: ["r1"], limitations: [.init(text: "small n", source: .inferred)],
        keyTerms: [.init(term: "RG", definition: "radial glia")],
        resources: [.init(kind: .protocol_, name: "proto", identifier: nil, url: "https://example.org")],
        paperType: .resource, category: ReadingCard.newCategoryToken,
        newCategory: .init(name: "Brain Atlases", description: "Atlases"), tags: ["single-cell"],
        difficulty: .hard, estimatedMinutes: 110,
        checklist: [.init(task: "Fig. 2", section: "Fig. 2", page: 5, minutes: 15, kind: .figure)],
        textQuality: .good)
}

@Suite struct DatabasePaperTests {
    @Test func everyPaperFieldRoundTrips() async throws {
        let db = try Database.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let p = Paper(
            id: UUID().uuidString.lowercased(), sha256: String(repeating: "f", count: 64), fileSize: 35_000_000,
            ids: PaperIDs(doi: "10.1038/s41586-024-08351-7", arxivID: "2606.24530", arxivVersion: 2,
                          pii: "S0092867424013321", publishedDOI: "10.1016/j.cell.2024.1"),
            title: "Molecular and cellular dynamics", titleRank: .api, authors: ["Li Wang", "Ana \"Q\" Müller"],
            year: 2024, venue: "Nature", abstract: "Abstract…", metaSource: .crossref, metaUserEdited: true,
            pageCount: 49, charCount: 250_000, flags: [.locked, .missing],
            folder: "Papers/2024_Wang_Molecular", pdfName: "2024_Wang_Molecular.pdf", originalName: "s41586.pdf",
            nameFinal: true, stage: .ready, status: .reading, priority: .high,
            deadline: LocalDate(year: 2026, month: 10, day: 2), scheduleMode: .pinned, deadlineOrigin: .user,
            queueRank: 17, placementFloor: LocalDate(year: 2026, month: 9, day: 30), provisional: false,
            estMinutes: 110, estSource: .agent, categoryPK: 5, categoryUserSet: true, needsReview: true,
            tldr: "TLDR", card: fullCard(), cardVersion: 1, textQuality: .partial, aiState: .needsLogin,
            aiNote: "note", aiSeen: false, notes: "my notes\nline 2",
            addedAt: t0, updatedAt: t0.addingTimeInterval(1), openedAt: t0.addingTimeInterval(2),
            doneAt: t0.addingTimeInterval(3), deletedAt: nil)
        let saved = try await db.insertPaper(p)
        var expected = p
        expected.pk = saved.pk
        #expect(saved == expected)
        #expect(try await db.paper(pk: saved.pk) == expected)
        #expect(try await db.paper(id: p.id.uppercased()) == expected)
        #expect(try await db.paper(sha256: p.sha256) == expected)

        // All-optional-nil variant.
        let bare = try await db.insertPaper(makePaper(2))
        var bareExpected = makePaper(2)
        bareExpected.pk = bare.pk
        bareExpected.id = bare.id
        bareExpected.queueRank = bare.queueRank
        bareExpected.addedAt = bare.addedAt
        bareExpected.updatedAt = bare.updatedAt
        #expect(bare == bareExpected)
        #expect(bare.card == nil && bare.deadline == nil && bare.flags.isEmpty)
    }

    @Test func timestampsAreNormalizedToMilliseconds() async throws {
        let db = try Database.inMemory()
        var p = makePaper(1)
        p.addedAt = Date(timeIntervalSince1970: 1_790_000_000.123456)
        let saved = try await db.insertPaper(p)
        #expect(abs(saved.addedAt.timeIntervalSince(p.addedAt)) < 0.001)
        #expect(try await db.paper(pk: saved.pk) == saved)             // what insert returns is what reads return
        #expect(Database.timestamp(saved.addedAt) == "2026-09-21T14:13:20.123Z")
        #expect(Database.date(fromTimestamp: "2026-09-30T02:15:00Z") == Date(timeIntervalSince1970: 1_790_734_500))
        #expect(Database.date(fromTimestamp: "2026-09-30T04:15:00.5+02:00") == Date(timeIntervalSince1970: 1_790_734_500.5))
        #expect(Database.date(fromTimestamp: "2026-13-30T02:15:00Z") == nil)
        #expect(Database.date(fromTimestamp: "2026-02-30T02:15:00.000Z") == nil)
        #expect(Database.timestamp(Date(timeIntervalSince1970: 951_782_400)) == "2000-02-29T00:00:00.000Z")
        #expect(Database.timestamp(Date(timeIntervalSince1970: -0.0004)) == "1970-01-01T00:00:00.000Z")
        #expect(Database.timestamp(Date(timeIntervalSince1970: -0.001)) == "1969-12-31T23:59:59.999Z")
        #expect(Database.date(fromTimestamp: "yesterday") == nil)

        // Re-saving never drifts, even though most millisecond values are inexact doubles.
        var again = saved
        for _ in 0..<20 { again = try await db.updatePaper(again, now: again.updatedAt) }
        #expect(again.addedAt == saved.addedAt && again.updatedAt == saved.updatedAt)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let d = Date(timeIntervalSince1970: Double.random(in: -2_000_000_000...4_000_000_000, using: &rng))
            let s = Database.timestamp(d)
            let parsed = try #require(Database.date(fromTimestamp: s))
            #expect(abs(parsed.timeIntervalSince(d)) <= 0.000501)
            #expect(Database.timestamp(parsed) == s)
            #expect(Database.date(fromTimestamp: Database.timestamp(parsed)) == parsed)
        }
        #expect(Database.date(fromTimestamp: Database.timestamp(.distantPast)) == .distantPast)   // proleptic Gregorian
    }

    @Test func updateSetsUpdatedAtAndRejectsMissingRows() async throws {
        let db = try Database.inMemory()
        var p = try await db.insertPaper(makePaper(1))
        p.title = "Renamed"
        p.status = .done
        p.flags.insert(.scanned)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = try await db.updatePaper(p, now: now)
        #expect(updated.title == "Renamed" && updated.status == .done && updated.flags == [.scanned])
        #expect(updated.updatedAt == now)
        var ghost = p
        ghost.pk = 999
        await #expect(throws: DatabaseError.notFound("paper 999")) { try await db.updatePaper(ghost) }
    }

    @Test func modifyPaperEditsTheCurrentRow() async throws {
        let db = try Database.inMemory()
        let stale = try await db.insertPaper(makePaper(1))
        try await db.modifyPaper(pk: stale.pk) { $0.status = .reading }          // e.g. the user, meanwhile
        let result = try await db.modifyPaper(pk: stale.pk) { $0.title = "Canonical title"; $0.pk = 999 }
        #expect(result.pk == stale.pk && result.status == .reading && result.title == "Canonical title")
        #expect(try await db.search("canonical", limit: 5) == [stale.pk])
        await #expect(throws: DatabaseError.self) { try await db.modifyPaper(pk: 42) { $0.notes = "x" } }
    }

    @Test func queueRankIsAssignedAsMaxPlusOne() async throws {
        let db = try Database.inMemory()
        #expect(try await db.nextQueueRank() == 1)
        let a = try await db.insertPaper(makePaper(1))
        var explicit = makePaper(2)
        explicit.queueRank = 10
        _ = try await db.insertPaper(explicit)
        let c = try await db.insertPaper(makePaper(3))
        #expect(a.queueRank == 1 && c.queueRank == 11)
        #expect(try await db.nextQueueRank() == 12)
        #expect(try await db.livePapers().map(\.queueRank) == [1, 10, 11])
    }

    @Test func liveDOIAndArxivAreUniqueUntilSoftDeleted() async throws {
        let db = try Database.inMemory()
        let first = try await db.insertPaper(makePaper(1, doi: "10.1101/2025.09.01.673319", arxiv: "2606.24530"))

        for dup in [makePaper(2, doi: "10.1101/2025.09.01.673319"), makePaper(3, doi: "10.1101/2025.09.01.673319".uppercased()),
                    makePaper(4, arxiv: "2606.24530")] {
            do {
                try await db.insertPaper(dup)
                Issue.record("duplicate live id accepted")
            } catch let e as SQLiteError {
                #expect(e.isUniqueViolation)
            }
        }

        try await db.softDelete(pk: first.pk, at: Date(timeIntervalSince1970: 1_790_000_000))
        let second = try await db.insertPaper(makePaper(5, doi: "10.1101/2025.09.01.673319", arxiv: "2606.24530"))
        #expect(second.pk != first.pk)
        // Restoring the first would create two live copies of the same work.
        await #expect(throws: SQLiteError.self) { try await db.restore(pk: first.pk) }

        #expect(try await db.livePapers().map(\.pk) == [second.pk])
        #expect(try await db.deletedPapers().map(\.pk) == [first.pk])
        #expect(try await db.paper(pk: first.pk)?.deletedAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func emptyIdentifiersAreStoredAsNull() async throws {
        let db = try Database.inMemory()
        let a = try await db.insertPaper(makePaper(1, doi: "", arxiv: "  "))
        _ = try await db.insertPaper(makePaper(2, doi: "", arxiv: ""))    // no collision on ''
        #expect(a.ids.doi == nil && a.ids.arxivID == nil)
    }

    @Test func shaStaysReservedUntilHardDelete() async throws {
        let db = try Database.inMemory()
        let a = try await db.insertPaper(makePaper(1))
        try await db.softDelete(pk: a.pk)
        #expect(try await db.paper(sha256: a.sha256)?.isDeleted == true)
        await #expect(throws: SQLiteError.self) { try await db.insertPaper(makePaper(1)) }
        try await db.hardDelete(pk: a.pk)
        try await db.hardDelete(pk: a.pk)                                // idempotent
        #expect(try await db.paper(pk: a.pk) == nil)
        _ = try await db.insertPaper(makePaper(1))
        await #expect(throws: DatabaseError.self) { try await db.softDelete(pk: 12345) }
    }

    @Test func matchingWorkCrossesPreprintAndJournal() async throws {
        let db = try Database.inMemory()
        let preprint = try await db.insertPaper(makePaper(1, doi: "10.1101/2025.09.01.673319",
                                                          publishedDOI: "10.1038/s41586-025-00001-1"))
        let arxiv = try await db.insertPaper(makePaper(2, arxiv: "2606.24530"))
        let journal = try await db.insertPaper(makePaper(3, doi: "10.1016/j.cell.2024.10.023"))

        #expect(try await db.paperMatchingWork(doi: "10.1101/2025.09.01.673319".uppercased(), arxivID: nil, publishedDOI: nil)?.pk == preprint.pk)
        // New journal version of the preprint: its DOI equals the preprint's published_doi.
        #expect(try await db.paperMatchingWork(doi: "10.1038/S41586-025-00001-1", arxivID: nil, publishedDOI: nil)?.pk == preprint.pk)
        // New preprint whose published DOI is already in the library.
        #expect(try await db.paperMatchingWork(doi: "10.1101/9999", arxivID: nil, publishedDOI: "10.1016/j.cell.2024.10.023")?.pk == journal.pk)
        #expect(try await db.paperMatchingWork(doi: nil, arxivID: "2606.24530", publishedDOI: nil)?.pk == arxiv.pk)
        #expect(try await db.paperMatchingWork(doi: nil, arxivID: nil, publishedDOI: nil) == nil)
        #expect(try await db.paperMatchingWork(doi: "10.9/none", arxivID: "1234.56789", publishedDOI: nil) == nil)

        try await db.softDelete(pk: arxiv.pk)
        #expect(try await db.paperMatchingWork(doi: nil, arxivID: "2606.24530", publishedDOI: nil) == nil)
    }

    @Test func stageAndBatchQueries() async throws {
        let db = try Database.inMemory()
        var a = makePaper(1); a.stage = .ready
        var b = makePaper(2); b.stage = .enriched
        var c = makePaper(3); c.stage = .committed
        let pa = try await db.insertPaper(a), pb = try await db.insertPaper(b), pc = try await db.insertPaper(c)
        try await db.softDelete(pk: pc.pk)
        #expect(try await db.papers(notInStage: .ready).map(\.pk) == [pb.pk])
        #expect(try await db.papers(pks: [pc.pk, 77, pa.pk]).map(\.pk) == [pc.pk, pa.pk])
        #expect(try await db.allPapers().count == 3)
    }
}

@Suite struct DatabaseChecklistTagTests {
    @Test func checklistOrderingAndEdits() async throws {
        let db = try Database.inMemory()
        let done = Date(timeIntervalSince1970: 1_790_000_000)
        let items = [
            ChecklistItem(id: "c", ord: 3, text: "Discussion", minutes: 10, kind: .discussion, origin: .heuristic),
            ChecklistItem(id: "a", ord: 1, text: "Abstract", section: "Abstract", page: 1, minutes: 5, kind: .overview,
                          origin: .agent, userEdited: true, doneAt: done),
            ChecklistItem(id: "b", ord: 2, text: "Fig. 2", section: "Fig. 2", page: 5, minutes: 15, kind: .figure, origin: .agent),
        ]
        let p = try await db.insertPaper(makePaper(1), checklist: items)
        let loaded = try await db.checklist(paperPK: p.pk)
        #expect(loaded.map(\.id) == ["a", "b", "c"])
        try #require(loaded.count > 0)          // no index past a failed expectation (QA-15)
        #expect(loaded[0] == items[1])

        // Insert between a and b without renumbering; edit c.
        try await db.upsertChecklistItem(paperPK: p.pk, item: ChecklistItem(id: "ab", ord: 1.5, text: "Intro", minutes: 5, origin: .user))
        var c = items[0]; c.doneAt = done; c.text = "Discussion (edited)"
        try await db.upsertChecklistItem(paperPK: p.pk, item: c)
        #expect(try await db.checklist(paperPK: p.pk).map(\.id) == ["a", "ab", "b", "c"])
        #expect(try await db.checklist(paperPK: p.pk).last == c)

        try await db.deleteChecklistItem(id: "ab")
        try await db.deleteChecklistItem(id: "nope")
        #expect(try await db.checklist(paperPK: p.pk).map(\.id) == ["a", "b", "c"])

        let other = try await db.insertPaper(makePaper(2))
        try await db.replaceChecklist(paperPK: p.pk, items: [ChecklistItem(id: "z", ord: 1, text: "Only", minutes: 30, origin: .user)])
        let map = try await db.checklists(paperPKs: [p.pk, other.pk])
        #expect(map[p.pk]?.map(\.id) == ["z"])
        #expect(map[other.pk] == [])
        #expect(try await db.checklists(paperPKs: []).isEmpty)
    }

    @Test func tagsAreSharedCaseInsensitivelyAndCounted() async throws {
        let db = try Database.inMemory()
        let a = try await db.insertPaper(makePaper(1))
        let b = try await db.insertPaper(makePaper(2))
        let c = try await db.insertPaper(makePaper(3))
        try await db.setTags(paperPK: a.pk, [Tag(name: "single-cell", origin: .agent), Tag(name: "atlas", origin: .user),
                                             Tag(name: "  ", origin: .agent)])
        try await db.setTags(paperPK: b.pk, [Tag(name: "Single-Cell", origin: .agent), Tag(name: "atlas", origin: .suppressed)])
        try await db.setTags(paperPK: c.pk, [Tag(name: "single-cell", origin: .user), Tag(name: "gone", origin: .agent)])

        #expect(Set(try await db.tags(paperPK: a.pk)) == [Tag(name: "single-cell", origin: .agent), Tag(name: "atlas", origin: .user)])
        #expect(try await db.tags(paperPK: b.pk).map(\.name) == ["single-cell", "atlas"])   // existing spelling reused
        let freq = try await db.frequentTags(limit: 10)
        #expect(freq.map(\.name) == ["single-cell", "atlas", "gone"])                    // suppressed not counted
        #expect(freq.map(\.count) == [3, 1, 1])
        #expect(try await db.frequentTags(limit: 1).count == 1)

        try await db.softDelete(pk: c.pk)                                               // deleted papers don't count
        #expect(try await db.frequentTags(limit: 10).map(\.count) == [2, 1])

        try await db.setTags(paperPK: c.pk, [])
        let batch = try await db.tags(paperPKs: [a.pk, c.pk])
        #expect(batch[a.pk]?.count == 2 && batch[c.pk] == [])
    }

    @Test func categoriesAndCounts() async throws {
        let db = try Database.inMemory()
        let neuro = try #require(try await db.category(named: "neuroscience & development"))
        let mine = try await db.insertCategory(PaperCategory(name: "Brain Atlases", description: "d", hue: 7, origin: .agent, acknowledged: false))
        #expect(mine.pk > 7)
        await #expect(throws: SQLiteError.self) { try await db.insertCategory(PaperCategory(name: "BRAIN ATLASES", origin: .user)) }

        var a = makePaper(1); a.categoryPK = neuro.pk
        var b = makePaper(2); b.categoryPK = mine.pk
        var c = makePaper(3); c.categoryPK = mine.pk
        _ = try await db.insertPaper(a)
        let pb = try await db.insertPaper(b)
        let pc = try await db.insertPaper(c)
        try await db.softDelete(pk: pc.pk)
        try await db.setTags(paperPK: pb.pk, [Tag(name: "atlas", origin: .agent), Tag(name: "x", origin: .suppressed)])

        let counts = try await db.categoryCounts()
        #expect(counts[neuro.pk] == 1 && counts[mine.pk] == 1 && counts[1] == 0)
        #expect(counts.count == 8)
        #expect(try await db.tagSetsByCategory() == [mine.pk: ["atlas"]])

        var renamed = mine; renamed.name = "Atlases"; renamed.acknowledged = true
        try await db.updateCategory(renamed)
        #expect(try await db.category(pk: mine.pk) == renamed)

        try await db.deleteCategory(pk: mine.pk)
        #expect(try await db.paper(pk: pb.pk)?.categoryPK == nil)                    // ON DELETE SET NULL
        #expect(try await db.categories().count == 7)
    }
}
