import Foundation
import Security
import ServiceManagement
import PaperDeckCore

// Off-main-actor probes used by settings and the setup assistant. Everything here is
// nonisolated and returns Sendable values; blocking work goes through BlockingIO and
// child processes through Core's ProcessRunner (async, never on the main thread).

/// How the running app is signed (§3.6 / setup assistant row 2). Reads the process's own
/// code signature — no keychain access.
nonisolated enum CodeSigningProbe {
    enum Kind: Sendable, Equatable {
        case certificate(String)      // leaf certificate subject (the build's signing certificate name)
        case adhoc
        case unsigned
    }

    static func current() async -> Kind {
        await BlockingIO.run { inspect() }
    }

    private static func inspect() -> Kind {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unsigned }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adhoc }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            let name = SecCertificateCopySubjectSummary(leaf) as String? ?? "?"
            return .certificate(name)
        }
        return dict[kSecCodeInfoIdentifier as String] == nil ? .unsigned : .adhoc
    }
}

/// `pluginkit -m -v -i <widget bundle id>` (settings ▸ 小组件; `SharedPaths.widgetBundleID`).
nonisolated enum PluginKitProbe {
    struct Result: Sendable, Equatable {
        var output: String            // trimmed stdout; empty = not registered
        var failed: Bool
        /// pluginkit marks an extension the user disabled with a leading "-".
        var isDisabled: Bool { output.hasPrefix("-") }
    }

    static func query(bundleID: String = SharedPaths.widgetBundleID) async -> Result {
        let runner = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1))
        let env = ["HOME": SharedPaths.realHome.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        do {
            let r = try await runner.run(.init(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-i", bundleID],
                                               environment: env, currentDirectory: NSTemporaryDirectory(),
                                               timeout: .seconds(10)))
            let out = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(output: out, failed: r.timedOut)
        } catch {
            return Result(output: String(describing: error), failed: true)
        }
    }
}

/// Counts PDFs below a folder the user picked (setup assistant row 6).
nonisolated enum FolderScan {
    static func countPDFs(in folder: URL, limit: Int = 20_000) async -> Int {
        await BlockingIO.run {
            guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
            var n = 0
            for case let url as URL in e where url.pathExtension.lowercased() == "pdf" {
                n += 1
                if n >= limit { break }
            }
            return n
        }
    }
}

/// Library root health, probed off the main thread (touches the file system).
nonisolated enum LibraryProbe {
    static func status(of root: URL) async -> LibraryStatus {
        await BlockingIO.run { LibraryPaths.status(of: root) }
    }

    /// Creates `~/Papers` (the documented alternative when Documents access is denied).
    static func createAlternative() async -> URL? {
        let alt = SharedPaths.realHome.appendingPathComponent("Papers", isDirectory: true)
        return await BlockingIO.run {
            do {
                try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
                return alt
            } catch {
                return nil
            }
        }
    }
}

/// The CLI the settings show (zero quota: `--version`, maybe `zsh -lc 'command -v claude'`).
/// The engine's own locator is fixed when the library opens; an override applies after restart.
nonisolated enum ClaudeBinaryProbe {
    static func locate(override: String) async -> BinaryLocator.Binary? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let locator = BinaryLocator(override: trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath)
        return await locator.locate()
    }
}

/// The Codex CLI settings ▸ AI shows (zero quota: `codex --version`, maybe a login shell's
/// `command -v codex`). The engine's CodexLocator re-reads `agent.codexPath` on every resolve.
nonisolated enum CodexBinaryProbe {
    static func locate(override: String) async -> BinaryLocator.Binary? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let locator = CodexLocator(overrideSource: { trimmed.isEmpty ? nil : trimmed })
        return await locator.locate()
    }

    /// `/Applications/ChatGPT.app/Contents/Resources/codex login` — what the user types in
    /// Terminal (the path is quoted when it contains spaces).
    static func loginCommand(path: String?) -> String {
        guard let path, !path.isEmpty else { return "codex login" }
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@~".contains($0) }
        return (safe ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'") + " login"
    }
}

/// ChatGPT models for settings ▸ AI: the slugs + display names the Codex CLI caches in
/// `~/.codex/models_cache.json` (only entries marked `"visibility": "list"`), falling back to
/// `AIProviderKind.codexModelChoices`. Reads only that file — never `auth.json` or the keychain.
nonisolated enum CodexModelCatalog {
    struct Model: Sendable, Equatable, Identifiable {
        var id: String            // slug passed to `codex exec -m`
        var name: String          // "GPT-5.6-Terra"
        var detail: String?       // 「均衡（推荐）」 for the known ones
    }

    static var cacheURL: URL {
        SharedPaths.realHome.appendingPathComponent(".codex/models_cache.json")
    }

    static func load(lang: UILang, url: URL = cacheURL) async -> [Model] {
        let cached = await BlockingIO.run { () -> [(slug: String, name: String)]? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return parse(data)
        }
        return merge(cached ?? [], lang: lang)
    }

    /// Visible models in the CLI's priority order.
    static func parse(_ data: Data) -> [(slug: String, name: String)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return nil }
        let visible = models.compactMap { m -> (slug: String, name: String, priority: Int)? in
            guard let slug = m["slug"] as? String, !slug.isEmpty, slug.count <= 64,
                  (m["visibility"] as? String ?? "list") == "list" else { return nil }
            let name = (m["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            return (slug, name, m["priority"] as? Int ?? .max)
        }
        return visible.sorted { $0.priority < $1.priority }.map { ($0.slug, $0.name) }
    }

    /// The recommended three first (terra, sol, luna — when the cache has them or has no list),
    /// then the other cached models.
    static func merge(_ cached: [(slug: String, name: String)], lang: UILang) -> [Model] {
        let names = Dictionary(cached.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [Model] = []
        for choice in AIProviderKind.codexModelChoices where cached.isEmpty || names[choice.id] != nil {
            out.append(Model(id: choice.id, name: names[choice.id] ?? displayName(choice.id), detail: choice.detail(lang)))
        }
        for m in cached where !out.contains(where: { $0.id == m.slug }) {
            out.append(Model(id: m.slug, name: m.name, detail: nil))
        }
        return out
    }

    /// Picker entries in `lang` (hints re-derived, so a language switch needs no reload), always
    /// including the current setting (a slug no longer in the cache).
    static func choices(_ models: [Model], including current: String, lang: UILang) -> [Model] {
        var base = models.isEmpty ? merge([], lang: lang) : models
        for i in base.indices {
            if let known = AIProviderKind.codexModelChoices.first(where: { $0.id == base[i].id }) {
                base[i].detail = known.detail(lang)
            }
        }
        guard !current.isEmpty, !base.contains(where: { $0.id == current }) else { return base }
        return base + [Model(id: current, name: displayName(current), detail: nil)]
    }

    /// `gpt-5.6-terra` → `GPT-5.6-Terra`.
    static func displayName(_ slug: String) -> String {
        slug.split(separator: "-").map { part -> String in
            part.lowercased() == "gpt" ? "GPT" : part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: "-")
    }
}

/// 开机自启 (SMAppService). The user's choice is remembered separately from the service
/// status so a launch-time check can re-register after the app was moved or re-signed.
enum LaunchAtLogin {
    static let wantedKey = "general.launchAtLogin"

    static var wanted: Bool { UserDefaults.standard.bool(forKey: wantedKey) }

    /// `.notFound` for a bare `swift build` binary (no bundle to register).
    static var status: SMAppService.Status {
        Bundle.main.bundleIdentifier == nil ? .notFound : SMAppService.mainApp.status
    }

    static func set(_ on: Bool, settings: SettingsStore) {
        UserDefaults.standard.set(on, forKey: wantedKey)
        settings.setLaunchAtLogin(on)
    }

    /// Called once per launch by `DerivedRefresher.start()`: enabled by the user but not
    /// registered any more → register again (never opens System Settings).
    static func reconcileAtLaunch(settings: SettingsStore) {
        guard settings.launchAtLoginAvailable else { return }
        let status = SMAppService.mainApp.status
        if UserDefaults.standard.object(forKey: wantedKey) == nil {
            // First run with this key: adopt whatever the system has.
            UserDefaults.standard.set(status == .enabled, forKey: wantedKey)
            return
        }
        guard wanted, status != .enabled, status != .requiresApproval else { return }
        do {
            try SMAppService.mainApp.register()
            Log.app.info("launch at login re-registered")
        } catch {
            Log.app.error("launch at login re-register failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
