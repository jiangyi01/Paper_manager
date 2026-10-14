import AppKit
import SwiftUI
import PaperDeckCore

/// The inbox header's status pill (`MailNoticePolicy.pill`): one short line — synced N min ago,
/// syncing, N accounts need attention, sync off, not set up — instead of a status line per account
/// and the triage usage. Its popover (`MailStatusPopover`) has the rest. `compact`: the icon only
/// (a narrow column), the line is its tooltip.
struct MailStatusPillLabel: View {
    let pill: MailStatusPill
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            icon
            if !compact {
                Text(Self.text(pill))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Self.textTint(pill))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Self.fill(pill)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Capsule())
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        if case .syncing = pill {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: Self.symbol(pill))
                .foregroundStyle(Self.iconTint(pill))
                .accessibilityHidden(true)
        }
    }

    static func text(_ pill: MailStatusPill) -> String {
        switch pill {
        case .notSetUp: return L.Mail.pillNotSetUp
        case .off: return L.Mail.pillOff
        case .paused: return L.Mail.pillPaused
        case .syncing: return L.Mail.syncing
        case .attention(let n, _): return L.Mail.pillAttention(n)
        case .synced(let at): return at.map { L.Mail.pillSynced(L.Mail.ago($0)) } ?? L.Mail.pillNotSynced
        }
    }

    static func symbol(_ pill: MailStatusPill) -> String {
        switch pill {
        case .notSetUp: return "envelope.badge"
        case .off, .paused: return "pause.circle"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .attention(_, let critical): return critical ? "key.slash" : "exclamationmark.triangle.fill"
        case .synced(let at): return at == nil ? "circle.dotted" : "checkmark.circle.fill"
        }
    }

    static func iconTint(_ pill: MailStatusPill) -> Color {
        switch pill {
        case .attention(_, let critical): return critical ? .red : .orange
        case .synced(let at): return at == nil ? .secondary : .green
        case .notSetUp: return .accentColor
        default: return .secondary
        }
    }

    static func textTint(_ pill: MailStatusPill) -> Color {
        if case .attention(_, let critical) = pill { return critical ? .red : .orange }
        return .secondary
    }

    static func fill(_ pill: MailStatusPill) -> Color {
        if case .attention(_, let critical) = pill { return (critical ? Color.red : Color.orange).opacity(0.1) }
        return Color.primary.opacity(0.05)
    }
}

/// The status pill's popover: every account (status, last sync, its warnings with their fixes,
/// ignored files), the AI triage (today's usage, emails waiting), and Sync Now · Import .eml… ·
/// Mail Settings….
struct MailStatusPopover: View {
    let state: AppState
    let snap: MailSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.Mail.accountsTitle).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if snap.enabled && !snap.accounts.isEmpty {
                    Button(state.mailSyncing ? L.Mail.syncing : L.Mail.syncNow) { state.syncMailNow() }
                        .controlSize(.small)
                        .disabled(state.mailSyncing)
                }
            }
            if snap.accounts.isEmpty || !snap.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snap.accounts.isEmpty ? L.Mail.setUpTitle : L.Mail.disabledTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(snap.accounts.isEmpty ? L.Mail.setUpBody : L.Mail.disabledBody)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L.Mail.setUp) { state.router.showSettings("mail") }
                        .controlSize(.small)
                }
            }
            ForEach(snap.accounts) { info in
                MailStatusAccountRow(state: state, info: info)
            }
            Divider()
            triage
            Divider()
            HStack(spacing: 8) {
                Button(L.Mail.importEML) { state.pickAndImportEML(window: NSApp.keyWindow) }
                    .controlSize(.small)
                Spacer(minLength: 8)
                Button(L.Mail.mailSettings) { state.router.showSettings("mail") }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder private var triage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.Mail.aiTriageTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if snap.aiMode == .ai {
                Label(L.Mail.triageUsage(used: snap.triageUsage.used, limit: snap.triageUsage.limit), systemImage: "sparkles")
                    .foregroundStyle(snap.triageUsage.isExhausted ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                if snap.triageQueued > 0 {
                    Label(L.Mail.triageQueued(snap.triageQueued), systemImage: "hourglass").foregroundStyle(.secondary)
                }
            } else {
                Label(L.Mail.triageLocalOnly, systemImage: "wand.and.stars")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
    }
}

/// One account in the status popover: name, status (synced N min ago / what's wrong), the
/// transport's detail, its notices with their fixes, and the quiet ignored-files line.
private struct MailStatusAccountRow: View {
    let state: AppState
    let info: MailAccountSyncInfo

    var body: some View {
        let s = Self.status(info)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: s.symbol)
                .font(.system(size: 12))
                .foregroundStyle(s.tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: MailInboxRules.line(info.displayName, limit: 60))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: s.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(s.problem ? AnyShapeStyle(s.tint) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = s.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ForEach(MailAccountNotice.notices(info, active: info.enabled), id: \.kind) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Label { Text(notice.text).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            .font(.system(size: 11.5))
                            .textSelection(.enabled)
                        DetailFlowLayout(spacing: 8, lineSpacing: 6) {
                            switch notice {
                            case .notEmail:
                                MailNotEmailActions(state: state, accountID: info.id, ignored: false)
                                Button(L.Mail.howToFix) { state.openPowerAutomateGuide(accountID: info.id) }
                                    .buttonStyle(.link)
                                    .controlSize(.small)
                            case .skipped:
                                Button(state.mailSyncing ? L.Mail.syncing : L.Mail.syncNow) { state.syncMailNow() }
                                    .controlSize(.small)
                                    .disabled(state.mailSyncing)
                                Button(L.Mail.hideNotice) { state.dismissSkippedNotice(accountID: info.id) }
                                    .controlSize(.small)
                                    .help(L.Mail.ignoreSkippedHelp)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                if info.kind == .folder, info.ignoredNotEmailFiles > 0 {
                    MailIgnoredFilesLine(state: state, accountID: info.id, count: info.ignoredNotEmailFiles)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Status line, icon, tint, whether the status itself is a problem (its text takes the tint),
    /// and the transport's detail ("Watching …", "Signed in as …").
    static func status(_ info: MailAccountSyncInfo) -> (text: String, symbol: String, tint: Color, problem: Bool, detail: String?) {
        if !info.enabled { return (L.Mail.accountPaused, "pause.circle", .secondary, false, nil) }
        if info.isSyncing { return (L.Mail.syncing, "arrow.triangle.2.circlepath", .secondary, false, nil) }
        let warned = MailNoticePolicy.needsAttention(info)
        switch MailNoticePolicy.shownStatus(info, active: true) {
        case nil:
            return (L.Mail.statusNotChecked, warned ? "exclamationmark.triangle.fill" : "circle.dotted",
                    warned ? .orange : .secondary, false, nil)
        case .ready(let detail)?:
            let synced = info.lastSuccessAt.map { L.Mail.pillSynced(L.Mail.ago($0)) } ?? L.Mail.statusReady
            return (synced, warned ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", warned ? .orange : .green, false, detail)
        case .needsSetup(let why)?:
            return (L.Mail.statusNeedsSetup(MailInboxRules.line(why, limit: 160)), "exclamationmark.circle", .orange, true, nil)
        case .authFailed(let why)?:
            return (L.Mail.statusAuthFailed(MailInboxRules.line(why, limit: 160)), "key.slash", .red, true, nil)
        case .unavailable(let why)?:
            return (L.Mail.statusUnavailable(MailInboxRules.line(why, limit: 160)), "wifi.exclamationmark", .orange, true, nil)
        }
    }
}
