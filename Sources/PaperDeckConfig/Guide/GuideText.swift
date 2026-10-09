import Foundation
import PaperDeckCore

/// Help Center search over titles, keywords, summaries and steps (en and zh tokens).
package enum GuideSearch {
    /// Topic ids matching every token of `q`, best first (the UI language counts more than the other).
    package static func search(_ q: String, lang: UILang) -> [GuideTopicID] {
        search(q, lang: lang, in: GuideCatalog.topics)
    }

    /// `search(_:lang:)` over `topics` (tests, previews).
    package static func search(_ q: String, lang: UILang, in topics: [GuideTopic]) -> [GuideTopicID] {
        let tokens = tokenize(q)
        guard !tokens.isEmpty else { return [] }
        let other: UILang = lang == .zh ? .en : .zh
        var scored: [(id: GuideTopicID, score: Int, order: Int)] = []
        for (order, t) in topics.enumerated() {
            let primary = fields(t, lang)
            let secondary = fields(t, other)
            let id = normalize(t.id.rawValue)
            var total = 0
            var all = true
            for token in tokens {
                let p = primary.score(token) * 2
                let s = secondary.score(token)
                let i = id.contains(token) ? 4 : 0
                let best = max(p, s, i)
                if best == 0 { all = false; break }
                total += best
            }
            if all { scored.append((t.id, total, order)) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.id)
    }

    /// Lower-cased, diacritics folded, split on spaces and punctuation (CJK runs stay whole and
    /// match as substrings).
    static func tokenize(_ q: String) -> [String] {
        normalize(q).split { $0.isWhitespace || ($0.isPunctuation && $0 != "-") || $0.isSymbol }
            .map(String.init).filter { !$0.isEmpty }
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private struct Fields {
        var title: String, keywords: String, summary: String, steps: String
        func score(_ token: String) -> Int {
            if title.contains(token) { return 8 }
            if keywords.contains(token) { return 6 }
            if summary.contains(token) { return 3 }
            if steps.contains(token) { return 1 }
            return 0
        }
    }

    private static func fields(_ t: GuideTopic, _ lang: UILang) -> Fields {
        Fields(title: normalize(t.title(lang)),
               keywords: normalize(t.keywords.map { $0(lang) }.joined(separator: " ")),
               summary: normalize(t.summary(lang)),
               steps: normalize(t.steps.map { $0.text(lang) }.joined(separator: " ")))
    }
}

/// Markdown of guide topics (`--guide-export`, the generated blocks of docs/TROUBLESHOOTING.md).
/// Deterministic: the same topics give the same bytes.
package enum GuideMarkdown {
    /// The block between `<!-- BEGIN GENERATED: troubleshooting <lang> -->` and its END marker in
    /// docs/TROUBLESHOOTING.md: every troubleshooting topic, in catalog order.
    package static func troubleshooting(lang: UILang, topics: [GuideTopic] = GuideCatalog.topics) -> String {
        render(topics.filter { $0.kind == .troubleshoot }, lang: lang)
    }

    /// Where a link to a topic that isn't in the rendered set points: docs/USER_GUIDE.md, next to
    /// docs/TROUBLESHOOTING.md, has an anchor for every topic id.
    package static let otherTopicsDocument = "USER_GUIDE.md"

    /// `#id` for a topic in `topics`, else `USER_GUIDE.md#id` (a troubleshooting block's related
    /// tutorials live in the user guide).
    static func href(_ id: GuideTopicID, in topics: [GuideTopic]) -> String {
        topics.contains { $0.id == id } ? "#\(id.rawValue)" : "\(otherTopicsDocument)#\(id.rawValue)"
    }

    package static func render(_ topics: [GuideTopic], lang: UILang) -> String {
        var out: [String] = []
        for t in topics {
            out.append("<a id=\"\(t.id.rawValue)\"></a>")
            out.append("### \(t.title(lang))")
            out.append("")
            let summary = t.summary(lang).trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                out.append(summary)
                out.append("")
            }
            for (i, step) in t.steps.enumerated() {
                out.append("\(i + 1). \(step.text(lang).trimmingCharacters(in: .whitespacesAndNewlines))")
                for command in step.commands {
                    out.append("")
                    out.append("   ```")
                    out.append("   \(command)")
                    out.append("   ```")
                }
                let links = step.actions.compactMap(link(lang, topics))
                if !links.isEmpty {
                    out.append("")
                    out.append("   " + links.joined(separator: " · "))
                }
            }
            if !t.steps.isEmpty { out.append("") }
            let related = t.related.map { id -> String in
                let title = topics.first { $0.id == id }?.title(lang) ?? GuideCatalog.topic(id)?.title(lang) ?? id.rawValue
                return "[\(title)](\(href(id, in: topics)))"
            }
            if !related.isEmpty {
                out.append("**\(lang == .zh ? "相关" : "Related"):** " + related.joined(separator: ", "))
                out.append("")
            }
            out.append("*\(lang == .zh ? "最近核对" : "Last reviewed"): \(t.lastReviewed)*")
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func link(_ lang: UILang, _ topics: [GuideTopic]) -> (GuideAction) -> String? {
        { action in
            switch action {
            case .openURL(let url):
                guard GuideLinks.isAllowed(url) else { return nil }
                return "[\(url.host ?? url.absoluteString)](\(url.absoluteString))"
            case .openTopic(let id):
                let title = topics.first { $0.id == id }?.title(lang) ?? GuideCatalog.topic(id)?.title(lang) ?? id.rawValue
                return "[\(title)](\(href(id, in: topics)))"
            default:
                return nil
            }
        }
    }
}

/// The official sites a guide may link to (`GuideAction.openURL`): https only, these hosts only.
package enum GuideLinks {
    package static let allowedHosts: Set<String> = [
        "make.powerautomate.com", "myaccount.google.com", "script.google.com", "account.apple.com",
        "support.apple.com", "support.google.com", "support.microsoft.com", "claude.ai", "chatgpt.com",
        "openai.com", "login.yahoo.com", "app.fastmail.com",
    ]

    package static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}

/// The copyable diagnostics text (redacted: home → `~`, email local parts masked, never titles,
/// subjects or secrets — `SetupFacts` holds none of those).
package enum DiagnosticsReport {
    package static func render(_ f: SetupFacts, identity: BuildIdentity, config: ConfigSnapshot, appVersion: String,
                               home: String, redact: Bool) -> String {
        var lines: [String] = []
        func add(_ key: String, _ value: String) { lines.append("\(key): \(value)") }
        func path(_ p: String) -> String { redact ? tilde(p, home: home) : p }

        lines.append("PaperDeck diagnostics")
        add("Version", appVersion)
        add("Bundle id", identity.bundleID)
        add("Widget id", identity.widgetBundleID)
        add("Keychain service", identity.keychainService)
        add("Channel", identity.channel.rawValue)
        switch f.app {
        case .value(let a): add("Location", "\(a.location.rawValue) · quarantined \(yesNo(a.quarantined))")
        default: add("Location", probe(f.app))
        }
        switch f.signing {
        case .value(let s):
            switch s.kind {
            case .certificate(let name): add("Signing", "certificate \"\(name)\"")
            case .adhoc: add("Signing", "ad hoc")
            case .unsigned: add("Signing", "unsigned")
            }
        default: add("Signing", probe(f.signing))
        }

        switch f.library {
        case .value(let l):
            var parts = [path(l.tildePath), l.status.rawValue, l.volume.rawValue, "manifest \(yesNo(l.hasManifest))"]
            if let id = l.identity { parts.append("identity \(identityText(id))") }
            add("Library", parts.joined(separator: " · "))
        default: add("Library", probe(f.library))
        }
        switch f.papers {
        case .value(let p):
            add("Papers", "\(p.live) (cards \(p.withCard), opened \(p.opened), missing files \(p.missingFiles), full text \(p.fullTextIndexed))")
        default: add("Papers", probe(f.papers))
        }

        add("AI", "mode \(f.ai.mode.rawValue) · provider \(f.ai.provider.rawValue) · decision \(f.ai.decision ?? "—")"
            + (f.ai.pausedUntil.map { " · paused until \(stamp($0))" } ?? ""))
        for kind in AIProviderKind.allCases {
            let line: String
            switch f.ai.statuses[kind] {
            case .value(let s)?: line = providerText(s, path: path)
            case .checking?: line = "checking"
            case .unknown?, nil: line = "not checked"
            }
            lines.append("  \(kind.shortName): \(line)")
        }

        switch f.notifications {
        case .value(let n): add("Notifications", "\(n.authorization.rawValue) · reminder \(n.reminderEnabled ? "on" : "off")")
        default: add("Notifications", probe(f.notifications))
        }
        switch f.loginItem {
        case .value(let l): add("Open at login", l.status.rawValue)
        default: add("Open at login", probe(f.loginItem))
        }
        switch f.widget {
        case .value(let w): add("Widget", w.registration.rawValue + (w.placedCount.map { " · placed \($0)" } ?? ""))
        default: add("Widget", probe(f.widget))
        }

        add("Mail", "\(f.mail.enabled ? "on" : "off") · \(f.mail.accounts.count) account(s) · decision \(f.mail.decision ?? "—")")
        for (i, a) in f.mail.accounts.enumerated() {
            var parts = [a.source.rawValue, a.status.map(statusText) ?? "not checked"]
            if let at = a.lastSuccessAt { parts.append("last sync \(stamp(at))") }
            parts.append("captured \(a.captured)")
            if a.notEmailFiles > 0 { parts.append("not-email files \(a.notEmailFiles)") }
            if let pw = a.passwordPresent { parts.append("password saved \(yesNo(pw))") }
            if let fe = a.folderExists { parts.append("folder exists \(yesNo(fe))") }
            lines.append("  account \(i + 1): " + parts.joined(separator: " · "))
        }
        let senders = SenderKind.allCases.map { "\($0.rawValue) \(f.mail.senders[$0] ?? 0)" }
        add("Senders", senders.joined(separator: ", "))
        switch f.cloud {
        case .value(let c):
            let names = c.roots.map { "\($0.provider.rawValue) \(redact ? maskRootName($0.name) : $0.name)" }
            add("Cloud folders", names.isEmpty ? "none" : names.joined(separator: ", "))
        default: add("Cloud folders", probe(f.cloud))
        }
        add("Config", "org \(config.organization.id) · field \(config.field.id) · stage \(config.stage.rawValue)"
            + " · origin \(config.origin.rawValue) · dates \(config.mailDateOrder.rawValue)"
            + " · reader \(config.readerOverride == nil ? "composed" : "custom")")
        add("Profile stored", "field \(f.profile.fieldID ?? "—") · org \(f.profile.organizationID ?? "—")")
        add("Settings transfer", "exported \(f.transfer.lastExportedAt.map(stamp) ?? "never") · imported \(f.transfer.importedAt.map(stamp) ?? "never")")
        let activity = GuideActivityKind.allCases.filter { f.activity[$0] != nil }.map(\.rawValue)
        add("First uses", activity.isEmpty ? "none" : activity.joined(separator: ", "))

        let text = lines.joined(separator: "\n") + "\n"
        return redact ? maskEmails(tilde(text, home: home)) : text
    }

    // MARK: Redaction

    /// Every occurrence of `home` (followed by `/` or the end) becomes `~`.
    package static func tilde(_ s: String, home: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard h.count > 1 else { return s }
        var out = s.replacingOccurrences(of: h + "/", with: "~/")
        if out.hasSuffix(h) { out = String(out.dropLast(h.count)) + "~" }
        return out.replacingOccurrences(of: h + "\n", with: "~\n").replacingOccurrences(of: h + " ", with: "~ ")
    }

    /// `GoogleDrive-jane@example.com` → `GoogleDrive-j***@example.com` (the provider prefix stays).
    package static func maskRootName(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-"), name[dash...].contains("@") else { return maskEmails(name) }
        return String(name[...dash]) + maskEmails(String(name[name.index(after: dash)...]))
    }

    /// `jane.doe@example.edu` → `j***@example.edu`.
    package static func maskEmails(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\\.[A-Za-z]{2,})") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1***@$2")
    }

    // MARK: Formatting

    private static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    private static func probe<T>(_ p: ProbeState<T>) -> String {
        switch p {
        case .unknown: return "not checked"
        case .checking: return "checking"
        case .value: return "known"
        }
    }

    private static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func identityText(_ c: LibraryIdentityCheck) -> String {
        switch c {
        case .match: return "match"
        case .noManifest: return "no manifest"
        case .unreadableManifest: return "unreadable manifest"
        case .emptyIndex: return "empty index"
        case .mismatch(_, _, let n): return "MISMATCH (index has \(n) papers)"
        }
    }

    private static func providerText(_ s: ProviderStatus, path: (String) -> String) -> String {
        switch s {
        case .ready(let plan, let version, let p):
            return ["ready", plan ?? "subscription", version, path(p)].filter { !$0.isEmpty }.joined(separator: " · ")
        case .notInstalled: return "not installed"
        case .notLoggedIn(let code): return "not signed in (\(code))"
        case .unsupported(let code): return "unsupported (\(code))"
        }
    }

    private static func statusText(_ s: MailSourceStatus) -> String {
        switch s {
        case .ready: return "ready"
        case .needsSetup: return "needs setup"
        case .authFailed: return "sign-in failed"
        case .unavailable: return "unavailable"
        }
    }
}
