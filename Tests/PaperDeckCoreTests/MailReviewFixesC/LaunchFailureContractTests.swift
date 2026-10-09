import Foundation
import Testing
@testable import PaperDeckCore

/// What the app's launch alert (review integrity-4, `LibraryOpenFailure` in the app target) relies
/// on from `Engine.open`: a database newer than this build arrives as `DatabaseError.newerSchema`
/// and leaves the file untouched; a failed pre-migration backup is a database error (never a
/// `FileOpsError`) and leaves the file at its old version; only an unusable library folder is a
/// `FileOpsError` — the one case where the app may offer another folder (~/Papers).
/// The app-side mapping itself is checked by `PaperDeck --selftest app-rules`.
@Suite struct LaunchFailureContractTests {
    private static func scratchRoot(_ tag: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-launch-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func deps() -> Engine.Dependencies {
        let es = EngineSettings(plan: PlanSettings(), lang: .en, agentMode: .off, autoReadNewPapers: false,
                                metadataLookup: false)
        return Engine.Dependencies(loadSettings: { es }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
                                   codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                   sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                   loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()])
    }

    /// Opens and, if it unexpectedly succeeds, closes the engine; returns the error.
    private static func openError(_ paths: AppPaths) async -> (any Error)? {
        do {
            let engine = try await Engine.open(paths: paths, deps: deps())
            await engine.shutdown()
            await engine.db.close()
            return nil
        } catch {
            return error
        }
    }

    private static func backupFiles(_ paths: AppPaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? [])
            .filter { $0.hasPrefix("pre-migration-") }
    }

    @Test func newerSchemaReachesTheAppUnwrappedAndUntouched() async throws {
        let root = try Self.scratchRoot("newer")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths.rooted(at: root)
        try LibraryPaths.ensureLayout(paths: paths)
        let newer = Migrations.latestVersion + 1
        do {
            let raw = try SQLiteConnection(path: paths.database.path)
            try raw.exec("CREATE TABLE future_thing(x TEXT); INSERT INTO future_thing VALUES('kept')")
            try raw.exec("PRAGMA user_version = \(newer)")
            raw.close()
        }

        let error = await Self.openError(paths)
        #expect(error as? DatabaseError == .newerSchema(found: newer, supported: Migrations.latestVersion))
        #expect(!(error is FileOpsError))

        let raw = try SQLiteConnection(path: paths.database.path)
        defer { raw.close() }
        #expect(try raw.userVersion() == newer)
        #expect(try raw.scalarString("SELECT x FROM future_thing") == "kept")
        #expect(Self.backupFiles(paths).isEmpty)
    }

    @Test func failedPreMigrationBackupIsADatabaseErrorAndKeepsTheOldFile() async throws {
        let root = try Self.scratchRoot("backup")
        let paths = AppPaths.rooted(at: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.backups.path)
            try? FileManager.default.removeItem(at: root)
        }
        try LibraryPaths.ensureLayout(paths: paths)
        do {
            let raw = try SQLiteConnection(path: paths.database.path)
            try Migrations.prepare(raw, backupsDir: nil, targetVersion: 1)
            try raw.exec("INSERT INTO kv(key, value) VALUES('canary', 'v1')")
            raw.close()
        }
        // VACUUM INTO can't create the copy (as with a full disk): the migration must not run.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.backups.path)

        let error = await Self.openError(paths)
        #expect(error != nil)
        #expect(!(error is FileOpsError))
        if case .newerSchema? = error as? DatabaseError { Issue.record("a failed backup is not a newer schema") }

        let raw = try SQLiteConnection(path: paths.database.path)
        defer { raw.close() }
        #expect(try raw.userVersion() == 1)
        #expect(try raw.scalarString("SELECT value FROM kv WHERE key = 'canary'") == "v1")
        #expect(try raw.scalarInt("SELECT count(*) FROM sqlite_master WHERE name LIKE 'mail_%'") == 0)
    }

    @Test func unusableLibraryFolderIsAFileOpsError() async throws {
        let root = try Self.scratchRoot("folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths.rooted(at: root)
        // A file where the library folder should be (a volume that isn't a folder any more).
        try Data("not a folder".utf8).write(to: paths.library)

        let error = await Self.openError(paths)
        #expect(error is FileOpsError)
        #expect(!FileManager.default.fileExists(atPath: paths.database.path))
    }

    /// The app tells a full disk apart from other database failures through these.
    @Test func diskFullIsRecognisedFromCocoaAndPOSIXErrors() {
        #expect(FileOps.classify(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(FileOps.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskFull)
        #expect(FileOps.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permissionDenied)
        #expect(SQLiteError(code: 13, message: "database or disk is full").code == 13)
    }
}
