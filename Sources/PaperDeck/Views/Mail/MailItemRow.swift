import AppKit
import SwiftUI
import PaperDeckCore

/// One candidate paper of an email card (MAIL_DESIGN Part A §3):
///
///     [附件 PDF] Molecular and cellular dynamics… · Nature 2024        [合并到论文库]
///     [可下载]  Eubiota… · bioRxiv 2026                                [自动下载并合并] [打开链接]
///     [需要 PDF] Spatial atlas of… · Cell 2025          [打开链接] ┆ 把下载好的 PDF 拖到这里 ┆
///     [已在库中] SpatialFormer…                                        [打开卡片]
///     [附件文档] Lab_manuscript.docx · 附件：Word 稿件 · docx · 7.2 MB   [转换为 PDF 并合并] [打开]
///     [需导出]  Lab_meeting.pptx                          [打开] ┆ 导出为 PDF 后拖到这里 ┆
///     [共享链接] 共享的 Word 文档 · SharePoint          [打开链接] ┆ 下载后把 PDF 拖到这里 ┆
///
/// Document and share-link rows (`MailDocumentInfo`, `MailDocumentNotes`) add what conversion may
/// lose, the possibly-unpublished hold, sign-in for share links and 「正在本机转换为 PDF…」.
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
    /// 「转换为 PDF 并合并」 is running for this row (its notes show the progress line).
    private var converting: Bool { MailDocumentActivity.shared.isConverting(item.id) }
    /// The row's spinner beside the buttons (a conversion shows its own progress line instead).
    private var spinning: Bool { (busy || chip == .downloading) && !converting }
    private var documentRow: Bool { MailDocumentInfo.isDocument(item) || MailDocumentInfo.isShareLink(item) }
    private var zone: DropTargetRegistry.Target? {
        layout == .wide && actions.contains(.acceptsDrop) && card.message.isOpen ? .mailItem(itemID: item.id) : nil
    }
    private var targeted: Bool { zone != nil && state.dropTargets.hovered == zone }
    private var showsDropBox: Bool { layout == .wide && offersDropBox && card.message.isOpen }
    /// 「把下载好的 PDF 拖到这里」 — also on a document whose conversion failed (export it yourself).
    private var offersDropBox: Bool { actions.contains(.dropBox) || conversionFailed }
    private var conversionFailed: Bool {
        chip == .convertible && item.status == .pending && !converting && !(item.downloadError ?? "").isEmpty
    }

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
                        MailItemChipView(chip: chip, converting: converting)
                        texts.frame(maxWidth: .infinity, alignment: .leading)
                        if hasButtons { wrappingButtons }
                    }
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        MailItemChipView(chip: chip, converting: converting)
                        Spacer(minLength: 4)
                        if spinning { ProgressView().controlSize(.small) }
                    }
                    texts
                    DetailFlowLayout(spacing: 8, lineSpacing: 4) { buttonItems }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, layout == .wide ? 6 : 8)
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
                                 if actions.contains(.convertAndMerge) {
                                     state.convertMailDocument(item, options: options)
                                 } else {
                                     state.mergeMailItem(item, options: options)
                                 }
                             },
                             onCancel: { showMerge = false })
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .dropZone(zone)
        .accessibilityElement(children: .contain)
    }

    /// The narrowest a title column gets beside the buttons (two lines of ~45 characters — a
    /// narrower column moves the buttons under the title instead of cutting the title short), and
    /// beside the chip once the buttons moved under it.
    static let minTitleWidth: CGFloat = 300
    static let minStackedTitleWidth: CGFloat = 240
    private var chipWidth: CGFloat { L.lang == .zh ? 76 : 112 }

    private var chipColumn: some View {
        MailItemChipView(chip: chip, converting: converting)
            .frame(width: chipWidth, alignment: .leading)
    }

    /// Whether the wide row shows any button (or the progress spinner) at all.
    private var hasButtons: Bool {
        spinning || actions.contains(.merge) || actions.contains(.downloadAndMerge)
            || actions.contains(.convertAndMerge) || actions.contains(.openDocument)
            || actions.contains(.openLink) || (actions.contains(.openCard) && item.paperID != nil)
            || showsDropBox || actions.contains(.skip)
    }

    // MARK: Text

    /// The title line: the paper's title (or DOI / arXiv id); a document's file name; a share
    /// link's name or 「共享的 Word 文档 · SharePoint」.
    private var displayTitle: String {
        if MailDocumentInfo.isDocument(item) {
            return MailDocumentInfo.fileName(item) ?? L.Mail.documentKind(.other)
        }
        if MailDocumentInfo.isShareLink(item) { return MailDocumentInfo.shareTitle(item) }
        let title = MailInboxRules.line(item.title, limit: 240)
        return title.isEmpty ? (item.ids.doi ?? item.ids.arxivID ?? L.Mail.untitled) : title
    }

    /// The AI's "why" (untrusted, clipped): its own line in the inspector; in the list the
    /// title's tooltip (one line of information per element).
    private var why: String? {
        item.why.map { MailInboxRules.line($0, limit: 160) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var texts: some View {
        let title = displayTitle
        let wide = layout == .wide
        let tooltip = wide ? ([title] + [why, item.foundBy == .ai ? L.Mail.foundByAI : nil].compactMap { $0 }).joined(separator: "\n") : title
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if item.relevance == .requested {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        .help(L.Mail.requested).accessibilityLabel(L.Mail.requested)
                } else if item.relevance == .highlighted {
                    Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(.tint)
                        .help(L.Mail.highlighted).accessibilityLabel(L.Mail.highlighted)
                }
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(tooltip)
                if wide, item.foundBy == .ai {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(L.Mail.foundByAI)
                        .accessibilityLabel(L.Mail.foundByAI)
                }
            }
            if let meta = metaLine {
                Text(verbatim: meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(meta)
            }
            if !wide, let why {
                Text(verbatim: why)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !wide, item.foundBy == .ai {
                Label(L.Mail.foundByAI, systemImage: "checkmark.seal")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if documentRow {
                MailDocumentNotes(card: card, item: item, chip: chip, converting: converting)
            }
            if let error = item.downloadError.map({ MailInboxRules.line($0, limit: 200) }), !error.isEmpty,
               item.status == .pending, !converting {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    /// `Nature · 2024 · Wang, Smith…` (venue, year, first authors, or the host / DOI); a document's
    /// 「附件：Word 稿件 · docx · 7.2 MB」; a share link's kind and host.
    private var metaLine: String? {
        if MailDocumentInfo.isDocument(item) { return MailDocumentInfo.documentMeta(item) }
        if MailDocumentInfo.isShareLink(item) { return MailDocumentInfo.shareMeta(item) }
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
            if spinning {
                ProgressView().controlSize(.small)
            }
            buttonItems
        }
        .fixedSize()
    }

    /// The row's buttons on as many lines as the width needs (narrow layouts).
    private var wrappingButtons: some View {
        DetailFlowLayout(spacing: 6, lineSpacing: 4) {
            if spinning { ProgressView().controlSize(.small) }
            buttonItems
        }
    }

    @ViewBuilder private var buttonItems: some View {
            if actions.contains(.convertAndMerge) {
                Button(L.Mail.convertAndAdd) { showMerge = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy || converting)
                    .help(L.Mail.convertHelp)
            }
            if actions.contains(.openDocument) {
                Button(L.Mail.openDocument) { state.openMailDocument(item) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(L.Mail.openDocumentHelp)
            }
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
                MailDropBox(targeted: targeted, caption: MailDocumentInfo.dropCaption(item, chip: chip),
                            detail: MailDocumentInfo.dropDetail(item, chip: chip)) {
                    state.choosePDF(for: item, window: NSApp.keyWindow)
                }
            } else if layout == .stacked, offersDropBox, card.message.isOpen {
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
        if actions.contains(.convertAndMerge) {
            Button(L.Mail.convertAndAdd) { showMerge = true }
                .disabled(busy || converting)
        }
        if actions.contains(.openDocument) {
            Button(L.Mail.openDocument) { state.openMailDocument(item) }
        }
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
            if MailDocumentInfo.isShareLink(item), let url = MailInboxRules.linkURL(item) {
                Button(L.Mail.copyRowLink) { state.copyText(url.absoluteString) }
            }
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
