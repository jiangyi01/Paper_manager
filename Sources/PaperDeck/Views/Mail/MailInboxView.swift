import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Library ▸ 邮件 (MAIL_DESIGN Part A §3): email cards — one centred column (max width 820), or
/// balanced columns once a wide window fits two or three (`MailInboxLayout`) — under the segmented
/// filter 待处理 · 稍后 · 已处理 · 已忽略 · 无阅读需求 and the status pill (accounts, triage usage,
/// 立即同步 / 导入 .eml… in its popover). The list is the coordinate space of the per-row drop
/// boxes (`DropTargetRegistry.space`, anchored by `DropSpaceAnchor`).
struct MailInboxView: View {
    @Bindable var state: AppState
    /// This list's drop space (`DropTargetRegistry`): its anchor and zones come and go with it.
    @State private var dropSpace = UUID().uuidString
    /// The list's width (columns: `MailInboxLayout`).
    @State private var listWidth: CGFloat = 0

    /// Horizontal padding of the list.
    static let sidePadding: CGFloat = 24
    /// Space between cards (both ways).
    static let cardSpacing = CGFloat(MailInboxLayout.gap)

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
        let inner = max(0, Double(listWidth) - 2 * Double(Self.sidePadding))
        let columns = listWidth > 0 ? MailInboxLayout.columns(width: inner) : 1
        let column = listWidth > 0 ? CGFloat(MailInboxLayout.columnWidth(width: inner, columns: columns)) : CGFloat(MailInboxLayout.maxColumn)
        let content = listWidth > 0 ? CGFloat(MailInboxLayout.contentWidth(width: inner, columns: columns)) : CGFloat(MailInboxLayout.maxColumn)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.cardSpacing) {
                    MailInboxHeader(state: state, snap: snap)
                    if cards.isEmpty {
                        MailInboxEmpty(state: state, filter: state.mailFilter, snap: snap)
                            .padding(.top, 24)
                    } else if columns <= 1 {
                        LazyVStack(alignment: .leading, spacing: Self.cardSpacing) {
                            ForEach(cards) { card in
                                MailCardView(state: state, card: card, aiMode: snap.aiMode)
                                    .id(card.id)
                            }
                        }
                    } else {
                        columnsView(cards, columns: columns, width: column, aiMode: snap.aiMode)
                    }
                }
                .frame(maxWidth: listWidth > 0 ? content : CGFloat(MailInboxLayout.maxColumn))
                .padding(.horizontal, Self.sidePadding)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .environment(\.mailDropSpace, dropSpace)
            .coordinateSpace(.named(DropTargetRegistry.space))
            .background(DropSpaceAnchor(registry: state.dropTargets, space: dropSpace))
            .onChange(of: state.selectedMailID, initial: true) { _, id in
                guard let id, cards.contains(where: { $0.id == id }) else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
    }

    /// A wide window: the cards flow into balanced columns (`MailInboxLayout.distribute`), newest
    /// first in each; VoiceOver still reads them newest first.
    private func columnsView(_ cards: [MailCard], columns: Int, width: CGFloat, aiMode: MailSettings.AIMode) -> some View {
        let groups = MailInboxLayout.distribute(heights: cards.map { Self.estimatedHeight($0, aiMode: aiMode) }, columns: columns)
        return HStack(alignment: .top, spacing: Self.cardSpacing) {
            ForEach(groups.indices, id: \.self) { c in
                LazyVStack(alignment: .leading, spacing: Self.cardSpacing) {
                    ForEach(groups[c], id: \.self) { i in
                        MailCardView(state: state, card: cards[i], aiMode: aiMode)
                            .id(cards[i].id)
                            .accessibilitySortPriority(Double(cards.count - i))
                    }
                }
                .frame(width: width, alignment: .top)
            }
        }
    }

    static func estimatedHeight(_ card: MailCard, aiMode: MailSettings.AIMode) -> Double {
        let parts = MailInboxRules.partition(card.items, digest: MailInboxRules.isDigest(card.message))
        return MailInboxLayout.estimatedHeight(rows: parts.shown.count, hasMoreLine: !parts.rest.isEmpty,
                                               hasConsent: aiMode == .ai && card.canRequestAI
                                                   && card.displayTriageState == .awaitingConsent)
    }
}

// MARK: - Header

/// The filter and the status pill on one line; under it at most one notice — the most serious
/// real problem of any account (`MailNoticePolicy.notices`), or how to set mail up. Everything
/// else (each account's status and last sync, warnings, today's AI triage, Sync Now, Import .eml…)
/// is in the pill's popover.
struct MailInboxHeader: View {
    @Bindable var state: AppState
    let snap: MailSnapshot
    @State private var showStatus = false

    private var setupKey: String { Self.setupKey(snap) }
    private var needsSetup: Bool { Self.needsSetup(snap) }

    /// The session dismissal key of the setup notice (mail off / no account).
    static func setupKey(_ snap: MailSnapshot) -> String { "setup|\(snap.enabled)|\(snap.accounts.isEmpty)" }
    private static func needsSetup(_ snap: MailSnapshot) -> Bool { !snap.enabled || snap.accounts.isEmpty }

    /// Whether the header shows a notice (how to set mail up, or an account's most serious problem)
    /// with these session dismissals — the library's banners make room then (`NoticeQueue.showsOverInbox`).
    static func showsNotice(_ snap: MailSnapshot, dismissed: Set<String>) -> Bool {
        needsSetup(snap) ? !dismissed.contains(setupKey(snap))
                         : !MailNoticePolicy.notices(snap.accounts, dismissed: dismissed).isEmpty
    }

    var body: some View {
        let dismissals = MailNoticeDismissals.shared
        let notices = needsSetup ? [] : MailNoticePolicy.notices(snap.accounts, dismissed: dismissals.keys)
        VStack(alignment: .leading, spacing: 8) {
            // Never truncated: the pill loses its words first (icon + tooltip), then the segmented
            // filter becomes a pop-up menu.
            ViewThatFits(in: .horizontal) {
                toolbar(segmented: true, compactPill: false)
                toolbar(segmented: true, compactPill: true)
                toolbar(segmented: false, compactPill: false)
                toolbar(segmented: false, compactPill: true)
            }
            .popover(isPresented: $showStatus, attachmentAnchor: .point(.bottomTrailing), arrowEdge: .bottom) {
                MailStatusPopover(state: state, snap: snap)
            }
            if needsSetup {
                if !dismissals.isDismissed(setupKey) {
                    MailSetupNotice(state: state, enabled: snap.enabled, hasAccounts: !snap.accounts.isEmpty,
                                    onDismiss: { dismissals.dismiss(setupKey) })
                }
            } else if let first = notices.first {
                MailInboxNoticeView(state: state, notice: first, more: notices.count - 1, onShowAll: { showStatus = true })
            }
        }
    }

    private func toolbar(segmented: Bool, compactPill: Bool) -> some View {
        let pill = MailNoticePolicy.pill(snap.accounts, enabled: snap.enabled)
        let text = MailStatusPillLabel.text(pill)
        return HStack(spacing: 8) {
            filterPicker(segmented: segmented)
            Spacer(minLength: 8)
            Button { showStatus.toggle() } label: {
                MailStatusPillLabel(pill: state.mailSyncing ? .syncing : pill, compact: compactPill)
            }
            .buttonStyle(.plain)
            .help(compactPill ? text + "\n" + L.Mail.pillHelp : L.Mail.pillHelp)
            .accessibilityLabel(L.Mail.pillHelp)
            .accessibilityValue(text)
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

    private func count(_ f: MailInboxFilter) -> Int {
        switch f {
        case .pending: return snap.counts.pending
        case .snoozed: return snap.counts.snoozed
        default: return snap.cards(f).count
        }
    }
}

/// Mail is off or has no account: what to do (the .eml drop always works).
private struct MailSetupNotice: View {
    let state: AppState
    let enabled: Bool
    let hasAccounts: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(L.Mail.hideNoticeHelp)
            .accessibilityLabel(L.Mail.hideNotice)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.06)))
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
