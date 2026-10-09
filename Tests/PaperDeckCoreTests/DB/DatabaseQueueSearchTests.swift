import Foundation
import Testing
@testable import PaperDeckCore

fileprivate func makePaper(_ n: Int, title: String? = nil, doi: String? = nil, arxiv: String? = nil) -> Paper {
    Paper(sha256: String(format: "%064x", n), fileSize: 1, ids: PaperIDs(doi: doi, arxivID: arxiv),
          title: title ?? "Untitled \(n)", folder: "Papers/\(n)", pdfName: "\(n).pdf", originalName: "\(n).pdf")
}

@Suite struct DatabaseJobTests {
    @Test func runnableSelectionHonoursPriorityAgeAndBackoff() async throws {
        let db = try Database.inMemory()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var pks: [Int64] = []
        for n in 1...5 { pks.append(try await db.insertPaper(makePaper(n)).pk) }

        let oldLow = try await db.insertJob(AgentJob(paperPK: pks[0], provider: "mock", state: .queued, createdAt: t0))
        let newLow = try await db.insertJob(AgentJob(paperPK: pks[1], provider: "mock", state: .queued, createdAt: t0 + 10))
        let high = try await db.insertJob(AgentJob(paperPK: pks[2], provider: "mock", state: .queued, priority: 5, createdAt: t0 + 20))
        let backedOff = try await db.insertJob(AgentJob(paperPK: pks[3], provider: "mock", state: .queued, priority: 9,
                                                        notBefore: t0 + 600, createdAt: t0))
        _ = try await db.insertJob(AgentJob(paperPK: pks[4], provider: "mock", state: .held, priority: 99, createdAt: t0))

        #expect(try await db.nextRunnableJob(now: t0 + 60)?.pk == high.pk)
        #expect(try await db.nextRunnableJob(now: t0 + 600)?.pk == backedOff.pk)   // not_before <= now
        #expect(try await db.earliestNotBefore() == t0 + 600)

        var running = high
        running.state = .running
        running.startedAt = t0 + 61
        try await db.updateJob(running)
        #expect(try await db.nextRunnableJob(now: t0 + 60)?.pk == oldLow.pk)
        #expect(try await db.jobs(states: [.queued]).map(\.pk) == [backedOff.pk, oldLow.pk, newLow.pk])
        #expect(try await db.activeJob(paperPK: pks[2])?.state == .running)
        #expect(try await db.job(id: high.id)?.pk == high.pk)

        // A job whose paper went to Recently Deleted is not picked up.
        try await db.softDelete(pk: pks[0])
        #expect(try await db.nextRunnableJob(now: t0 + 60)?.pk == newLow.pk)
    }

    @Test func oneActiveJobPerPaper() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(makePaper(1))
        var job = try await db.insertJob(AgentJob(paperPK: p.pk, provider: "claude", state: .held))
        await #expect(throws: SQLiteError.self) {
            try await db.insertJob(AgentJob(paperPK: p.pk, provider: "claude", state: .queued))
        }
        job.state = .succeeded
        job.finishedAt = Date().addingTimeInterval(3600)
        job.costUSD = 0.0123
        job.model = "claude-sonnet"
        job.inputTokens = 1200
        job.outputTokens = 800
        job.durationMs = 45_000
        try await db.updateJob(job)
        let retry = try await db.insertJob(AgentJob(paperPK: p.pk, provider: "claude", state: .queued, attempt: 1,
                                                    textBudget: 60_000, effort: "low", errorKind: "timeout"))
        #expect(try await db.activeJob(paperPK: p.pk) == retry)
        let stored = try #require(try await db.job(pk: job.pk))
        #expect(stored.costUSD == 0.0123 && stored.model == "claude-sonnet" && stored.durationMs == 45_000)
        #expect(try await db.recentJobs(limit: 1).map(\.pk) == [job.pk])     // finished most recently
        #expect(try await db.recentJobs(limit: 10).count == 2)

        try await db.hardDelete(pk: p.pk)                                        // jobs cascade
        #expect(try await db.job(pk: job.pk) == nil)
    }

    @Test func resetRunningJobsToQueued() async throws {
        let db = try Database.inMemory()
        var p = try await db.insertPaper(makePaper(1))
        p.aiState = .running
        p = try await db.updatePaper(p)
        let other = try await db.insertPaper(makePaper(2))
        _ = try await db.insertJob(AgentJob(paperPK: p.pk, provider: "mock", state: .running, startedAt: Date()))
        _ = try await db.insertJob(AgentJob(paperPK: other.pk, provider: "mock", state: .queued))

        #expect(try await db.resetRunningJobsToQueued() == 1)
        #expect(try await db.jobs(states: [.running]).isEmpty)
        let queued = try await db.jobs(states: [.queued, .held])
        #expect(queued.count == 2 && queued.allSatisfy { $0.startedAt == nil })
        #expect(try await db.paper(pk: p.pk)?.aiState == .queued)
        #expect(try await db.resetRunningJobsToQueued() == 0)
        #expect(try await db.jobs(states: []).isEmpty)
    }
}

@Suite struct DatabaseSearchTests {
    private func library() async throws -> (Database, [Int64]) {
        let db = try Database.inMemory()
        var neo = makePaper(1, title: "Molecular and cellular dynamics of the developing human neocortex",
                            doi: "10.1038/s41586-024-08351-7")
        neo.authors = ["Li Wang", "Arnold Kriegstein"]
        neo.abstract = "We profile radial glia across gestation."
        var agent = makePaper(2, title: "Biomni: a general-purpose biomedical AI agent", arxiv: "2606.24530")
        agent.notes = "compare with Coscientist"
        var cjk = makePaper(3, title: "单细胞空间转录组图谱")
        cjk.tldr = "空间组学综述"
        let spatial = makePaper(4, title: "SpatialFormer: transformers for spatial transcriptomics")
        var pks: [Int64] = []
        for p in [neo, agent, cjk, spatial] { pks.append(try await db.insertPaper(p).pk) }
        try await db.indexFullText(pk: pks[3], text: "Unlike prior work on the neocortex, we cite 10.1038/s41586-024-08351-7.")
        try await db.indexFullText(pk: pks[1], text: "The agent executes protocols autonomously.")
        return (db, pks)
    }

    @Test func metadataHitsRankBeforeFullTextHits() async throws {
        let (db, pks) = try await library()
        #expect(try await db.search("neocortex", limit: 10) == [pks[0], pks[3]])
        #expect(try await db.search("neocortex", limit: 1) == [pks[0]])
        #expect(try await db.search("kriegstein", limit: 10) == [pks[0]])            // authors
        #expect(try await db.search("radial glia", limit: 10) == [pks[0]])           // abstract
        #expect(try await db.search("coscientist", limit: 10) == [pks[1]])           // notes
        #expect(try await db.search("autonomously", limit: 10) == [pks[1]])          // full text only
        #expect(try await db.search("nothing-like-this", limit: 10).isEmpty)
    }

    @Test func prefixDiacriticsAndPhrases() async throws {
        let (db, pks) = try await library()
        #expect(try await db.search("neocor", limit: 10) == [pks[0], pks[3]])        // last token is a prefix
        #expect(try await db.search("general-purpose", limit: 10) == [pks[1]])       // hyphenated phrase
        #expect(try await db.search("Neocórtex", limit: 10).contains(pks[0]))       // remove_diacritics
        #expect(try await db.search("spatial transcript", limit: 10) == [pks[3]])
    }

    @Test func hostileInputNeverThrows() async throws {
        let (db, pks) = try await library()
        for q in [#""foo" OR bar*) NEAR("#, "\"", "*", "(", "NEAR(", "a:b", "^^^", "' OR 1=1 --", "\u{0}abc"] {
            _ = try await db.search(q, limit: 10)
        }
        #expect(try await db.search(#"neocortex" OR ("#, limit: 10) == [pks[0], pks[3]])
        #expect(try await db.search("agent", limit: 0).isEmpty)
    }

    @Test func likeFallbackForCJKAndShortInput() async throws {
        let (db, pks) = try await library()
        #expect(try await db.search("转录组", limit: 10) == [pks[2]])                 // title
        #expect(try await db.search("空间组学", limit: 10) == [pks[2]])               // tldr
        #expect(try await db.search("AI", limit: 10).contains(pks[1]))
        #expect(try await db.search("单细胞", limit: 10) == [pks[2]])
        let brain = try await db.insertCategory(PaperCategory(name: "脑科学", origin: .user))
        var p = try #require(try await db.paper(pk: pks[3]))
        p.categoryPK = brain.pk
        try await db.updatePaper(p)
        #expect(try await db.search("脑科学", limit: 10) == [pks[3]])               // category name
        #expect(try await db.search("%", limit: 10).isEmpty)                         // wildcards are literal
    }

    @Test func identifierLookup() async throws {
        let (db, pks) = try await library()
        #expect(try await db.search("10.1038/S41586-024-08351-7", limit: 10) == [pks[0]])
        #expect(try await db.search("https://doi.org/10.1038/s41586-024-08351-7", limit: 10) == [pks[0]])
        #expect(try await db.search("arXiv:2606.24530v2", limit: 10) == [pks[1]])
        // Not in the library: fall back to papers citing it in their text.
        try await db.softDelete(pk: pks[0])
        #expect(try await db.search("10.1038/s41586-024-08351-7", limit: 10) == [pks[3]])
    }

    @Test func reindexingFollowsEditsTagsCardsAndDeletes() async throws {
        let (db, pks) = try await library()
        #expect(try await db.search("organoid", limit: 10).isEmpty)
        try await db.setTags(paperPK: pks[2], [Tag(name: "organoid", origin: .agent), Tag(name: "hidden", origin: .suppressed)])
        #expect(try await db.search("organoid", limit: 10) == [pks[2]])
        #expect(try await db.search("hidden", limit: 10).isEmpty)

        var p = try #require(try await db.paper(pk: pks[3]))
        p.card = ReadingCard(tldr: "Transformer for tissue niches.", summary: "Learns niche embeddings.",
                             contributions: ["benchmark"], method: "attention", results: ["wins"], limitations: [],
                             keyTerms: [.init(term: "niche", definition: "microenvironment")], resources: [],
                             paperType: .methods, category: "x", tags: [], difficulty: .medium, estimatedMinutes: 60,
                             checklist: [], textQuality: .good)
        p.notes = "zebrafish idea"
        try await db.updatePaper(p)
        #expect(try await db.search("microenvironment", limit: 10) == [pks[3]])
        #expect(try await db.search("zebrafish", limit: 10) == [pks[3]])

        try await db.softDelete(pk: pks[3])                                          // hidden while deleted
        #expect(try await db.search("zebrafish", limit: 10).isEmpty)
        try await db.restore(pk: pks[3])
        #expect(try await db.search("zebrafish", limit: 10) == [pks[3]])

        try await db.hardDelete(pk: pks[3])                                          // both FTS rows gone
        #expect(try await db.search("zebrafish", limit: 10).isEmpty)
        #expect(try await db.search("neocortex", limit: 10) == [pks[0]])
        await #expect(throws: DatabaseError.self) { try await db.indexFullText(pk: pks[3], text: "x") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DatabaseChangeTests {
    @Test func changesAreSentAfterCommitOnly() async throws {
        let db = try Database.inMemory()
        var events = db.changes.subscribe().makeAsyncIterator()

        let p = try await db.insertPaper(makePaper(1))
        #expect(await events.next() == .paper(pk: p.pk))

        // A failed write emits nothing: the next event is the sentinel below.
        await #expect(throws: SQLiteError.self) { try await db.insertPaper(makePaper(1)) }
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.transaction { db in
                try db.setTags(paperPK: p.pk, [Tag(name: "x", origin: .user)])
                throw Boom()
            }
        }
        #expect(try await db.tags(paperPK: p.pk).isEmpty)                            // rolled back
        try await db.setKV("plan.skipDays", "[]")
        #expect(await events.next() == .settings)

        // One transaction → deduped events after COMMIT.
        let pk = p.pk
        try await db.transaction { db in
            try db.setTags(paperPK: pk, [Tag(name: "x", origin: .user)])
            try db.replaceChecklist(paperPK: pk, items: [])
            _ = try db.insertCategory(PaperCategory(name: "New", origin: .agent))
        }
        #expect(await events.next() == .paper(pk: pk))
        #expect(await events.next() == .categories)

        try await db.insertJob(AgentJob(paperPK: pk, provider: "mock", state: .queued))
        #expect(await events.next() == .jobs)
    }

    @Test func largeBatchesCollapseToBulk() async throws {
        let db = try Database.inMemory()
        var events = db.changes.subscribe().makeAsyncIterator()
        let papers = (1...40).map { makePaper($0) }
        try await db.transaction { db in
            for p in papers { try db.insertPaper(p) }
        }
        #expect(await events.next() == .papersBulk)
        try await db.setKV("k", "v")
        #expect(await events.next() == .settings)
        #expect(try await db.livePapers().count == 40)
    }
}

@Suite struct DatabaseMaintenanceTests {
    @Test func metaCacheAndKV() async throws {
        let db = try Database.inMemory()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(try await db.metaCache(key: "crossref:10.1/x") == nil)
        try await db.putMetaCache(key: "crossref:10.1/x", status: 404, body: nil, at: t)
        var hit = try #require(try await db.metaCache(key: "crossref:10.1/x"))
        #expect(hit.status == 404 && hit.body == nil && hit.fetchedAt == t)
        try await db.putMetaCache(key: "crossref:10.1/x", status: 200, body: Data("{}".utf8), at: t + 5)
        hit = try #require(try await db.metaCache(key: "crossref:10.1/x"))
        #expect(hit.status == 200 && hit.body == Data("{}".utf8) && hit.fetchedAt == t + 5)
        try await db.putMetaCache(key: "empty", status: 204, body: Data(), at: t)
        #expect(try await db.metaCache(key: "empty")?.body == Data())

        #expect(try await db.kv("reminder.lastDeliveredDay") == nil)
        try await db.setKV("reminder.lastDeliveredDay", "2026-09-30")
        try await db.setKV("reminder.lastDeliveredDay", "2026-10-01")
        #expect(try await db.kv("reminder.lastDeliveredDay") == "2026-10-01")
        try await db.removeKV("reminder.lastDeliveredDay")
        #expect(try await db.kv("reminder.lastDeliveredDay") == nil)
    }

    @Test func vacuumIntoMakesAReadableCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-db-vacuum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("library.sqlite"), backupsDir: nil)
        let p = try await db.insertPaper(makePaper(1, title: "Backed up neocortex"))
        try await db.indexFullText(pk: p.pk, text: "hippocampus")
        #expect(await db.quickCheck())
        #expect(await db.integrityCheck() == "ok")
        try await db.checkpoint()

        let copyURL = dir.appendingPathComponent("Backups/library-2026-09-30.sqlite")
        try await db.vacuumInto(copyURL)
        await #expect(throws: SQLiteError.self) { try await db.vacuumInto(copyURL) }     // never overwrites

        let copy = try Database(url: copyURL, backupsDir: nil)
        #expect(copy.migration.fromVersion == Migrations.latestVersion)
        #expect(try await copy.livePapers().map(\.title) == ["Backed up neocortex"])
        #expect(try await copy.search("hippocampus", limit: 5) == [p.pk])
        #expect(await copy.integrityCheck() == "ok")
        await copy.close()

        await db.close()
        await db.close()
        await #expect(throws: SQLiteError.self) { try await db.livePapers() }
        #expect(await db.quickCheck() == false)
    }

    @Test func concurrentTasksThroughTheActor() async throws {
        let db = try Database.inMemory()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 1...100 {
                group.addTask {
                    let p = try await db.insertPaper(makePaper(n, title: "Concurrent paper \(n)", doi: "10.5555/\(n)"))
                    try await db.setTags(paperPK: p.pk, [Tag(name: "t\(n % 7)", origin: .agent)])
                    _ = try await db.livePapers()
                    _ = try await db.search("concurrent", limit: 5)
                    #expect(try await db.paper(id: p.id)?.ids.doi == "10.5555/\(n)")
                }
            }
            try await group.waitForAll()
        }
        let live = try await db.livePapers()
        #expect(live.count == 100)
        #expect(Set(live.map(\.queueRank)) == Set(1...100))
        #expect(try await db.frequentTags(limit: 10).map(\.count).reduce(0, +) == 100)
        #expect(try await db.search("concurrent", limit: 500).count == 100)
    }
}
