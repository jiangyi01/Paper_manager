import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T1 (PORTABILITY_PLAN §5.4): the one-time configuration migration. Every domain here is a
// scratch suite (`ScratchDefaults`) or a synthetic dictionary; the app's own domain, the real
// database and the real backups folder are never touched.

/// A scratch domain seeded with a fixture, plus a temp folder for the database flag and backups.
struct MigrationScratch {
    let scratch: ScratchDefaults
    let dir: URL
    var database: URL { dir.appendingPathComponent("library.sqlite") }
    var backups: URL { dir.appendingPathComponent("Backups", isDirectory: true) }

    init(_ tag: String, fixture: String? = nil, values: [String: Any] = [:], databaseExists: Bool = false) throws {
        scratch = fixture.map { try? GoldenFixtures.seeded($0, tag: tag) }.flatMap { $0 } ?? ScratchDefaults(tag)
        for (k, v) in values { scratch.defaults.set(v, forKey: k) }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-tests-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if databaseExists { try Data("SQLite format 3\u{0}".utf8).write(to: database) }
    }

    var persisted: [String: Any] { scratch.defaults.persistentDomain(forName: scratch.name) ?? [:] }

    @discardableResult
    func run(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> ConfigOrigin {
        ConfigMigration.runIfNeeded(defaults: scratch.defaults, domain: scratch.name, databaseURL: database,
                                    backupsDirectory: backups, now: now)
    }

    func backupFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(ConfigMigration.backupPrefix) }
    }

    func drop() {
        scratch.drop()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Plist values compared by their serialized bytes (byte-identical pre-existing keys).
func plistBytes(_ v: Any) -> Data? {
    try? PropertyListSerialization.data(fromPropertyList: ["v": v], format: .binary, options: 0)
}

@Suite(.serialized) struct ConfigMigrationTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let legacyWrites: Set<String> = [
        ConfigKeys.migrationVersion, ConfigKeys.origin, ConfigKeys.migratedAt, ConfigKeys.migrationNote,
        ConfigKeys.orgPreset, ConfigKeys.profileField, ConfigKeys.mailDateOrder, ConfigKeys.importLastFolder,
    ]

    // (a) The current user's shape: exactly the allowed keys, everything else byte-identical, a backup.
    @Test func theLegacyFixtureGetsExactlyTheAllowedKeysAndABackup() throws {
        let fixture = try GoldenFixtures.plist("legacy-washu-domain")
        let plan = try #require(ConfigMigration.plan(PersistedDomain(fixture), databaseExists: true, now: Self.now))
        #expect(plan.origin == .legacy && plan.backup && plan.fromVersion == nil && plan.toVersion == 1)
        #expect(Set(plan.writes.keys) == Self.legacyWrites)
        #expect(plan.writes[ConfigKeys.orgPreset] == .string("washu"))
        #expect(plan.writes[ConfigKeys.profileField] == .string("lifeSciencesCompBio"))
        #expect(plan.writes[ConfigKeys.mailDateOrder] == .string("mdy"))
        #expect(plan.writes[ConfigKeys.importLastFolder] == .string("~/Desktop/Paper_reading"))
        #expect(plan.writes[ConfigKeys.origin] == .string("legacy"))
        #expect(plan.writes[ConfigKeys.migrationVersion] == .int(1))

        let s = try MigrationScratch("migration-legacy", fixture: "legacy-washu-domain", databaseExists: true)
        defer { s.drop() }
        let before = s.persisted
        #expect(s.run(now: Self.now) == .legacy)
        let after = s.persisted
        let added = Set(after.keys).subtracting(before.keys)
        #expect(added == Self.legacyWrites)
        for (key, value) in before {
            #expect(plistBytes(after[key] as Any) == plistBytes(value), "\(key) changed")
        }
        let backups = s.backupFiles()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        let restored = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any])
        #expect(Set(restored.keys) == Set(before.keys))
        #expect(after[ConfigKeys.migrationVersion] as? Int == 1)
        #expect(after[ConfigKeys.origin] as? String == "legacy")
        // The resolver now reads today's configuration from the keys themselves.
        let snapshot = ConfigResolver.load(s.scratch.defaults, legacyFallback: false)
        #expect(snapshot.organization == OrganizationPresets.washu && snapshot.field == FieldPresets.lifeSciencesCompBio)
        #expect(snapshot.stage == .phd && snapshot.mailDateOrder == .mdy && snapshot.origin == .legacy)
        #expect(snapshot.cardPromptProfile == .legacyCompBio)
        #expect(CardSchema.systemPrompt(for: ConfigResolver.cardPromptProfile(s.scratch.defaults)) == CardSchema.systemPrompt)
    }

    // (b) An empty domain with a database is an existing install.
    @Test func anEmptyDomainWithADatabaseIsLegacy() throws {
        let plan = try #require(ConfigMigration.plan(PersistedDomain([:]), databaseExists: true, now: Self.now))
        #expect(plan.origin == .legacy && plan.backup)
        #expect(plan.writes[ConfigKeys.orgPreset] == .string("washu"))
        #expect(plan.markers.isEmpty)
        #expect(plan.writes[ConfigKeys.migrationNote] == .string("markers: none"))
    }

    // (c) A fresh Mac: origin fresh, dates follow the region, nothing else.
    @Test func anEmptyDomainWithoutADatabaseIsFresh() throws {
        let plan = try #require(ConfigMigration.plan(PersistedDomain([:]), databaseExists: false, now: Self.now))
        #expect(plan.origin == .fresh && !plan.backup)
        #expect(Set(plan.writes.keys) == [ConfigKeys.migrationVersion, ConfigKeys.origin, ConfigKeys.migratedAt,
                                          ConfigKeys.mailDateOrder])
        #expect(plan.writes[ConfigKeys.mailDateOrder] == .string("auto"))
        #expect(plan.writes[ConfigKeys.migratedAt] == .double(Self.now.timeIntervalSince1970))

        let s = try MigrationScratch("migration-fresh")
        defer { s.drop() }
        #expect(s.run(now: Self.now) == .fresh)
        #expect(Set(s.persisted.keys) == Set(plan.writes.keys))
        #expect(s.backupFiles().isEmpty)
        let snapshot = ConfigResolver.load(s.scratch.defaults, legacyFallback: true)
        #expect(snapshot.organization == OrganizationPresets.generic && snapshot.field == FieldPresets.general)
        #expect(snapshot.mailDateOrder == .auto && snapshot.origin == .fresh)
    }

    // (d) Idempotent: a second run changes nothing and writes no second backup.
    @Test func runningTwiceChangesNothing() throws {
        let s = try MigrationScratch("migration-twice", fixture: "legacy-washu-domain", databaseExists: true)
        defer { s.drop() }
        s.run(now: Self.now)
        let once = s.persisted
        #expect(s.run(now: Self.now.addingTimeInterval(3600)) == .legacy)
        let twice = s.persisted
        #expect(Set(once.keys) == Set(twice.keys))
        for (k, v) in once { #expect(plistBytes(twice[k] as Any) == plistBytes(v), "\(k)") }
        #expect(s.backupFiles().count == 1)
        #expect(ConfigMigration.plan(PersistedDomain(twice), databaseExists: true, now: Self.now) == nil)
    }

    // (e) Registered defaults are not user data: a domain with only registered values is fresh.
    @Test func registeredOnlyDefaultsCountAsFresh() throws {
        let s = try MigrationScratch("migration-registered")
        defer { s.drop() }
        s.scratch.defaults.register(defaults: ["setup.completed": false, "library.path": "/Users/example/Documents/PaperDeck"])
        #expect(s.scratch.defaults.object(forKey: "setup.completed") != nil)
        #expect(s.run(now: Self.now) == .fresh)
        #expect(s.persisted[ConfigKeys.origin] as? String == "fresh")
    }

    // (f) A `--dev` build writes only agent.mode = off: still a fresh install.
    @Test func aDevBuildsAgentModeOffAloneIsFresh() throws {
        #expect(!LegacyInstallDetector.isLegacy(PersistedDomain(["agent.mode": "off"]), databaseExists: false))
        #expect(LegacyInstallDetector.isLegacy(PersistedDomain(["agent.mode": "claude"]), databaseExists: false))
        for key in LegacyInstallDetector.userKeys {
            #expect(LegacyInstallDetector.isLegacy(PersistedDomain([key: "x"]), databaseExists: false), "\(key)")
        }
        let s = try MigrationScratch("migration-dev", values: ["agent.mode": "off"])
        defer { s.drop() }
        #expect(s.run(now: Self.now) == .fresh)
        #expect(s.persisted["agent.mode"] as? String == "off")
    }

    // (g) An explicit choice is never overwritten.
    @Test func anExplicitOrganizationIsNeverOverwritten() throws {
        let s = try MigrationScratch("migration-explicit", fixture: "legacy-washu-domain",
                                     values: [ConfigKeys.orgPreset: "generic", ConfigKeys.profileField: "csML",
                                              ConfigKeys.mailDateOrder: "dmy"],
                                     databaseExists: true)
        defer { s.drop() }
        s.run(now: Self.now)
        #expect(s.persisted[ConfigKeys.orgPreset] as? String == "generic")
        #expect(s.persisted[ConfigKeys.profileField] as? String == "csML")
        #expect(s.persisted[ConfigKeys.mailDateOrder] as? String == "dmy")
        let snapshot = ConfigResolver.load(s.scratch.defaults, legacyFallback: true)
        #expect(snapshot.organization == OrganizationPresets.generic && snapshot.field == FieldPresets.csML)
    }

    // (h) The legacy fixture's markers (diagnostics only; never values).
    @Test func theLegacyFixtureListsItsMarkers() throws {
        let markers = LegacyInstallDetector.markers(PersistedDomain(try GoldenFixtures.plist("legacy-washu-domain")))
        #expect(markers == ["mail.accounts.folderPath", "mail.accounts.displayName", "mail.senders.domain"])
        #expect(!markers.joined().contains("/") && !markers.joined().contains("@"))
        #expect(LegacyInstallDetector.markers(PersistedDomain([:])).isEmpty)
    }

    @Test func aFailedBackupMigratesNothing() throws {
        let s = try MigrationScratch("migration-nobackup", fixture: "legacy-washu-domain", databaseExists: true)
        defer { s.drop() }
        // A file where the Backups folder should be: the backup can't be written.
        try Data("x".utf8).write(to: s.backups)
        let before = s.persisted
        #expect(s.run(now: Self.now) == .legacy)
        #expect(Set(s.persisted.keys) == Set(before.keys))
        // The resolver's legacy fallback still reads today's configuration.
        #expect(ConfigResolver.load(s.scratch.defaults, legacyFallback: true).cardPromptProfile == .legacyCompBio)
    }

    @Test func plistScalarsAreWhatUserDefaultsTakes() {
        #expect(PlistScalar.string("a").plistValue as? String == "a")
        #expect(PlistScalar.int(1).plistValue as? Int == 1)
        #expect(PlistScalar.double(1.5).plistValue as? Double == 1.5)
        #expect(PlistScalar.bool(true).plistValue as? Bool == true)
    }
}
