import AppKit
import SwiftUI
import PaperDeckCore

/// What an account needs from the user beyond its status line, under the account's row in
/// Settings ▸ Mail ▸ Accounts (the inbox header shows at most one notice for every account —
/// `MailNoticePolicy.notices` — and lists the rest in its status popover):
/// - files in a watched folder that are not complete emails and that the user hasn't ignored →
///   Move to Trash… · Ignore · the Power Automate guide;
/// - allowlisted emails skipped because the account's retry list was full (and the notice not
///   hidden since the count last grew) → 「立即同步」, which lists the account's look-back again
///   (headers only) to pick them up. The sentence is the engine's `MailAccountSyncInfo.skippedHint`,
///   worded in the UI language.
enum MailAccountNotice: Equatable {
    case notEmail(files: Int)
    case skipped(count: Int, hint: String)

    enum Action: Equatable {
        case openGuide
        case syncNow
    }

    var action: Action {
        switch self {
        case .notEmail: .openGuide
        case .skipped: .syncNow
        }
    }

    /// The notice's sentence (UI language).
    var text: String {
        switch self {
        case .notEmail(let n): MailSyncText.notEmailFiles(n, L.lang)
        case .skipped(_, let hint): hint
        }
    }

    var kind: String {
        switch self {
        case .notEmail: "not-email"
        case .skipped: "skipped"
        }
    }

    /// One account's notices, in order. `active`: the account syncs (mail on, account not paused);
    /// only then is the skipped notice shown — its 「立即同步」 syncs active accounts only.
    static func notices(_ info: MailAccountSyncInfo?, active: Bool) -> [MailAccountNotice] {
        guard let info else { return [] }
        var out: [MailAccountNotice] = []
        if info.notEmailFiles > 0 { out.append(.notEmail(files: info.notEmailFiles)) }
        if MailNoticePolicy.skippedNoticeDue(info, active: active), let hint = info.skippedHint {
            out.append(.skipped(count: info.skipped, hint: hint))
        }
        return out
    }

    /// The status to show next to the notices (`MailNoticePolicy.shownStatus`): without the
    /// skipped sentence the pipeline appends while the account syncs.
    static func shownStatus(_ info: MailAccountSyncInfo?, active: Bool) -> MailSourceStatus? {
        MailNoticePolicy.shownStatus(info, active: active)
    }
}

/// Notices hidden with ✕ this session (the status notices and the setup notice: they come back
/// after a relaunch, or when their sentence changes). Files and skipped emails have their own,
/// lasting dismissal in the engine (Ignore / hidden until the count grows).
@Observable
final class MailNoticeDismissals {
    static let shared = MailNoticeDismissals()
    private(set) var keys: Set<String> = []

    func dismiss(_ key: String) { keys.insert(key) }
    func isDismissed(_ key: String) -> Bool { keys.contains(key) }
    /// Renders only (`MailWidthRenders`): the session's dismissals as they were.
    func restore(_ saved: Set<String>) { keys = saved }
}

// MARK: - The inbox's one notice

/// The inbox header's notice — the most serious real problem (`MailNoticePolicy.notices`, first):
/// one line with its account, the fix's buttons, and ✕ / Ignore; "+N more" opens the status
/// popover when other accounts need something too. The full sentence is the line's tooltip.
struct MailInboxNoticeView: View {
    let state: AppState
    let notice: MailNotice
    /// Other notices behind this one.
    let more: Int
    let onShowAll: () -> Void

    private var tint: Color { notice.kind == .authFailed ? .red : .orange }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                icon
                line.frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 8)
                actions
                close
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    line
                    Spacer(minLength: 4)
                    close
                }
                DetailFlowLayout(spacing: 8, lineSpacing: 6) { actionItems }
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: notice.kind == .authFailed ? "key.slash" : "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    /// One primary line; the engine's whole sentence (the fix) is its tooltip.
    private var line: some View {
        Text(verbatim: Self.title(notice))
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(notice.text)
            .textSelection(.enabled)
    }

    /// The notice's line (UI language; account names are shown verbatim).
    static func title(_ n: MailNotice) -> String {
        let name = MailInboxRules.line(n.accountName, limit: 40)
        switch n.kind {
        case .notEmail: return L.Mail.notEmailNotice(n.count, account: name)
        case .skipped: return L.Mail.skippedNotice(n.count, account: name)
        case .authFailed: return L.Mail.accountLine(name: name, status: L.Mail.statusAuthFailed(MailInboxRules.line(n.text, limit: 90)))
        case .needsSetup: return L.Mail.accountLine(name: name, status: L.Mail.statusNeedsSetup(MailInboxRules.line(n.text, limit: 90)))
        case .unavailable: return L.Mail.accountLine(name: name, status: L.Mail.statusUnavailable(MailInboxRules.line(n.text, limit: 90)))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) { actionItems }.fixedSize()
    }

    @ViewBuilder private var actionItems: some View {
        switch notice.kind {
        case .notEmail:
            MailNotEmailActions(state: state, accountID: notice.accountID, ignored: false)
            Button(L.Mail.howToFix) { state.openPowerAutomateGuide(accountID: notice.accountID) }
                .buttonStyle(.link)
                .controlSize(.small)
                .help(L.Mail.powerAutomateGuide)
        case .skipped:
            Button(state.mailSyncing ? L.Mail.syncing : L.Mail.syncNow) { state.syncMailNow() }
                .controlSize(.small)
                .disabled(state.mailSyncing)
        case .authFailed, .needsSetup, .unavailable:
            Button(L.Mail.mailSettings) { state.router.showSettings("mail") }
                .controlSize(.small)
        }
        if more > 0 {
            Button(L.Mail.moreNotices(more), action: onShowAll)
                .buttonStyle(.link)
                .controlSize(.small)
                .help(L.Mail.moreNoticesHelp)
        }
    }

    /// ✕: Ignore for files has its own button; skipped emails hide until the count grows;
    /// status notices hide for this session.
    @ViewBuilder private var close: some View {
        if notice.kind != .notEmail {
            Button {
                if notice.kind == .skipped {
                    state.dismissSkippedNotice(accountID: notice.accountID)
                } else {
                    MailNoticeDismissals.shared.dismiss(notice.dismissKey)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(notice.kind == .skipped ? L.Mail.ignoreSkippedHelp : L.Mail.hideNoticeHelp)
            .accessibilityLabel(L.Mail.hideNotice)
        }
    }
}

// MARK: - Files that aren't emails

/// [Move to Trash…] [Ignore] for a folder account's not-email files — the notice's (`ignored`
/// false) or, in the ignored files' popover, the ignored ones (Ignore becomes Stop Ignoring there).
struct MailNotEmailActions: View {
    let state: AppState
    let accountID: String
    let ignored: Bool

    var body: some View {
        Button(L.Mail.moveToTrash) { state.trashNotEmailFiles(accountID: accountID, ignored: ignored) }
            .controlSize(.small)
            .help(L.Mail.moveToTrashHelp)
        if ignored {
            Button(L.Mail.stopIgnoring) { state.unignoreNotEmailFiles(accountID: accountID) }
                .controlSize(.small)
        } else {
            Button(L.Mail.ignore) { state.ignoreNotEmailFiles(accountID: accountID) }
                .controlSize(.small)
                .help(L.Mail.ignoreFilesHelp)
        }
    }
}

/// The quiet 「1 ignored file · Show」 line (Settings ▸ Mail, the status popover): Show opens what
/// they are, with Show in Finder, Move to Trash… and Stop Ignoring.
struct MailIgnoredFilesLine: View {
    let state: AppState
    let accountID: String
    let count: Int
    @State private var showing = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text(L.Mail.ignoredFiles(count))
            Text(verbatim: "·").accessibilityHidden(true)
            Button(L.Mail.showIgnored) { showing.toggle() }
                .buttonStyle(.link)
                .foregroundStyle(.tint)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.Mail.ignoredExplain)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        DetailFlowLayout(spacing: 8, lineSpacing: 6) {
                            Button(L.Mail.showInFinder) { state.revealNotEmailFiles(accountID: accountID, ignored: true) }
                                .controlSize(.small)
                            MailNotEmailActions(state: state, accountID: accountID, ignored: true)
                        }
                    }
                    .padding(14)
                    .frame(width: 320, alignment: .leading)
                }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }
}
