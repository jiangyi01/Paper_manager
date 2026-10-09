import Foundation

/// Whether the index (database) belongs to the library folder it was opened on.
package enum LibraryIdentityCheck: Sendable, Equatable {
    case match, noManifest, unreadableManifest, emptyIndex
    /// The folder's manifest names another library than the one the index holds papers of.
    case mismatch(manifestID: String, indexID: String?, indexedPapers: Int)
}

/// What a folder the user picked contains (Settings ▸ Library ▸ Change…, onboarding).
package enum LibraryFolderKind: Sendable, Equatable {
    case missing, unreadable, empty, otherContent(items: Int)
    case existingLibrary(libraryID: String?, cardCount: Int)
    case parentOfLibrary(child: URL, cardCount: Int)
}

/// Bounded, read-only inspection of a picked folder (off the main actor). Reads directory
/// listings and the library manifest only — never a card's contents — and stops after `limit`
/// entries.
package enum LibraryInspector {
    package static func inspect(_ folder: URL, limit: Int = 5_000) async -> LibraryFolderKind {
        await BlockingIO.run { inspectBlocking(folder, limit: limit) }
    }

    static func inspectBlocking(_ folder: URL, limit: Int) -> LibraryFolderKind {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue, fm.isReadableFile(atPath: folder.path),
              let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return .unreadable }
        if let kind = library(at: folder, limit: limit) { return kind }
        let visible = items.filter { !$0.hasPrefix(".") }
        if visible.isEmpty { return .empty }
        // One level down: the user picked the folder that holds the library ("Documents").
        var scanned = 0
        for name in visible.sorted() {
            scanned += 1
            if scanned > limit { break }
            let child = folder.appendingPathComponent(name, isDirectory: true)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDir), childIsDir.boolValue else { continue }
            if case .existingLibrary(_, let cards)? = library(at: child, limit: limit) {
                return .parentOfLibrary(child: child, cardCount: cards)
            }
        }
        return .otherContent(items: visible.count)
    }

    /// `folder` as a PaperDeck library: a manifest (its id, when readable) or a `Papers/` folder
    /// holding paper folders with a card.json. Nil when it is neither.
    static func library(at folder: URL, limit: Int) -> LibraryFolderKind? {
        let manifestURL = folder.appendingPathComponent(LibraryManifest.fileName)
        let hasManifest = FileManager.default.fileExists(atPath: manifestURL.path)
        let cards = cardCount(papers: folder.appendingPathComponent("Papers", isDirectory: true), limit: limit)
        guard hasManifest || cards > 0 else { return nil }
        let id = hasManifest ? (try? SidecarWriter.readManifest(at: manifestURL))?.libraryID : nil
        return .existingLibrary(libraryID: id, cardCount: cards)
    }

    /// Paper folders with a card.json under `Papers/` and `Papers/_Inbox/` (bounded).
    static func cardCount(papers: URL, limit: Int) -> Int {
        let fm = FileManager.default
        var count = 0, scanned = 0
        for dir in [papers, papers.appendingPathComponent("_Inbox", isDirectory: true)] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !name.hasPrefix(".") && name != "_Inbox" {
                scanned += 1
                if scanned > limit { return count }
                if fm.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent(CardSidecar.fileName).path) {
                    count += 1
                }
            }
        }
        return count
    }
}

/// A Core port whose body lands in a later slice (W0 contracts only).
package enum CorePortError: Error, Equatable {
    case notImplemented(String)
}

extension Engine {
    /// Compares the folder's manifest id with the index's library id (`kv library.id`). Only a
    /// readable manifest naming another library while the index holds papers is a mismatch —
    /// `start()` then stops before any maintenance, manifest write, agent or mail work, so the
    /// other library's manifest and folders are left exactly as they are. No manifest, an
    /// unreadable one or an empty index behave as before (logged, never blocking).
    package func checkLibraryIdentity() async -> LibraryIdentityCheck {
        let manifestURL = paths.libraryManifest
        let manifest: LibraryManifest
        do {
            guard let m = try await BlockingIO.run({ try SidecarWriter.readManifest(at: manifestURL) }) else {
                return .noManifest
            }
            manifest = m
        } catch {
            Log.storage.notice("library identity: the manifest is unreadable — not checked")
            return .unreadableManifest
        }
        let papers = (try? await db.allPapers().count) ?? 0
        guard papers > 0 else { return .emptyIndex }
        let indexID = try? await db.kv(Self.libraryIDKey)
        if let indexID, indexID.lowercased() == manifest.libraryID.lowercased() { return .match }
        Log.storage.error("library identity: the index (\(papers, privacy: .public) papers) belongs to another library than the folder's manifest")
        return .mismatch(manifestID: manifest.libraryID, indexID: indexID, indexedPapers: papers)
    }

    /// The kv key of the index's library id (written with the manifest).
    package static let libraryIDKey = "library.id"

    /// "Open existing" / "Start new empty": `maintenance.backupNow()`, then
    /// `rebuildFromSidecars(replacingExisting: true)` — the index is rebuilt from the folder's
    /// cards and manifest (only DB rows are dropped; files stay; the mail tables are kept). A
    /// folder without a manifest gets a new library id, so two folders never share one; with no
    /// manifest and no cards either, the categories become `starterPackIfEmpty` (when given).
    package func replaceIndexFromLibraryFolder(starterPackIfEmpty: [StarterCategory]?) async throws -> RebuildReport {
        _ = try await maintenance.backupNow()
        let manifestURL = paths.libraryManifest
        let hasManifest = await BlockingIO.run { FileManager.default.fileExists(atPath: manifestURL.path) }
        if !hasManifest {
            try await db.setKV(Self.libraryIDKey, UUID().uuidString.lowercased())
        }
        var report = try await rebuildFromSidecars(replacingExisting: true)
        if !report.manifestFound, report.papers + report.deleted == 0,
           let pack = StarterPack.normalized(starterPackIfEmpty ?? []), !pack.isEmpty {
            report.categories = try await replaceCategories(with: pack)
            await ctx.writeManifest()
        }
        Log.storage.notice("library replaced from its folder: \(report.papers) live, \(report.deleted) deleted, manifest=\(report.manifestFound)")
        return report
    }

    /// How many live papers search finds by title only (no full-text row) although their PDF has
    /// text — a library rebuilt on a new Mac before 「重建全文索引」 / "Re-index Full Text". Locked,
    /// scanned, unreadable and missing papers are not counted (re-indexing cannot help them), so
    /// the count reaches 0 once `reindexMissingFullText` ran. One COUNT query; no PDF is opened.
    package func papersMissingFullTextCount() async throws -> Int {
        try await db.countPapersMissingFullText()
    }

    /// Re-extracts full text (PDFKit, no quota) for live papers without a full-text row: the
    /// text cache when present, else the PDF itself (and the cache is written). Returns how many
    /// papers were indexed. Papers whose PDF is missing or has no text are skipped.
    package func reindexMissingFullText() async -> Int {
        guard let pks = try? await db.paperPKsWithoutFullText(), !pks.isEmpty else { return 0 }
        let texts = ctx.texts
        let extractor = PDFExtractor()
        var indexed = 0
        for pk in pks {
            guard !Task.isCancelled, let paper = try? await db.paper(pk: pk), paper.isLive else { continue }
            let id = paper.id
            var text = await BlockingIO.run { (try? texts.load(id: id)) ?? nil }
            if text?.isEmpty ?? true {
                let url = ctx.pdfURL(paper)
                guard await BlockingIO.run({ FileManager.default.fileExists(atPath: url.path) }),
                      let extracted = try? await extractor.extract(url: url, fileName: paper.pdfName) else { continue }
                text = extracted.fullText
                if let fresh = text, !fresh.isEmpty {
                    await BlockingIO.run { try? texts.save(fresh, id: id) }
                }
            }
            guard let body = text, !body.isEmpty else { continue }
            do {
                try await db.indexFullText(pk: pk, text: body)
                indexed += 1
            } catch {
                Log.storage.error("re-index full text failed for \(id, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        Log.storage.notice("re-index full text: \(indexed, privacy: .public) of \(pks.count, privacy: .public) papers")
        return indexed
    }
}
