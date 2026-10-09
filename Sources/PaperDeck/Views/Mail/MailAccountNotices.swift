import AppKit
import SwiftUI
import PaperDeckCore

/// What an account needs from the user beyond its status line, shown as a notice of its own with
/// its action — under the account's row in Settings ▸ Mail ▸ Accounts and in the inbox header:
/// - files in a watched folder that are not complete emails → the Power Automate guide;
/// - allowlisted emails skipped because the account's retry list was full → 「立即同步」, which
///   lists the account's look-back again (headers only) to pick them up. The sentence is the
///   engine's `MailAccountSyncInfo.skippedHint`, worded in the UI language.
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
        if active, info.skipped > 0, let hint = info.skippedHint, !hint.isEmpty {
            out.append(.skipped(count: info.skipped, hint: hint))
        }
        return out
    }

    /// The inbox header's notices: every account's, in Settings order.
    static func inbox(_ accounts: [MailAccountSyncInfo]) -> [Entry] {
        accounts.flatMap { info in notices(info, active: info.enabled).map { Entry(info: info, notice: $0) } }
    }

    struct Entry: Identifiable {
        let info: MailAccountSyncInfo
        let notice: MailAccountNotice
        var id: String { info.id + "/" + notice.kind }
    }

    /// The status to show next to the notices. After a pass that still has skipped emails the
    /// engine appends the skipped sentence to a ready status (`… · <skippedHint>`, a warning); while
    /// the skipped notice says it, the status line doesn't repeat it — and is ready again unless the
    /// account also has emails it couldn't download. Any other status is shown as it is.
    static func shownStatus(_ info: MailAccountSyncInfo?, active: Bool) -> MailSourceStatus? {
        guard let info, let status = info.status else { return nil }
        guard skippedCount(info, active: active) != nil, let hint = info.skippedHint,
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

    /// The skipped count the inbox's account line adds (「· 跳过 3 封邮件」), nil without a notice.
    static func skippedCount(_ info: MailAccountSyncInfo, active: Bool) -> Int? {
        for case .skipped(let n, _) in notices(info, active: active) { return n }
        return nil
    }
}

/// The inbox header's notice for allowlisted emails skipped because the retry list was full:
/// the account, the engine's sentence, and 「立即同步」.
struct MailSkippedNotice: View {
    let state: AppState
    let info: MailAccountSyncInfo
    let hint: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: MailInboxRules.line(info.displayName, limit: 40))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: hint)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(state.mailSyncing ? L.Mail.syncing : L.Mail.syncNow) { state.syncMailNow() }
                .controlSize(.small)
                .disabled(state.mailSyncing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }
}
