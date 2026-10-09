import Foundation
import Security
import UserNotifications
import PaperDeckCore
import PaperDeckConfig

/// Environment check that spends no quota and never probes TCC-protected folders.
enum Doctor {
    static func run(_ args: CLIArgs) async -> Int32 {
        if args.has("--mail-only") {
            identity(MailCLI.mailSettings(args).suite ?? .standard)
            await mail(args, paths: libraryPaths(args))
            return 0
        }
        CLIRunner.line(["app": CLIRunner.versionString, "bundle": Bundle.main.bundlePath])
        identity(.standard)
        CLIRunner.line(["signing": signingDescription()])
        CLIRunner.line(["agent.mode": UserDefaults.standard.string(forKey: "agent.mode") ?? "off (default)",
                        "agent.provider": UserDefaults.standard.string(forKey: "agent.provider") ?? "claude (default)",
                        "agent.codexModel": UserDefaults.standard.string(forKey: "agent.codexModel") ?? "\(AIProviderKind.defaultCodexModel) (default)"])

        // Both providers' detection — zero quota: `claude --version` / `auth status`;
        // `codex --version` / `login status` / `exec --help` / `features list` (never `codex exec`).
        let claude = ClaudeCodeProvider(locator: BinaryLocator(override: AgentCLI.cliOverride(.claude)),
                                        agentCwd: AgentCLI.agentCwd(args), spawnGate: { _ in false })
        report(.claude, await claude.detect(), authMethod: "claude.ai")
        let codex = AgentCLI.codexProvider(args)
        report(.codex, await codex.detect(), authMethod: "ChatGPT")

        let paths = libraryPaths(args)
        CLIRunner.line(["library": paths.library.path, "support": paths.support.path])
        if FileManager.default.fileExists(atPath: paths.database.path) {
            do {
                let db = try await Database.open(url: paths.database, backupsDir: nil)
                let ok = await db.quickCheck()
                let count = try await db.livePapers().count
                CLIRunner.line(["database": ok ? "ok" : "CORRUPT", "papers": count, "schema": (try? await db.schemaVersion()) ?? -1])
                await db.close()
            } catch {
                CLIRunner.line(["database": "error: \(error)"])
            }
        } else {
            CLIRunner.line(["database": "not created yet"])
        }

        if Bundle.main.bundleIdentifier != nil {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            CLIRunner.line(["notifications": String(describing: s.authorizationStatus.rawValue),
                            "alertStyle": s.alertStyle.rawValue])
        }
        CLIRunner.line(["widget": pluginkit()])
        await mail(args, paths: paths)
        return 0
    }

    /// This build's identity (bundle, widget, keychain service, channel — `BuildIdentity`) and the
    /// configuration summary (institution, field, stage, origin, date order) of `d` (read-only).
    static func identity(_ d: UserDefaults) {
        let id = BuildIdentity.current
        CLIRunner.line(["bundleID": id.bundleID, "widgetID": id.widgetBundleID, "keychainService": id.keychainService,
                        "channel": id.channel.rawValue, "signingIdentity": id.signingIdentityName ?? "unknown (not stamped)"])
        let c = ConfigResolver.load(d, legacyFallback: true)
        CLIRunner.line(["config.org": c.organization.id, "config.field": c.field.id, "config.stage": c.stage.rawValue,
                        "config.origin": c.origin.rawValue, "config.dateOrder": c.mailDateOrder.rawValue,
                        "config.migrationVersion": c.migrationVersion.map(String.init) ?? "none",
                        "config.reader": c.readerOverride == nil ? "composed" : "custom"])
    }

    static func libraryPaths(_ args: CLIArgs) -> AppPaths {
        args.url("--root").map(AppPaths.rooted(at:)) ?? AppPaths.production(
            library: UserDefaults.standard.string(forKey: "library.path").map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    // MARK: Mail

    /// Settings ▸ Mail (read-only), each account's local configuration state and whether its
    /// app password is in the keychain (attributes only — the secret is never read), the mail
    /// counts of the library DB. No network, no folder listing (cloud folders may be offline).
    static func mail(_ args: CLIArgs, paths: AppPaths) async {
        let (m, suite) = MailCLI.mailSettings(args)
        CLIRunner.line(["mail.enabled": m.enabled, "mail.sync": m.syncMinutes == 0 ? "manual" : "every \(m.syncMinutes) min",
                        "mail.aiMode": m.aiMode.rawValue,
                        "mail.triageProvider": m.triageProvider?.rawValue ?? "reading provider",
                        "mail.triageModels": "claude \(m.triageModelClaude), codex \(m.triageModelCodex)",
                        "mail.triageDailyMax": m.triageDailyMax, "mail.triageBodyCap": m.triageBodyCap,
                        "mail.retentionDays": m.retentionDays < 0 ? "keep" : "\(m.retentionDays)",
                        "mail.maxAttachmentMB": m.maxAttachmentMB])
        let enabled = m.senders.filter(\.enabled)
        let byKind = Dictionary(grouping: enabled, by: \.kind.rawValue).mapValues(\.count)
        let byPolicy = Dictionary(grouping: enabled, by: \.aiPolicy.rawValue).mapValues(\.count)
        let invalid = m.senders.filter { SenderMatcher.Pattern($0.pattern) == nil }.map(\.pattern)
        CLIRunner.line(["mail.senders": m.senders.count, "enabled": enabled.count, "byKind": byKind, "ai": byPolicy,
                        "invalidPatterns": invalid.isEmpty ? nil : invalid])
        for a in m.accounts {
            var info: [String: Any?] = ["mail.account": a.displayName, "id": a.id, "kind": a.kind.rawValue,
                                        "source": MailSourceResolver.source(of: a).rawValue,
                                        "sourceStored": a.source != nil,
                                        "enabled": a.enabled, "lookbackDays": a.lookbackDays]
            switch a.kind {
            case .folder:
                let path = (a.folderPath ?? "").trimmingCharacters(in: .whitespaces)
                info["folder"] = path.isEmpty ? nil : SettingsFormat.tildePath((path as NSString).expandingTildeInPath)
                info["deleteProcessed"] = a.deleteProcessedFiles
                info["config"] = path.isEmpty ? "needs setup: no folder" : "ok"
            case .imap:
                let host = (a.host?.isEmpty == false ? a.host : a.imapPreset?.host).flatMap { $0.isEmpty ? nil : $0 }
                info["preset"] = a.imapPreset?.rawValue
                info["server"] = host.map { "\($0):\(a.port ?? a.imapPreset?.port ?? 993)" }
                info["mailbox"] = a.mailbox ?? "INBOX"
                info["user"] = a.username
                let password: String
                if suite != nil { password = "not checked (--defaults-suite)" }
                else { password = keychainHasItem(a.secretKey) ? "saved in keychain" : "missing" }
                info["password"] = password
                info["config"] = host == nil ? "needs setup: no server"
                    : (a.username ?? "").isEmpty ? "needs setup: no address"
                    : password == "missing" ? "needs setup: no app password" : "ok"
            }
            CLIRunner.line(info)
        }
        guard FileManager.default.fileExists(atPath: paths.database.path) else { return }
        do {
            let db = try await Database.open(url: paths.database, backupsDir: nil)
            let counts = try await db.mailCounts()
            let last = try await db.kv("mail.lastSyncAt")
            let day = try await db.kv(MailTriageCoordinator.dayKey)
            CLIRunner.line(["mail.pending": counts.pending, "mail.requests": counts.requests,
                            "mail.lastSyncAt": last, "mail.triageToday": day])
            await db.close()
        } catch {
            CLIRunner.line(["mail.database": "unavailable (\(String(describing: type(of: error))))"])
        }
    }

    /// True when the app's keychain item for `key` exists (attributes only; the secret is not read).
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

    private static func report(_ kind: AIProviderKind, _ status: ProviderStatus, authMethod: String) {
        switch status {
        case .ready(let plan, let version, let path):
            CLIRunner.line([kind.rawValue: "ready", "plan": plan, "version": version, "path": path, "authMethod": authMethod])
        default:
            CLIRunner.line([kind.rawValue: String(describing: status), "reason": status.reasonText(.en, provider: kind)])
        }
    }

    /// "certificate: <common name>" or "ad-hoc".
    static func signingDescription() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "unsigned" }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            var name: CFString?
            SecCertificateCopyCommonName(leaf, &name)
            return "certificate: \((name as String?) ?? "?")"
        }
        return "ad-hoc"
    }

    static func pluginkit() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-v", "-i", SharedPaths.widgetBundleID]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "pluginkit failed" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "not registered" : out
    }
}
