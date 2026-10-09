import Foundation

// 设置 ▸ 资料库与存储: statistics and orphan detection (§3.4 存储统计口径, §8, §9 M6).
// `du` and `totalFileAllocatedSize` count APFS clones at full size, so the only honest
// sharing figure is an estimate: Σ size of files whose `mayShareFileContent` is true.

package struct StorageStats: Sendable, Equatable {
    package struct LargePaper: Sendable, Equatable {
        package var id: String
        package var title: String
        package var bytes: Int64
    }

    package var paperCount: Int                 // live papers
    package var deletedCount: Int               // in 最近删除
    package var logicalBytes: Int64             // Σ on-disk size of live papers' PDFs
    /// 「可能与原文件共享（APFS 克隆，估算）」: Σ size where mayShareFileContent — an ESTIMATE.
    package var estimatedSharedBytes: Int64
    package var missingFiles: Int               // live papers whose PDF is not on disk
    package var thumbnailBytes: Int64           // card + widget thumbnails
    package var textCacheBytes: Int64
    package var databaseBytes: Int64            // library.sqlite + -wal (+ -shm)
    package var recentlyDeletedBytes: Int64
    package var largest: [LargePaper]           // top 5 by PDF size

    /// Everything PaperDeck stores besides the PDFs themselves.
    package var cacheBytes: Int64 { thumbnailBytes + textCacheBytes }
}

package struct StorageOrphans: Sendable, Equatable {
    package struct Folder: Sendable, Equatable {
        package var relativePath: String        // "Papers/…" / "Papers/_Inbox/…" / ".recently-deleted/…"
        package var hasCard: Bool
        package var pdfCount: Int
        package var bytes: Int64
    }

    /// Folders no DB row points at (card.json + PDF ones are adoptable by `Maintenance.reconcile()`).
    package var folders: [Folder]
    /// Live papers whose PDF is missing on disk (ids).
    package var missingFiles: [String]
    /// Cached text/thumbnail files of ids that are not in the DB.
    package var cacheFiles: [URL]

    package var isEmpty: Bool { folders.isEmpty && missingFiles.isEmpty && cacheFiles.isEmpty }
}

package struct StorageTools: Sendable {
    package static let largestCount = 5

    package let engine: Engine

    package init(engine: Engine) { self.engine = engine }

    package func stats() async throws -> StorageStats {
        let live = try await engine.db.livePapers()
        let deletedCount = try await engine.db.deletedPapers().count
        let files = live.map { (id: $0.id, title: $0.title, url: engine.ctx.pdfURL($0)) }
        let paths = engine.paths, texts = engine.ctx.texts, thumbs = engine.ctx.thumbs
        return await BlockingIO.run {
            var logical: Int64 = 0, shared: Int64 = 0, missing = 0
            var sizes: [StorageStats.LargePaper] = []
            for f in files {
                guard let size = FileOps.fileSize(f.url) else { missing += 1; continue }
                logical += size
                if FileOps.mayShareFileContent(f.url) == true { shared += size }
                sizes.append(.init(id: f.id, title: f.title, bytes: size))
            }
            let largest = sizes.sorted { ($0.bytes, $1.id) > ($1.bytes, $0.id) }.prefix(StorageTools.largestCount)
            let db = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
                sum + (FileOps.fileSize(URL(fileURLWithPath: paths.database.path + suffix)) ?? 0)
            }
            return StorageStats(paperCount: files.count, deletedCount: deletedCount, logicalBytes: logical,
                                estimatedSharedBytes: shared, missingFiles: missing, thumbnailBytes: thumbs.totalSize(),
                                textCacheBytes: texts.totalSize(), databaseBytes: db,
                                recentlyDeletedBytes: StorageTools.treeSize(paths.recentlyDeleted),
                                largest: Array(largest))
        }
    }

    /// Folders under Papers/ (incl. _Inbox) and .recently-deleted/ without a DB row, live
    /// rows whose PDF is missing, and cache files of unknown ids.
    package func orphans() async throws -> StorageOrphans {
        let all = try await engine.db.allPapers()
        let known = Set(all.map { StorageTools.folderKey($0.folder) })
        let ids = Set(all.map { $0.id.lowercased() })
        let live = all.filter(\.isLive).map { (id: $0.id, url: engine.ctx.pdfURL($0)) }
        let paths = engine.paths, texts = engine.ctx.texts, thumbs = engine.ctx.thumbs
        return await BlockingIO.run {
            var folders: [StorageOrphans.Folder] = []
            let inbox = paths.inbox
            let candidates = StorageTools.subfolders(paths.papers).filter { $0.lastPathComponent != inbox.lastPathComponent }
                + StorageTools.subfolders(inbox) + StorageTools.subfolders(paths.recentlyDeleted)
            for folder in candidates {
                let relative = OpsFiles.relative(folder, library: paths.library)
                guard !known.contains(StorageTools.folderKey(relative)) else { continue }
                folders.append(.init(relativePath: relative,
                                     hasCard: PaperOpsSupport.itemExists(folder.appendingPathComponent(CardSidecar.fileName)),
                                     pdfCount: SidecarRestore.pdfNames(in: folder).count, bytes: StorageTools.treeSize(folder)))
            }
            let missing = live.filter { !PaperOpsSupport.itemExists($0.url) }.map(\.id)
            var cache: [URL] = []
            for (dir, suffix) in [(texts.directory, "." + TextStore.fileExtension), (thumbs.cardDirectory, "@2x.jpg"),
                                  (thumbs.widgetDirectory, ".jpg")] {
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
                where name.hasSuffix(suffix) && !ids.contains(String(name.dropLast(suffix.count)).lowercased()) {
                    cache.append(dir.appendingPathComponent(name))
                }
            }
            return StorageOrphans(folders: folders, missingFiles: missing, cacheFiles: cache)
        }
    }

    /// 清理孤立文件: adopts folders with card.json + PDF (reconcile), deletes cache files of
    /// unknown ids and moves empty leftover folders (no PDF, no card.json) to the Trash.
    /// Folders that still hold a PDF are never touched. Returns what is left afterwards.
    @discardableResult
    package func cleanOrphans(trash: @escaping @Sendable (URL) -> Bool = { FileOps.trash($0) }) async throws -> StorageOrphans {
        _ = try await Maintenance(engine: engine, trash: trash).reconcile()
        let found = try await orphans()
        let library = engine.paths.library
        await BlockingIO.run {
            for url in found.cacheFiles { try? FileManager.default.removeItem(at: url) }
            for f in found.folders where !f.hasCard && f.pdfCount == 0 {
                _ = trash(LibraryPaths.folderURL(forRelative: f.relativePath, library: library))
            }
        }
        return try await orphans()
    }

    // MARK: Helpers (blocking)

    static func folderKey(_ relative: String) -> String {
        relative.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func subfolders(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Σ logical size of the regular files below `url` (0 when missing).
    static func treeSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}

extension Engine {
    /// 设置 ▸ 资料库与存储 statistics and orphan tools.
    package var storage: StorageTools { StorageTools(engine: self) }
}

/// Old PDFs parked by 「替换并保留清单」 (§5 查重 2), dated so they can be purged:
/// `.recently-deleted/.replaced/<stamp>_<paper folder>/<pdf>`, where the stamp
/// (`yyyyMMdd'T'HHmmss'Z'`, UTC) is when the file was parked. `Engine.purgeExpired` trashes
/// entries older than the 最近删除 retention. The folder is hidden, so orphan scans and
/// rebuilds from sidecars skip it; its bytes count towards `recentlyDeletedBytes`.
package enum ReplacedPDFs {
    package static let directoryName = ".replaced"

    package static func root(_ paths: AppPaths) -> URL {
        paths.recentlyDeleted.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates a fresh entry folder for a PDF of `paperFolder` parked at `date` (the bin and
    /// `.replaced` are created as needed; the library root never is). Blocking.
    static func makeEntry(in paths: AppPaths, paperFolder: String, at date: Date) throws -> URL {
        let root = root(paths)
        try FileOps.createFolder(paths.recentlyDeleted)
        try FileOps.createFolder(root)
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        let dir = root.appendingPathComponent(FileNamer.uniqueName(stamp(date) + "_" + paperFolder, existing: taken),
                                              isDirectory: true)
        try FileOps.createFolder(dir)
        return dir
    }

    /// Entries parked at or before `cutoff` (by their stamp; an entry without a readable
    /// stamp goes by its modification date). Blocking.
    static func expired(root: URL, cutoff: Date) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { item in
            let parked = parkedAt(item.lastPathComponent)
                ?? (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (parked ?? .distantFuture) <= cutoff
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `20260929T150000Z` for 2026-09-29 15:00:00 UTC.
    static func stamp(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The parking date encoded at the start of an entry name, nil if there is none.
    static func parkedAt(_ name: String) -> Date? {
        let b = Array(name.utf8.prefix(16))
        guard b.count == 16, b[8] == UInt8(ascii: "T"), b[15] == UInt8(ascii: "Z") else { return nil }
        func number(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                guard b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int(b[i] - UInt8(ascii: "0"))
            }
            return v
        }
        guard let y = number(0..<4), let mo = number(4..<6), let d = number(6..<8),
              let h = number(9..<11), let mi = number(11..<13), let s = number(13..<15) else { return nil }
        return utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}
