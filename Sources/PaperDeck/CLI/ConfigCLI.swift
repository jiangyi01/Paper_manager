import Foundation
import PaperDeckCore
import PaperDeckConfig

/// Read-only configuration tools (never spawn anything, never write any defaults domain):
/// `--config`, `--migrate-dry-run`, `--export-settings`, `--import-settings --dry-run`.
///
/// Values come from `--plist FILE` (a defaults export, e.g. `defaults export <domain> FILE`),
/// `--suite NAME` (a scratch suite), or — with neither — the app's own domain, read-only. Only the
/// persisted values count (never registered defaults), exactly like the launch-time migration.
/// `--db-exists yes|no` stands in for "a library index exists"; without it the app's own domain
/// checks whether the production database file exists (existence only, never opened), and a
/// `--plist` / `--suite` source assumes "no".
enum ConfigCLI {
    /// A domain to read and where it came from.
    struct Source {
        var domain: PersistedDomain
        var label: String
        var databaseExists: Bool
        var databaseAssumed: Bool
    }

    static func source(_ a: CLIArgs) -> Result<Source, CLIError> {
        let db = a.value("--db-exists").map { $0.lowercased() }
        if let db, db != "yes", db != "no" { return .failure(CLIError("--db-exists must be yes or no")) }
        if let path = a.value("--plist") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else { return .failure(CLIError("can't read \(url.path)")) }
            guard let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                return .failure(CLIError("\(url.path) is not a property-list dictionary"))
            }
            return .success(Source(domain: PersistedDomain(values), label: "plist:\(url.path)",
                                   databaseExists: db == "yes", databaseAssumed: db == nil))
        }
        if let suite = a.value("--suite") {
            return .success(Source(domain: PersistedDomain.suite(suite), label: "suite:\(suite)",
                                   databaseExists: db == "yes", databaseAssumed: db == nil))
        }
        let exists = db.map { $0 == "yes" }
            ?? FileManager.default.fileExists(atPath: AppPaths.production().database.path)
        return .success(Source(domain: PersistedDomain.app(), label: "app:\(BuildIdentity.current.bundleID)",
                               databaseExists: exists, databaseAssumed: false))
    }

    struct CLIError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: --config

    /// `--config [--plist FILE | --suite NAME] [--db-exists yes|no] [--json] [--card-prompt | --card-prompt-sha256]`:
    /// the resolved institution, field, stage, origin and date order, plus this build's identity;
    /// `--card-prompt` prints the reading-card system prompt this configuration sends,
    /// `--card-prompt-sha256` only its SHA-256 (hex).
    static func config(_ a: CLIArgs) -> Int32 {
        let s: Source
        switch source(a) {
        case .success(let v): s = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let snapshot = ConfigResolver.resolve(s.domain, databaseExists: s.databaseExists)
        let prompt = CardSchema.systemPrompt(for: snapshot.cardPromptProfile)
        if a.has("--card-prompt") {
            print(prompt, terminator: prompt.hasSuffix("\n") ? "" : "\n")
            return 0
        }
        let sha = FileOps.sha256(of: Data(prompt.utf8))
        if a.has("--card-prompt-sha256") {
            print(sha)
            return 0
        }
        let id = BuildIdentity.current
        let rows: [(String, Any)] = [
            ("source", s.label),
            ("origin", snapshot.origin.rawValue),
            ("originRecorded", s.domain.string(ConfigKeys.origin) != nil),
            ("migrationVersion", snapshot.migrationVersion.map(String.init) ?? "none"),
            ("org", snapshot.organization.id),
            ("orgName", snapshot.organization.name?.en ?? "—"),
            ("orgShortName", snapshot.organization.shortName ?? "—"),
            ("peopleDefault", snapshot.organization.peopleDefault.rawValue),
            ("field", snapshot.field.id),
            ("stage", snapshot.stage.rawValue),
            ("reader", snapshot.readerOverride == nil ? "composed" : "custom"),
            ("dateOrder", snapshot.mailDateOrder.rawValue),
            ("databaseExists", s.databaseAssumed ? "no (assumed)" : (s.databaseExists ? "yes" : "no")),
            ("bundle", id.bundleID),
            ("widget", id.widgetBundleID),
            ("keychain", id.keychainService),
            ("channel", id.channel.rawValue),
            ("signing", id.signingIdentityName ?? "unknown (not stamped)"),
            ("cardPromptSHA256", sha),
            ("cardPromptIsLegacy", snapshot.cardPromptProfile == .legacyCompBio),
        ]
        emit(rows, json: a.has("--json"))
        return 0
    }

    // MARK: --migrate-dry-run

    /// `--migrate-dry-run [--plist FILE | --suite NAME] [--db-exists yes|no] [--json] [--now ISO] [--out FILE]`:
    /// what the launch-time migration would write into that domain (nothing is written). `--out`
    /// writes the domain with the planned keys added to a NEW plist file (never a defaults
    /// domain) — the input for `--config --plist`.
    static func migrateDryRun(_ a: CLIArgs) -> Int32 {
        let s: Source
        switch source(a) {
        case .success(let v): s = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let now = a.date("--now") ?? Date()
        guard let plan = ConfigMigration.plan(s.domain, databaseExists: s.databaseExists, now: now) else {
            let origin = s.domain.string(ConfigKeys.origin) ?? "legacy (not recorded)"
            emit([("source", s.label), ("upToDate", true), ("origin", origin),
                  ("migrationVersion", s.domain.int(ConfigKeys.migrationVersion).map(String.init) ?? "none")],
                 json: a.has("--json"))
            if let out = a.value("--out") { return writeMigrated(s.domain.values, to: out) }
            return 0
        }
        let writes = plan.writes.keys.sorted()
        if a.has("--json") {
            var w: [String: Any] = [:]
            for key in writes { w[key] = plan.writes[key]?.plistValue }
            CLIRunner.line(["source": s.label, "upToDate": false, "origin": plan.origin.rawValue,
                            "fromVersion": plan.fromVersion.map(String.init) ?? "none", "toVersion": plan.toVersion,
                            "backup": plan.backup, "markers": plan.markers, "writes": w,
                            "databaseExists": s.databaseExists, "databaseAssumed": s.databaseAssumed])
        } else {
            print("source=\(s.label)")
            print("origin=\(plan.origin.rawValue)")
            print("fromVersion=\(plan.fromVersion.map(String.init) ?? "none")")
            print("toVersion=\(plan.toVersion)")
            print("backup=\(plan.backup ? "yes (settings-before-config-v1-<stamp>.plist)" : "no")")
            print("markers=\(plan.markers.isEmpty ? "none" : plan.markers.joined(separator: ", "))")
            for key in writes { print("write \(key)=\(plan.writes[key].map(describe) ?? "")") }
            print("unchanged=\(s.domain.values.count) existing key(s) are never rewritten")
        }
        if let out = a.value("--out") {
            var merged = s.domain.values
            for (key, value) in plan.writes { merged[key] = value.plistValue }
            return writeMigrated(merged, to: out)
        }
        return 0
    }

    private static func describe(_ v: PlistScalar) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    private static func writeMigrated(_ values: [String: Any], to path: String) -> Int32 {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return CLIRunner.fail("\(url.path) exists — choose a new file (nothing was written)")
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            return CLIRunner.fail("couldn't write \(url.path): \(error.localizedDescription)")
        }
        FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
        return 0
    }

    // MARK: --export-settings

    /// `--export-settings OUT.json [--plist FILE | --suite NAME] [--sections a,b,…] [--include-personal] [--home DIR]`:
    /// a `paperdeck.settings/1` file, byte-compatible with Settings ▸ General ▸ Export Settings…
    /// (never a password or app password: those live in the keychain, which is never read).
    /// `--home` (default: your home folder) is where paths are made portable from and where the
    /// cloud-folder root names are listed (`<home>/Library/CloudStorage`, names only).
    static func exportSettings(_ a: CLIArgs) -> Int32 {
        guard let out = a.positional else {
            return CLIRunner.fail("--export-settings OUT.json [--plist FILE | --suite NAME] [--sections \(SettingsSection.allCases.map(\.rawValue).joined(separator: ","))] [--include-personal] [--home DIR]")
        }
        let s: Source
        switch source(a) {
        case .success(let v): s = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let sections: Set<SettingsSection>
        switch parseSections(a.value("--sections")) {
        case .success(let v): sections = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let home = a.url("--home") ?? SharedPaths.realHome
        let roots = cloudRoots(home: home)
        let bundle = SettingsExporter.export(s.domain, sections: sections, includePersonal: a.has("--include-personal"),
                                             home: home, roots: roots, app: SettingsExportSheet.appVersion, now: Date())
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return CLIRunner.fail("\(url.path) exists — choose a new file (nothing was written)")
        }
        do {
            let data = try SettingsExportSheet.encode(bundle)
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            return CLIRunner.fail("couldn't write \(url.path): \(error.localizedDescription)")
        }
        let keys = bundle.sections.values.reduce(0) { $0 + ($1.objectValue?.count ?? 0) }
        CLIRunner.line(["ok": true, "out": url.path, "source": s.label, "format": bundle.format,
                        "sections": bundle.sections.keys.sorted(), "keys": keys])
        return 0
    }

    // MARK: --import-settings --dry-run

    /// `--import-settings IN.json --dry-run [--plist FILE | --suite NAME] [--sections …] [--keep-people-always]
    /// [--accept-reader] [--accept-instructions] [--accept-looser] [--home DIR] [--lang en|zh]`: what importing the file would
    /// change here, with the same rules as the app (never `agent.mode`, `mail.enabled` or
    /// `setup.completed`; a privacy or quota setting looser in the file than here keeps this Mac's
    /// value — one `keptStricter` line each — unless `--accept-looser`; a new person's "Always"
    /// arrives as "Ask"; IMAP accounts need their app password again). Nothing is written — a real
    /// import is GUI-only (Settings ▸ General ▸ Import Settings…).
    static func importSettings(_ a: CLIArgs) -> Int32 {
        guard let input = a.positional else {
            return CLIRunner.fail("--import-settings IN.json --dry-run [--plist FILE | --suite NAME] [--sections …] [--keep-people-always] [--accept-reader] [--accept-instructions] [--accept-looser] [--home DIR] [--lang en|zh]")
        }
        guard a.has("--dry-run") else {
            return CLIRunner.fail("a real import is GUI-only (Settings ▸ General ▸ Import Settings…); add --dry-run to preview it")
        }
        LangStore.shared.lang = UILang(rawValue: a.value("--lang") ?? "en") ?? .en
        let s: Source
        switch source(a) {
        case .success(let v): s = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let sections: Set<SettingsSection>
        switch parseSections(a.value("--sections")) {
        case .success(let v): sections = v
        case .failure(let e): return CLIRunner.fail(e.message)
        }
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return CLIRunner.fail(L.Transfer.readFailed(url.path)) }
        let bundle: SettingsBundle
        do {
            bundle = try SettingsImporter.decode(data)
        } catch SettingsImporter.Failure.unknownFormat(let f) {
            return CLIRunner.fail(L.Transfer.unknownFormat(f))
        } catch {
            return CLIRunner.fail(L.Transfer.malformed)
        }
        let home = a.url("--home") ?? SharedPaths.realHome
        let plan = SettingsImporter.plan(bundle, current: s.domain, sections: sections,
                                         keepPeopleAlways: a.has("--keep-people-always"),
                                         acceptReaderDescription: a.has("--accept-reader"),
                                         acceptLooser: looserAcceptance(a),
                                         acceptCriteriaInstructions: a.has("--accept-instructions"),
                                         home: home, roots: cloudRoots(home: home))
        CLIRunner.line(["file": url.path, "format": bundle.format, "app": bundle.app,
                        "exportedAt": ISO8601DateFormatter().string(from: bundle.exportedAt), "into": s.label])
        for c in plan.changes {
            CLIRunner.line(["change": c.key, "label": L.Transfer.keyLabel(c.key), "section": c.section.rawValue,
                            "old": c.old, "new": c.new, "confirm": c.needsConfirmation,
                            "written": plan.writes[c.key] != nil])
        }
        for l in plan.loosenings {
            CLIRunner.line(["keptStricter": !l.accepted, "id": l.id, "label": L.Transfer.looseningLabel(l),
                            "thisMac": L.Transfer.looseningValue(l, l.mine), "file": L.Transfer.looseningValue(l, l.theirs),
                            "accepted": l.accepted, "text": SettingsImportSheet.keptStricterLine(l)])
        }
        for w in plan.warnings { CLIRunner.line(["warning": L.Transfer.warning(w)]) }
        let never = SettingsImporter.neverWritten.sorted()
        let leaked = never.filter { plan.writes[$0] != nil }
        // A kept-stricter key is never among the writes (its looser value would be applied).
        let loosened = plan.keptStricter.filter { $0.id == $0.key && plan.writes[$0.key] != nil }.map(\.id)
        let ok = leaked.isEmpty && loosened.isEmpty
        CLIRunner.line(["writes": plan.writes.count, "keys": plan.writes.keys.sorted(), "neverWritten": never,
                        "keptStricter": plan.keptStricter.map(\.id), "acceptedLooser": plan.loosenings.filter(\.accepted).map(\.id),
                        "dryRun": true, "ok": ok])
        return ok ? 0 : 1
    }

    // MARK: Helpers

    /// `--accept-looser`: every looser privacy / quota value of the file; otherwise none (each is
    /// kept stricter). `--selftest settings`.
    static func looserAcceptance(_ a: CLIArgs) -> LooserAcceptance {
        a.has("--accept-looser") ? .all : .none
    }

    private static func parseSections(_ raw: String?) -> Result<Set<SettingsSection>, CLIError> {
        guard let raw, !raw.isEmpty else { return .success(Set(SettingsSection.allCases)) }
        var out: Set<SettingsSection> = []
        for name in raw.split(whereSeparator: { ",; ".contains($0) }).map(String.init) {
            guard let s = SettingsSection(rawValue: name) else {
                return .failure(CLIError("unknown section '\(name)' (\(SettingsSection.allCases.map(\.rawValue).joined(separator: ", ")))"))
            }
            out.insert(s)
        }
        return .success(out)
    }

    /// The cloud-folder roots under `<home>/Library/CloudStorage` (root names only — never inside
    /// them), as Settings ▸ General's export and import sheets see them.
    static func cloudRoots(home: URL) -> [CloudRoot] {
        let cloud = CloudRootLocator.cloudStorage(home: home)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        return CloudRootLocator.classify(names: names, cloudStorage: cloud)
    }

    /// `key=value` lines, or one sorted JSON object.
    private static func emit(_ rows: [(String, Any)], json: Bool) {
        if json {
            var o: [String: Any?] = [:]
            for (k, v) in rows { o[k] = v }
            CLIRunner.line(o)
        } else {
            for (k, v) in rows {
                if let b = v as? Bool { print("\(k)=\(b ? "yes" : "no")") } else { print("\(k)=\(v)") }
            }
        }
    }
}
