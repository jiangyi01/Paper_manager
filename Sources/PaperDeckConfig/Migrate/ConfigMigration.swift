import Foundation
import os
import PaperDeckCore
import PaperDeckShared

/// A property-list value a migration writes.
package enum PlistScalar: Sendable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool)

    /// The value as `UserDefaults.set(_:forKey:)` takes it.
    package var plistValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        }
    }
}

/// What one migration run would do (pure; `--migrate-dry-run` prints it).
package struct MigrationPlan: Sendable, Equatable {
    package var fromVersion: Int?
    package var toVersion: Int
    package var origin: ConfigOrigin
    /// Only keys that are absent today (an existing key is never rewritten).
    package var writes: [String: PlistScalar]
    /// Back up the domain first (legacy installs).
    package var backup: Bool
    package var markers: [String]

    package init(fromVersion: Int?, toVersion: Int, origin: ConfigOrigin, writes: [String: PlistScalar],
                 backup: Bool, markers: [String]) {
        self.fromVersion = fromVersion; self.toVersion = toVersion; self.origin = origin; self.writes = writes
        self.backup = backup; self.markers = markers
    }
}

/// Runs once per install, first thing at launch (before `SettingsStore` registers defaults):
/// records whether this install is legacy or fresh and pins today's behavior for legacy ones
/// (PORTABILITY_PLAN §2.6). It only ever adds keys that are absent — never `agent.*`,
/// `library.path`, the `mail.*` JSON, `language`, `setup.completed` or `reminder.*` — and backs the
/// domain up first on a legacy install. The CLI, `--selftest` and `--render` never run it.
package enum ConfigMigration {
    package static let currentVersion = 1
    /// Backup file name prefix in `<support>/Backups` (Maintenance prunes only `library-*.sqlite`).
    package static let backupPrefix = "settings-before-config-v1-"

    /// The writes for `p`, or nil when the domain is already at `currentVersion`.
    /// - Legacy (`LegacyInstallDetector`, or a recorded `config.origin = legacy`): the legacy
    ///   institution preset, life sciences & comp-bio, month-first dates and today's import folder
    ///   — each only when absent — plus the markers note; backup first.
    /// - Fresh: `mail.dateOrder = auto` (when absent).
    /// Both: `config.origin` (when absent), `config.migratedAt`, `config.migrationVersion`.
    package static func plan(_ p: PersistedDomain, databaseExists: Bool, now: Date) -> MigrationPlan? {
        let from = p.int(ConfigKeys.migrationVersion)
        if let from, from >= currentVersion { return nil }
        let recorded = p.string(ConfigKeys.origin).flatMap(ConfigOrigin.init(rawValue:))
        let origin = recorded ?? (LegacyInstallDetector.isLegacy(p, databaseExists: databaseExists) ? .legacy : .fresh)
        var writes: [String: PlistScalar] = [:]
        func ifAbsent(_ key: String, _ value: PlistScalar) { if !p.has(key) { writes[key] = value } }
        ifAbsent(ConfigKeys.origin, .string(origin.rawValue))
        var markers: [String] = []
        switch origin {
        case .legacy:
            markers = LegacyInstallDetector.markers(p)
            ifAbsent(ConfigKeys.orgPreset, .string(LegacyInstall.organizationID))
            ifAbsent(ConfigKeys.profileField, .string(LegacyInstall.fieldID))
            ifAbsent(ConfigKeys.mailDateOrder, .string(LegacyInstall.dateOrder.rawValue))
            ifAbsent(ConfigKeys.importLastFolder, .string(LegacyInstall.importFolder))
            ifAbsent(ConfigKeys.migrationNote, .string(markers.isEmpty ? "markers: none" : "markers: " + markers.joined(separator: ", ")))
        case .fresh:
            ifAbsent(ConfigKeys.mailDateOrder, .string(SlashDateOrder.auto.rawValue))
        }
        writes[ConfigKeys.migratedAt] = .double(now.timeIntervalSince1970)
        writes[ConfigKeys.migrationVersion] = .int(currentVersion)
        return MigrationPlan(fromVersion: from, toVersion: currentVersion, origin: origin, writes: writes,
                             backup: origin == .legacy, markers: markers)
    }

    /// Applies `plan` to `domain` (through `defaults`): the backup plist first on a legacy install
    /// (no writes when it can't be written — the next launch tries again, and meanwhile the
    /// resolver's legacy fallback reads today's configuration), then every write, the version
    /// marker last. Returns the install's origin (the recorded one when there is nothing to do;
    /// a domain migrated by nobody but read here counts as legacy, as the app treats it).
    @discardableResult
    package static func runIfNeeded(defaults: UserDefaults = .standard,
                                    domain: String = BuildIdentity.current.bundleID,
                                    databaseURL: URL = AppPaths.production().database,
                                    backupsDirectory: URL = AppPaths.production().backups,
                                    now: Date = Date()) -> ConfigOrigin {
        let values = defaults.persistentDomain(forName: domain) ?? [:]
        let p = PersistedDomain(values)
        let dbExists = FileManager.default.fileExists(atPath: databaseURL.path)
        guard let plan = plan(p, databaseExists: dbExists, now: now) else {
            return p.string(ConfigKeys.origin).flatMap(ConfigOrigin.init(rawValue:)) ?? .legacy
        }
        if plan.backup {
            do {
                _ = try writeBackup(values, to: backupsDirectory, now: now)
            } catch {
                log.error("config migration: settings backup failed (\(String(describing: type(of: error)), privacy: .public)) — not migrated this launch")
                return plan.origin
            }
        }
        for (key, value) in plan.writes where key != ConfigKeys.migrationVersion {
            defaults.set(value.plistValue, forKey: key)
        }
        if let version = plan.writes[ConfigKeys.migrationVersion] {
            defaults.set(version.plistValue, forKey: ConfigKeys.migrationVersion)
        }
        log.notice("config migration: v\(plan.toVersion, privacy: .public) origin=\(plan.origin.rawValue, privacy: .public) keys=\(plan.writes.count, privacy: .public)")
        return plan.origin
    }

    /// `<dir>/settings-before-config-v1-<UTC stamp>.plist` (XML, `_2`… on a clash). Returns its URL.
    @discardableResult
    package static func writeBackup(_ values: [String: Any], to dir: URL, now: Date) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = backupPrefix + Migrations.fileStamp(now)
        var url = dir.appendingPathComponent(base + ".plist")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_\(n).plist")
            n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    private static let log = Logger(subsystem: Log.subsystem, category: "config")
}
