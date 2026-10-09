import Foundation
import Observation
import PaperDeckCore
import PaperDeckConfig

/// The app's view of the configuration layer (institution, research field, stage, reader, date
/// order): the resolved `snapshot` plus setters that write their keys (never registered) and
/// reload. `reload()` mirrors the organization and field into `LangStore`, which the
/// organization- and field-dependent strings read.
///
/// Setters write exactly their own key (`ConfigKeys`); nothing here is ever passed to
/// `register(defaults:)`, so an absent key keeps meaning "not chosen" (resolved by origin).
@Observable
final class ConfigStore {
    @ObservationIgnored private let d: UserDefaults
    @ObservationIgnored private let legacyFallback: Bool
    /// True while `reload()` copies the resolved values into the properties (no writes then).
    @ObservationIgnored private var reloading = false

    /// The import panels' example / start folder when `import.lastFolder` is absent.
    static let defaultImportFolder = "~/Downloads"

    private(set) var snapshot: ConfigSnapshot

    var fieldID: String { didSet { write(fieldID, ConfigKeys.profileField) } }
    var stage: CareerStage { didSet { write(stage.rawValue, ConfigKeys.profileStage) } }
    /// A user-written reader description (`profile.readerDescription`); nil = composed from field and stage.
    var readerOverride: String? { didSet { write(readerOverride, ConfigKeys.profileReaderDescription) } }
    var organizationID: String { didSet { write(organizationID, ConfigKeys.orgPreset) } }
    /// `org.custom` (JSON, never with texts).
    var customOrganization: OrganizationProfile? {
        didSet {
            guard !reloading else { return }
            if var custom = customOrganization {
                custom.texts = [:]
                if let data = try? JSONEncoder().encode(custom) {
                    d.set(String(decoding: data, as: UTF8.self), forKey: ConfigKeys.orgCustom)
                }
            } else {
                d.removeObject(forKey: ConfigKeys.orgCustom)
            }
            reload()
        }
    }
    var dateOrder: SlashDateOrder { didSet { write(dateOrder.rawValue, ConfigKeys.mailDateOrder) } }
    var importLastFolder: String? { didSet { write(importLastFolder, ConfigKeys.importLastFolder) } }
    /// `mail.cloudRoot`: the cloud root (directory name) of the last folder / Power Automate
    /// account saved — the Power Automate form ranks it after the organization's hint.
    var cloudRoot: String? { didSet { write(cloudRoot, ConfigKeys.mailCloudRoot) } }
    /// `onboarding.legacy` (developer rollback to the old Setup Assistant).
    var legacyOnboardingFlag: Bool { d.bool(forKey: ConfigKeys.onboardingLegacy) }

    /// How this Mac's configuration began (legacy installs see no Getting Started card).
    var origin: ConfigOrigin { snapshot.origin }
    /// The configured institution / research field (resolved: unknown ids fall back).
    var organization: OrganizationProfile { snapshot.organization }
    var field: FieldPreset { snapshot.field }

    /// Reads only; writes nothing.
    init(defaults: UserDefaults, legacyFallback: Bool = true) {
        d = defaults
        self.legacyFallback = legacyFallback
        // The assignments after the last non-optional one run the @Observable didSets (write +
        // reload): `reloading` keeps the init from writing anything back.
        reloading = true
        defer { reloading = false }
        let s = ConfigResolver.load(defaults, legacyFallback: legacyFallback)
        snapshot = s
        fieldID = s.field.id
        stage = s.stage
        readerOverride = s.readerOverride
        organizationID = s.organization.id
        customOrganization = Self.custom(defaults, resolved: s.organization)
        dateOrder = s.mailDateOrder
        importLastFolder = defaults.string(forKey: ConfigKeys.importLastFolder)
        cloudRoot = defaults.string(forKey: ConfigKeys.mailCloudRoot)
        mirror()
    }

    /// Re-resolves the snapshot (another writer, or after a setter), copies it into the
    /// properties without writing anything, and mirrors it into LangStore.
    func reload() {
        let s = ConfigResolver.load(d, legacyFallback: legacyFallback)
        reloading = true
        defer { reloading = false }
        if s != snapshot { snapshot = s }
        if fieldID != s.field.id { fieldID = s.field.id }
        if stage != s.stage { stage = s.stage }
        if readerOverride != s.readerOverride { readerOverride = s.readerOverride }
        if organizationID != s.organization.id { organizationID = s.organization.id }
        let custom = Self.custom(d, resolved: s.organization)
        if customOrganization != custom { customOrganization = custom }
        if dateOrder != s.mailDateOrder { dateOrder = s.mailDateOrder }
        let folder = d.string(forKey: ConfigKeys.importLastFolder)
        if importLastFolder != folder { importLastFolder = folder }
        let root = d.string(forKey: ConfigKeys.mailCloudRoot)
        if cloudRoot != root { cloudRoot = root }
        mirror()
    }

    /// The reading-card reader composed from the field and stage alone (Settings ▸ Profile's
    /// placeholder and Reset).
    var composedReader: String {
        snapshot.field.cardProfile(stage: snapshot.stage, readerOverride: nil).reader
    }

    // MARK: Private

    private func write(_ value: String?, _ key: String) {
        guard !reloading else { return }
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        reload()
    }

    /// The stored `org.custom` (only meaningful while the resolved organization is custom).
    private static func custom(_ d: UserDefaults, resolved: OrganizationProfile) -> OrganizationProfile? {
        if resolved.id == "custom" { return resolved }
        guard let s = d.string(forKey: ConfigKeys.orgCustom), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OrganizationProfile.self, from: data)
    }

    private func mirror() {
        let lang = LangStore.shared
        if lang.org != snapshot.organization { lang.org = snapshot.organization }
        if lang.field != snapshot.field { lang.field = snapshot.field }
        let folder = importLastFolder.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultImportFolder
        if lang.importFolderExample != folder { lang.importFolderExample = folder }
    }
}
