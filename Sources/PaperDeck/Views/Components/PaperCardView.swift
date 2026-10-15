import AppKit
import ImageIO
import SwiftUI
import PaperDeckCore

/// One library card (§8 卡片). Display only: selection, clicks and the context menu are
/// attached by the container (CardGridView), which also sizes it (`CardGridMetrics`): a tile
/// (thumbnail on top) in the multi-column grid, or a compact horizontal card in the one-column
/// grid of a narrow content column. The height follows the content — the title and the TL;DR are
/// never clipped — and the grid gives every card of a row the row's tallest height (the footer
/// stays at the bottom).
///
/// One line per kind of information; the rest lives in the inspector: the AI badge only while
/// the reading isn't ready or needs the user, the priority mark only for high, at most two chips
/// (category, then tags, the rest folded into `+N`), no TL;DR placeholder.
struct PaperCardView: View {
    static let cornerRadius: CGFloat = 14
    /// The thumbnail of a card at the grid's minimum width (single cards drawn on their own).
    static let thumbnailHeight: CGFloat = 120

    let row: PaperRow
    let today: LocalDate
    let lang: UILang
    let agentStatus: AgentQueueStatus
    let queuePosition: Int?
    let isSelected: Bool
    /// Tile or compact (one-column grid).
    var style: CardGridMetrics.Style
    /// Tile thumbnail height (`CardGridMetrics.thumbnailHeight`).
    var thumbnailHeight: CGFloat
    /// Compact cards: the thumbnail strip on the leading edge (dropped when the card is narrow).
    var showsThumbnailStrip: Bool
    /// The multi-selection's checkmark (on the thumbnail, or at the trailing edge of a compact card).
    var showsCheckmark: Bool

    @State private var hovering = false

    init(row: PaperRow, today: LocalDate, lang: UILang, agentStatus: AgentQueueStatus,
         queuePosition: Int?, isSelected: Bool, style: CardGridMetrics.Style = .tiles,
         thumbnailHeight: CGFloat = PaperCardView.thumbnailHeight, showsThumbnailStrip: Bool = true,
         showsCheckmark: Bool = false) {
        self.row = row
        self.today = today
        self.lang = lang
        self.agentStatus = agentStatus
        self.queuePosition = queuePosition
        self.isSelected = isSelected
        self.style = style
        self.thumbnailHeight = thumbnailHeight
        self.showsThumbnailStrip = showsThumbnailStrip
        self.showsCheckmark = showsCheckmark
    }

    private var paper: Paper { row.paper }

    var body: some View {
        Group {
            switch style {
            case .tiles: tile
            case .compact: compact
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(hovering ? 0.16 : 0.09),
                              lineWidth: isSelected ? 2.5 : 0.75)
        }
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 10 : 3, y: hovering ? 5 : 1)
        .offset(y: hovering ? -2 : 0)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Tile (thumbnail on top)

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
                .frame(height: thumbnailHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
                .overlay(alignment: .bottomLeading) { aiBadge(iconOnly: false).padding(8) }
                .overlay(alignment: .topTrailing) { priorityMark.padding(8) }
                .overlay(alignment: .topLeading) { DuplicateRibbon(row: row) }   // dedupe (Slice B), once it ships
                .overlay(alignment: .bottomTrailing) { if showsCheckmark { SelectionCheckmark().padding(8) } }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    title(lines: 3)
                    byline
                }
                chips
                tldr(lines: 3)
                Spacer(minLength: 0)
                footer
            }
            .padding(12)
        }
    }

    // MARK: Compact (one-column grid)

    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsThumbnailStrip {
                // A small page: the top-leading corner of page 1 (journal line, start of the title).
                thumbnail
                    .frame(width: CardGridMetrics.compactThumbnailWidth, height: CardGridMetrics.compactThumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .overlay(alignment: .bottomLeading) { aiBadge(iconOnly: true).padding(4) }
                    .overlay(alignment: .topLeading) { DuplicateRibbon(row: row, compact: true).offset(x: -6, y: -6) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        title(lines: 3, flag: true)
                        byline
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if showsCheckmark { SelectionCheckmark() }
                }
                tldr(lines: 2)
                Spacer(minLength: 0)
                compactFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        CardThumbnail(url: row.thumbnailURL, placeholder: placeholderSymbol,
                      placeholderText: style == .compact ? nil : placeholderText,
                      placeholderIsWarning: placeholderText != nil)
            .help(style == .compact ? (placeholderText ?? "") : "")
    }

    private var placeholderSymbol: String {
        if paper.flags.contains(.missing) { return "exclamationmark.triangle" }
        if paper.flags.contains(.locked) { return "lock.doc" }
        return "doc.text"
    }

    private var placeholderText: String? {
        if paper.flags.contains(.missing) { return L.cardsMissingFile }
        if paper.flags.contains(.locked) { return L.cardsLocked }
        return nil
    }

    /// The AI status, only while it isn't ready or needs the user (`AgentBadgeKind.showsOnCard`).
    @ViewBuilder private func aiBadge(iconOnly: Bool) -> some View {
        AgentBadge(paper: paper, status: agentStatus, queuePosition: queuePosition, lang: lang, iconOnly: iconOnly)
    }

    @ViewBuilder private var priorityMark: some View {
        if CardBadgeRules.showsPriorityMark(paper.priority) {
            Image(systemName: "flag.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.flagRed)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .help(L.cardsHighPriority)
                .accessibilityLabel(L.cardsHighPriority)
        }
    }

    private static let flagRed = ChipPalette.dynamic(light: 0xD32F2F, dark: 0xFF6B61)

    // MARK: Text

    /// The title with the NEW dot (a fresh AI reading) and, on compact cards, the high-priority flag.
    private func title(lines: Int, flag: Bool = false) -> some View {
        let text = CardText.displayTitle(paper)
        let pending = CardText.metadataPending(paper)
        var marks: [Text] = []
        if !paper.aiSeen {
            marks.append(Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(Color.blue))
        }
        if flag, CardBadgeRules.showsPriorityMark(paper.priority) {
            marks.append(Text(Image(systemName: "flag.fill")).font(.system(size: 10)).foregroundStyle(Self.flagRed))
        }
        let base = Text(text).italic(pending)
        let composed = marks.reduce(Text("")) { acc, mark in Text("\(acc)\(mark) ") }
        return Text("\(composed)\(base)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .help(text)
            .accessibilityLabel(titleA11y(text, flag: flag))
    }

    private func titleA11y(_ text: String, flag: Bool) -> String {
        var label = paper.aiSeen ? text : L.cardsNewA11y(text)
        if flag, CardBadgeRules.showsPriorityMark(paper.priority) { label += ", " + L.cardsHighPriority }
        return label
    }

    /// `Wang L … Kriegstein AR · Nature · 2024` — the venue already says arXiv / bioRxiv, so no
    /// separate preprint badge on the card (the inspector has it).
    @ViewBuilder private var byline: some View {
        let line = CardText.byline(paper, venue: CardText.venue(paper).name)
        if !line.isEmpty {
            Text(line)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(line)
        }
    }

    /// The category (when set) and tags, two chips in all; the rest folds into `+N`.
    private var chips: some View { chips(budget: 2) }

    /// `budget` chips (the category first); the rest folds into `+N`.
    @ViewBuilder private func chips(budget n: Int) -> some View {
        let budget = CardBadgeRules.chips(hasCategory: row.category != nil, tagCount: row.tags.count, budget: n)
        if budget.showsCategory || !row.tags.isEmpty {
            HStack(spacing: 4) {
                if budget.showsCategory {
                    CategoryChip(category: row.category, lang: lang)
                        .layoutPriority(1)
                }
                TagChips(tags: row.tags, limit: budget.tags)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The TL;DR, else the abstract's first sentence; nothing while neither exists (the inspector
    /// says the TL;DR is pending).
    @ViewBuilder private func tldr(lines: Int) -> some View {
        if let t = paper.tldr?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            Text(t)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .help(t)
        } else if let first = CardText.firstSentence(paper.abstract) {
            Text(L.cardsAbstractPrefix + first)
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var progress: some View {
        HStack(spacing: 6) {
            if paper.status == .done {
                ProgressRing(done: max(row.doneCount, row.totalCount), total: max(row.totalCount, 1))
            } else {
                ProgressRing(done: row.doneCount, total: row.totalCount)
            }
            Text(CardText.progress(row, lang: lang))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// A read paper already says 「已读 · 9/28」 on the left; its ✓ chip would repeat it.
    @ViewBuilder private var deadlineChip: some View {
        if paper.status != .done {
            DDLChip(spec: row.cardChipSpec(today: today, lang: lang),
                    atRiskHint: row.cardAtRiskHint(today: today, lang: lang))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            progress
            Spacer(minLength: 8)
            deadlineChip
        }
    }

    /// Compact: progress, the chips while they fit, the DDL; when it's narrow the chips shrink to
    /// the category and `+N` first, then go. Without the thumbnail, the ribbon and the AI badge
    /// (icons) lead the line.
    private var compactFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusIcons
                progress
                chips.fixedSize()
                Spacer(minLength: 8)
                deadlineChip
            }
            HStack(spacing: 8) {
                statusIcons
                progress
                chips(budget: 1).fixedSize()
                Spacer(minLength: 8)
                deadlineChip
            }
            HStack(spacing: 8) {
                statusIcons
                progress
                Spacer(minLength: 8)
                deadlineChip
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusIcons
                    progress
                }
                deadlineChip
            }
        }
    }

    @ViewBuilder private var statusIcons: some View {
        if !showsThumbnailStrip {
            DuplicateRibbon(row: row, compact: true, inline: true)
            aiBadge(iconOnly: true)
        }
    }
}

/// The multi-selection's badge on a card (the thumbnail's bottom-trailing corner of a tile, the
/// title line's trailing end of a compact card; the priority mark sits top-trailing, the AI badge
/// bottom-leading, the duplicate ribbon top-leading).
struct SelectionCheckmark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .background(Circle().fill(.white).padding(2))
            .allowsHitTesting(false)
            .accessibilityLabel(L.Select.selectedA11y)
    }
}

// MARK: - Text helpers (shared by the card, the Today row and the context menu)

enum CardText {
    /// Title as shown: the file name (without `.pdf`) while only the file name is known.
    static func displayTitle(_ p: Paper) -> String {
        var t = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = p.originalName }
        if p.titleRank == .filename, t.lowercased().hasSuffix(".pdf") { t = String(t.dropLast(4)) }
        return t
    }

    /// Metadata has not arrived yet (only the file name is known): title in italics.
    static func metadataPending(_ p: Paper) -> Bool {
        p.titleRank == .filename && (p.metaSource == .none || p.metaSource == .pdf)
    }

    /// bioRxiv/medRxiv DOIs (10.1101/…, 10.64898/…) and bare arXiv ids are preprints.
    static func venue(_ p: Paper) -> (name: String?, preprint: Bool) {
        let venue = p.venue?.trimmingCharacters(in: .whitespacesAndNewlines).cardsNonEmpty
        let doi = p.ids.doi?.lowercased() ?? ""
        if doi.hasPrefix("10.1101/") || doi.hasPrefix("10.64898/") {
            let keep = venue.map { $0.lowercased().contains("rxiv") } ?? false
            return (keep ? venue : "bioRxiv", true)
        }
        if venue == nil, p.ids.doi == nil, p.ids.arxivID != nil { return ("arXiv", true) }
        return (venue, false)
    }

    /// `Wang L … Kriegstein AR · Nature · 2024` (empty parts are skipped).
    static func byline(_ p: Paper, venue: String?) -> String {
        let authors = SnapshotBuilder.authorLine(p.authors)
        return [authors.cardsNonEmpty, venue, p.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// `3/7 · 剩 40′`, `剩 40′` (no checklist yet) or `已读 · 9/28`.
    static func progress(_ row: PaperRow, lang: UILang) -> String {
        if row.paper.status == .done {
            return L.cardsReadOn(row.paper.doneAt.map { SharedStrings.monthDay(LocalDate($0, calendar: LocalDate.localGregorian)) })
        }
        if row.totalCount > 0 {
            return L.cardsProgress(done: row.doneCount, total: row.totalCount, remaining: row.remainingMinutes)
        }
        return L.cardsRemaining(row.remainingMinutes)
    }

    /// First sentence of an abstract (≤ 220 characters), skipping common abbreviations.
    static func firstSentence(_ abstract: String?, limit: Int = 220) -> String? {
        guard let raw = abstract else { return nil }
        let flat = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        let window = String(flat.prefix(limit + 40))
        let abbreviations: Set<String> = ["e.g", "i.e", "al", "fig", "figs", "vs", "cf", "approx", "ca", "no", "ref", "eq", "sp", "spp"]
        var end: String.Index?
        var i = window.startIndex
        while i < window.endIndex {
            let c = window[i]
            if c == "。" || c == "！" || c == "？" { end = window.index(after: i); break }
            if c == "." || c == "!" || c == "?" {
                let next = window.index(after: i)
                if next == window.endIndex || window[next] == " " {
                    let word = window[..<i].split(separator: " ").last.map { $0.lowercased() } ?? ""
                    let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "(["))
                    if c != "." || !abbreviations.contains(trimmed) { end = next; break }
                }
            }
            i = window.index(after: i)
        }
        var sentence = String(window[..<(end ?? window.endIndex)])
        if sentence.count > limit {
            sentence = String(sentence.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        } else if end == nil, flat.count > window.count {
            sentence += "…"
        }
        return sentence
    }
}

extension String {
    fileprivate var cardsNonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Thumbnail

/// First-page thumbnail (caches/thumbs/<id>@2x.jpg, already cropped to the card area),
/// decoded off the main thread and kept in a small in-memory cache.
private struct CardThumbnail: View {
    let url: URL?
    let placeholder: String
    let placeholderText: String?
    /// The placeholder stands for a problem (missing / encrypted file): never covered by an image.
    var placeholderIsWarning = false

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    init(url: URL?, placeholder: String, placeholderText: String?, placeholderIsWarning: Bool = false) {
        self.url = url
        self.placeholder = placeholder
        self.placeholderText = placeholderText
        self.placeholderIsWarning = placeholderIsWarning || placeholderText != nil
        _image = State(initialValue: url.flatMap { CardThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.045))
            if let image, !placeholderIsWarning {
                // The crop's top-leading corner (journal line, start of the title) stays in view
                // however the card is shaped.
                // The fill overflows the frame; the overlay pins it to the frame's top-leading corner.
                Color.clear
                    .overlay(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .brightness(colorScheme == .dark ? -0.06 : 0)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: placeholder)
                        .font(.system(size: placeholderText == nil && !placeholderIsWarning ? 30 : 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    if let placeholderText {
                        Text(placeholderText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = CardThumbnailCache.shared.cached(url) { image = hit; return }
            image = await CardThumbnailCache.shared.load(url)
        }
    }
}

/// In-memory cache of decoded card thumbnails (≈ 560×240 px JPEGs, ~0.5 MB decoded each), keyed
/// by the row's versioned URL (`ThumbnailStore.versioned`): a thumbnail rewritten in place (a
/// replaced PDF, a merge, their Undo) comes with a new URL and is decoded again.
final class CardThumbnailCache {
    static let shared = CardThumbnailCache()

    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 300
        return c
    }()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            guard let decoded = await Self.decode(url) else { return nil }
            let cg = decoded.image
            return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Drops everything (e.g. after thumbnails were regenerated).
    func removeAll() { cache.removeAllObjects() }

    private struct Decoded: @unchecked Sendable { let image: CGImage }

    /// Reads and fully decodes the JPEG on a background executor (the file the versioned URL names).
    @concurrent
    nonisolated private static func decode(_ url: URL) async -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(ThumbnailStore.unversioned(url) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return Decoded(image: image)
    }
}
