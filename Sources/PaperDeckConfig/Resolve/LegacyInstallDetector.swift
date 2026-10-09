import Foundation
import PaperDeckCore

/// Whether a defaults domain belongs to an install from before institutions were configurable
/// (PORTABILITY_PLAN §2.6), and which markers of the legacy institution preset it carries
/// (diagnostics only — every legacy install maps to that preset, markers or not).
package enum LegacyInstallDetector {
    /// Keys only an existing install has persisted (registered defaults never count: the domain
    /// holds persisted values only).
    package static let userKeys = ["setup.completed", "library.path", "mail.accounts", "mail.senders", "agent.provider"]

    /// Legacy: the library database exists, or the domain holds a user key, or an AI mode other
    /// than off — a `--dev` build writes only `agent.mode = off`, which alone is not an install.
    package static func isLegacy(_ p: PersistedDomain, databaseExists: Bool) -> Bool {
        if databaseExists { return true }
        if userKeys.contains(where: p.has) { return true }
        if let mode = p.string("agent.mode"), mode != "off" { return true }
        return false
    }

    /// Which of the legacy preset's markers the domain carries: a mail folder under its OneDrive
    /// root, an account named with its short name, a sender in one of its domains. Never values
    /// (no paths or addresses): just which kind matched.
    package static func markers(_ p: PersistedDomain) -> [String] {
        let org = OrganizationPresets.legacyInstallPreset
        var out: [String] = []
        let accounts = MailSettings.list(p.string(MailSettings.Keys.accounts), MailAccount.self, what: "account")
        if let hint = org.mail.oneDriveRootHint?.lowercased(), !hint.isEmpty,
           accounts.contains(where: { ($0.folderPath ?? "").lowercased().contains(hint) }) {
            out.append("mail.accounts.folderPath")
        }
        if let short = org.shortName?.lowercased(), !short.isEmpty,
           accounts.contains(where: { $0.displayName.lowercased().contains(short) }) {
            out.append("mail.accounts.displayName")
        }
        let senders = MailSettings.list(p.string(MailSettings.Keys.senders), SenderRule.self, what: "sender")
        let domains = org.mail.knownSenderDomains.map { $0.lowercased() }
        if senders.contains(where: { rule in
            let pattern = rule.pattern.lowercased()
            return domains.contains { pattern.hasSuffix("@" + $0) || pattern.hasSuffix("." + $0) }
        }) {
            out.append("mail.senders.domain")
        }
        return out
    }
}
