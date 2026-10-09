import Foundation
import Testing
@testable import PaperDeckCore

// Regression tests for review findings in the intake half of the import pipeline
// (IntakeActor, FileOps, Maintenance temp sweep). Each test names the finding it guards.

private var fm: FileManager { FileManager.default }

// MARK: - Finding 1: bioRxiv 10.1101 ↔ 10.64898 are one work

@Suite(.serialized) struct RegressionBiorxivIdentityTests {
    private typealias Kit = OpsTestKit
    static let oldPrefix = "10.1101/2026.02.27.708412"
    static let newPrefix = "10.64898/2026.02.27.708412"

    private static func row(_ sha: String, doi: String? = nil, published: String? = nil,
                            deleted: Bool = false) -> Paper {
        Paper(sha256: sha, fileSize: 1, ids: PaperIDs(doi: doi, publishedDOI: published), title: "Paper \(sha)",
              titleRank: .api, folder: "Papers/\(sha)", pdfName: "\(sha).pdf", originalName: "\(sha).pdf")
    }

    /// v1 is enriched (DOI rewritten 10.1101 → 10.64898); dropping v2 (different bytes, the
    /// 10.1101 DOI in its file name) must hit the same-work prompt, not become a second paper.
    @Test func biorxivSecondVersionAfterPrefixMigrationIsSameWork() async throws {
        try await withRIHarness(RIConfig(fetcher: MetadataResolverTests.FakeFetcher())) { h in
            let first = await h.importAll([.file(try h.writeSource("2026.02.27.708412v1.full.pdf"))])
            let a = try await h.paper(try #require(first.added.first))
            #expect(a.ids.doi == Self.newPrefix)
            h.events.clear()
            let second = await h.importAll([.file(try h.writeSource("2026.02.27.708412v2.full.pdf"))])
            #expect(second.added.isEmpty, "v2 was imported as a separate paper: \(second.added)")
            #expect(await h.intake.pendingIDs().count == 1)
            #expect(try await h.db.livePapers().count == 1)
            #expect(h.events.toasts.contains { $0.message.hasPrefix("同一论文已在库中") })
        }
    }

    @Test func paperMatchingWorkCrossesTheBiorxivPrefixes() async throws {
        let db = try Database.inMemory()
        let migrated = try await db.insertPaper(Self.row("aaaa", doi: Self.newPrefix))
        #expect(try await db.paperMatchingWork(doi: Self.oldPrefix, arxivID: nil, publishedDOI: nil)?.pk == migrated.pk)
        #expect(try await db.paperMatchingWork(doi: Self.oldPrefix.uppercased(), arxivID: nil, publishedDOI: nil)?.pk
                == migrated.pk)
        #expect(try await db.paperMatchingWork(doi: Self.oldPrefix + "v3", arxivID: nil, publishedDOI: nil)?.pk
                == migrated.pk)
        #expect(try await db.paperMatchingWork(doi: nil, arxivID: nil, publishedDOI: Self.oldPrefix)?.pk == migrated.pk)
        // published_doi recorded under the old prefix matches the new one too.
        let journal = try await db.insertPaper(Self.row("bbbb", doi: "10.1016/j.cell.2026.01.001",
                                                        published: "10.1101/2025.09.01.673319"))
        #expect(try await db.paperMatchingWork(doi: "10.64898/2025.09.01.673319", arxivID: nil, publishedDOI: nil)?.pk
                == journal.pk)
        // Cold Spring Harbor journals share 10.1101 but have no alias.
        _ = try await db.insertPaper(Self.row("cccc", doi: "10.1101/gr.123456.111"))
        #expect(try await db.paperMatchingWork(doi: "10.64898/gr.123456.111", arxivID: nil, publishedDOI: nil) == nil)
        // Deleted papers never match.
        try await db.softDelete(pk: migrated.pk)
        #expect(try await db.paperMatchingWork(doi: Self.oldPrefix, arxivID: nil, publishedDOI: nil) == nil)
    }

    /// The paper being checked never hides another holder (bioRxiv aliases make it match itself).
    @Test func paperMatchingWorkCanExcludeThePaperItself() async throws {
        let db = try Database.inMemory()
        let checked = try await db.insertPaper(Self.row("aaaa", doi: Self.oldPrefix))
        let holder = try await db.insertPaper(Self.row("bbbb", doi: Self.newPrefix))
        #expect(try await db.paperMatchingWork(doi: Self.newPrefix, arxivID: nil, publishedDOI: nil)?.pk == checked.pk)
        #expect(try await db.paperMatchingWork(doi: Self.newPrefix, arxivID: nil, publishedDOI: nil,
                                               excluding: checked.pk)?.pk == holder.pk)
        #expect(try await db.livePaper(holdingDOI: Self.oldPrefix, excluding: checked.pk)?.pk == holder.pk)
        #expect(try await db.livePaper(holdingDOI: "10.1016/none", excluding: nil) == nil)
    }

    /// IntakeActor tells an exact duplicate (sha256) from the same work (ux_doi / ux_arxiv)
    /// by the constraint SQLite names; pin that message shape.
    @Test func uniqueViolationsNameTheirColumn() async throws {
        let db = try Database.inMemory()
        _ = try await db.insertPaper(Self.row("aaaa", doi: "10.1038/one"))
        do {
            _ = try await db.insertPaper(Self.row("aaaa", doi: "10.1038/two"))
            Issue.record("duplicate sha256 was accepted")
        } catch let e as SQLiteError {
            #expect(e.isUniqueViolation && e.message.contains("sha256"), "\(e.message)")
        }
        do {
            _ = try await db.insertPaper(Self.row("bbbb", doi: "10.1038/ONE"))
            Issue.record("duplicate live DOI was accepted")
        } catch let e as SQLiteError {
            #expect(e.isUniqueViolation && e.message.contains("doi") && !e.message.contains("sha256"), "\(e.message)")
        }
    }

    @Test func searchFindsTheWorkUnderEitherPrefix() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(Self.row("aaaa", doi: Self.newPrefix))
        #expect(try await db.search(Self.newPrefix) == [p.pk])
        #expect(try await db.search(Self.oldPrefix) == [p.pk])
        #expect(try await db.search("https://doi.org/" + Self.oldPrefix) == [p.pk])
        let q = try await db.insertPaper(Self.row("bbbb", doi: "10.1038/x1", published: "10.1101/2025.09.01.673319"))
        #expect(try await db.search("doi:10.64898/2025.09.01.673319") == [q.pk])
    }

    @Test func editMetadataRefusesTheOtherPrefixOfALivePaper() async throws {
        try await Kit.run { env in
            let holder = try await Kit.addPaper(env, title: "Holder", doi: Self.newPrefix)
            let other = try await Kit.addPaper(env, title: "Other")
            await #expect(throws: PaperOperationError.duplicateIdentifier(paperID: holder.id, title: "Holder")) {
                try await env.engine.editMetadata(paperID: other.id, title: "Other", authors: [], year: nil, venue: nil,
                                                  doi: Self.oldPrefix, arxivID: nil)
            }
            #expect(try await Kit.paper(env, other.id).ids.doi == nil)
            // The holder itself may switch between the two prefixes.
            let moved = try await env.engine.editMetadata(paperID: holder.id, title: "Holder", authors: [], year: nil,
                                                          venue: nil, doi: Self.oldPrefix, arxivID: nil)
            #expect(moved.ids.doi == Self.oldPrefix)
        }
    }

    @Test func restoreRefusesWhileTheOtherPrefixIsLive() async throws {
        try await Kit.run { env in
            let old = try await Kit.addPaper(env, title: "v1", doi: Self.oldPrefix)
            _ = try await env.engine.softDelete(paperID: old.id)
            let fresh = try await Kit.addPaper(env, title: "v2", doi: Self.newPrefix)
            await #expect(throws: PaperOperationError.restoreConflict(paperID: fresh.id, title: "v2")) {
                try await env.engine.restore(paperID: old.id)
            }
            #expect(try await Kit.paper(env, old.id).isDeleted)
        }
    }

    /// Crossref answers a title search with the 10.64898 record while another paper holds the
    /// 10.1101 DOI: enrichment must warn that the two are the same work.
    @Test func enrichmentWarnsWhenTheOtherPrefixIsHeld() async throws {
        let fetcher = CrossrefTitleFetcher()
        let title = try fetcher.workTitle()
        try await withRIHarness(RIConfig(fetcher: fetcher,
                                         extractor: RIFakeExtractor(docs: ["found-by-title.pdf": RIFakeDoc(title: title)]))) { h in
            var holder = Self.row("dddd", doi: Self.oldPrefix)
            holder.metaUserEdited = true
            holder.stage = .ready
            let saved = try await h.db.insertPaper(holder)
            let summary = await h.importAll([.file(try h.writeSource("found-by-title.pdf"))])
            let p = try await h.paper(try #require(summary.added.first))
            #expect(fetcher.requested.contains { $0.contains("query.bibliographic") })
            #expect(p.titleRank == .api)
            let warning = h.events.toasts.first { $0.message.hasPrefix("可能与已有论文重复") }
            #expect(warning?.buttons.map(\.action) == [.openPaper(id: saved.id)], "no same-work warning for \(p.ids)")
        }
    }
}

/// Serves Crossref's 10.64898 Eubiota record as the only hit of any title search; 404 elsewhere.
private final class CrossrefTitleFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    var requested: [String] { lock.withLock { urls } }

    private func work() throws -> [String: Any] {
        let data = try MetadataParsingTests.fixture("crossref-64898-2026-02-27-708412", "json")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["message"] as? [String: Any])
    }

    func workTitle() throws -> String {
        try #require((try work()["title"] as? [String])?.first)
    }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        lock.withLock { urls.append(url.absoluteString) }
        if url.host == "api.crossref.org", url.path == "/works", (url.query ?? "").contains("query.bibliographic=") {
            let list: [String: Any] = ["status": "ok", "message": ["items": [try work()]]]
            return HTTPResult(status: 200, body: try JSONSerialization.data(withJSONObject: list))
        }
        return HTTPResult(status: 404, body: Data())
    }
}

// MARK: - Finding 3: a DOI adopted during the commit must not fail the drop

@Suite(.serialized) struct RegressionCommitRaceTests {
    /// The same-work check ran outside the insert transaction; an enrichment adopting the DOI
    /// in that window made the insert hit ux_doi and the drop failed with a raw SQLite error.
    @Test func doiAdoptedDuringCommitFailsTheDrop() async throws {
        var docs: [String: RIFakeDoc] = [:]
        for i in 0..<60 {
            docs["a\(i).pdf"] = RIFakeDoc(title: "Some untitled study number \(i)")
            docs["b\(i).pdf"] = RIFakeDoc(title: "Some untitled study number \(i)", ids: PaperIDs(doi: "10.1234/race.\(i)"))
        }
        try await withRIHarness(RIConfig(extractor: RIFakeExtractor(docs: docs))) { h in
            var failed = 0
            for i in 0..<60 {
                let a = try await h.paper(try #require(await h.importAll([.file(try h.writeSource("a\(i).pdf"))]).added.first))
                let src = try h.writeSource("b\(i).pdf")
                let delay = UInt64(i % 12) * 100_000
                async let summary = h.intake.ingest([.file(src)], options: ImportOptions(origin: .drop))
                async let adopt: Void = {
                    try? await Task.sleep(nanoseconds: delay)
                    _ = try? await h.db.modifyPaper(pk: a.pk) { $0.ids.doi = "10.1234/race.\(i)" }   // EnrichActor merge
                }()
                let s = await summary
                await adopt
                if s.failed > 0 { failed += 1 }
            }
            await h.events.drain()
            #expect(failed == 0, "\(failed)/60 drops failed instead of a same-work prompt")
            #expect(!h.events.toasts.contains { $0.message.contains("SQLite") })
        }
    }
}

// MARK: - Finding 8: setup assistant / CLI imports copy, never move

@Suite(.serialized) struct RegressionImportModeTests {
    @Test func setupAssistantImportNeverTrashesOriginals() async throws {
        let trashed = RITrash()
        try await withRIHarness(RIConfig(settings: riSettings(importMode: .move), trash: trashed.function)) { h in
            let folder = h.sources.appendingPathComponent("Paper_reading", isDirectory: true)
            let a = try h.writeSource("a.pdf", in: folder)
            let b = try h.writeSource("b.pdf", in: folder.appendingPathComponent("Sub"))
            let summary = await h.importAll([.file(folder)], ImportOptions(origin: .setupAssistant))
            #expect(summary.added.count == 2)
            #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path), "setup-assistant import trashed originals")

            let cli = try h.writeSource("cli.pdf")
            #expect(await h.importAll([.file(cli)], ImportOptions(origin: .cli, ai: .skip)).added.count == 1)
            #expect(fm.fileExists(atPath: cli.path), "CLI import trashed the original")
            #expect(trashed.all.isEmpty)
            #expect(!h.events.toasts.contains { $0.message.contains("原文件已保留") })

            // An ordinary drop in move mode still moves the original.
            let dropped = try h.writeSource("drop.pdf")
            #expect(await h.importAll([.file(dropped)]).added.count == 1)
            #expect(trashed.all.map(\.lastPathComponent) == ["drop.pdf"])
        }
    }
}

// MARK: - Finding 9: the launch sweep never deletes an in-flight partial

@Suite(.serialized) struct RegressionPartialSweepTests {
    /// A clone kept the source's mtime, so `partialsBefore: launchedAt` swept a partial that an
    /// ingest running concurrently with Engine.start() had just created.
    @Test func freshPartialCloneLooksOlderThanLaunch() async throws {
        try await withRIHarness { h in
            let src = try h.writeSource("old.pdf")
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: src.path)
            let clone = try FileOps.cloneIntoPartial(source: src, partialDir: h.paths.partial)
            let launchedAt = Date().addingTimeInterval(-1)       // the app launched a second ago
            let removed = await Maintenance(engine: h.engine).cleanTemporaryFiles(partialsBefore: launchedAt)
            #expect(removed.partials == 0, "an in-flight partial created after launch was swept")
            #expect(fm.fileExists(atPath: clone.url.path))
        }
    }

    /// Even a partial that looks old is kept while an import is still working on it.
    @Test func inFlightPartialSurvivesTheSweep() async throws {
        let gate = RILatch()
        try await withRIHarness(RIConfig(extractor: RIFakeExtractor(gate: gate))) { h in
            let src = try h.writeSource("in-flight.pdf")
            async let summary = h.intake.ingest([.file(src)], options: ImportOptions(origin: .drop))
            await gate.waitForArrivals(1)
            let names = h.names(h.paths.partial)
            #expect(names.count == 1)
            for name in names {
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                     ofItemAtPath: h.paths.partial.appendingPathComponent(name).path)
            }
            let removed = await Maintenance(engine: h.engine).cleanTemporaryFiles(partialsBefore: Date())
            gate.open()
            let s = await summary
            #expect(removed.partials == 0)
            #expect(s.added.count == 1 && s.failed == 0)
            // Once committed it is no longer protected (nothing is left to protect).
            #expect(h.names(h.paths.partial).isEmpty)
        }
    }
}

// MARK: - Finding 10: commit failures are localized, once

@Suite(.serialized) struct RegressionCommitFailureTextTests {
    @Test func unwritableInboxSaysCouldNotWriteToTheLibrary() async throws {
        let gate = RILatch()
        try await withRIHarness(RIConfig(extractor: RIFakeExtractor(gate: gate))) { h in
            let src = try h.writeSource("locked-inbox.pdf")
            async let summary = h.intake.ingest([.file(src)], options: ImportOptions(origin: .drop))
            await gate.waitForArrivals(1)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.paths.inbox.path)
            gate.open()
            let s = await summary
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.paths.inbox.path)
            await h.events.drain()
            #expect(s.failed == 1)
            let errors = h.events.toasts.filter { $0.kind == .error }.map(\.message)
            #expect(errors == ["无法导入 locked-inbox.pdf：写入资料库失败"])
            #expect(h.events.rows.last?.stage == .failed(reason: "写入资料库失败"))
            #expect(h.names(h.paths.partial).isEmpty)
            #expect(try await h.db.allPapers().isEmpty)
        }
    }

    @Test func databaseErrorIsGenericAndLocalized() async throws {
        let gate = RILatch()
        try await withRIHarness(RIConfig(settings: riSettings(lang: .en), extractor: RIFakeExtractor(gate: gate))) { h in
            let src = try h.writeSource("db-down.pdf")
            async let summary = h.intake.ingest([.file(src)], options: ImportOptions(origin: .drop))
            await gate.waitForArrivals(1)
            await h.db.close()
            gate.open()
            let s = await summary
            await h.events.drain()
            #expect(s.failed == 1)
            let errors = h.events.toasts.filter { $0.kind == .error }.map(\.message)
            #expect(errors == ["Can't import db-down.pdf: Couldn't write to the library"])
            #expect(h.names(h.paths.inbox).isEmpty)
            #expect(h.names(h.paths.partial).isEmpty)
        }
    }

    /// A vanished library at commit time pauses the batch (one toast), like the ingest path.
    @Test func libraryVanishingAtCommitPausesTheBatch() async throws {
        let gate = RILatch()
        try await withRIHarness(RIConfig(extractor: RIFakeExtractor(gate: gate))) { h in
            let a = try h.writeSource("a.pdf"), b = try h.writeSource("b.pdf")
            async let summary = h.intake.ingest([.file(a), .file(b)], options: ImportOptions(origin: .drop))
            await gate.waitForArrivals(2)
            let aside = h.root.appendingPathComponent("Papers-aside", isDirectory: true)
            try fm.moveItem(at: h.paths.papers, to: aside)
            gate.open()
            let s = await summary
            try fm.moveItem(at: aside, to: h.paths.papers)
            await h.events.drain()
            #expect(s.failed == 2 && s.added.isEmpty)
            let errors = h.events.toasts.filter { $0.kind == .error }.map(\.message)
            #expect(errors == ["资料库不可用，导入已暂停"])
            #expect(h.events.rows.filter { $0.stage == .failed(reason: "资料库不可用") }.count == 2)
        }
    }
}
