import Foundation
import os

// User-configurable mail settings (all DIY in Settings ▸ Mail). Stored in UserDefaults
// as JSON; secrets (IMAP app passwords) live in the Keychain (MailSecretStore).

/// Whether a sender's mail may be sent to the AI provider for triage.
package enum MailAIPolicy: String, Codable, Sendable, CaseIterable {
    case ask        // local heuristics first; AI only after the user clicks 「让 AI 分析」 (default for people)
    case always     // triage with AI automatically (default for alerts — public content)
    case never      // local heuristics only, never sent to AI
}

/// One entry of the sender list. `pattern` is an exact address ("prof.x@university.edu"),
/// a domain ("@biorxiv.org") or a wildcard subdomain ("@*.nature.com"). Matching uses
/// the address part only (lowercased, "+tag" stripped); display names never match.
package struct SenderRule: Codable, Sendable, Equatable, Identifiable {
    package var id: String
    package var pattern: String
    package var label: String                   // "Prof. Smith", "Google Scholar"
    package var kind: SenderKind                // advisor | person | alert
    package var enabled: Bool
    package var aiPolicy: MailAIPolicy
    // Per-sender defaults applied on merge (the user can still change them per card).
    package var defaultPriority: Priority?      // nil → by kind (advisor high, others normal)
    package var defaultCategory: String?        // category name to file merged papers under
    package var useDueDateAsDDL: Bool           // pin the email's due date as the DDL (when confident)
    package var autoMerge: Bool                 // merge PDF-ready papers without waiting for the user
    package var autoDownload: Bool              // fetch attachments / open PDF links automatically

    package init(id: String = UUID().uuidString.lowercased(), pattern: String, label: String = "",
                 kind: SenderKind, enabled: Bool = true, aiPolicy: MailAIPolicy? = nil,
                 defaultPriority: Priority? = nil, defaultCategory: String? = nil, useDueDateAsDDL: Bool = true,
                 autoMerge: Bool = false, autoDownload: Bool = true) {
        self.id = id; self.pattern = pattern; self.label = label; self.kind = kind; self.enabled = enabled
        self.aiPolicy = aiPolicy ?? (kind == .alert ? .always : .ask)
        self.defaultPriority = defaultPriority; self.defaultCategory = defaultCategory
        self.useDueDateAsDDL = useDueDateAsDDL; self.autoMerge = autoMerge; self.autoDownload = autoDownload
    }

    /// Effective merge priority for this sender.
    package var effectivePriority: Priority { defaultPriority ?? (kind == .advisor ? .high : .normal) }

    /// Presets offered in the sender-list editor (verified against the user's recent senders in the UI).
    /// They are domain-wide on purpose (journals mail alerts from many subdomains). The same
    /// domains also host manuscript systems and submission / screening desks: such mail —
    /// reviewer invitations, manuscripts under review, the user's own unposted submissions — is
    /// caught by the confidentiality guard (`MailHeuristics.isConfidential`) and never triaged by
    /// AI or merged automatically, whatever the preset's policy; and an alert rule triages only
    /// mailing-list mail (`MailSyncActor.isBulk`) on its own.
    package static let presets: [SenderRule] = [
        SenderRule(id: "preset-google-scholar", pattern: "scholaralerts-noreply@google.com", label: "Google Scholar Alerts", kind: .alert),
        SenderRule(id: "preset-arxiv", pattern: "@arxiv.org", label: "arXiv", kind: .alert),
        SenderRule(id: "preset-biorxiv", pattern: "@biorxiv.org", label: "bioRxiv", kind: .alert),
        SenderRule(id: "preset-medrxiv", pattern: "@medrxiv.org", label: "medRxiv", kind: .alert),
        SenderRule(id: "preset-highwire", pattern: "@alerts.highwire.org", label: "HighWire alerts (bioRxiv/medRxiv)", kind: .alert),
        SenderRule(id: "preset-nature", pattern: "@*.nature.com", label: "Nature", kind: .alert),
        SenderRule(id: "preset-cell", pattern: "@cell.com", label: "Cell Press", kind: .alert),
        SenderRule(id: "preset-elsevier", pattern: "@*.elsevier.com", label: "Elsevier / Cell alerts", kind: .alert),
        SenderRule(id: "preset-ncbi", pattern: "@ncbi.nlm.nih.gov", label: "PubMed (My NCBI)", kind: .alert),
    ]
}

/// What counts as a paper-reading need (DIY). Applied by both the local heuristics and
/// the AI triage prompt; the AI never overrides an explicit exclude.
package struct ReadingCriteria: Codable, Sendable, Equatable {
    /// Request kinds that create pending cards; others land in 「无阅读需求」.
    package var keepKinds: Set<MailRequestKind>
    package var includeKeywords: [String]       // any match → relevant (alerts: highlight these papers)
    package var excludeKeywords: [String]       // any match → not relevant (never merged automatically)
    package var researchInterests: String       // free text: "single-cell & spatial omics, AI agents for biology"
    package var customInstructions: String      // free text appended to the AI triage prompt (untrusted-safe)
    package var minConfidence: Double           // below → card shown as 「待确认」
    package var maxAlertPapers: Int             // alert digests: keep at most N most relevant candidates

    package init(keepKinds: Set<MailRequestKind> = [.advisorRequest, .journalClub, .alertDigest, .fyi],
                 includeKeywords: [String] = [], excludeKeywords: [String] = [], researchInterests: String = "",
                 customInstructions: String = "", minConfidence: Double = 0.5, maxAlertPapers: Int = 8) {
        self.keepKinds = keepKinds; self.includeKeywords = includeKeywords; self.excludeKeywords = excludeKeywords
        self.researchInterests = researchInterests; self.customInstructions = customInstructions
        self.minConfidence = minConfidence; self.maxAlertPapers = maxAlertPapers
    }
}

/// A configured mail account (the "portal" list in Settings ▸ Mail ▸ Accounts).
package struct MailAccount: Codable, Sendable, Equatable, Identifiable {
    package enum Kind: String, Codable, Sendable, CaseIterable {
        case folder     // watched folder of .eml files (Power Automate → OneDrive, Mail rules, manual saves)
        case imap       // IMAP over TLS with an app password (Gmail, iCloud, Yahoo, Fastmail, custom)
    }

    /// Known IMAP providers (host/port prefill + where to create an app password).
    package enum IMAPPreset: String, Codable, Sendable, CaseIterable {
        case gmail, icloud, yahoo, fastmail, custom

        package var host: String {
            switch self {
            case .gmail: return "imap.gmail.com"
            case .icloud: return "imap.mail.me.com"
            case .yahoo: return "imap.mail.yahoo.com"
            case .fastmail: return "imap.fastmail.com"
            case .custom: return ""
            }
        }
        package var port: Int { 993 }
        /// The provider's official page where the user creates an app password.
        package var appPasswordURL: URL? {
            switch self {
            case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
            case .icloud: return URL(string: "https://account.apple.com/account/manage")
            case .yahoo: return URL(string: "https://login.yahoo.com/account/security")
            case .fastmail: return URL(string: "https://app.fastmail.com/settings/security/devicekeys")
            case .custom: return nil
            }
        }
        /// Web mail link for "open in browser" (search by Message-ID where supported).
        package var webMailBase: String? {
            switch self {
            case .gmail: return "https://mail.google.com/mail/u/0/#search/rfc822msgid:"
            default: return nil
            }
        }
    }

    package var id: String
    package var kind: Kind
    package var displayName: String             // "Work (Power Automate)", "Gmail — me@gmail.com"
    package var enabled: Bool
    package var lookbackDays: Int               // first sync only
    // folder
    package var folderPath: String?             // absolute path of the watched folder
    package var deleteProcessedFiles: Bool      // remove .eml files after they were captured
    // imap
    package var imapPreset: IMAPPreset?
    package var host: String?
    package var port: Int?
    package var username: String?               // the mailbox address
    package var mailbox: String?                // "INBOX" or a label/folder (e.g. "PaperDeck")
    /// Where the mail comes from (a `MailSourceID` raw value, e.g. "m365.powerAutomate"), written by
    /// the add/edit sheet. Nil for accounts saved by older builds: the source is then inferred from
    /// the account (`MailSourceResolver`). Encoded only when set, so older JSON stays byte-identical.
    package var source: String?

    package init(id: String = UUID().uuidString.lowercased(), kind: Kind, displayName: String, enabled: Bool = true,
                 lookbackDays: Int = 14, folderPath: String? = nil, deleteProcessedFiles: Bool = false,
                 imapPreset: IMAPPreset? = nil, host: String? = nil, port: Int? = nil, username: String? = nil,
                 mailbox: String? = "INBOX", source: String? = nil) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.enabled = enabled
        self.lookbackDays = lookbackDays; self.folderPath = folderPath; self.deleteProcessedFiles = deleteProcessedFiles
        self.imapPreset = imapPreset; self.host = host; self.port = port; self.username = username
        self.mailbox = mailbox; self.source = source
    }

    /// Keychain account key for this account's app password.
    package var secretKey: String { "\(id).imap" }
    // The Power Automate folder suggestion lives in PaperDeckConfig (`CloudRootLocator.suggestedFolder`):
    // the engine knows no institution or tenant folder name.

    /// Where (and as whom) an IMAP account signs in, normalised the way the account form saves it:
    /// trimmed, case-insensitive host (an empty host means the preset's; a trailing dot is the same
    /// host) and username, the default port. The keychain item (`secretKey`) is keyed by the account
    /// id alone, so comparing this is the only thing binding a saved app password to its server.
    package struct ServerIdentity: Sendable, Equatable {
        package var host: String
        package var port: Int
        package var username: String

        package init(host: String, port: Int, username: String) {
            self.host = host; self.port = port; self.username = username
        }

        /// "me@example.com · imap.example.com:993" (no address: just the host and port).
        package var summary: String {
            let server = "\(host.isEmpty ? "—" : host):\(port)"
            return username.isEmpty ? server : "\(username) · \(server)"
        }
    }

    package var serverIdentity: ServerIdentity {
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var host = clean(self.host)
        if host.isEmpty { host = clean(imapPreset?.host) }
        while host.hasSuffix(".") { host.removeLast() }          // `imap.gmail.com.` is the same host
        return ServerIdentity(host: host, port: port ?? imapPreset?.port ?? 993, username: clean(username))
    }

    /// Whether the app password saved for `original` (an IMAP account as it is saved here) may be
    /// sent when signing in as `edited`: only for the same account (same id, IMAP both times) on the
    /// same server, port and address — never to another host, whether the account was edited
    /// (「编辑…」) or changed by a settings import.
    package static func mayReuseSavedPassword(original: MailAccount?, edited: MailAccount) -> Bool {
        guard let original, original.id == edited.id, original.kind == .imap, edited.kind == .imap else { return false }
        return original.serverIdentity == edited.serverIdentity
    }
}

/// Global mail settings snapshot (engine side). Loaded like EngineSettings.
package struct MailSettings: Sendable, Equatable {
    package enum AIMode: String, Codable, Sendable { case ai, heuristicOnly = "heuristic_only" }

    package var enabled: Bool                   // master switch for syncing
    package var accounts: [MailAccount]
    package var senders: [SenderRule]
    package var criteria: ReadingCriteria
    package var syncMinutes: Int                // 5 / 15 / 30 / 60; 0 = manual only
    package var aiMode: AIMode                  // heuristicOnly → nothing is ever sent to AI
    package var triageProvider: AIProviderKind? // nil → the reading provider (EngineSettings.selectedProvider)
    package var triageModelClaude: String       // default "haiku"
    package var triageModelCodex: String        // default "gpt-5.6-luna"
    package var triageDailyMax: Int             // AI triage calls per day (quota guard)
    package var triageBodyCap: Int              // chars of body text sent to the AI
    package var maxAttachmentMB: Int
    package var prefillNotes: Bool              // "来自邮件：…" line in notes of merged papers
    package var notifyNewRequests: Bool         // notification for new person/advisor requests (default off)
    package var includeInDailyReminder: Bool    // 「邮件待处理 N 封」 line at 11:00
    package var retentionDays: Int              // purge bodies N days after a card is handled
    /// How "3/10" in an email reads (month/day today; `mail.dateOrder`).
    package var dateOrder: SlashDateOrder

    package init(enabled: Bool = false, accounts: [MailAccount] = [], senders: [SenderRule] = [],
                 criteria: ReadingCriteria = ReadingCriteria(), syncMinutes: Int = 15, aiMode: AIMode = .ai,
                 triageProvider: AIProviderKind? = nil, triageModelClaude: String = "haiku",
                 triageModelCodex: String = "gpt-5.6-luna", triageDailyMax: Int = 30, triageBodyCap: Int = 12_000,
                 maxAttachmentMB: Int = 50, prefillNotes: Bool = true, notifyNewRequests: Bool = false,
                 includeInDailyReminder: Bool = true, retentionDays: Int = 30, dateOrder: SlashDateOrder = .mdy) {
        self.enabled = enabled; self.accounts = accounts; self.senders = senders; self.criteria = criteria
        self.syncMinutes = syncMinutes; self.aiMode = aiMode; self.triageProvider = triageProvider
        self.triageModelClaude = triageModelClaude; self.triageModelCodex = triageModelCodex
        self.triageDailyMax = triageDailyMax; self.triageBodyCap = triageBodyCap
        self.maxAttachmentMB = maxAttachmentMB; self.prefillNotes = prefillNotes
        self.notifyNewRequests = notifyNewRequests; self.includeInDailyReminder = includeInDailyReminder
        self.retentionDays = retentionDays; self.dateOrder = dateOrder
    }

    // UserDefaults keys (the app's SettingsStore writes the same keys).
    package enum Keys {
        package static let enabled = "mail.enabled", accounts = "mail.accounts", senders = "mail.senders"
        package static let criteria = "mail.criteria", syncMinutes = "mail.syncMinutes", aiMode = "mail.aiMode"
        package static let triageProvider = "mail.triageProvider", triageModelClaude = "mail.triageModelClaude"
        package static let triageModelCodex = "mail.triageModelCodex", triageDailyMax = "mail.triageDailyMax"
        package static let triageBodyCap = "mail.triageBodyCap", maxAttachmentMB = "mail.maxAttachmentMB"
        package static let prefillNotes = "mail.prefillNotes", notifyNewRequests = "mail.notifyNewRequests"
        package static let includeInDailyReminder = "mail.includeInDailyReminder", retentionDays = "mail.retentionDays"
        package static let dateOrder = "mail.dateOrder"
    }

    package static func load(from d: UserDefaults = .standard) -> MailSettings {
        func json<T: Decodable>(_ key: String, _ t: T.Type) -> T? {
            guard let s = d.string(forKey: key), let data = s.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        return MailSettings(
            enabled: bool(Keys.enabled, false),
            accounts: list(d.string(forKey: Keys.accounts), MailAccount.self, what: "account"),
            senders: list(d.string(forKey: Keys.senders), SenderRule.self, what: "sender"),
            criteria: json(Keys.criteria, ReadingCriteria.self) ?? ReadingCriteria(),
            syncMinutes: int(Keys.syncMinutes, 15),
            aiMode: AIMode(rawValue: d.string(forKey: Keys.aiMode) ?? "ai") ?? .ai,
            triageProvider: d.string(forKey: Keys.triageProvider).flatMap(AIProviderKind.init(rawValue:)),
            triageModelClaude: d.string(forKey: Keys.triageModelClaude) ?? "haiku",
            triageModelCodex: d.string(forKey: Keys.triageModelCodex) ?? "gpt-5.6-luna",
            triageDailyMax: int(Keys.triageDailyMax, 30),
            triageBodyCap: int(Keys.triageBodyCap, 12_000),
            maxAttachmentMB: int(Keys.maxAttachmentMB, 50),
            prefillNotes: bool(Keys.prefillNotes, true),
            notifyNewRequests: bool(Keys.notifyNewRequests, false),
            includeInDailyReminder: bool(Keys.includeInDailyReminder, true),
            retentionDays: int(Keys.retentionDays, 30),
            // Absent (every install before this key existed) → month first, as always.
            dateOrder: d.string(forKey: Keys.dateOrder).flatMap(SlashDateOrder.init(rawValue:)) ?? .mdy
        )
    }

    /// A stored JSON list decoded element by element: an entry this build cannot read (written
    /// by a newer build, or edited by hand) is dropped on its own instead of emptying the whole
    /// list — which the next settings edit would then save for good. Logs counts only.
    package static func list<T: Decodable>(_ json: String?, _ type: T.Type, what: String) -> [T] {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LenientElement<T>].self, from: data) else { return [] }
        let kept = entries.compactMap(\.value)
        if kept.count < entries.count {
            Logger(subsystem: Log.subsystem, category: "mail").error("mail settings: \(entries.count - kept.count, privacy: .public) \(what, privacy: .public) entr(ies) could not be read and were skipped")
        }
        return kept
    }

    /// Encodes a Codable value the way `load` expects (JSON string in UserDefaults).
    package static func encode<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self)
    }

    package func account(id: String) -> MailAccount? { accounts.first { $0.id == id } }
    package func rule(id: String?) -> SenderRule? { id.flatMap { rid in senders.first { $0.id == rid } } }
}

/// One element of a stored list; nil when it cannot be decoded (the rest of the list still loads).
private struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Lenient decoding (settings written by another build or edited by hand)
//
// Every field but the identity (`id`, plus `pattern` / `kind` where nothing works without them)
// may be missing: a non-optional one gets the memberwise default, an optional one nil (what the
// synthesized decoding did — the synthesized encoding omits nil). An unknown enum value falls back to the
// safest choice (an unknown AI policy → `ask`; an unknown sender kind → `person`; unknown
// request kinds are dropped from the kept set). Encoding stays synthesized.

extension SenderRule {
    private enum CodingKeys: String, CodingKey {
        case id, pattern, label, kind, enabled, aiPolicy, defaultPriority, defaultCategory, useDueDateAsDDL
        case autoMerge, autoDownload
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let pattern = try c.decode(String.self, forKey: .pattern)
        let kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }
            .map { SenderKind(rawValue: $0) ?? .person } ?? .person
        // Missing → the kind's default (alerts always, people ask); unreadable → ask.
        let policy: MailAIPolicy? = (try? c.decodeIfPresent(String.self, forKey: .aiPolicy)).flatMap { $0 }
            .map { MailAIPolicy(rawValue: $0) ?? .ask }
        let priority = (try? c.decodeIfPresent(Int.self, forKey: .defaultPriority)).flatMap { $0 }
            .flatMap(Priority.init(rawValue:))
        self.init(id: id, pattern: pattern,
                  label: (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 } ?? "",
                  kind: kind,
                  enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true,
                  aiPolicy: policy, defaultPriority: priority,
                  defaultCategory: (try? c.decodeIfPresent(String.self, forKey: .defaultCategory)).flatMap { $0 },
                  useDueDateAsDDL: (try? c.decodeIfPresent(Bool.self, forKey: .useDueDateAsDDL)).flatMap { $0 } ?? true,
                  autoMerge: (try? c.decodeIfPresent(Bool.self, forKey: .autoMerge)).flatMap { $0 } ?? false,
                  autoDownload: (try? c.decodeIfPresent(Bool.self, forKey: .autoDownload)).flatMap { $0 } ?? true)
    }
}

extension ReadingCriteria {
    private enum CodingKeys: String, CodingKey {
        case keepKinds, includeKeywords, excludeKeywords, researchInterests, customInstructions, minConfidence
        case maxAlertPapers
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReadingCriteria()
        let kinds = (try? c.decodeIfPresent([String].self, forKey: .keepKinds)).flatMap { $0 }
            .map { Set($0.compactMap(MailRequestKind.init(rawValue:))) }
        self.init(keepKinds: kinds ?? d.keepKinds,
                  includeKeywords: (try? c.decodeIfPresent([String].self, forKey: .includeKeywords)).flatMap { $0 } ?? [],
                  excludeKeywords: (try? c.decodeIfPresent([String].self, forKey: .excludeKeywords)).flatMap { $0 } ?? [],
                  researchInterests: (try? c.decodeIfPresent(String.self, forKey: .researchInterests)).flatMap { $0 } ?? "",
                  customInstructions: (try? c.decodeIfPresent(String.self, forKey: .customInstructions)).flatMap { $0 } ?? "",
                  minConfidence: (try? c.decodeIfPresent(Double.self, forKey: .minConfidence)).flatMap { $0 } ?? d.minConfidence,
                  maxAlertPapers: (try? c.decodeIfPresent(Int.self, forKey: .maxAlertPapers)).flatMap { $0 } ?? d.maxAlertPapers)
    }
}

extension MailAccount {
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, enabled, lookbackDays, folderPath, deleteProcessedFiles, imapPreset, host, port
        case username, mailbox, source
    }

    /// `id` and a known `kind` are required (an account of a transport this build does not
    /// have cannot sync); the rest falls back to the memberwise defaults.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard let kind = Kind(rawValue: try c.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown account kind")
        }
        self.init(id: id, kind: kind,
                  displayName: (try? c.decodeIfPresent(String.self, forKey: .displayName)).flatMap { $0 } ?? "",
                  enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true,
                  lookbackDays: (try? c.decodeIfPresent(Int.self, forKey: .lookbackDays)).flatMap { $0 } ?? 14,
                  folderPath: (try? c.decodeIfPresent(String.self, forKey: .folderPath)).flatMap { $0 },
                  deleteProcessedFiles: (try? c.decodeIfPresent(Bool.self, forKey: .deleteProcessedFiles)).flatMap { $0 } ?? false,
                  imapPreset: (try? c.decodeIfPresent(String.self, forKey: .imapPreset)).flatMap { $0 }
                    .map { IMAPPreset(rawValue: $0) ?? .custom },
                  host: (try? c.decodeIfPresent(String.self, forKey: .host)).flatMap { $0 },
                  port: (try? c.decodeIfPresent(Int.self, forKey: .port)).flatMap { $0 },
                  username: (try? c.decodeIfPresent(String.self, forKey: .username)).flatMap { $0 },
                  mailbox: (try? c.decodeIfPresent(String.self, forKey: .mailbox)).flatMap { $0 },
                  source: (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 })
    }
}
