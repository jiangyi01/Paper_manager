import Foundation
import Testing
@testable import PaperDeckCore

// Regression tests for review findings on library files: filing vs. soft delete, purge,
// restore, launch recovery of interrupted commits, and replaced PDFs in 最近删除.

private var fm: FileManager { FileManager.default }

// MARK: - Finding 2: filing and soft delete are atomic with respect to each other

@Suite(.serialized) struct RegressionFilingRaceTests {
    private typealias Kit = OpsTestKit

    /// fileStep moved the folder outside the Database call, so a delete could record
    /// `.recently-deleted/<old>` while the files ended up under Papers/<new> (orphaned).
    @Test func refileRacingSoftDeleteOrphansFolder() async throws {
        try await Kit.run { env in
            var orphans = 0, lost = 0, errors = 0
            for i in 0..<200 {
                let p = try await Kit.addPaper(env, title: "Race \(i)", folder: "old-name-\(i)")
                let delay = UInt64(i % 20) * 50_000
                async let moved: Bool = env.engine.enrich.refile(pk: p.pk)
                async let deleted: Paper? = {
                    try? await Task.sleep(nanoseconds: delay)
                    return try? await env.engine.softDelete(paperID: p.id)
                }()
                _ = await moved
                if await deleted == nil { errors += 1 }
                let row = try await Kit.paper(env, p.id)
                let canonical = env.paths.papers.appendingPathComponent(
                    FileNamer.folderName(year: row.year, firstAuthor: row.authors.first, title: row.title))
                if row.isDeleted, fm.fileExists(atPath: canonical.path) { orphans += 1 }
                if !fm.fileExists(atPath: env.engine.ctx.pdfURL(row).path) || row.flags.contains(.missing) { lost += 1 }
            }
            #expect(orphans == 0, "\(orphans)/200 deleted papers left their folder live under Papers/")
            #expect(lost == 0, "\(lost)/200 rows point at a folder/PDF that is not there")
            #expect(errors == 0)
        }
    }

    /// The state such a race (or a Finder move) leaves: the folder is not where the row says.
    /// Soft delete finds it by its card.json id and takes it along, so the 30-day purge can't
    /// leave it behind to be adopted back as a live paper.
    @Test func orphanFromRaceResurrectsAfterPurge() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Deleted for good", folder: "old-name")
            await env.engine.ctx.sidecars.flush()
            let moved = env.paths.papers.appendingPathComponent("2024_Wang_Deleted-for-good")
            try fm.moveItem(at: env.paths.papers.appendingPathComponent("old-name"), to: moved)
            let deleted = try await env.engine.softDelete(paperID: p.id)
            #expect(!deleted.flags.contains(.missing))
            #expect(!fm.fileExists(atPath: moved.path))
            #expect(fm.fileExists(atPath: env.engine.ctx.pdfURL(deleted).path))
            env.advance(31 * 86_400)
            _ = try await env.engine.purgeExpired(trash: { _ in true })
            #expect(try await env.db.paper(id: p.id) == nil)
            let report = try await Maintenance(engine: env.engine, trash: { _ in true }).reconcile()
            #expect(!report.adopted.contains(p.id), "a paper deleted 31 days ago came back as a live paper")
        }
    }

    @Test func folderMovedInFinderComesBackOnRestore() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Moved by hand", folder: "by-hand")
            await env.engine.ctx.sidecars.flush()
            let moved = env.paths.papers.appendingPathComponent("Renamed in Finder")
            try fm.moveItem(at: env.paths.papers.appendingPathComponent("by-hand"), to: moved)
            try fm.moveItem(at: moved.appendingPathComponent("by-hand.pdf"), to: moved.appendingPathComponent("renamed.pdf"))
            let deleted = try await env.engine.softDelete(paperID: p.id)
            #expect(!deleted.flags.contains(.missing))
            #expect(deleted.pdfName == "renamed.pdf")
            let restored = try await env.engine.restore(paperID: p.id)
            #expect(!restored.flags.contains(.missing))
            #expect(restored.folder.hasPrefix("Papers/"))
            #expect(fm.fileExists(atPath: env.engine.ctx.pdfURL(restored).path))
        }
    }

    /// Deleted while its folder was outside the library; the user later drags the folder back
    /// into Papers/. The purge trashes that copy too instead of leaving it to be re-adopted.
    @Test func purgeTrashesAFolderThatReappearedUnderPapers() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Came back", folder: "came-back")
            let other = try await Kit.addPaper(env, title: "Unrelated", folder: "unrelated")
            await env.engine.ctx.sidecars.flush()
            let outside = env.root.appendingPathComponent("Desktop-copy", isDirectory: true)
            try fm.moveItem(at: env.paths.papers.appendingPathComponent("came-back"), to: outside)
            let deleted = try await env.engine.softDelete(paperID: p.id)
            #expect(deleted.flags.contains(.missing))
            let back = env.paths.papers.appendingPathComponent("Came-back-again", isDirectory: true)
            try fm.moveItem(at: outside, to: back)
            env.advance(31 * 86_400)
            let trash = RITrash()
            #expect(try await env.engine.purgeExpired(trash: trash.function) == [p.id])
            #expect(!fm.fileExists(atPath: back.path))
            #expect(fm.fileExists(atPath: env.engine.ctx.pdfURL(other).path))
            let report = try await Maintenance(engine: env.engine, trash: trash.function).reconcile()
            #expect(report.adopted.isEmpty)
        }
    }
}

// MARK: - Finding 5: purge / 永久删除 re-read the row

@Suite(.serialized) struct RegressionPurgeSnapshotTests {
    private typealias Kit = OpsTestKit

    /// purgeExpired worked from a list read before its awaits; a paper restored meanwhile was
    /// hard-deleted anyway.
    @Test func purgeHardDeletesPaperRestoredMeanwhile() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Restored late")
            _ = try await env.engine.softDelete(paperID: p.id)
            env.advance(31 * 86_400)
            let expired = try await env.db.deletedPapers()                 // purgeExpired's snapshot
            _ = try await env.engine.restore(paperID: p.id)                 // user clicks 恢复 meanwhile
            let trash = RITrash()
            for old in expired { _ = try await OpsFiles.hardRemove(env.engine, old, trash: trash.function) }
            let row = try #require(try await env.db.paper(id: p.id), "a live (restored) paper was hard-deleted by the purge")
            #expect(row.isLive)
            #expect(trash.all.isEmpty)
            #expect(fm.fileExists(atPath: env.engine.ctx.pdfURL(row).path))
        }
    }

    /// Restored and deleted again after the snapshot: not expired any more, so not purged.
    @Test func purgeSkipsAPaperDeletedAgainSinceTheSnapshot() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Deleted twice")
            _ = try await env.engine.softDelete(paperID: p.id)
            env.advance(31 * 86_400)
            let expired = try await env.db.deletedPapers()
            _ = try await env.engine.restore(paperID: p.id)
            let again = try await env.engine.softDelete(paperID: p.id)
            let cutoff = env.clock.value.addingTimeInterval(-Engine.recentlyDeletedRetention)
            let trash = RITrash()
            for old in expired {
                #expect(try await OpsFiles.hardRemove(env.engine, old, scope: .stillDeleted(cutoff: cutoff),
                                                      trash: trash.function) == .skipped)
            }
            let row = try #require(try await env.db.paper(id: p.id))
            #expect(row.deletedAt == again.deletedAt && trash.all.isEmpty)
            #expect(fm.fileExists(atPath: env.engine.ctx.pdfURL(row).path))
        }
    }

    /// 永久删除 acts on the paper as it is when it runs: its current folder goes to the
    /// Trash (not the stale one), so nothing is left behind to be re-adopted.
    @Test func deleteNowTrashesTheFolderThePaperHasNow() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Now")
            let stale = try await env.engine.softDelete(paperID: p.id)
            let restored = try await env.engine.restore(paperID: p.id)
            #expect(stale.folder != restored.folder)
            let trash = RITrash()
            #expect(try await OpsFiles.hardRemove(env.engine, stale, scope: .asIsNow, trash: trash.function) == .removed)
            #expect(try await env.db.paper(id: p.id) == nil)
            #expect(trash.all.map(\.lastPathComponent) == [OpsFiles.folderName(restored)])
            #expect(!fm.fileExists(atPath: env.engine.ctx.folderURL(restored).path))
            #expect(try await Maintenance(engine: env.engine, trash: trash.function).reconcile().adopted.isEmpty)
            // Public entry point: a second call finds nothing and is not an error.
            await #expect(throws: PaperOperationError.paperNotFound(p.id)) {
                try await env.engine.deleteNow(paperID: p.id, trash: trash.function)
            }
        }
    }

    @Test func deleteNowKeepsTheRowWhenTrashFails() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Sticky", folder: "sticky")
            await #expect(throws: PaperOperationError.trashFailed("sticky")) {
                try await env.engine.deleteNow(paperID: p.id, trash: { _ in false })
            }
            #expect(try await env.db.paper(id: p.id) != nil)
        }
    }

    /// The sidecar writer runs outside the Database, so folders move (最近删除, 恢复, Trash) while
    /// a card.json is being written. Foundation's atomic write left its temp file
    /// (`card.json.sb-…`) inside a folder that moved mid-write — about one paper in four here,
    /// where OpsTestKit's 10 ms writer window overlaps the moves. Writes are staged in
    /// `.partial` now, so a moved or trashed folder gets the whole file or nothing.
    @Test func foldersMovedWhileTheirCardIsWrittenKeepNoTempFiles() async throws {
        try await Kit.run { env in
            let trash = RITrash()
            var trashed: [URL] = []
            for i in 0..<60 {
                let p = try await Kit.addPaper(env, title: "Moving \(i)")
                _ = try await env.engine.softDelete(paperID: p.id)
                let restored = try await env.engine.restore(paperID: p.id)
                try? await Task.sleep(nanoseconds: UInt64(i % 12) * 1_000_000)     // vary the overlap
                #expect(try await OpsFiles.hardRemove(env.engine, restored, scope: .asIsNow, trash: trash.function) == .removed)
                trashed.append(env.engine.ctx.folderURL(restored))
            }
            await env.engine.ctx.sidecars.flush()
            #expect(trash.all == trashed)
            #expect(trashed.allSatisfy { !fm.fileExists(atPath: $0.path) }, "a trashed folder was re-created")
            let expected: Set<String> = [CardSidecar.fileName, CardSidecar.notesFileName]
            var strays: [String] = []
            for folder in (try? fm.contentsOfDirectory(at: trash.directory, includingPropertiesForKeys: nil)) ?? [] {
                let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                strays += names.filter { !expected.contains($0) && !$0.hasSuffix(".pdf") }
            }
            #expect(strays.isEmpty, "temp files stranded in moved folders: \(strays.prefix(3))")
            #expect(((try? fm.contentsOfDirectory(atPath: env.paths.partial.path)) ?? []).isEmpty)
            #expect(await env.engine.ctx.sidecars.statistics.failures == 0)
        }
    }
}

// MARK: - Finding 4: a crash between `.partial → _Inbox/<sha8>/` and the insert

@Suite(.serialized) struct RegressionInterruptedCommitTests {
    /// The orphan folder was never adopted and a re-drop filed a second copy (`<sha8>_2`).
    @Test func orphanInboxFolderFromCrashBeforeCommit() async throws {
        try await withRIHarness { h in
            let src = try h.writeSource("Crashy.pdf")
            let sha = try FileOps.sha256(of: src)
            // State left by a crash right after placeInInbox (no row, no card.json yet).
            let orphan = h.paths.inbox.appendingPathComponent(FileNamer.inboxFolderName(sha: sha, originalName: "Crashy.pdf"))
            try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: orphan.appendingPathComponent(FileNamer.inboxPDFName(originalName: "Crashy.pdf")))
            let trash = RITrash()
            let report = await Maintenance(engine: h.engine, trash: trash.function).onLaunch()
            #expect(report.errors.isEmpty)
            #expect(report.reconcile.adopted.count == 1, "orphan inbox folder was neither adopted nor cleaned")
            await h.engine.enrich.waitUntilIdle()
            let id = try #require(report.reconcile.adopted.first)
            let p = try await h.paper(id)
            #expect(p.isLive && p.sha256 == sha && p.originalName == "Crashy.pdf")
            #expect(p.stage == .ready)
            #expect(fm.fileExists(atPath: h.ctx.pdfURL(p).path))
            #expect(trash.all.isEmpty)

            let again = await h.importAll([.file(src)])
            #expect(again.duplicates == 1)
            #expect(h.copies(ofSHA: sha) == 1, "\(h.copies(ofSHA: sha)) copies of the same PDF in the library")
        }
    }

    /// Only a bare `_Inbox/<sha8>/` holding exactly the PDF that hashes to it is recovered.
    @Test func otherInboxLeftoversAreNotTouched() async throws {
        try await withRIHarness { h in
            let known = try h.writeSource("known.pdf")
            let summary = await h.importAll([.file(known)])
            #expect(summary.added.count == 1)
            func leftover(_ folder: String, files: [URL]) throws -> URL {
                let dir = h.paths.inbox.appendingPathComponent(folder, isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in files { try fm.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent)) }
                return dir
            }
            let loose = try leftover("loose", files: [try h.writeSource("loose.pdf")])            // not a sha8 name
            let knownSHA = try FileOps.sha256(of: known)
            let dup = try leftover(String(knownSHA.prefix(8)), files: [known])                  // bytes already a paper
            let x = try h.writeSource("x.pdf"), y = try h.writeSource("y.pdf")
            let two = try leftover(String(try FileOps.sha256(of: x).prefix(8)), files: [x, y])  // two PDFs
            let wrong = try leftover("0123abcd", files: [try h.writeSource("mismatch.pdf")])     // name ≠ its hash
            let report = try await Maintenance(engine: h.engine, trash: RITrash().function).reconcile()
            #expect(report.adopted.isEmpty)
            for dir in [loose, dup, two, wrong] { #expect(fm.fileExists(atPath: dir.path)) }
            #expect(try await h.db.allPapers().count == 1)
        }
    }
}

// MARK: - Finding 6: the old PDF of 「替换并保留清单」 is purged after 30 days

@Suite(.serialized) struct RegressionReplacedPDFTests {
    private static func replaceOnce(_ h: RIHarness) async throws -> (paper: Paper, oldSHA: String) {
        let first = await h.importAll([.file(try h.writeSource("2606.24530v2.pdf"))])
        let p = try await h.paper(try #require(first.added.first))
        _ = await h.importAll([.file(try h.writeSource("2606.24530v3.pdf"))])
        let pendingID = try #require(await h.intake.pendingIDs().first)
        await h.intake.resolvePending(pendingID: pendingID, replace: true)
        await h.ctx.sidecars.flush()
        return (p, p.sha256)
    }

    /// Paths below `.recently-deleted/` of files whose bytes hash to `sha`.
    private static func parked(_ h: RIHarness, sha: String) -> [String] {
        var out: [String] = []
        let walker = fm.enumerator(at: h.paths.recentlyDeleted, includingPropertiesForKeys: nil)
        while let u = walker?.nextObject() as? URL {
            if u.pathExtension == "pdf", (try? FileOps.sha256(of: u)) == sha {
                out.append(String(u.standardizedFileURL.path.dropFirst(h.paths.recentlyDeleted.standardizedFileURL.path.count)))
            }
        }
        return out
    }

    /// Both reviewers: "Replace, keep checklist" parked the old PDF in .recently-deleted/<folder>/
    /// without any record — not purged after 30 days, not cleaned as an orphan, kept forever.
    @Test func replacedPDFIsNeverPurged() async throws {
        try await withRIHarness { h in
            let (p, oldSHA) = try await Self.replaceOnce(h)
            #expect(Self.parked(h, sha: oldSHA).count == 1)
            #expect(Self.parked(h, sha: oldSHA).first?.hasSuffix("/" + p.pdfName) == true)
            #expect(try await h.db.deletedPapers().isEmpty)
            let trash = RITrash()
            _ = try await h.engine.purgeExpired(olderThan: 0, trash: trash.function)
            _ = try await h.engine.storage.cleanOrphans(trash: trash.function)
            #expect(Self.parked(h, sha: oldSHA).isEmpty, "old PDF of a replaced paper is kept forever in .recently-deleted")
            #expect(try await h.engine.storage.orphans().folders.isEmpty)
            #expect(h.copies(ofSHA: oldSHA) == 0)
        }
    }

    /// Kept (recoverable) for the 最近删除 retention, then trashed by the launch purge; never
    /// listed as an orphan folder meanwhile.
    @Test func replacedPDFFollowsTheRecentlyDeletedRetention() async throws {
        try await withRIHarness { h in
            let (_, oldSHA) = try await Self.replaceOnce(h)
            let trash = RITrash()
            #expect(try await h.engine.storage.orphans().folders.isEmpty)
            #expect(try await h.engine.storage.stats().recentlyDeletedBytes > 0)

            h.clock.value = riStart.addingTimeInterval(29 * 86_400)
            _ = await Maintenance(engine: h.engine, trash: trash.function).onLaunch()
            #expect(Self.parked(h, sha: oldSHA).count == 1)
            #expect(trash.all.isEmpty)

            h.clock.value = riStart.addingTimeInterval(31 * 86_400)
            let report = await Maintenance(engine: h.engine, trash: trash.function).onLaunch()
            #expect(report.errors.isEmpty)
            #expect(Self.parked(h, sha: oldSHA).isEmpty)
            #expect(trash.all.count == 1)
            #expect(try await h.engine.storage.stats().recentlyDeletedBytes == 0)
        }
    }

    /// A parked PDF whose trash fails stays for the next run.
    @Test func parkedPDFThatCannotBeTrashedIsKept() async throws {
        try await withRIHarness { h in
            let (_, oldSHA) = try await Self.replaceOnce(h)
            _ = try await h.engine.purgeExpired(olderThan: 0, trash: { _ in false })
            #expect(Self.parked(h, sha: oldSHA).count == 1)
        }
    }
}

// MARK: - Findings 2 + 7: deleted during enrichment, then restored

@Suite(.serialized) struct RegressionRestoreResumeTests {
    /// Deleted while metadata was in flight, then restored: nothing resubmitted it, so it stayed
    /// unfiled in _Inbox without a ready/AI decision until the next launch.
    @Test func restoredMidPipelinePaperIsNeverFinished() async throws {
        let gate = RILatch()
        try await withRIHarness(RIConfig(fetcher: RIGatedFetcher(gate: gate))) { h in
            let summary = await h.intake.ingest([.file(try h.writeSource("Some_long_enough_title_here.pdf"))],
                                                options: ImportOptions(origin: .drop))
            let id = try #require(summary.added.first)
            await gate.waitForArrivals(1)                     // the lookup is in flight
            _ = try await h.engine.softDelete(paperID: id)
            gate.open()
            await h.enrich.waitUntilIdle()
            let deleted = try await h.paper(id)
            #expect(deleted.stage == .committed, "enrichment advanced a paper deleted meanwhile to \(deleted.stage)")
            #expect(deleted.folder.hasPrefix(".recently-deleted/"))

            _ = try await h.engine.restore(paperID: id)
            await h.engine.enrich.waitUntilIdle()
            let p = try await h.paper(id)
            #expect(p.stage == .ready, "restored paper stuck at stage \(p.stage) in \(p.folder)")
            #expect(p.folder.hasPrefix("Papers/") && !p.folder.hasPrefix("Papers/_Inbox/"))
            #expect(fm.fileExists(atPath: h.ctx.pdfURL(p).path))
        }
    }
}
