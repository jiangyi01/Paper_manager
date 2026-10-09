import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct StorageToolsTests {
    private typealias Kit = OpsTestKit
    private static var fm: FileManager { FileManager.default }
    /// A small real paper (read-only fixture); the test degrades gracefully without it.
    private static let fixture = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/PaperDeck-dev/fixtures/2026.04.06.716850.full.pdf")

    /// Clones the fixture into the library like a copy-mode import (APFS clone), inserts the row.
    private static func addClonedFixture(_ env: OpsTestKit.Env) async throws -> Paper? {
        guard fm.fileExists(atPath: fixture.path) else { return nil }
        let name = "2026_Real_Fixture"
        let dir = env.paths.papers.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let pdf = dir.appendingPathComponent(name + ".pdf")
        try fm.copyItem(at: fixture, to: pdf)
        FileOps.makeOwnerWritable(pdf)
        let size = try #require(FileOps.fileSize(pdf))
        return try await env.db.insertPaper(Paper(sha256: try FileOps.sha256(of: pdf), fileSize: size, title: "Real fixture",
                                                  folder: "Papers/" + name, pdfName: name + ".pdf",
                                                  originalName: fixture.lastPathComponent, stage: .ready))
    }

    @Test func statsCountSizesAndSharedEstimate() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "Tiny A")
            let b = try await Kit.addPaper(env, title: "Tiny B")
            let gone = try await Kit.addPaper(env, title: "Tiny gone")
            _ = try await env.engine.softDelete(paperID: gone.id)
            let real = try await Self.addClonedFixture(env)
            try env.engine.ctx.texts.save(String(repeating: "text ", count: 2000), id: a.id)
            try env.engine.ctx.thumbs.save(cardJPEG: Kit.jpeg(), id: a.id)

            let stats = try await env.engine.storage.stats()
            let live = [a, b] + (real.map { [$0] } ?? [])
            let urls = live.map { env.engine.ctx.pdfURL($0) }
            #expect(stats.paperCount == live.count && stats.deletedCount == 1 && stats.missingFiles == 0)
            #expect(stats.logicalBytes == urls.reduce(0) { $0 + (FileOps.fileSize($1) ?? 0) })
            let shared = urls.filter { FileOps.mayShareFileContent($0) == true }.reduce(Int64(0)) { $0 + (FileOps.fileSize($1) ?? 0) }
            #expect(stats.estimatedSharedBytes == shared)
            if let real {
                #expect(stats.largest.first?.id == real.id && stats.largest.first?.bytes == real.fileSize)
                // Same-volume copy = APFS clone → counted in the shared estimate (§9 M6 acceptance).
                #expect(FileOps.mayShareFileContent(env.engine.ctx.pdfURL(real)) == true)
                #expect(stats.estimatedSharedBytes >= real.fileSize)
            }
            #expect(stats.largest.count == live.count)
            #expect(stats.recentlyDeletedBytes >= gone.fileSize)
            #expect(stats.textCacheBytes > 0 && stats.thumbnailBytes > 0 && stats.cacheBytes == stats.textCacheBytes + stats.thumbnailBytes)
            #expect(stats.databaseBytes > 0)

            try Self.fm.removeItem(at: urls[1])
            #expect(try await env.engine.storage.stats().missingFiles == 1)
        }
    }

    @Test func orphansAreDetectedAndCleaned() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Present")
            let lost = try await Kit.addPaper(env, title: "Lost")
            try Self.fm.removeItem(at: env.engine.ctx.pdfURL(lost))
            let stray = env.paths.papers.appendingPathComponent("Stray empty folder")
            try Self.fm.createDirectory(at: stray, withIntermediateDirectories: false)
            let loose = env.paths.inbox.appendingPathComponent("loose")
            try Self.fm.createDirectory(at: loose, withIntermediateDirectories: false)
            try Kit.pdfBytes("loose").write(to: loose.appendingPathComponent("loose.pdf"))
            let unknownID = UUID().uuidString.lowercased()
            try env.engine.ctx.texts.save("orphan text", id: unknownID)
            try env.engine.ctx.texts.save("kept text", id: p.id)

            let found = try await env.engine.storage.orphans()
            #expect(found.folders.map(\.relativePath).sorted() == ["Papers/Stray empty folder", "Papers/_Inbox/loose"])
            #expect(found.folders.first { $0.relativePath == "Papers/_Inbox/loose" }?.pdfCount == 1)
            #expect(found.missingFiles == [lost.id])
            #expect(found.cacheFiles == [env.engine.ctx.texts.url(for: unknownID)])

            let trashDir = env.root.appendingPathComponent("Trash", isDirectory: true)
            try Self.fm.createDirectory(at: trashDir, withIntermediateDirectories: false)
            let left = try await env.engine.storage.cleanOrphans(trash: { url in
                (try? FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))) != nil
            })
            #expect(left.folders.map(\.relativePath) == ["Papers/_Inbox/loose"])       // PDFs are never removed
            #expect(left.cacheFiles.isEmpty && left.missingFiles == [lost.id])
            #expect(Self.fm.fileExists(atPath: trashDir.appendingPathComponent("Stray empty folder").path))
            #expect(env.engine.ctx.texts.exists(id: p.id) && !env.engine.ctx.texts.exists(id: unknownID))
        }
    }
}
