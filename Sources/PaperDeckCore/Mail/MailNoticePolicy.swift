import Foundation

// What the Mail inbox says about its accounts (the decluttered header): one status pill — its
// popover lists every account, the last sync, warnings and today's triage usage — and at most
// one notice, the most serious real problem. Pure rules over `MailAccountSyncInfo`, so the app's
// header, its popover and Settings ▸ Mail agree, and the tests can reach them.

/// A problem the inbox may raise as a notice, most serious first.
package enum MailNoticeKind: String, Sendable, CaseIterable {
    case authFailed     // the server rejected the sign-in
    case needsSetup     // something to configure (no password saved, not a folder…)
    case unavailable    // a watched folder that can't be read, or an account failing again and again
    case notEmail       // files in a watched folder that aren't emails (not ignored)
    case skipped        // allowlisted emails skipped because the retry list was full (not dismissed)

    package var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    /// Dismissed per session only (it says so again after a relaunch, or when its sentence changes);
    /// the other two have their own persistent dismissal (Ignore / dismiss until the count grows).
    package var isStatus: Bool { self == .authFailed || self == .needsSetup || self == .unavailable }
}

/// One notice for one account.
package struct MailNotice: Sendable, Equatable, Identifiable {
    package var accountID: String
    package var accountName: String
    package var kind: MailNoticeKind
    /// notEmail / skipped: how many.
    package var count: Int
    /// The account's status sentence (status kinds) or the engine's hint (UI language).
    package var text: String

    package init(accountID: String, accountName: String, kind: MailNoticeKind, count: Int = 0, text: String) {
        self.accountID = accountID; self.accountName = accountName; self.kind = kind; self.count = count; self.text = text
    }

    package var id: String { accountID + "/" + kind.rawValue }
    /// The key a session dismissal (✕) remembers: another sentence (a different error) or another
    /// count shows the notice again.
    package var dismissKey: String { id + "|" + (kind.isStatus ? text : String(count)) }
}

/// The status pill's state.
package enum MailStatusPill: Sendable, Equatable {
    /// No account configured.
    case notSetUp
    /// The master switch is off.
    case off
    /// Every account is paused.
    case paused
    case syncing
    /// Accounts with a problem (`critical`: a rejected sign-in among them).
    case attention(accounts: Int, critical: Bool)
    /// Everything fine; the latest successful sync (nil: none yet).
    case synced(Date?)
}

package enum MailNoticePolicy {
    /// The status to show for an account. A pass that got through while allowlisted emails stay
    /// skipped appends the skipped sentence to its ready status (`… · <skippedHint>`, a warning):
    /// while the account syncs (`active`) that sentence is the skipped notice's — or was dismissed —
    /// so the status leaves it out, and is ready again unless the account also has emails it
    /// couldn't download. Any other status is shown as it is.
    package static func shownStatus(_ info: MailAccountSyncInfo?, active: Bool) -> MailSourceStatus? {
        guard let info, let status = info.status else { return nil }
        guard active, info.skipped > 0, let hint = info.skippedHint, !hint.isEmpty,
              case .unavailable(let text) = status else { return status }
        let rest: String
        if text == hint {
            rest = ""
        } else if text.contains(" · " + hint) {
            rest = text.replacingOccurrences(of: " · " + hint, with: "")
        } else {
            return status                                   // not the pipeline's suffix: as it is
        }
        return info.undownloadable > 0 ? .unavailable(rest) : .ready(detail: rest)
    }

    /// The account's last pass reached its server or folder: it succeeded (no failure since), even
    /// when it left allowlisted emails skipped or undownloadable — the `.unavailable` status the
    /// pipeline gives such a pass (`ready detail · <sentence>`) words those emails, not the connection.
    /// A sign-in or setup problem never counts.
    package static func reachable(_ info: MailAccountSyncInfo) -> Bool {
        guard info.consecutiveFailures == 0, info.lastSuccessAt != nil else { return false }
        switch info.status {
        case .ready?, .unavailable?: return true
        case .authFailed?, .needsSetup?, nil: return false
        }
    }

    /// Whether the skipped notice is due: the account syncs, emails are skipped, the engine worded
    /// the hint, and the count grew past the one the user dismissed it at.
    package static func skippedNoticeDue(_ info: MailAccountSyncInfo, active: Bool) -> Bool {
        active && info.skipped > 0 && !(info.skippedHint ?? "").isEmpty && info.skipped > info.skippedDismissed
    }

    /// An `unavailable` status worth a notice: a watched folder that can't be read (missing,
    /// permission), or any account that failed three passes in a row. A server that is briefly
    /// unreachable, or emails that are still being retried, only tint the pill.
    static let unavailableFailures = 3

    /// Every account's notices, most serious first (Settings order within a kind), without the
    /// ones in `dismissed` (`MailNotice.dismissKey`).
    package static func notices(_ accounts: [MailAccountSyncInfo], dismissed: Set<String> = []) -> [MailNotice] {
        var out: [MailNotice] = []
        for info in accounts {
            let active = info.enabled
            let name = info.displayName
            if active, let status = shownStatus(info, active: true) {
                switch status {
                case .authFailed(let why):
                    out.append(MailNotice(accountID: info.id, accountName: name, kind: .authFailed, text: why))
                case .needsSetup(let why):
                    out.append(MailNotice(accountID: info.id, accountName: name, kind: .needsSetup, text: why))
                case .unavailable(let why) where info.consecutiveFailures > 0
                    && (info.kind == .folder || info.consecutiveFailures >= unavailableFailures):
                    out.append(MailNotice(accountID: info.id, accountName: name, kind: .unavailable, text: why))
                default:
                    break
                }
            }
            if info.kind == .folder, info.notEmailFiles > 0 {
                out.append(MailNotice(accountID: info.id, accountName: name, kind: .notEmail, count: info.notEmailFiles,
                                      text: info.notEmailHint ?? ""))
            }
            if skippedNoticeDue(info, active: active) {
                out.append(MailNotice(accountID: info.id, accountName: name, kind: .skipped, count: info.skipped,
                                      text: info.skippedHint ?? ""))
            }
        }
        let order = Dictionary(accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return out.filter { !dismissed.contains($0.dismissKey) }
            .sorted { ($0.kind.rank, order[$0.accountID] ?? 0) < ($1.kind.rank, order[$1.accountID] ?? 0) }
    }

    /// Whether an account needs the user (the pill's count): a status that isn't ready, files
    /// that aren't emails, or skipped emails not dismissed. Paused accounts only for their files.
    package static func needsAttention(_ info: MailAccountSyncInfo) -> Bool {
        if info.kind == .folder, info.notEmailFiles > 0 { return true }
        guard info.enabled else { return false }
        if skippedNoticeDue(info, active: true) { return true }
        switch shownStatus(info, active: true) {
        case .authFailed?, .needsSetup?, .unavailable?: return true
        case .ready?, nil: return false
        }
    }

    /// The pill: off / not set up / paused, syncing, the accounts needing attention, else the
    /// latest successful sync of the syncing accounts.
    package static func pill(_ accounts: [MailAccountSyncInfo], enabled: Bool) -> MailStatusPill {
        guard !accounts.isEmpty else { return .notSetUp }
        guard enabled else { return .off }
        let active = accounts.filter(\.enabled)
        guard !active.isEmpty else { return .paused }
        if active.contains(where: \.isSyncing) { return .syncing }
        let troubled = accounts.filter(needsAttention)
        if !troubled.isEmpty {
            let critical = troubled.contains { info in
                if case .authFailed? = info.status { return info.enabled }
                return false
            }
            return .attention(accounts: troubled.count, critical: critical)
        }
        return .synced(active.compactMap(\.lastSuccessAt).max())
    }
}

/// The chips a list card may show, most important first.
package enum MailCardChipKind: Int, Sendable, CaseIterable, Comparable {
    case unverified     // DKIM / DMARC failed: always shown
    case due            // the email's due date
    case priorityHigh   // the triage's high priority (low is not shown in the list)
    case request        // 导师请求 / Alert / FYI…

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// List-card density: the most important `max` chips, the rest collapse into one "+N".
package enum MailCardDensity {
    package static let maxChips = 2

    package static func chips(_ kinds: [MailCardChipKind], max: Int = maxChips) -> (shown: [MailCardChipKind], hidden: [MailCardChipKind]) {
        let sorted = Array(Set(kinds)).sorted()
        let n = Swift.max(0, max)
        return (Array(sorted.prefix(n)), Array(sorted.dropFirst(n)))
    }
}
