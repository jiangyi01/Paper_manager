import Foundation
import Testing
@testable import PaperDeckCore

/// DB lost → rebuilt from card.json + .paperdeck-library.json → canonical dump byte-identical (§9 M6).
@Suite struct RebuildTests {
    private typealias Kit = OpsTestKit
    private typealias PDTag = PaperDeckCore.Tag
    private static func d(_ m: Int, _ day: Int) -> LocalDate { OpsTestKit.day(2026, m, day) }

    private static let card = ReadingCard(
        tldr: "Radial glia diversify into lineage-restricted progenitors across the second trimester.",
        summary: "A single-nucleus atlas of the developing human neocortex.", contributions: ["Map 700k nuclei"],
        method: "snRNA-seq + spatial transcriptomics", results: ["Lineage restriction precedes birth"],
        limitations: [.init(text: "Few donors", source: .inferred)], keyTerms: [.init(term: "RG", definition: "radial glia")],
        resources: [.init(kind: .dataset, name: "GEO", identifier: "GSE123", url: nil)], paperType: .research,
        category: "Spatial Omics", tags: ["atlas"], difficulty: .hard, estimatedMinutes: 90,
        checklist: [.init(task: "Fig. 1: overview", section: "Fig. 1", page: 2, minutes: 20, kind: .figure)],
        textQuality: .good)

    /// A library exercising every column the rebuild must carry. Returns the ids (A, B, C, D).
    private static func buildLibrary(_ env: OpsTestKit.Env) async throws -> [String] {
        let e = env.engine
        // Categories: a user one with description/hue, a renamed starter, a deleted starter, an agent one.
        let spatial = try await e.createCategory(name: "Spatial Omics", description: "Spatial methods and atlases")
        let starters = try await env.db.categories()
        let neuro = try #require(starters.first { $0.name == "Neuroscience & Development" })
        _ = try await e.renameCategory(pk: neuro.pk, name: "Neuro & Dev")
        _ = try await e.setCategoryDescription(pk: neuro.pk, "Brains, renamed by the user")
        try await e.deleteCategory(pk: try #require(starters.first { $0.name == "Microbiome & Metabolism" }).pk)
        let agentCat = try await env.db.insertCategory(PaperCategory(name: "Agent Found", description: nil, hue: 8,
                                                                     origin: .agent, acknowledged: false,
                                                                     createdAt: Kit.start.addingTimeInterval(1.234)))

        // A: AI card + job provenance, ticked + user items, three tag origins, pinned DDL, flags, notes, full text.
        let a = try await Kit.addPaper(env, title: "Alpha atlas", doi: "10.1038/s41586-024-08351-7", deadline: d(10, 2))
        _ = try await env.db.modifyPaper(pk: a.pk) {
            $0.card = Self.card; $0.tldr = Self.card.tldr; $0.cardVersion = 1; $0.aiState = .done; $0.aiSeen = false
            $0.textQuality = .good; $0.flags = [.scanned]; $0.abstract = "An abstract."; $0.charCount = 123_456
        }
        let finished = Kit.start.addingTimeInterval(42.5)
        _ = try await env.db.insertJob(AgentJob(paperPK: a.pk, provider: "mock", state: .succeeded, model: "mock-1",
                                                createdAt: finished, startedAt: finished, finishedAt: finished))
        let items = try await Kit.checklist(env, a.id)
        env.advance(1.5)
        _ = try await e.toggleChecklistItem(paperID: a.id, itemID: items[0].id)
        _ = try await e.addChecklistItem(paperID: a.id, text: "Compare with our organoids", section: "Fig. 3", minutes: 15, page: 7)
        _ = try await e.moveChecklistItem(paperID: a.id, itemID: items[3].id, toIndex: 1)
        try await env.db.setTags(paperPK: a.pk, [PDTag(name: "atlas", origin: .agent), PDTag(name: "noise", origin: .agent)])
        _ = try await e.removeTag(paperID: a.id, "noise")
        _ = try await e.addTag(paperID: a.id, "must-read")
        _ = try await e.setCategory(paperID: a.id, categoryPK: spatial.pk)
        _ = try await e.pinDeadline(paperID: a.id, date: d(10, 6))
        _ = try await e.setNotes(paperID: a.id, "Ask the lab about GSE123.\nSecond line.")
        _ = try await e.setEstimate(paperID: a.id, minutes: 95)
        try e.ctx.texts.save("full text mentioning subventricular zones", id: a.id)
        try await env.db.indexFullText(pk: a.pk, text: "full text mentioning subventricular zones")

        // B: provisional ≈DDL, untouched heuristic checklist, arXiv id + version, renamed starter category.
        let b = try await Kit.addPaper(env, title: "Beta preprint", arxiv: "2606.24530", deadline: d(9, 30), provisional: true)
        _ = try await env.db.modifyPaper(pk: b.pk) { $0.ids.arxivVersion = 2; $0.needsReview = true; $0.placementFloor = OpsTestKit.day(2026, 9, 29) }
        _ = try await e.setCategory(paperID: b.id, categoryPK: neuro.pk)

        // C: unfiled inbox paper, done, in the agent category (not user-set).
        let c = try await Kit.addPaper(env, title: "Gamma inbox", folder: "c0ffee12", doi: "10.1101/2024.01.16.575956",
                                       deadline: d(9, 29), stage: .committed, inInbox: true)
        _ = try await env.db.modifyPaper(pk: c.pk) { $0.categoryPK = agentCat.pk; $0.nameFinal = false; $0.titleRank = .font }
        await e.ctx.syncSidecar(pk: c.pk)
        env.advance(60)
        _ = try await e.setStatus(paperID: c.id, .done)

        // D: soft-deleted, with its own checklist progress and tags.
        let dPaper = try await Kit.addPaper(env, title: "Delta deleted", deadline: d(10, 1))
        _ = try await e.addTag(paperID: dPaper.id, "old")
        _ = try await e.toggleChecklistItem(paperID: dPaper.id, itemID: try await Kit.checklist(env, dPaper.id)[2].id)
        env.advance(60)
        _ = try await e.softDelete(paperID: dPaper.id)

        // Skip days (moves B) — persisted in kv and mirrored into the manifest.
        _ = try await e.skipToday()

        await e.ctx.writeManifest()
        await e.ctx.sidecars.flush()
        return [a.id, b.id, c.id, dPaper.id]
    }

    private static func dropDatabase(_ env: OpsTestKit.Env) async throws {
        await env.engine.shutdown()
        await env.engine.db.close()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: env.paths.database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func cards(_ env: OpsTestKit.Env, _ ids: [String]) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        for id in ids {
            let p = try await Kit.paper(env, id)
            out[id] = try Data(contentsOf: env.engine.ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName))
        }
        return out
    }

    @Test func rebuildFromSidecarsIsLossless() async throws {
        let first = try await Kit.make()
        let root = first.root
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = try await Self.buildLibrary(first)
        let before = try await first.engine.dumpCanonical()
        let cardsBefore = try await Self.cards(first, ids)
        let now = first.clock.value
        try await Self.dropDatabase(first)

        let second = try await Kit.make(root: root, now: now)
        let report = try await second.engine.rebuildFromSidecars()
        #expect(report.papers == 3 && report.deleted == 1)
        #expect(report.manifestFound && report.skipped.isEmpty && report.unreadable.isEmpty)
        #expect(report.skipDays == 1 && report.fullTextIndexed == 1)
        let after = try await second.engine.dumpCanonical()
        if before != after {
            let b = String(decoding: before, as: UTF8.self).split(separator: "\n")
            let a = String(decoding: after, as: UTF8.self).split(separator: "\n")
            let firstDiff = zip(b, a).enumerated().first { $0.element.0 != $0.element.1 }
            Issue.record("canonical dumps differ at line \(firstDiff?.offset ?? -1): \(firstDiff?.element.0 ?? "") ≠ \(firstDiff?.element.1 ?? "")")
        }
        #expect(before == after)

        // Rewriting the sidecars from the rebuilt rows reproduces the same bytes (AI provenance kept).
        for id in ids { await second.engine.ctx.syncSidecar(pk: try await Kit.paper(second, id).pk) }
        await second.engine.ctx.sidecars.flush()
        let cardsAfter = try await Self.cards(second, ids)
        for id in ids where cardsAfter[id] != cardsBefore[id] {
            let b = String(decoding: cardsBefore[id] ?? Data(), as: UTF8.self).split(separator: "\n")
            let a = String(decoding: cardsAfter[id] ?? Data(), as: UTF8.self).split(separator: "\n")
            let diff = zip(b, a).first { $0.0 != $0.1 }
            Issue.record("card.json of \(id) differs: \(diff?.0 ?? "") ≠ \(diff?.1 ?? "")")
        }
        #expect(try await second.engine.search("subventricular") == [ids[0]])
        #expect(await second.engine.ctx.skipDays() == [Self.d(9, 29)])
        await second.engine.shutdown()
        await second.engine.db.close()
    }

    @Test func launchMaintenanceRebuildsAnEmptyIndex() async throws {
        let first = try await Kit.make()
        let root = first.root
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Kit.addPaper(first, title: "Only one")
        let category = try await first.engine.createCategory(name: "Kept Category", description: "kept")
        _ = try await first.engine.setCategory(paperID: p.id, categoryPK: category.pk)
        await first.engine.ctx.sidecars.flush()
        let before = try await first.engine.dumpCanonical()
        try await Self.dropDatabase(first)

        let second = try await Kit.make(root: root)
        let report = await Maintenance(engine: second.engine, trash: { _ in false }).onLaunch()
        #expect(report.errors.isEmpty)
        #expect(report.rebuilt?.papers == 1)
        #expect(try await second.engine.dumpCanonical() == before)
        #expect(try await Kit.paper(second, p.id).categoryPK != nil)
        await second.engine.shutdown()
        await second.engine.db.close()
    }

    @Test func rebuildRefusesANonEmptyIndexUnlessReplacing() async throws {
        try await Kit.run { env in
            _ = try await Self.buildLibrary(env)
            let before = try await env.engine.dumpCanonical()
            await #expect(throws: PaperOperationError.libraryNotEmpty) { try await env.engine.rebuildFromSidecars() }
            let report = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            #expect(report.papers == 3 && report.deleted == 1)
            #expect(try await env.engine.dumpCanonical() == before)
        }
    }

    @Test func dumpIsDeterministicAndExcludesVolatileColumns() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let one = try await env.engine.dumpCanonical()
            #expect(try await env.engine.dumpCanonical() == one)
            _ = try await env.db.modifyPaper(pk: p.pk, now: Date()) { _ in }        // only updated_at changes
            #expect(try await env.engine.dumpCanonical() == one)
            let text = String(decoding: one, as: UTF8.self)
            #expect(!text.contains("\"pk\"") && !text.contains("updatedAt"))
            #expect(text.contains("\"skipDays\"") && text.contains("\"categories\""))
        }
    }
}
