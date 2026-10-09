import AppKit
import SwiftUI
import PaperDeckCore

/// One candidate paper of an email card (MAIL_DESIGN Part A §3):
///
///     [附件 PDF] Molecular and cellular dynamics… · Nature 2024        [合并到论文库]
///     [可下载]  Eubiota… · bioRxiv 2026                                [自动下载并合并] [打开链接]
///     [需要 PDF] Spatial atlas of… · Cell 2025          [打开链接] ┆ 把下载好的 PDF 拖到这里 ┆
///     [已在库中] SpatialFormer…                                        [打开卡片]
///
/// Titles, venues and the AI's "why" are untrusted text (plain `Text(verbatim:)`, clipped).
/// In the inbox the whole row is a drop zone (`DropTargetRegistry`) while it can take a PDF.
/// The inspector's copy (`.stacked`, a narrow column) registers no zone and offers
/// 「选择 PDF…」 instead of the drop box.
struct MailItemRow: View {
    enum Layout { case wide, stacked }

    let state: AppState
    let card: MailCard
    let item: MailItem
    var layout: Layout = .wide

    @State private var showMerge = false
    @State private var hovering = false

    private var chip: MailInboxRules.ItemChip { MailInboxRules.chip(item) }
    private var actions: MailInboxRules.ItemActions { MailInboxRules.actions(item) }
    private var busy: Bool { state.mailBusy.contains(item.id) || state.mailBusy.contains(card.id) }
    private var zone: DropTargetRegistry.Target? {
        layout == .wide && actions.contains(.acceptsDrop) && card.message.isOpen ? .mailItem(itemID: item.id) : nil
    }
    private var targeted: Bool { zone != nil && state.dropTargets.hovered == zone }
    private var showsDropBox: Bool { layout == .wide && actions.contains(.dropBox) && card.message.isOpen }

    var body: some View {
        Group {
            switch layout {
            case .wide:
                // Buttons beside the title while the title keeps ≥ `minTitleWidth`; else (a narrow
                // inbox, e.g. with the inspector open) they move under the title and wrap; in a very
                // narrow column chip, title and buttons each take the full width.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        chipColumn
                        texts
                            .frame(minWidth: Self.minTitleWidth, idealWidth: Self.minTitleWidth,
                                   maxWidth: .infinity, alignment: .leading)
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            chipColumn
                            texts
                                .frame(minWidth: Self.minStackedTitleWidth, idealWidth: Self.minStackedTitleWidth,
                                       maxWidth: .infinity, alignment: .leading)
                        }
                        if hasButtons {
                            wrappingButtons
                                .padding(.leading, chipWidth + 10)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        MailItemChipView(chip: chip)
                        texts.frame(maxWidth: .infinity, alignment: .leading)
                        if hasButtons { wrappingButtons }
                    }
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        MailItemChipView(chip: chip)
                        Spacer(minLength: 4)
                        if busy || chip == .downloading { ProgressView().controlSize(.small) }
                    }
                    texts
                    DetailFlowLayout(spacing: 8, lineSpacing: 4) { buttonItems }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.05 : 0.025)))
        .opacity(item.status == .skipped ? 0.6 : 1)
        .mailDropHighlight(targeted && !showsDropBox, caption: L.Mail.dropRelease)
        .contentShape(Rectangle())
        // On the row, not the button: the wide layout chooses between copies of the buttons
        // (ViewThatFits), and only one popover may ever be bound to `showMerge`.
        .popover(isPresented: $showMerge, arrowEdge: .bottom) {
            MailMergePopover(state: state, card: card, items: [item],
                             onConfirm: { options in
                                 showMerge = false
                                 state.mergeMailItem(item, options: options)
                             },
                             onCancel: { showMerge = false })
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .dropZone(zone)
        .accessibilityElement(children: .contain)
    }

    /// The narrowest a title column gets beside the buttons (two lines of ~30 characters), and
    /// beside the chip once the buttons moved under it.
    static let minTitleWidth: CGFloat = 220
    static let minStackedTitleWidth: CGFloat = 160
    private var chipWidth: CGFloat { L.lang == .zh ? 76 : 112 }

    private var chipColumn: some View {
        MailItemChipView(chip: chip)
            .frame(width: chipWidth, alignment: .leading)
    }

    /// Whether the wide row shows any button (or the progress spinner) at all.
    private var hasButtons: Bool {
        busy || chip == .downloading || actions.contains(.merge) || actions.contains(.downloadAndMerge)
            || actions.contains(.openLink) || (actions.contains(.openCard) && item.paperID != nil)
            || showsDropBox || actions.contains(.skip)
    }

    // MARK: Text

    private var texts: some View {
        let title = MailInboxRules.line(item.title, limit: 240)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if item.relevance == .requested {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        .help(L.Mail.requested).accessibilityLabel(L.Mail.requested)
                } else if item.relevance == .highlighted {
                    Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(.tint)
                        .help(L.Mail.highlighted).accessibilityLabel(L.Mail.highlighted)
                }
                Text(verbatim: title.isEmpty ? (item.ids.doi ?? item.ids.arxivID ?? L.Mail.untitled) : title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(title)
            }
            if let meta = metaLine {
                Text(verbatim: meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let why = item.why.map({ MailInboxRules.line($0, limit: 160) }), !why.isEmpty {
                Text(verbatim: why)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if item.foundBy == .ai {
                Label(L.Mail.foundByAI, systemImage: "checkmark.seal")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let error = item.downloadError.map({ MailInboxRules.line($0, limit: 200) }), !error.isEmpty,
               item.status == .pending {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    /// `Nature · 2024 · Wang, Smith…` (venue, year, first authors, or the host / DOI).
    private var metaLine: String? {
        var parts: [String] = []
        if let v = item.venue.map({ MailInboxRules.line($0, limit: 60) }), !v.isEmpty { parts.append(v) }
        if let y = item.year { parts.append(String(y)) }
        let authors = item.authors.prefix(2).map { MailInboxRules.line($0, limit: 30) }.filter { !$0.isEmpty }
        if !authors.isEmpty { parts.append(authors.joined(separator: ", ") + (item.authors.count > 2 ? " et al." : "")) }
        if parts.isEmpty, let host = item.host.map({ MailInboxRules.line($0, limit: 60) }), !host.isEmpty { parts.append(host) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 6) {
            if busy || chip == .downloading {
                ProgressView().controlSize(.small)
            }
            buttonItems
        }
        .fixedSize()
    }

    /// The row's buttons on as many lines as the width needs (narrow layouts).
    private var wrappingButtons: some View {
        DetailFlowLayout(spacing: 6, lineSpacing: 4) {
            if busy || chip == .downloading { ProgressView().controlSize(.small) }
            buttonItems
        }
    }

    @ViewBuilder private var buttonItems: some View {
            if actions.contains(.merge) || actions.contains(.downloadAndMerge) {
                Button(mergeTitle) { showMerge = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy)
            }
            if actions.contains(.openLink) {
                Button(L.Mail.openLink) { state.openMailLink(item) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L.Mail.linkHelp)
            }
            if actions.contains(.openCard), let paperID = item.paperID {
                Button(L.Mail.openCard) { state.router.showPaper(paperID) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            if showsDropBox {
                MailDropBox(targeted: targeted) { state.choosePDF(for: item, window: NSApp.keyWindow) }
            } else if layout == .stacked, actions.contains(.dropBox), card.message.isOpen {
                Button(L.Mail.choosePDF) { state.choosePDF(for: item, window: NSApp.keyWindow) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if actions.contains(.skip) {
                Button(L.Mail.skip) { state.skipMailItem(item) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .disabled(busy)
            }
    }

    private var mergeTitle: String {
        if actions.contains(.downloadAndMerge) { return L.Mail.downloadAndMerge }
        return chip == .inLibrary ? L.Mail.linkExisting : L.Mail.merge
    }

    @ViewBuilder private var menu: some View {
        if actions.contains(.merge) || actions.contains(.downloadAndMerge) {
            Button(mergeTitle) { showMerge = true }
        }
        if actions.contains(.download) {
            Button(L.Mail.downloadOnly) { state.downloadMailItem(item) }
        }
        if actions.contains(.acceptsDrop) {
            Button(L.Mail.choosePDF) { state.choosePDF(for: item, window: NSApp.keyWindow) }
        }
        if actions.contains(.openLink) {
            Button(L.Mail.openLink) { state.openMailLink(item) }
        }
        if actions.contains(.openCard), let paperID = item.paperID {
            Button(L.Mail.openCard) { state.router.showPaper(paperID) }
        }
        if let doi = item.ids.doi {
            Button(L.Mail.copyDOI) { state.copyText(doi) }
        }
        if actions.contains(.skip) {
            Divider()
            Button(L.Mail.skip) { state.skipMailItem(item) }
        }
    }
}
