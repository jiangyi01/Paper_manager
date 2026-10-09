import AppKit
import ServiceManagement
import Synchronization
import UserNotifications
import WidgetKit
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// The probed half of `SetupFacts` (file system, permissions, CLIs): every call is off the main
/// actor, zero quota (providers only through `ProviderProbe`), and privacy-preserving (cloud
/// roots by name only, folders by existence only, keychain items by attributes only).
nonisolated protocol FactSources: Sendable {
    func library(_ root: URL) async -> LibraryFact
    func provider(_ kind: AIProviderKind, overridePath: String?) async -> ProviderStatus
    func notifications(reminderEnabled: Bool) async -> NotificationFact
    func loginItem() async -> LoginItemFact
    func widget() async -> WidgetFact
    func appLocation() async -> AppLocationFact
    func signing() async -> SigningFact
    func cloud(home: URL) async -> CloudFact
    func folderExists(_ path: String) async -> Bool
    func passwordPresent(secretKey: String) async -> Bool
}

/// The real Mac (the app only — renders and self-tests use `FakeFactSources`).
nonisolated struct LiveFactSources: FactSources {
    /// The agent working directory `ProviderProbe` runs the CLIs in (created if needed).
    let agentCwd: URL

    func library(_ root: URL) async -> LibraryFact {
        await BlockingIO.run { Self.inspectLibrary(root) }
    }

    static func inspectLibrary(_ root: URL) -> LibraryFact {
        let status = LibraryPaths.status(of: root)
        var url = root
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsInternalKey])
        let volume: LibraryFact.Volume
        if status == .ubiquitous || FileOps.isUbiquitous(root) || root.path.contains("/Library/CloudStorage/") {
            volume = .cloud
        } else if values?.volumeIsLocal == false {
            volume = .network
        } else if values?.volumeIsRemovable == true || values?.volumeIsInternal == false || root.path.hasPrefix("/Volumes/") {
            volume = .removable
        } else {
            volume = .local
        }
        let manifest = FileManager.default.fileExists(atPath: root.appendingPathComponent(".paperdeck-library.json").path)
        return LibraryFact(status: status, tildePath: tilde(root.path), volume: volume, hasManifest: manifest)
    }

    func provider(_ kind: AIProviderKind, overridePath: String?) async -> ProviderStatus {
        try? FileManager.default.createDirectory(at: agentCwd, withIntermediateDirectories: true)
        let path = overridePath.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return await ProviderProbe.status(kind, overridePath: path, agentCwd: agentCwd)
    }

    func notifications(reminderEnabled: Bool) async -> NotificationFact {
        let service = await MainActor.run { ReminderService.shared }
        guard let service, await MainActor.run(body: { service.notificationsAvailable }) else {
            return NotificationFact(authorization: .unavailable, reminderEnabled: reminderEnabled)
        }
        let status = await service.refreshAuthorization()
        let auth: NotificationFact.Authorization
        switch status {
        case .authorized: auth = .authorized
        case .provisional, .ephemeral: auth = .provisional
        case .denied: auth = .denied
        case .notDetermined: auth = .notDetermined
        @unknown default: auth = .notDetermined
        }
        return NotificationFact(authorization: auth, reminderEnabled: reminderEnabled)
    }

    func loginItem() async -> LoginItemFact {
        guard Bundle.main.bundleIdentifier != nil else { return LoginItemFact(status: .notFound) }
        switch SMAppService.mainApp.status {
        case .enabled: return LoginItemFact(status: .enabled)
        case .requiresApproval: return LoginItemFact(status: .requiresApproval)
        case .notRegistered: return LoginItemFact(status: .notRegistered)
        case .notFound: return LoginItemFact(status: .notFound)
        @unknown default: return LoginItemFact(status: .notFound)
        }
    }

    func widget() async -> WidgetFact {
        let probe = await PluginKitProbe.query()
        let registration: WidgetFact.Registration
        if probe.failed { registration = .failed }
        else if probe.output.isEmpty { registration = .notRegistered }
        else if probe.isDisabled { registration = .disabled }
        else { registration = .registered }
        let placed = registration == .registered ? await Self.placedWidgets() : nil
        return WidgetFact(registration: registration, placedCount: placed)
    }

    /// How many PaperDeck widgets are placed (nil: macOS didn't say within 3 s). WidgetCenter's
    /// configurations call answers through a callback off the main thread, so it is wrapped here
    /// (nonisolated) and resumed once by whichever comes first — the callback or the timeout. A
    /// callback that never comes can't stall `widget()` (and with it the guides' refresh loop).
    static func placedWidgets(timeout: Duration = .seconds(3)) async -> Int? {
        await firstAnswer(timeout: timeout) { answer in
            WidgetCenter.shared.getCurrentConfigurations { result in   // pd-callback-ok: the nonisolated wrapper
                answer((try? result.get())?.count)
            }
        }
    }

    /// Starts `start`, which answers at most once through its argument (later answers are
    /// ignored); returns that answer, or nil when `timeout` passes first. Returns after at most
    /// `timeout` even if `start` never answers.
    static func firstAnswer<T: Sendable>(timeout: Duration,
                                         _ start: @Sendable (@escaping @Sendable (T?) -> Void) -> Void) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            once.install(cont)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
            start { value in
                timer.cancel()
                once.resume(value)
            }
        }
    }

    func appLocation() async -> AppLocationFact {
        let path = Bundle.main.bundlePath
        return Self.location(bundlePath: path, home: SharedPaths.realHome.path,
                             quarantined: getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
    }

    static func location(bundlePath path: String, home: String, quarantined: Bool) -> AppLocationFact {
        let location: AppLocationFact.Location
        if path.contains("/AppTranslocation/") { location = .translocated }
        else if path.hasPrefix("/Applications/") { location = .applications }
        else if path.hasPrefix(home + "/Applications/") { location = .userApplications }
        else { location = .other }
        return AppLocationFact(location: location, quarantined: quarantined)
    }

    func signing() async -> SigningFact {
        let kind: SigningFact.Kind
        switch await CodeSigningProbe.current() {
        case .certificate(let name): kind = .certificate(name)
        case .adhoc: kind = .adhoc
        case .unsigned: kind = .unsigned
        }
        return SigningFact(kind: kind, channel: BuildIdentity.current.channel)
    }

    /// Root names of `~/Library/CloudStorage` only (never anything inside them), plus iCloud Drive.
    func cloud(home: URL) async -> CloudFact {
        await BlockingIO.run {
            let storage = home.appendingPathComponent("Library").appendingPathComponent("CloudStorage", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
            var roots = CloudRootLocator.classify(names: names.filter { !$0.hasPrefix(".") }, cloudStorage: storage)
            let icloud = CloudRootLocator.iCloudDrive(home: home)
            if FileManager.default.fileExists(atPath: icloud.url.path) { roots.append(icloud) }
            return CloudFact(roots: roots)
        }
    }

    func folderExists(_ path: String) async -> Bool {
        await BlockingIO.run {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    func passwordPresent(secretKey: String) async -> Bool {
        await BlockingIO.run { Self.keychainHasItem(secretKey) }
    }

    /// Attributes only (`kSecReturnAttributes`): the secret itself is never read.
    static func keychainHasItem(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainMailSecretStore.defaultService,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    static func tilde(_ path: String) -> String {
        let home = SharedPaths.realHome.path
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}

/// A continuation resumed exactly once, whoever calls `resume` first (a callback racing a timeout).
nonisolated final class ResumeOnce<T: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<T, Never>?>(nil)

    func install(_ cont: CheckedContinuation<T, Never>) {
        state.withLock { $0 = cont }
    }

    /// The first call resumes; later calls do nothing.
    func resume(_ value: T) {
        let cont = state.withLock { c -> CheckedContinuation<T, Never>? in
            defer { c = nil }
            return c
        }
        cont?.resume(returning: value)
    }
}

/// Canned Macs for renders and self-tests (never any I/O).
nonisolated enum FactScenario: String, CaseIterable, Sendable {
    case fresh, legacy, codexOnly, noAI, allReady, mailError, m365Contoso

    /// The whole fact set this scenario stands for.
    func facts(home: URL) -> SetupFacts {
        let documents = LibraryFact(status: .ok, tildePath: "~/Documents/PaperDeck", volume: .local, hasManifest: true)
        let claudeReady = ProviderStatus.ready(plan: "max", version: "2.1.284", path: home.path + "/.local/bin/claude")
        let codexReady = ProviderStatus.ready(plan: "plus", version: "0.153.4",
                                              path: "/Applications/ChatGPT.app/Contents/Resources/codex")
        var f = SetupFacts(
            library: .value(documents), papers: .value(PaperCounts()),
            ai: AIFact(statuses: [.claude: .value(.notInstalled), .codex: .value(.notInstalled)]),
            notifications: .value(NotificationFact(authorization: .notDetermined, reminderEnabled: true)),
            loginItem: .value(LoginItemFact(status: .notRegistered)),
            widget: .value(WidgetFact(registration: .registered, placedCount: 0)),
            app: .value(AppLocationFact(location: .applications, quarantined: false)),
            signing: .value(SigningFact(kind: .certificate(BuildIdentity.defaultSigningIdentityName), channel: .local)),
            cloud: .value(CloudFact(roots: [])),
            profile: ProfileFact(origin: .fresh, fieldID: FieldPresets.general.id, organizationID: OrganizationPresets.generic.id),
            features: [.settingsTransfer, .libraryFlows, .widgetRepair])
        func root(_ provider: CloudProvider, _ name: String, _ display: String) -> CloudRoot {
            CloudRoot(provider: provider, name: name,
                      url: home.appendingPathComponent("Library").appendingPathComponent("CloudStorage")
                        .appendingPathComponent(name, isDirectory: true),
                      displayName: display)
        }
        switch self {
        case .fresh:
            f.library = .value(LibraryFact(status: .ok, tildePath: "~/Documents/PaperDeck", volume: .local, hasManifest: false))
        case .legacy:
            f.papers = .value(PaperCounts(live: 120, withCard: 110, opened: 80, missingFiles: 0, fullTextIndexed: 120))
            f.ai = AIFact(mode: .claude, provider: .claude, statuses: [.claude: .value(claudeReady), .codex: .value(.notInstalled)])
            f.notifications = .value(NotificationFact(authorization: .authorized, reminderEnabled: true))
            f.loginItem = .value(LoginItemFact(status: .enabled))
            f.widget = .value(WidgetFact(registration: .registered, placedCount: 1))
            f.mail = MailFact(enabled: true, accounts: [
                MailAccountFact(id: "work-pa", source: .m365PowerAutomate, status: .ready(detail: ""),
                                lastSuccessAt: Date(timeIntervalSince1970: 1_790_000_000), captured: 3, folderExists: true),
            ], senders: [.advisor: 1, .alert: 2])
            f.cloud = .value(CloudFact(roots: [root(.oneDriveBusiness, "OneDrive-Example University", "OneDrive - Example University")]))
            f.profile = ProfileFact(origin: .legacy)
            for kind in GuideActivityKind.allCases { f.activity[kind] = Date(timeIntervalSince1970: 1_780_000_000) }
        case .codexOnly:
            f.ai = AIFact(provider: .codex, statuses: [.claude: .value(.notInstalled), .codex: .value(codexReady)])
        case .noAI:
            f.ai = AIFact(decision: "none", statuses: [.claude: .value(.notInstalled), .codex: .value(.notInstalled)])
            f.papers = .value(PaperCounts(live: 3, withCard: 0, opened: 1, fullTextIndexed: 3))
        case .allReady:
            f.papers = .value(PaperCounts(live: 12, withCard: 12, opened: 5, missingFiles: 0, fullTextIndexed: 12))
            f.ai = AIFact(mode: .claude, provider: .claude, decision: "claude",
                          statuses: [.claude: .value(claudeReady), .codex: .value(codexReady)])
            f.notifications = .value(NotificationFact(authorization: .authorized, reminderEnabled: true))
            f.loginItem = .value(LoginItemFact(status: .enabled))
            f.widget = .value(WidgetFact(registration: .registered, placedCount: 1))
            f.mail = MailFact(enabled: true, decision: "configured", accounts: [
                MailAccountFact(id: "gmail", source: .imapGmail, status: .ready(detail: ""),
                                lastSuccessAt: Date(timeIntervalSince1970: 1_790_000_000), captured: 4, passwordPresent: true),
            ], senders: [.advisor: 1, .alert: 3])
            f.transfer = TransferFact(lastExportedAt: Date(timeIntervalSince1970: 1_790_000_000))
            for kind in [GuideActivityKind.panelDrop, .openedDetail, .tourCompleted] {
                f.activity[kind] = Date(timeIntervalSince1970: 1_790_000_000)
            }
        case .mailError:
            f.papers = .value(PaperCounts(live: 4, withCard: 2, opened: 2, fullTextIndexed: 4))
            f.ai = AIFact(decision: "none", statuses: [.claude: .value(.notInstalled), .codex: .value(.notInstalled)])
            f.mail = MailFact(enabled: true, decision: "configured", accounts: [
                MailAccountFact(id: "gmail", source: .imapGmail, status: .authFailed("LOGIN rejected"), passwordPresent: true),
                MailAccountFact(id: "folder", source: .folder, status: .ready(detail: ""), captured: 1, notEmailFiles: 2,
                                folderExists: true),
            ], senders: [.alert: 2])
        case .m365Contoso:
            f.cloud = .value(CloudFact(roots: [
                root(.oneDriveBusiness, "OneDrive-Contoso University", "OneDrive - Contoso University"),
                root(.dropbox, "Dropbox", "Dropbox"),
            ]))
            f.mail = MailFact(suggestedFolderExists: false)
        }
        return f
    }

    /// The organization the scenario's renders use.
    var organization: OrganizationProfile {
        self == .legacy ? (OrganizationPresets.preset(id: LegacyInstall.organizationID) ?? OrganizationPresets.generic)
            : OrganizationPresets.generic
    }
}

/// `FactSources` answering from a scenario (renders, `--selftest onboarding`).
nonisolated struct FakeFactSources: FactSources {
    let scenario: FactScenario
    let home: URL

    private var f: SetupFacts { scenario.facts(home: home) }

    func library(_ root: URL) async -> LibraryFact {
        f.library.known ?? LibraryFact(status: .ok, tildePath: root.path, volume: .local, hasManifest: false)
    }
    func provider(_ kind: AIProviderKind, overridePath: String?) async -> ProviderStatus {
        f.ai.statuses[kind]?.known ?? .notInstalled
    }
    func notifications(reminderEnabled: Bool) async -> NotificationFact {
        f.notifications.known ?? NotificationFact(authorization: .notDetermined, reminderEnabled: reminderEnabled)
    }
    func loginItem() async -> LoginItemFact { f.loginItem.known ?? LoginItemFact(status: .notRegistered) }
    func widget() async -> WidgetFact { f.widget.known ?? WidgetFact(registration: .notRegistered) }
    func appLocation() async -> AppLocationFact { f.app.known ?? AppLocationFact(location: .applications, quarantined: false) }
    func signing() async -> SigningFact { f.signing.known ?? SigningFact(kind: .unsigned, channel: .local) }
    func cloud(home: URL) async -> CloudFact { f.cloud.known ?? CloudFact(roots: []) }
    func folderExists(_ path: String) async -> Bool { f.mail.accounts.contains { $0.folderExists == true } }
    func passwordPresent(secretKey: String) async -> Bool { true }
}
