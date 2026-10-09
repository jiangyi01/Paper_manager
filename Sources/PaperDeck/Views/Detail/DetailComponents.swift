import AppKit
import SwiftUI
import PaperDeckCore

// Small building blocks shared by the detail inspector's files. Everything here is
// prefixed `Detail…` so it can never collide with another slice's helpers.

// MARK: - Flow layout

/// Marks a `DetailDot` so the flow layout can drop it at line starts/ends.
nonisolated struct DetailFlowSeparator: LayoutValueKey {
    static let defaultValue = false
}

/// The `·` between items of a wrapping line; hidden when a line would start or end with it.
struct DetailDot: View {
    var body: some View {
        Circle()
            .fill(.tertiary)
            .frame(idealWidth: 3, idealHeight: 3)
            .layoutValue(key: DetailFlowSeparator.self, value: true)
            .accessibilityHidden(true)
    }
}

/// Left-aligned wrapping row (tags, the venue/year/doi line, button rows). Items in a line
/// are centred vertically; an item wider than the line is offered the full width (text wraps).
nonisolated struct DetailFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var height: CGFloat { items.map(\.size.height).max() ?? 0 }
        var width: CGFloat { items.reduce(0) { $0 + $1.size.width } }
    }

    private struct Arrangement {
        var lines: [Line] = []
        var hidden: [Int] = []               // separators dropped at a line break
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> Arrangement {
        var out = Arrangement()
        var current = Line()
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let separator = view[DetailFlowSeparator.self]
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !current.items.isEmpty, x + size.width > width {
                if let last = current.items.last, subviews[last.index][DetailFlowSeparator.self] {
                    current.items.removeLast()
                    out.hidden.append(last.index)
                }
                out.lines.append(current)
                current = Line()
                x = 0
            }
            if current.items.isEmpty, separator {
                out.hidden.append(i)
                continue
            }
            current.items.append((i, size))
            x += size.width + spacing
        }
        if let last = current.items.last, subviews[last.index][DetailFlowSeparator.self] {
            current.items.removeLast()
            out.hidden.append(last.index)
        }
        if !current.items.isEmpty { out.lines.append(current) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width).lines
        let used = lines.map { $0.width + spacing * CGFloat(max(0, $0.items.count - 1)) }.max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.map { min($0, used) } ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        var y = bounds.minY
        for line in arrangement.lines {
            var x = bounds.minX
            let height = line.height
            for item in line.items {
                let origin = CGPoint(x: x, y: y + (height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
        for i in arrangement.hidden {
            subviews[i].place(at: bounds.origin, proposal: .zero)
        }
    }
}

// MARK: - Chips

/// Grey capsule used for small status words ("inferred", "Preprint", "手动").
struct DetailCapsuleTag: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(verbatim: text)
        }
        .lineLimit(1)
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .background(Capsule().fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.quaternary)))
    }
}

/// `#tag` chip with an optional × button.
struct DetailTagChip: View {
    let name: String
    let origin: TagOrigin
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "#" + name)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L.Detail.removeTag(name))
                .accessibilityLabel(L.Detail.removeTag(name))
            }
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
        .help(origin == .agent ? L.Detail.tagFromClaude : L.Detail.tagFromUser)
    }
}

// MARK: - Text blocks

/// Plain-text bullet list (AI output is never parsed as Markdown).
struct DetailBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: "•").foregroundStyle(.tertiary)
                    Text(verbatim: text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// A paragraph of AI/metadata text.
struct DetailParagraph: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Muted one-liner shown where content is not available yet.
struct DetailPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Formatting

enum DetailFormat {
    static func statusName(_ s: PaperStatus) -> String {
        switch s {
        case .toRead: L.Detail.statusToRead
        case .reading: L.Detail.statusReading
        case .done: L.Detail.statusDone
        }
    }

    static func priorityName(_ p: Priority) -> String {
        switch p {
        case .low: L.Detail.priorityLow
        case .normal: L.Detail.priorityNormal
        case .high: L.Detail.priorityHigh
        }
    }

    private static var pathAllowed: CharacterSet {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "?#")
        return set
    }

    static func doiURL(_ doi: String) -> URL? {
        guard let enc = doi.addingPercentEncoding(withAllowedCharacters: pathAllowed) else { return nil }
        return URL(string: "https://doi.org/" + enc)
    }

    static func arxivURL(_ id: String, version: Int?) -> URL? {
        let stem = id + (version.map { "v\($0)" } ?? "")
        guard let enc = stem.addingPercentEncoding(withAllowedCharacters: pathAllowed) else { return nil }
        return URL(string: "https://arxiv.org/abs/" + enc)
    }

    /// Resource links: https + CardSanitizer's host allowlist, re-checked at display time.
    static func allowedResourceURL(_ raw: String?) -> URL? {
        guard let raw, let ok = CardSanitizer.allowedURL(.string(raw)) else { return nil }
        return URL(string: ok)
    }

    /// A size in the UI language (`L.bytes`).
    static func bytes(_ n: Int64) -> String { L.bytes(n) }

    /// `Fig. 2 · p.5`, `p.5`, `Methods`; nil when the item has no locator.
    static func locator(section: String?, page: Int?) -> String? {
        let parts = [section?.trimmingCharacters(in: .whitespacesAndNewlines), page.map { "p.\($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// `15:45` today, else `9/30 15:45`.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let time = clockFormatter.string(from: date)
        let day = LocalDate(date)
        return day == LocalDate(now) ? time : SharedStrings.monthDay(day) + " " + time
    }

    /// `9/29 10:42`.
    static func dayAndTime(_ date: Date) -> String {
        SharedStrings.monthDay(LocalDate(date)) + " " + clockFormatter.string(from: date)
    }

    /// `0:24`, `12:03`, `1:02:03`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Estimate shown when the paper has none yet: remaining minutes rounded up to 5 (≥ 5).
    static func fallbackEstimate(_ remaining: Int) -> Int {
        remaining > 0 ? max(5, (remaining + 4) / 5 * 5) : 30
    }

    /// "Sonnet" / "Opus" / "Haiku" from a CLI model id; nil when unknown.
    /// `claude-sonnet-4-5` → `Sonnet`; `gpt-5.6-terra` → `GPT-5.6-Terra`.
    static func modelName(_ model: String?) -> String? {
        guard let m = model?.lowercased(), !m.isEmpty else { return nil }
        for name in ["opus", "sonnet", "haiku"] where m.contains(name) { return name.capitalized }
        if m.hasPrefix("gpt-") { return CodexModelCatalog.displayName(m) }
        return model
    }

    /// Warnings derived from the file flags and the text quality (never colour alone).
    static func fileNotes(_ p: Paper) -> [(icon: String, text: String)] {
        var out: [(icon: String, text: String)] = []
        if p.flags.contains(.missing) { out.append(("questionmark.folder", L.Detail.flagMissing)) }
        if p.flags.contains(.locked) { out.append(("lock.doc", L.Detail.flagLocked)) }
        if p.flags.contains(.unreadable) { out.append(("exclamationmark.triangle", L.Detail.flagUnreadable)) }
        if p.flags.contains(.scanned) { out.append(("doc.text.magnifyingglass", L.Detail.flagScanned)) }
        if p.textQuality == .partial || p.textQuality == .poor {
            out.append(("text.badge.xmark", L.Detail.textIncomplete))
        }
        return out
    }
}

// MARK: - Engine calls

extension AppState {
    /// Runs an engine op for the detail view; `onError` rolls back optimistic UI first,
    /// then the failure becomes the usual error toast.
    func detailRun(_ op: @escaping () async throws -> Void, onError: @escaping () -> Void = {}) {
        Task {
            do { try await op() } catch {
                onError()
                report(error)
            }
        }
    }
}
