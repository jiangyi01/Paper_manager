import AppKit
import ImageIO
import SwiftUI
import PaperDeckCore

/// One library card (§8 卡片). Display only: selection, clicks and the context menu are
/// attached by the container (CardGridView). Fixed height 300 pt, pure stacks.
struct PaperCardView: View {
    static let height: CGFloat = 300
    static let thumbnailHeight: CGFloat = 120
    static let cornerRadius: CGFloat = 14

    let row: PaperRow
    let today: LocalDate
    let lang: UILang
    let agentStatus: AgentQueueStatus
    let queuePosition: Int?
    let isSelected: Bool

    @State private var hovering = false

    init(row: PaperRow, today: LocalDate, lang: UILang, agentStatus: AgentQueueStatus,
         queuePosition: Int?, isSelected: Bool) {
        self.row = row
        self.today = today
        self.lang = lang
        self.agentStatus = agentStatus
        self.queuePosition = queuePosition
        self.isSelected = isSelected
    }

    private var paper: Paper { row.paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                title
                byline
                chips
                tldr
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
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

    // MARK: Thumbnail

    private var thumbnail: some View {
        CardThumbnail(url: row.thumbnailURL, placeholder: placeholderSymbol, placeholderText: placeholderText)
            .frame(height: Self.thumbnailHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
            .overlay(alignment: .bottomLeading) {
                AgentBadge(paper: paper, status: agentStatus, queuePosition: queuePosition, lang: lang)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) { priorityMark.padding(8) }
            .overlay(alignment: .topLeading) { DuplicateRibbon(row: row) }   // dedupe (Slice B), once it ships
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

    @ViewBuilder private var priorityMark: some View {
        switch paper.priority {
        case .high:
            Image(systemName: "flag.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChipPalette.dynamic(light: 0xD32F2F, dark: 0xFF6B61))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .help(L.cardsHighPriority)
                .accessibilityLabel(L.cardsHighPriority)
        case .low:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .help(L.cardsLowPriority)
                .accessibilityLabel(L.cardsLowPriority)
        case .normal:
            EmptyView()
        }
    }

    // MARK: Text

    private var title: some View {
        let text = CardText.displayTitle(paper)
        let pending = CardText.metadataPending(paper)
        let base = Text(text).italic(pending)
        return Group {
            if !paper.aiSeen {
                Text("\(Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(Color.blue)) \(base)")
                    .accessibilityLabel(L.cardsNewA11y(text))
            } else {
                base
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .help(text)
    }

    @ViewBuilder private var byline: some View {
        let venue = CardText.venue(paper)
        let line = CardText.byline(paper, venue: venue.name)
        if !line.isEmpty || venue.preprint {
            HStack(spacing: 5) {
                if !line.isEmpty {
                    Text(line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if venue.preprint {
                    Text(L.cardsPreprint)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 0.75))
                        .fixedSize()
                }
            }
            .font(.system(size: 11))
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            CategoryChip(category: row.category, lang: lang)
                .layoutPriority(1)
            TagChips(tags: row.tags, limit: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var tldr: some View {
        Group {
            if let t = paper.tldr?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                Text(t).foregroundStyle(.primary.opacity(0.82))
            } else if let first = CardText.firstSentence(paper.abstract) {
                Text(L.cardsAbstractPrefix + first).italic().foregroundStyle(.secondary)
            } else {
                Text(L.cardsTLDRPending).italic().foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    private var footer: some View {
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
            Spacer(minLength: 6)
            // A read paper already says 「已读 · 9/28」 on the left; its ✓ chip would repeat it.
            if paper.status != .done {
                DDLChip(spec: row.cardChipSpec(today: today, lang: lang),
                        atRiskHint: row.cardAtRiskHint(today: today, lang: lang))
            }
        }
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
            return L.cardsReadOn(row.paper.doneAt.map { SharedStrings.monthDay(LocalDate($0, calendar: .current)) })
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

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    init(url: URL?, placeholder: String, placeholderText: String?) {
        self.url = url
        self.placeholder = placeholder
        self.placeholderText = placeholderText
        _image = State(initialValue: url.flatMap { CardThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.045))
            if let image, placeholderText == nil {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .brightness(colorScheme == .dark ? -0.06 : 0)
                    .accessibilityHidden(true)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: placeholder)
                        .font(.system(size: 30, weight: .light))
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

/// In-memory cache of decoded card thumbnails (≈ 560×240 px JPEGs, ~0.5 MB decoded each).
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

    /// Reads and fully decodes the JPEG on a background executor.
    @concurrent
    nonisolated private static func decode(_ url: URL) async -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return Decoded(image: image)
    }
}
