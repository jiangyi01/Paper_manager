import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Library ▸ 邮件 (MAIL_DESIGN Part A §3): a centred list (max width 820) of email cards with the
/// segmented filter 待处理 · 稍后 · 已处理 · 已忽略 · 无阅读需求, account / triage status and
/// 立即同步 / 导入 .eml…. The list is the coordinate space of the per-row drop boxes
/// (`DropTargetRegistry.space`, anchored by `DropSpaceAnchor`).
struct MailInboxView: View {
    @Bindable var state: AppState
    /// This list's drop space (`DropTargetRegistry`): its anchor and zones come and go with it.
    @State private var dropSpace = UUID().uuidString

    var body: some View {
        Group {
            if let snap = state.mailSnapshot {
                list(snap)
            } else {
                ProgressView(L.Mail.loading)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { state.scheduleMailRefresh(delay: .zero) }
    }

    private func list(_ snap: MailSnapshot) -> some View {
        let cards = snap.cards(state.mailFilter)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    MailInboxHeader(state: state, snap: snap)
                        .padding(.bottom, 2)
                    if cards.isEmpty {
                        MailInboxEmpty(state: state, filter: state.mailFilter, snap: snap)
                            .padding(.top, 30)
                    } else {
                        ForEach(cards) { card in
                            MailCardView(state: state, card: card, aiMode: snap.aiMode)
                                .id(card.id)
                        }
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .environment(\.mailDropSpace, dropSpace)
            .coordinateSpace(.named(DropTargetRegistry.space))
            .background(DropSpaceAnchor(registry: state.dropTargets, space: dropSpace))
            .onChange(of: state.selectedMailID, initial: true) { _, id in
                guard let id, cards.contains(where: { $0.id == id }) else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
    }
}

// MARK: - Header

/// Filter, counts, account status and the inbox actions.
struct MailInboxHeader: View {
    @Bindable var state: AppState
    let snap: MailSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Never truncated: the buttons lose their titles first (icon + tooltip), then the
            // segmented filter becomes a pop-up menu.
            ViewThatFits(in: .horizontal) {
                toolbar(segmented: true, iconOnly: false)
                toolbar(segmented: true, iconOnly: true)
                toolbar(segmented: false, iconOnly: false)
                toolbar(segmented: false, iconOnly: true)
            }
            if !snap.enabled || snap.accounts.isEmpty {
                MailSetupNotice(state: state, enabled: snap.enabled, hasAccounts: !snap.accounts.isEmpty)
            } else {
                statusLines
            }
            // Each account's notices (`MailAccountNotice`): files that aren't emails → the guide;
            // emails skipped because the retry list was full → 「立即同步」.
            ForEach(MailAccountNotice.inbox(snap.accounts)) { entry in
                switch entry.notice {
                case .notEmail:
                    MailNotEmailNotice(state: state, info: entry.info)
                case .skipped(_, let hint):
                    MailSkippedNotice(state: state, info: entry.info, hint: hint)
                }
            }
        }
    }

    private func toolbar(segmented: Bool, iconOnly: Bool) -> some View {
        HStack(spacing: 10) {
            filterPicker(segmented: segmented)
            Spacer(minLength: 8)
            toolbarButton(L.Mail.importEML, symbol: "tray.and.arrow.down", iconOnly: iconOnly) {
                state.pickAndImportEML(window: NSApp.keyWindow)
            }
            if snap.enabled && !snap.accounts.isEmpty {
                toolbarButton(state.mailSyncing ? L.Mail.syncing : L.Mail.syncNow, symbol: "arrow.clockwise",
                              iconOnly: iconOnly) { state.syncMailNow() }
                    .disabled(state.mailSyncing)
            }
        }
    }

    @ViewBuilder private func filterPicker(segmented: Bool) -> some View {
        let picker = Picker(L.Mail.filterLabel, selection: $state.mailFilter) {
            ForEach(MailInboxFilter.allCases) { f in
                Text(L.Mail.filterWithCount(f, count(f))).tag(f)
            }
        }
        .labelsHidden()
        if segmented {
            picker.pickerStyle(.segmented).fixedSize()
        } else {
            picker.pickerStyle(.menu).fixedSize()
        }
    }

    @ViewBuilder private func toolbarButton(_ title: String, symbol: String, iconOnly: Bool,
                                            action: @escaping () -> Void) -> some View {
        let button = Button(action: action) { Label(title, systemImage: symbol) }
            .controlSize(.small)
            .fixedSize()
        if iconOnly {
            button.labelStyle(.iconOnly).help(title)
        } else {
            button
        }
    }

    private func count(_ f: MailInboxFilter) -> Int {
        switch f {
        case .pending: return snap.counts.pending
        case .snoozed: return snap.counts.snoozed
        default: return snap.cards(f).count
        }
    }

    private var statusLines: some View {
        DetailFlowLayout(spacing: 10, lineSpacing: 4) {
            ForEach(snap.accounts) { info in
                accountLine(info)
            }
            if snap.aiMode == .ai {
                Label(L.Mail.triageUsage(used: snap.triageUsage.used, limit: snap.triageUsage.limit), systemImage: "sparkles")
                    .foregroundStyle(snap.triageUsage.isExhausted ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if snap.triageQueued > 0 {
                    Label(L.Mail.triageQueued(snap.triageQueued), systemImage: "hourglass").foregroundStyle(.secondary)
                }
            } else {
                Label(L.Mail.triageLocalOnly, systemImage: "wand.and.stars").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
    }

    private func accountLine(_ info: MailAccountSyncInfo) -> some View {
        let (text, symbol, tint) = Self.line(info)
        let notEmail = info.notEmailFiles > 0
        return Button {
            if notEmail { state.openPowerAutomateGuide(accountID: info.id) } else { state.router.showSettings("mail") }
        } label: {
            Label { Text(verbatim: L.Mail.accountLine(name: MailInboxRules.line(info.displayName, limit: 40), status: text)) }
                icon: { Image(systemName: symbol) }
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(notEmail ? L.Mail.powerAutomateGuide : L.Mail.mailSettings)
    }

    /// One account's line: its status, plus what its notices below say (files that aren't
    /// emails, emails skipped because the retry list was full) — those turn it orange.
    static func line(_ info: MailAccountSyncInfo) -> (String, String, Color) {
        var (text, symbol, tint) = status(info)
        var extras: [String] = []
        // Files the flow wrote that aren't emails: the notice below says how to fix it.
        if info.notEmailFiles > 0 { extras.append(L.Mail.notEmailShort(info.notEmailFiles)) }
        // Emails skipped (retry list full): the notice below has the sentence and 「立即同步」.
        if let n = MailAccountNotice.skippedCount(info, active: info.enabled) { extras.append(L.Mail.skippedShort(n)) }
        if !extras.isEmpty {
            text += " · " + extras.joined(separator: " · ")
            symbol = "exclamationmark.triangle"
            tint = .orange
        }
        return (text, symbol, tint)
    }

    static func status(_ info: MailAccountSyncInfo) -> (String, String, Color) {
        if info.isSyncing { return (L.Mail.syncing, "arrow.triangle.2.circlepath", .secondary) }
        // The skipped sentence the engine appended to a ready status is the notice's to say.
        switch MailAccountNotice.shownStatus(info, active: info.enabled) {
        case .none:
            return (L.Mail.statusNotChecked, "circle.dotted", .secondary)
        case .ready:
            if let at = info.lastSuccessAt { return (L.Mail.statusSynced(L.Mail.ago(at)), "checkmark.circle", .secondary) }
            return (L.Mail.statusReady, "checkmark.circle", .secondary)
        case .needsSetup(let why):
            return (L.Mail.statusNeedsSetup(MailInboxRules.line(why, limit: 80)), "exclamationmark.circle", .orange)
        case .authFailed(let why):
            return (L.Mail.statusAuthFailed(MailInboxRules.line(why, limit: 80)), "key.slash", .red)
        case .unavailable(let why):
            return (L.Mail.statusUnavailable(MailInboxRules.line(why, limit: 80)), "wifi.exclamationmark", .orange)
        }
    }
}

/// Mail is off or has no account: what to do (the .eml drop always works).
private struct MailSetupNotice: View {
    let state: AppState
    let enabled: Bool
    let hasAccounts: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(hasAccounts && !enabled ? L.Mail.disabledTitle : L.Mail.setUpTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(hasAccounts && !enabled ? L.Mail.disabledBody : L.Mail.setUpBody)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L.Mail.setUp) { state.router.showSettings("mail") }
                .controlSize(.small)
            HelpButton(.connectMail)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.06)))
    }
}

/// A folder account's watched folder holds files that are not complete emails (the Power Automate
/// flow's Create file got the trigger's Body): the fix, and the guide.
struct MailNotEmailNotice: View {
    let state: AppState
    let info: MailAccountSyncInfo

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
                Text(MailSyncText.notEmailFiles(info.notEmailFiles, L.lang))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L.Mail.powerAutomateGuide) { state.openPowerAutomateGuide(accountID: info.id) }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
        .accessibilityElement(children: .contain)
    }
}

/// Per-filter empty state.
private struct MailInboxEmpty: View {
    let state: AppState
    let filter: MailInboxFilter
    let snap: MailSnapshot

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .pending ? "tray" : "tray.2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(L.Mail.emptyTitle(filter)).font(.title3.weight(.semibold))
            Text(L.Mail.emptyMessage(filter))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if filter == .pending {
                Button(L.Mail.importEML) { state.pickAndImportEML(window: NSApp.keyWindow) }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
