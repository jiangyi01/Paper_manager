import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

// T8 StarterPackTests, T9 LibraryIdentityTests and T10 LibraryInspectorTests (PORTABILITY_PLAN
// §5.4, §2.9). Temp-rooted engines only (OpsTestKit): nothing here touches the real library.

enum LibraryPortKit {
    typealias K = OpsTestKit

    static func flushed(_ env: K.Env) async { await env.engine.ctx.sidecars.flush() }

    static func manifest(_ library: URL) throws -> LibraryManifest? {
        try SidecarWriter.readManifest(at: library.appendingPathComponent(LibraryManifest.fileName))
    }

    static func manifestBytes(_ library: URL) -> Data? {
        try? Data(contentsOf: library.appendingPathComponent(LibraryManifest.fileName))
    }

    static func categoryNames(_ env: K.Env) async throws -> [String] {
        try await env.db.categories().map(\.name)
    }
}

@Suite(.serialized) struct StarterPackTests {
    typealias K = OpsTestKit
    static let pack = FieldPresets.csML.starterCategories

    @Test func aPristineLibraryGetsThePackAndTheFirstManifestHoldsIt() async throws {
        try await K.run { (env: K.Env) async throws in
            #expect(try await LibraryPortKit.categoryNames(env) == PaperCategory.starters.map(\.name))
            #expect(try await env.engine.applyStarterPackIfPristine(Self.pack))
            #expect(try await LibraryPortKit.categoryNames(env) == Self.pack.map(\.name))
            #expect(try await env.db.categories().allSatisfy { $0.origin == .starter && $0.acknowledged })
            await env.engine.start()
            await LibraryPortKit.flushed(env)
            let manifest = try #require(try LibraryPortKit.manifest(env.paths.library))
            #expect(manifest.categoryModels().map(\.name) == Self.pack.map(\.name))
            // Once applied (or with a manifest on disk), never again.
            #expect(try await env.engine.applyStarterPackIfPristine(FieldPresets.humanities.starterCategories) == false)
        }
    }

    @Test func todaysStartersOrAnEmptyPackChangeNothing() async throws {
        try await K.run { (env: K.Env) async throws in
            #expect(try await env.engine.applyStarterPackIfPristine(FieldPresets.lifeSciencesCompBio.starterCategories) == false)
            #expect(try await env.engine.applyStarterPackIfPristine([]) == false)
            #expect(try await LibraryPortKit.categoryNames(env) == PaperCategory.starters.map(\.name))
        }
    }

    @Test func onePaperLeavesTheLibraryAlone() async throws {
        try await K.run { (env: K.Env) async throws in
            try await K.addPaper(env, title: "A paper")
            #expect(try await env.engine.applyStarterPackIfPristine(Self.pack) == false)
            #expect(try await LibraryPortKit.categoryNames(env) == PaperCategory.starters.map(\.name))
        }
    }

    @Test func aDeletedPaperCountsToo() async throws {
        try await K.run { (env: K.Env) async throws in
            let p = try await K.addPaper(env, title: "Gone")
            _ = try await env.db.modifyPaper(pk: p.pk, now: env.clock.value) { $0.deletedAt = env.clock.value }
            #expect(try await env.engine.applyStarterPackIfPristine(Self.pack) == false)
        }
    }

    @Test func aRenamedStarterLeavesTheLibraryAlone() async throws {
        try await K.run { (env: K.Env) async throws in
            var first = try #require(try await env.db.categories().first)
            first.name = "My own name"
            try await env.db.updateCategory(first)
            #expect(try await env.engine.applyStarterPackIfPristine(Self.pack) == false)
            #expect(try await LibraryPortKit.categoryNames(env).first == "My own name")
        }
    }

    @Test func aManifestOnDiskLeavesTheLibraryAlone() async throws {
        try await K.run { (env: K.Env) async throws in
            await env.engine.ctx.writeManifest()
            await LibraryPortKit.flushed(env)
            #expect(try LibraryPortKit.manifest(env.paths.library) != nil)
            #expect(try await env.engine.applyStarterPackIfPristine(Self.pack) == false)
        }
    }

    @Test func addMissingRespectsTheCapAndNeverDeletes() async throws {
        try await K.run { (env: K.Env) async throws in
            let before = try await LibraryPortKit.categoryNames(env)
            // 7 starters + 7 CS: all added, nothing removed.
            #expect(try await env.engine.addMissingStarterCategories(Self.pack) == 7)
            let after = try await LibraryPortKit.categoryNames(env)
            #expect(after == before + Self.pack.map(\.name))
            // Names already there (case-insensitively) are not added again.
            #expect(try await env.engine.addMissingStarterCategories([StarterCategory(name: "computer VISION", description: "")]) == 0)
            // 14 + 6 = 20: physics fills the cap; humanities adds nothing.
            #expect(try await env.engine.addMissingStarterCategories(FieldPresets.physicsAstro.starterCategories) == 6)
            #expect(try await env.engine.addMissingStarterCategories(FieldPresets.humanities.starterCategories) == 0)
            #expect(try await env.db.categories().count == Taxonomy.autoCreateLimit)
            #expect(Array(try await LibraryPortKit.categoryNames(env).prefix(before.count)) == before)
        }
    }

    @Test func packsAreNormalized() {
        let messy = [StarterCategory(name: "  Alpha\nBeta ", description: "one\ntwo"), StarterCategory(name: "alpha beta", description: "dup"),
                     StarterCategory(name: " ", description: "empty")] + (1...30).map { StarterCategory(name: "C\($0)", description: "") }
        let clean = StarterPack.normalized(messy) ?? []
        #expect(clean.first == StarterCategory(name: "Alpha Beta", description: "one two"))
        #expect(clean.count == Taxonomy.autoCreateLimit)
        #expect(StarterPack.normalized([]) == nil)
    }
}

@Suite(.serialized) struct LibraryIdentityTests {
    typealias K = OpsTestKit

    /// A library folder with one paper (card.json + PDF) and its manifest, written by its own engine.
    static func makeLibrary(_ root: URL, title: String) async throws -> (libraryID: String, paperID: String) {
        let env = try await K.make(root: root)
        let p = try await K.addPaper(env, title: title)
        await env.engine.start()
        await LibraryPortKit.flushed(env)
        let id = try #require(try await env.db.kv(Engine.libraryIDKey))
        await env.engine.shutdown()
        await env.engine.db.close()
        return (id, p.id)
    }

    @Test func anIndexOpenedOnAnotherLibraryStopsBeforeTouchingIt() async throws {
        let rootA = try K.newRoot(), rootB = try K.newRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = try await Self.makeLibrary(rootA, title: "Paper of A")
        let b = try await Self.makeLibrary(rootB, title: "Paper of B")
        #expect(a.libraryID != b.libraryID)
        let pathsA = AppPaths.rooted(at: rootA), pathsB = AppPaths.rooted(at: rootB)
        let manifestBefore = try #require(LibraryPortKit.manifestBytes(pathsB.library))

        // A mail row in A's index: the replacement keeps the mail tables.
        do {
            let db = try await Database.open(url: pathsA.database, backupsDir: nil)
            _ = try await db.insertMailMessage(MailMessage(accountID: "acct", internetMessageID: "<keep@x>", fromAddress: "a@b.org",
                                                           senderKind: .alert, subject: "kept", receivedAt: K.start), items: [])
            await db.close()
        }

        // A's index (support) opened on B's folder (library).
        let mixed = AppPaths(library: pathsB.library, support: pathsA.support, caches: pathsA.caches, widget: pathsA.widget)
        let deps = Engine.Dependencies(loadSettings: { K.settings() }, now: { K.start }, calendar: K.calendar, fetcher: nil,
                                       claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(), sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: mixed, deps: deps)
        #expect(await engine.checkLibraryIdentity() == .mismatch(manifestID: b.libraryID, indexID: a.libraryID, indexedPapers: 1))
        let report = await engine.start()
        #expect(report.libraryMismatch == .mismatch(manifestID: b.libraryID, indexID: a.libraryID, indexedPapers: 1))
        #expect(report.reconcile == ReconcileReport() && report.rebuilt == nil && report.backup == nil)
        await engine.ctx.sidecars.flush()
        // B's manifest is byte-identical; A's paper was not flagged missing; nothing adopted.
        #expect(LibraryPortKit.manifestBytes(pathsB.library) == manifestBefore)
        let papers = try await engine.db.allPapers()
        #expect(papers.map(\.id) == [a.paperID] && !papers[0].flags.contains(.missing))

        // "Open this library": rebuilt from B's folder; B's id; the mail row kept; a backup first.
        let rebuilt = try await engine.replaceIndexFromLibraryFolder(starterPackIfEmpty: nil)
        #expect(rebuilt.papers == 1 && rebuilt.manifestFound)
        #expect(try await engine.db.allPapers().map(\.id) == [b.paperID])
        #expect(try await engine.db.kv(Engine.libraryIDKey) == b.libraryID)
        #expect(try await engine.db.mailMessage(internetMessageID: "<keep@x>") != nil)
        #expect(await engine.checkLibraryIdentity() == .match)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: pathsA.backups.path)) ?? []
        #expect(backups.contains { $0.hasPrefix(Maintenance.backupPrefix) })
        // start() may run now.
        let second = await engine.start()
        #expect(second.libraryMismatch == nil)
        await engine.shutdown()
        await engine.db.close()
        #expect(try LibraryPortKit.manifest(pathsB.library)?.libraryID == b.libraryID)
    }

    @Test func theSameLibraryMatchesAndStartsAsToday() async throws {
        try await K.run { (env: K.Env) async throws in
            try await K.addPaper(env, title: "Mine")
            #expect(await env.engine.checkLibraryIdentity() == .noManifest)        // before the first start
            let first = await env.engine.start()
            #expect(first.libraryMismatch == nil)
            await LibraryPortKit.flushed(env)
            #expect(await env.engine.checkLibraryIdentity() == .match)
        }
    }

    @Test func anEmptyIndexOrAnUnreadableManifestNeverBlocks() async throws {
        try await K.run { (env: K.Env) async throws in
            try Data(#"{"libraryID":"someone-else","format":1,"categories":[],"skipDays":[]}"#.utf8)
                .write(to: env.paths.libraryManifest)
            #expect(await env.engine.checkLibraryIdentity() == .emptyIndex)
            try Data("not json".utf8).write(to: env.paths.libraryManifest)
            try await K.addPaper(env, title: "Mine")
            #expect(await env.engine.checkLibraryIdentity() == .unreadableManifest)
            #expect(await env.engine.start().libraryMismatch == nil)
        }
    }

    @Test func startingNewEmptyGetsANewIDAndThePack() async throws {
        let rootA = try K.newRoot(), empty = try K.newRoot()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: empty) }
        let a = try await Self.makeLibrary(rootA, title: "Paper of A")
        let pathsA = AppPaths.rooted(at: rootA)
        let newLibrary = empty.appendingPathComponent("New Library", isDirectory: true)
        let paths = AppPaths(library: newLibrary, support: pathsA.support, caches: pathsA.caches, widget: pathsA.widget)
        let deps = Engine.Dependencies(loadSettings: { K.settings() }, now: { K.start }, calendar: K.calendar, fetcher: nil,
                                       claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(), sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: paths, deps: deps)
        // No manifest in the new folder: as today (no guard), and "Start new empty" replaces the index.
        #expect(await engine.checkLibraryIdentity() == .noManifest)
        let report = try await engine.replaceIndexFromLibraryFolder(starterPackIfEmpty: FieldPresets.mathStats.starterCategories)
        #expect(report.papers == 0 && !report.manifestFound)
        #expect(try await engine.db.allPapers().isEmpty)
        let newID = try #require(try await engine.db.kv(Engine.libraryIDKey))
        #expect(newID != a.libraryID)
        #expect(try await engine.db.categories().map(\.name) == FieldPresets.mathStats.starterCategories.map(\.name))
        await engine.ctx.sidecars.flush()
        #expect(try LibraryPortKit.manifest(newLibrary)?.libraryID == newID)
        // A's folder still names A (its id was never reused).
        #expect(try LibraryPortKit.manifest(pathsA.library)?.libraryID == a.libraryID)
        await engine.shutdown()
        await engine.db.close()
    }

    @Test func reindexingFillsMissingFullText() async throws {
        try await K.run { (env: K.Env) async throws in
            let cached = try await K.addPaper(env, title: "Cached text")
            try env.engine.ctx.texts.save("cortical radial glia searchable words", id: cached.id)
            let real = try await K.addPaper(env, title: "Real PDF")
            try MailSyncKit.realPDF(title: "Radial glia and the developing cortex").write(to: env.engine.ctx.pdfURL(real))
            let broken = try await K.addPaper(env, title: "Unreadable")            // tiny fake PDF bytes: no text
            #expect(Set(try await env.db.paperPKsWithoutFullText()) == [cached.pk, real.pk, broken.pk])
            #expect(await env.engine.reindexMissingFullText() == 2)
            #expect(try await env.db.paperPKsWithoutFullText() == [broken.pk])
            #expect(try env.engine.ctx.texts.load(id: real.id)?.contains("Radial glia") == true)
            #expect(await env.engine.reindexMissingFullText() == 0)
        }
    }
}

@Suite struct LibraryInspectorTests {
    static func folder(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-inspect-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func addCard(_ library: URL, _ name: String) throws {
        let dir = library.appendingPathComponent("Papers/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(CardSidecar.fileName))
    }

    @Test func kindsOfFolders() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pd-inspect-missing-\(UUID().uuidString)")
        #expect(await LibraryInspector.inspect(missing) == .missing)

        let empty = try Self.folder()
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        #expect(await LibraryInspector.inspect(empty) == .empty)

        let other = try Self.folder()
        defer { try? FileManager.default.removeItem(at: other) }
        for n in ["a.txt", "b.pdf", "Photos"] { try Data().write(to: other.appendingPathComponent(n)) }
        #expect(await LibraryInspector.inspect(other) == .otherContent(items: 3))

        let library = try Self.folder()
        defer { try? FileManager.default.removeItem(at: library) }
        try Self.addCard(library, "2024_A_One")
        try Self.addCard(library, "2025_B_Two")
        try Data(#"{"libraryID":"lib-123","format":1,"categories":[],"skipDays":[]}"#.utf8)
            .write(to: library.appendingPathComponent(LibraryManifest.fileName))
        #expect(await LibraryInspector.inspect(library) == .existingLibrary(libraryID: "lib-123", cardCount: 2))

        // The folder above a library ("Documents" holding "PaperDeck").
        let parent = try Self.folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("PaperDeck", isDirectory: true)
        try Self.addCard(child, "2024_A_One")
        try Data().write(to: parent.appendingPathComponent("notes.txt"))
        #expect(await LibraryInspector.inspect(parent) == .parentOfLibrary(child: child, cardCount: 1))

        // A file is not a folder.
        let file = other.appendingPathComponent("a.txt")
        #expect(await LibraryInspector.inspect(file) == .unreadable)
    }

    @Test func theScanIsBounded() async throws {
        let library = try Self.folder()
        defer { try? FileManager.default.removeItem(at: library) }
        for i in 0..<12 { try Self.addCard(library, "2024_P_\(i)") }
        #expect(await LibraryInspector.inspect(library, limit: 5) == .existingLibrary(libraryID: nil, cardCount: 5))
        #expect(await LibraryInspector.inspect(library) == .existingLibrary(libraryID: nil, cardCount: 12))
    }
}
