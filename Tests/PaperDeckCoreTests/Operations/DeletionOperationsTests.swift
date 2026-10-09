import Foundation
import Testing
@testable import PaperDeckCore

/// 最近删除: soft delete / restore move folders; purge hard-deletes after 30 days into a test "Trash".
@Suite struct DeletionOperationsTests {
    private typealias Kit = OpsTestKit

    /// A stand-in Trash: moves items into `<root>/Trash` and records them.
    private final class FakeTrash: @unchecked Sendable {
        let dir: URL
        private let lock = NSLock()
        private var items: [String] = []
        var fail = false
        init(root: URL) throws {
            dir = root.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var trashed: [String] { lock.lock(); defer { lock.unlock() }; return items }
        var function: @Sendable (URL) -> Bool {
            { [self] url in
                guard !fail else { return false }
                let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return false }
                lock.lock(); items.append(url.lastPathComponent); lock.unlock()
                return true
            }
        }
    }

    @Test func softDeleteAndRestoreMoveTheFolder() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Brain atlas", folder: "2024_Wang_Brain-atlas")
            // A leftover of the same name in the bin forces a unique name.
            try FileManager.default.createDirectory(at: env.paths.recentlyDeleted.appendingPathComponent("2024_Wang_Brain-atlas"),
                                                    withIntermediateDirectories: false)
            env.advance(5)
            let deleted = try await env.engine.softDelete(paperID: p.id)
            #expect(deleted.folder == ".recently-deleted/2024_Wang_Brain-atlas_2")
            #expect(deleted.deletedAt == Kit.start.addingTimeInterval(5))
            #expect(!deleted.flags.contains(.missing))
            #expect(!FileManager.default.fileExists(atPath: env.paths.papers.appendingPathComponent("2024_Wang_Brain-atlas").path))
            #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(deleted).path))
            #expect(try await env.db.livePapers().isEmpty)
            await env.engine.ctx.sidecars.flush()
            let card = try CardSidecar.decoded(from: Data(contentsOf: env.engine.ctx.folderURL(deleted)
                .appendingPathComponent(CardSidecar.fileName)))
            #expect(card.reading.deletedAt == deleted.deletedAt)

            let restored = try await env.engine.restore(paperID: p.id)
            #expect(restored.folder == "Papers/2024_Wang_Brain-atlas_2")
            #expect(restored.deletedAt == nil && restored.isLive)
            #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(restored).path))
            await #expect(throws: PaperOperationError.paperNotDeleted(p.id)) {
                try await env.engine.restore(paperID: p.id)
            }
        }
    }

    @Test func unfiledPaperRestoresIntoTheInbox() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, folder: "5f31a23c", stage: .committed, inInbox: true)
            let deleted = try await env.engine.softDelete(paperID: p.id)
            #expect(deleted.folder == ".recently-deleted/5f31a23c")
            let restored = try await env.engine.restore(paperID: p.id)
            #expect(restored.folder == "Papers/_Inbox/5f31a23c")
        }
    }

    @Test func restoreRefusesWhenTheSameWorkIsLiveAgain() async throws {
        try await Kit.run { env in
            let old = try await Kit.addPaper(env, title: "v1", doi: "10.1101/2024.01.16.575956")
            _ = try await env.engine.softDelete(paperID: old.id)
            let fresh = try await Kit.addPaper(env, title: "v2", doi: "10.1101/2024.01.16.575956")
            await #expect(throws: PaperOperationError.restoreConflict(paperID: fresh.id, title: "v2")) {
                try await env.engine.restore(paperID: old.id)
            }
            let still = try await Kit.paper(env, old.id)
            #expect(still.isDeleted && still.folder.hasPrefix(".recently-deleted/"))
            #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(still).path))
            #expect(PaperOperationError.restoreConflict(paperID: fresh.id, title: "v2").message(.zh) == "无法恢复：同一论文已在库中（v2）")
        }
    }

    @Test func purgeExpiredAfterThirtyDays() async throws {
        try await Kit.run { env in
            let trash = try FakeTrash(root: env.root)
            let p = try await Kit.addPaper(env, title: "Old")
            let keep = try await Kit.addPaper(env, title: "Kept")
            try env.engine.ctx.texts.save("full text of the old paper", id: p.id)
            try env.engine.ctx.thumbs.save(cardJPEG: Kit.jpeg(), id: p.id)
            _ = try await env.engine.softDelete(paperID: p.id)

            env.advance(29 * 86_400)
            #expect(try await env.engine.purgeExpired(trash: trash.function).isEmpty)
            env.advance(1 * 86_400)
            #expect(try await env.engine.purgeExpired(trash: trash.function) == [p.id])

            #expect(try await env.db.paper(id: p.id) == nil)
            #expect(trash.trashed == [(p.folder as NSString).lastPathComponent])
            #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.recentlyDeleted.path).isEmpty)
            #expect(!env.engine.ctx.texts.exists(id: p.id))
            #expect(env.engine.ctx.thumbs.existingCardURL(for: p.id) == nil)
            #expect(env.engine.ctx.thumbs.existingWidgetURL(for: p.id) == nil)
            #expect(try await env.db.paper(id: keep.id) != nil)
            // The sha no longer blocks a re-import.
            _ = try await env.db.insertPaper(Paper(sha256: p.sha256, fileSize: 1, title: "again", folder: "Papers/again",
                                                   pdfName: "again.pdf", originalName: "again.pdf"))
        }
    }

    @Test func purgeKeepsTheRowWhenTrashFails() async throws {
        try await Kit.run { env in
            let trash = try FakeTrash(root: env.root)
            trash.fail = true
            let p = try await Kit.addPaper(env)
            _ = try await env.engine.softDelete(paperID: p.id)
            env.advance(31 * 86_400)
            #expect(try await env.engine.purgeExpired(trash: trash.function).isEmpty)
            #expect(try await env.db.paper(id: p.id)?.isDeleted == true)
            await #expect(throws: PaperOperationError.trashFailed((try await Kit.paper(env, p.id).folder as NSString).lastPathComponent)) {
                try await env.engine.deleteNow(paperID: p.id, trash: trash.function)
            }
        }
    }

    @Test func deleteNowRemovesImmediately() async throws {
        try await Kit.run { env in
            let trash = try FakeTrash(root: env.root)
            let p = try await Kit.addPaper(env, folder: "2026_Now_Gone")
            try await env.engine.deleteNow(paperID: p.id, trash: trash.function)
            #expect(try await env.db.paper(id: p.id) == nil)
            #expect(trash.trashed == ["2026_Now_Gone"])
            await #expect(throws: PaperOperationError.paperNotFound(p.id)) {
                try await env.engine.deleteNow(paperID: p.id, trash: trash.function)
            }
        }
    }
}
