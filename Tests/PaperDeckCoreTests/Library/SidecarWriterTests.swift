import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct SidecarWriterTests {
    private static func tempLibrary() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths.rooted(at: root)
        try LibraryPaths.ensureLayout(paths: paths)
        return paths
    }

    private static func cleanup(_ paths: AppPaths) {
        try? FileManager.default.removeItem(at: paths.library.deletingLastPathComponent())
    }

    private static func sidecar(id: String = "0f8fad5b-d9cb-469f-a165-70867728950e", title: String = "Brain atlas",
                                notes: String = "", card: ReadingCard? = nil) -> CardSidecar {
        let paper = Paper(id: id, sha256: String(repeating: "a", count: 64), fileSize: 10, title: title,
                          authors: ["Li Wang"], year: 2024, venue: "Nature", folder: "Papers/x", pdfName: "x.pdf",
                          originalName: "x.pdf", tldr: card?.tldr, card: card, notes: notes,
                          addedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        return CardSidecar(paper: paper, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil)
    }

    @Test func coalescesSchedulesIntoOneWrite() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let folder = paths.papers.appendingPathComponent("2024_Wang_Brain-atlas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let writer = SidecarWriter(paths: paths, delay: .seconds(30))

        await writer.schedule(Self.sidecar(title: "v1"), folderURL: folder)
        await writer.schedule(Self.sidecar(title: "v2"), folderURL: folder)
        await writer.schedule(Self.sidecar(title: "v3", notes: "mine"), folderURL: folder)
        #expect(await writer.hasPendingWrites)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("card.json").path))
        await writer.flush()

        let stats = await writer.statistics
        #expect(stats.cardWrites == 1)
        #expect(stats.notesWrites == 1)
        #expect(!(await writer.hasPendingWrites))
        let written = try CardSidecar.decoded(from: Data(contentsOf: folder.appendingPathComponent("card.json")))
        #expect(written.meta.title == "v3")
        let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(notes.contains("# v3") && notes.contains("mine"))

        // Same bytes again → nothing rewritten.
        await writer.schedule(Self.sidecar(title: "v3", notes: "mine"), folderURL: folder)
        await writer.flush()
        #expect(await writer.statistics.cardWrites == 1)
        #expect(await writer.statistics.unchanged == 2)
    }

    @Test func timerWritesWithinTheWindow() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let folder = paths.inbox.appendingPathComponent("5f31a23c")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let writer = SidecarWriter(paths: paths, delay: .milliseconds(100))
        await writer.schedule(Self.sidecar(), folderURL: folder)
        await writer.schedule(Self.sidecar(id: "11111111-2222-3333-4444-555555555555"), folderURL: folder)

        let deadline = ContinuousClock.now + .seconds(30)                   // load-tolerant (ENV-1)
        while await writer.statistics.cardWrites < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await writer.statistics.cardWrites == 2)                     // distinct ids are not merged
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("card.json").path))
    }

    @Test func neverCreatesMissingFolders() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let gone = paths.papers.appendingPathComponent("2024_Renamed_Away")
        let writer = SidecarWriter(paths: paths, delay: .seconds(30))
        await writer.schedule(Self.sidecar(), folderURL: gone)
        await writer.flush()
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        let stats = await writer.statistics
        #expect(stats.skippedMissingFolder == 1)
        #expect(stats.cardWrites == 0 && stats.failures == 0)

        // Manifest: written at the root, skipped (not created) when the library root is gone.
        let manifest = LibraryManifest(libraryID: "lib", categories: [], skipDays: [], updatedAt: Date(timeIntervalSince1970: 0))
        await writer.writeManifest(manifest)
        await writer.flush()
        #expect(try SidecarWriter.readManifest(at: paths.libraryManifest) == manifest)

        let orphanWriter = SidecarWriter(manifestURL: paths.library.appendingPathComponent("nope/.paperdeck-library.json"),
                                         delay: .seconds(30))
        await orphanWriter.writeManifest(manifest)
        await orphanWriter.flush()
        #expect(await orphanWriter.statistics.skippedMissingFolder == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.library.appendingPathComponent("nope").path))
        #expect(try SidecarWriter.readManifest(at: paths.library.appendingPathComponent("absent.json")) == nil)
    }

    /// New bytes are staged in `.partial` and renamed in, so a folder that moves mid-write never
    /// keeps a temp file; nothing stays behind in `.partial` either.
    @Test func writesAreStagedOutsideThePaperFolder() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let fm = FileManager.default
        let folder = paths.papers.appendingPathComponent("2024_Wang_Brain-atlas")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let writer = SidecarWriter(paths: paths, delay: .seconds(30))
        for title in ["v1", "v2"] {
            await writer.schedule(Self.sidecar(title: title), folderURL: folder)
            await writer.flush()
            #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["card.json", "notes.md"])
            #expect(try fm.contentsOfDirectory(atPath: paths.partial.path).isEmpty)
        }
        #expect(try CardSidecar.decoded(from: Data(contentsOf: folder.appendingPathComponent("card.json"))).meta.title == "v2")

        // No staging folder (yet): Foundation's atomic write next to the target.
        try fm.removeItem(at: paths.partial)
        await writer.schedule(Self.sidecar(title: "v3"), folderURL: folder)
        await writer.flush()
        #expect(try CardSidecar.decoded(from: Data(contentsOf: folder.appendingPathComponent("card.json"))).meta.title == "v3")
        #expect(!fm.fileExists(atPath: paths.partial.path))
        let stats = await writer.statistics
        #expect(stats.cardWrites == 3 && stats.notesWrites == 3 && stats.failures == 0)
    }

    /// 永久删除 drops the paper's pending write: a folder that later takes over the path never
    /// receives the deleted paper's card.json. Other papers' writes stay queued.
    @Test func discardDropsOnlyThatPapersPendingCard() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let gone = paths.papers.appendingPathComponent("2024_Wang_Brain-atlas")
        let kept = paths.inbox.appendingPathComponent("5f31a23c")
        let keptID = "11111111-2222-3333-4444-555555555555"
        for dir in [gone, kept] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
        let writer = SidecarWriter(paths: paths, delay: .seconds(30))
        await writer.schedule(Self.sidecar(), folderURL: gone)
        await writer.schedule(Self.sidecar(id: keptID), folderURL: kept)
        await writer.discard(paperID: Self.sidecar().id)
        await writer.flush()
        #expect(!FileManager.default.fileExists(atPath: gone.appendingPathComponent("card.json").path))
        #expect(try CardSidecar.decoded(from: Data(contentsOf: kept.appendingPathComponent("card.json"))).id == keptID)
        #expect(await writer.statistics.cardWrites == 1)
        #expect(!(await writer.hasPendingWrites))
    }

    @Test func notesMarkdownLayout() {
        let md = SidecarWriter.notesMarkdown(for: Self.sidecar(title: "Molecular\ndynamics", notes: "  my note  ",
                                                               card: CardSidecarTests.sampleCard()))
        let lines = md.components(separatedBy: "\n")
        #expect(lines.first == "<!-- Generated by PaperDeck. Edit notes inside the app. -->")
        #expect(md.contains("# Molecular dynamics\n"))
        #expect(md.contains("Li Wang · Nature · 2024"))
        #expect(md.contains("## TL;DR\n\nA spatial atlas of the developing human neocortex."))
        #expect(md.contains("## Summary\n\nThe authors profile 38 samples.\nThey find new progenitor states."))
        #expect(md.contains("- Atlas of 4 million cells"))
        #expect(md.contains("- Batch effects possible (inferred)"))
        #expect(md.contains("- **oRG**: outer radial glia"))
        // Only allow-listed resource URLs are linked (as <https://…>); example.org is not on the list.
        #expect(md.contains("- CELLxGENE (GSE123)\n"))
        #expect(!md.contains("example.org"))
        #expect(md.hasSuffix("## My notes\n\nmy note\n"))
        let order = ["## TL;DR", "## Summary", "## Key contributions", "## Method", "## Results", "## Limitations",
                     "## Key terms", "## Data & code", "## My notes"].compactMap { md.range(of: $0)?.lowerBound }
        #expect(order.count == 9 && order == order.sorted())

        let bare = SidecarWriter.notesMarkdown(for: Self.sidecar(title: "Plain"))
        #expect(!bare.contains("## TL;DR") && !bare.contains("## Summary"))
        #expect(bare.hasSuffix("## My notes\n"))
    }

    @Test func scanFindsSidecarsAndReportsBadOnes() async throws {
        let paths = try Self.tempLibrary()
        defer { Self.cleanup(paths) }
        let fm = FileManager.default
        let good = paths.papers.appendingPathComponent("2024_Wang_Brain")
        let inboxed = paths.inbox.appendingPathComponent("5f31a23c")
        let broken = paths.papers.appendingPathComponent("2023_Broken")
        let bare = paths.papers.appendingPathComponent("2022_NoCard")
        for dir in [good, inboxed, broken, bare] { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        let writer = SidecarWriter(paths: paths, delay: .seconds(30))
        await writer.schedule(Self.sidecar(), folderURL: good)
        await writer.schedule(Self.sidecar(id: "11111111-2222-3333-4444-555555555555"), folderURL: inboxed)
        await writer.flush()
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("card.json"))
        try Data("%PDF-".utf8).write(to: bare.appendingPathComponent("x.pdf"))
        // Hidden in-flight copies are never mistaken for papers.
        try Data("{}".utf8).write(to: paths.partial.appendingPathComponent("card.json"))

        let scan = await SidecarWriter.scanSidecars(papersRoot: paths.papers)
        #expect(Set(scan.entries.map { $0.folder.lastPathComponent }) == ["2024_Wang_Brain", "5f31a23c"])
        #expect(scan.unreadable.map { $0.folder.lastPathComponent } == ["2023_Broken"])
        #expect(scan.missingSidecar.map(\.lastPathComponent) == ["2022_NoCard"])
        let inboxEntry = try #require(scan.entries.first { $0.folder.lastPathComponent == "5f31a23c" })
        #expect(LibraryPaths.relativePath(of: inboxEntry.folder, root: paths.library) == "Papers/_Inbox/5f31a23c")
        #expect(inboxEntry.sidecar.id == "11111111-2222-3333-4444-555555555555")

        let empty = await SidecarWriter.scanSidecars(papersRoot: paths.recentlyDeleted)
        #expect(empty.entries.isEmpty && empty.unreadable.isEmpty)
    }
}
