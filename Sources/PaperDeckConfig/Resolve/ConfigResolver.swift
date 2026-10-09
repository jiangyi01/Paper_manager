import Foundation
import os
import PaperDeckCore

/// Resolves the stored configuration keys into a `ConfigSnapshot` (PORTABILITY_PLAN §2.5). Absent
/// keys resolve by origin — fresh → `generic` / `general`; legacy → the legacy institution preset
/// and life sciences & comp-bio — and unknown ids fall back the same way (an unknown institution
/// preset → `generic`, logged), never crash. Read-only: nothing is written here.
package enum ConfigResolver {
    private static let log = Logger(subsystem: Log.subsystem, category: "config")

    /// The snapshot of a persisted domain. Without `config.origin` (the migration hasn't run), the
    /// install is classified like the migration would (`LegacyInstallDetector`).
    package static func resolve(_ p: PersistedDomain, databaseExists: Bool) -> ConfigSnapshot {
        let origin = p.string(ConfigKeys.origin).flatMap(ConfigOrigin.init(rawValue:))
            ?? (LegacyInstallDetector.isLegacy(p, databaseExists: databaseExists) ? .legacy : .fresh)
        return snapshot(p, origin: origin)
    }

    /// The snapshot from a live defaults object (new keys via `object(forKey:)` — they are never
    /// registered). Without `config.origin`, `legacyFallback` decides: true (the app, the engine's
    /// card profile) treats the install as legacy — today's configuration — false as fresh.
    package static func load(_ d: UserDefaults, legacyFallback: Bool) -> ConfigSnapshot {
        var values: [String: Any] = [:]
        for key in ConfigKeys.all { if let v = d.object(forKey: key) { values[key] = v } }
        let p = PersistedDomain(values)
        let origin = p.string(ConfigKeys.origin).flatMap(ConfigOrigin.init(rawValue:)) ?? (legacyFallback ? .legacy : .fresh)
        return snapshot(p, origin: origin)
    }

    /// The reading-card reader the engine uses for the next card (`Engine.Dependencies.loadCardProfile`).
    package static func cardPromptProfile(_ d: UserDefaults = .standard) -> CardPromptProfile {
        load(d, legacyFallback: true).cardPromptProfile
    }

    // MARK: - Rules

    static func snapshot(_ p: PersistedDomain, origin: ConfigOrigin) -> ConfigSnapshot {
        ConfigSnapshot(
            migrationVersion: p.int(ConfigKeys.migrationVersion),
            origin: origin,
            field: field(p.string(ConfigKeys.profileField), origin: origin),
            stage: p.string(ConfigKeys.profileStage).flatMap(CareerStage.init(rawValue:)) ?? .phd,
            readerOverride: p.string(ConfigKeys.profileReaderDescription).flatMap(CardPromptProfile.sanitize),
            organization: organization(p.string(ConfigKeys.orgPreset), custom: p.string(ConfigKeys.orgCustom), origin: origin),
            mailDateOrder: p.string(ConfigKeys.mailDateOrder).flatMap(SlashDateOrder.init(rawValue:)) ?? .mdy)
    }

    /// The field for a stored id: known → it; absent or unknown → `general` (fresh) or
    /// life sciences & comp-bio (legacy).
    package static func field(_ id: String?, origin: ConfigOrigin) -> FieldPreset {
        if let preset = FieldPresets.preset(id: id) { return preset }
        if let id { log.notice("config: unknown field preset \(id, privacy: .public) — using the default") }
        return origin == .fresh ? FieldPresets.general : FieldPresets.lifeSciencesCompBio
    }

    /// The organization for a stored preset id: a built-in → it; `custom` → the stored JSON,
    /// re-sanitized (caps, https link, no texts — `OrganizationPresets.custom`; unreadable →
    /// `generic`); absent → by origin; unknown → `generic`, logged.
    package static func organization(_ id: String?, custom: String?, origin: ConfigOrigin) -> OrganizationProfile {
        guard let id else { return origin == .fresh ? OrganizationPresets.generic : OrganizationPresets.legacyInstallPreset }
        if let preset = OrganizationPresets.preset(id: id) { return preset }
        if id == "custom" {
            if let custom, let decoded = decodeCustom(custom) { return decoded }
            log.error("config: the custom organization could not be read — using the generic wording")
            return OrganizationPresets.generic
        }
        log.notice("config: unknown organization preset \(id, privacy: .public) — using the generic wording")
        return OrganizationPresets.generic
    }

    /// `org.custom` JSON → a sanitized custom organization (never carries texts).
    package static func decodeCustom(_ json: String) -> OrganizationProfile? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(OrganizationProfile.self, from: data) else { return nil }
        return OrganizationPresets.custom(name: raw.name?.en ?? "", shortName: raw.shortName,
                                          approvedAITools: raw.approvedAITools, policyURL: raw.policyURL,
                                          peopleDefault: raw.peopleDefault, oneDriveRootHint: raw.mail.oneDriveRootHint)
    }

    /// `org.custom` JSON for a custom organization (what `ConfigStore` and an import write).
    package static func encodeCustom(_ org: OrganizationProfile) -> String {
        var clean = org
        clean.texts = [:]
        clean.id = "custom"
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(clean)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
