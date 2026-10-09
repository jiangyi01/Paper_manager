import Foundation
import Observation
import PaperDeckCore
import PaperDeckConfig

/// The onboarding and Help Center state on this Mac (`onboarding.*`, `guide.*`, read-only
/// `transfer.*`; machine-local, never exported). `defaults == nil` keeps everything in memory
/// (self-tests and renders that never pass a suite).
@Observable
final class GuideStore {
    @ObservationIgnored private let d: UserDefaults?
    /// True while `reload()` copies stored values in (nothing is written back).
    @ObservationIgnored private var loading = false

    /// First use of each activity (`guide.activity`, seconds since 1970).
    private(set) var activity: [GuideActivityKind: Date]
    var checklistDismissed: Bool { didSet { store(checklistDismissed, ConfigKeys.guideChecklistDismissed) } }
    /// Optional Getting Started items the user skipped.
    var skipped: Set<String> { didSet { store(skipped.sorted(), ConfigKeys.guideSkipped) } }
    /// Ticked manual steps (`GuideEvaluator.manualKey`).
    var manualDone: Set<String> { didSet { store(manualDone.sorted(), ConfigKeys.guideManualDone) } }
    /// `onboarding.aiDecision` (claude / codex / none).
    var aiDecision: String? { didSet { write(aiDecision, ConfigKeys.onboardingAIDecision) } }
    /// `onboarding.mailDecision` (configured / dragOnly / skipped).
    var mailDecision: String? { didSet { write(mailDecision, ConfigKeys.onboardingMailDecision) } }
    private(set) var onboardingVersion: Int?
    private(set) var completedAt: Date?
    /// `transfer.*` (written by the settings export / import sheets).
    private(set) var lastExportedAt: Date?
    private(set) var importedAt: Date?
    /// The stored profile ids (nil: never chosen — `profileSet`).
    private(set) var storedFieldID: String?
    private(set) var storedOrganizationID: String?
    /// `mail.cloudRoot`: the cloud root the mail sheet used last (ranks the suggestion).
    private(set) var lastCloudRoot: String?
    /// Settings ▸ Library ▸ Change… is waiting for a restart (`library.pendingAction`).
    private(set) var libraryPendingAction: LibraryPendingAction?

    init(defaults: UserDefaults?) {
        d = defaults
        activity = [:]
        checklistDismissed = false
        skipped = []
        manualDone = []
        // `aiDecision` / `mailDecision` start nil. Never assign them here: once every non-optional
        // property is set the object is initialized, and an @Observable property's assignment
        // then runs its didSet — which would remove the stored decisions on every launch.
        reload()
    }

    /// Re-reads every key (another window or sheet wrote one).
    func reload() {
        guard let d else { return }
        loading = true
        defer { loading = false }
        var a: [GuideActivityKind: Date] = [:]
        for (key, value) in (d.dictionary(forKey: ConfigKeys.guideActivity) ?? [:]) {
            if let kind = GuideActivityKind(rawValue: key), let secs = (value as? NSNumber)?.doubleValue {
                a[kind] = Date(timeIntervalSince1970: secs)
            }
        }
        if a != activity { activity = a }
        let dismissed = d.bool(forKey: ConfigKeys.guideChecklistDismissed)
        if dismissed != checklistDismissed { checklistDismissed = dismissed }
        let sk = Set(d.stringArray(forKey: ConfigKeys.guideSkipped) ?? [])
        if sk != skipped { skipped = sk }
        let md = Set(d.stringArray(forKey: ConfigKeys.guideManualDone) ?? [])
        if md != manualDone { manualDone = md }
        let ai = d.string(forKey: ConfigKeys.onboardingAIDecision)
        if ai != aiDecision { aiDecision = ai }
        let mail = d.string(forKey: ConfigKeys.onboardingMailDecision)
        if mail != mailDecision { mailDecision = mail }
        onboardingVersion = (d.object(forKey: ConfigKeys.onboardingVersion) as? NSNumber)?.intValue
        completedAt = Self.date(d, ConfigKeys.onboardingCompletedAt)
        lastExportedAt = Self.date(d, ConfigKeys.transferLastExportedAt)
        importedAt = Self.date(d, ConfigKeys.transferImportedAt)
        storedFieldID = d.string(forKey: ConfigKeys.profileField)
        storedOrganizationID = d.string(forKey: ConfigKeys.orgPreset)
        lastCloudRoot = d.string(forKey: ConfigKeys.mailCloudRoot)
        libraryPendingAction = LibraryPendingAction.load(d)
    }

    /// Whether first uses are recorded now (nil: always — self-tests, renders). The app answers
    /// `GuideActivity.wanted`: a legacy install, whose Getting Started never shows, keeps them only
    /// while a guide view (Help Center, tour, Setup Assistant) is open to show them.
    @ObservationIgnored var recordsActivity: (() -> Bool)?

    /// Records the first use of `kind` (later uses change nothing; nothing while `recordsActivity`
    /// says no).
    func record(_ kind: GuideActivityKind, now: Date = Date()) {
        guard activity[kind] == nil, recordsActivity?() ?? true else { return }
        activity[kind] = now
        d?.set(Dictionary(uniqueKeysWithValues: activity.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
               forKey: ConfigKeys.guideActivity)
    }

    /// Finish: `onboarding.version`, `onboarding.completedAt`, `guide.checklist.dismissed`.
    func markOnboardingFinished(showChecklist: Bool, now: Date = Date()) {
        onboardingVersion = 1
        completedAt = now
        d?.set(1, forKey: ConfigKeys.onboardingVersion)
        d?.set(now.timeIntervalSince1970, forKey: ConfigKeys.onboardingCompletedAt)
        checklistDismissed = !showChecklist
    }

    func toggleManual(_ key: String) {
        if manualDone.contains(key) { manualDone.remove(key) } else { manualDone.insert(key) }
    }

    private func store(_ value: Any, _ key: String) {
        guard !loading else { return }
        d?.set(value, forKey: key)
    }

    private func write(_ value: String?, _ key: String) {
        guard let d, !loading else { return }
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }

    private static func date(_ d: UserDefaults, _ key: String) -> Date? {
        (d.object(forKey: key) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

/// First-use recording for the Getting Started checklist and the tour's "Try it" lines. The app
/// installs its store with its policy at launch (`install`); self-tests and renders never do, so
/// they record nothing.
enum GuideActivity {
    static weak var store: GuideStore?

    /// The app's wiring at launch (`AppDelegate`): the store and its recording policy, together.
    static func install(_ guide: GuideStore, settings: SettingsStore, facts: SetupFactsCollector) {
        guide.recordsActivity = policy(settings: settings, facts: facts)
        store = guide
    }

    /// Records through the installed store — only one with a policy: a store installed without it
    /// (a lost wiring) records nothing rather than everything, so a legacy install never gains
    /// `guide.activity` by accident (PORTABILITY_PLAN §6.2.6; `--selftest onboarding`).
    static func record(_ kind: GuideActivityKind) {
        guard let store, store.recordsActivity != nil else { return }
        store.record(kind)
    }

    /// The app's `GuideStore.recordsActivity`: a fresh install always records (its Getting Started
    /// checklist reads them); a legacy install only while a guide view is open — so an existing
    /// install's settings gain `guide.activity` only when the user follows a guide
    /// (PORTABILITY_PLAN §6.2.6).
    static func wanted(origin: ConfigOrigin, guideOpen: Bool) -> Bool {
        origin == .fresh || guideOpen
    }

    /// `wanted` for this Mac: the configured origin and whether a guide view is probing now.
    static func policy(settings: SettingsStore, facts: SetupFactsCollector) -> () -> Bool {
        { [weak settings, weak facts] in
            wanted(origin: settings?.config.origin ?? .legacy, guideOpen: facts?.isActive ?? false)
        }
    }
}
