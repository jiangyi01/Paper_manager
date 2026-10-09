import AppKit
import SwiftUI
import WidgetKit
import PaperDeckShared

// MARK: - Shared pieces

/// Compact DDL chip (mirrors the app's DDLChip styles).
struct WidgetChip: View {
    let spec: ChipSpec

    var body: some View {
        HStack(spacing: 2) {
            if spec.style == .overdue { Image(systemName: "exclamationmark.circle.fill") }
            if spec.pinned { Image(systemName: "pin.fill") }
            Text(spec.text).lineLimit(1)
            if spec.atRisk { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .overlay {
            if spec.style == .unscheduled || spec.provisional {
                Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: spec.provisional ? [1.5, 1.5] : [3, 2]))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var foreground: Color {
        switch spec.style {
        case .done: return .green
        case .overdue, .today: return .white
        case .unscheduled, .later: return .secondary
        default: return .primary
        }
    }

    private var background: Color {
        switch spec.style {
        case .overdue: return .red
        case .today: return .orange
        case .tomorrow: return .orange.opacity(0.22)
        case .soon: return .yellow.opacity(0.25)
        case .thisWeek: return .gray.opacity(0.18)
        default: return .clear
        }
    }
}

struct ThinProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: total > 0 ? g.size.width * CGFloat(done) / CGFloat(total) : 0)
            }
        }
        .frame(height: 3)
    }
}

enum WidgetPalette {
    static let colors: [Color] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .cyan, .indigo]
    static func color(_ hue: Int?) -> Color { colors[((hue ?? 0) % colors.count + colors.count) % colors.count] }
}

/// Loads a snapshot thumbnail (paths are relative to the widget directory).
func widgetThumbnail(_ relative: String?) -> NSImage? {
    guard let relative, !relative.contains("..") else { return nil }
    return NSImage(contentsOf: SharedPaths.widgetDirectory.appendingPathComponent(relative))
}

struct StaleFooter: View {
    let entry: SnapshotEntry
    var body: some View {
        if entry.isStale {
            Text(SharedStrings.Widget.stale(entry.lang)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PlaceholderView: View {
    let lang: UILang
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(.tint)
            Text(SharedStrings.Widget.placeholder(lang)).font(.caption).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .widgetURL(DeepLink.today.url)
    }
}

// MARK: - 今日待读

struct TodayReadingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snap = entry.snapshot {
            content(snap)
        } else {
            PlaceholderView(lang: entry.lang)
        }
    }

    @ViewBuilder
    private func content(_ snap: WidgetSnapshot) -> some View {
        let day = entry.day
        let ids = day?.ids ?? []
        let papers = ids.compactMap { id in snap.papers[id].map { (id, $0) } }
        switch family {
        case .systemSmall: small(snap, day: day, papers: papers)
        case .systemLarge: list(snap, day: day, papers: papers, limit: 6, rich: true)
        default: list(snap, day: day, papers: papers, limit: 3, rich: false)
        }
    }

    private func small(_ snap: WidgetSnapshot, day: WidgetSnapshot.Day?, papers: [(String, WidgetSnapshot.PaperEntry)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(day?.count ?? 0)").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(SharedStrings.aboutMinutesShort(day?.minutes ?? 0, entry.lang)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let overdue = day?.overdue, overdue > 0 {
                Text(SharedStrings.Widget.overdueCount(overdue, entry.lang)).font(.caption.bold()).foregroundStyle(.red)
            }
            if let first = papers.first?.1 {
                Text(first.title).font(.caption).lineLimit(2)
            } else {
                Text(SharedStrings.Widget.nothingToday(entry.lang)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text(SharedStrings.Widget.backlog(snap.backlog.total, entry.lang)).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                StaleFooter(entry: entry)
            }
        }
        .widgetURL(DeepLink.today.url)
    }

    private func list(_ snap: WidgetSnapshot, day: WidgetSnapshot.Day?, papers: [(String, WidgetSnapshot.PaperEntry)],
                      limit: Int, rich: Bool) -> some View {
        VStack(alignment: .leading, spacing: rich ? 8 : 6) {
            HStack {
                Label(SharedStrings.Widget.todayKind(entry.lang), systemImage: "books.vertical.fill")
                    .font(.caption.bold()).foregroundStyle(.tint)
                Spacer()
                Text("\(day?.count ?? 0) · \(SharedStrings.aboutMinutesShort(day?.minutes ?? 0, entry.lang))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if papers.isEmpty {
                Spacer()
                Text(SharedStrings.Widget.nothingToday(entry.lang)).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(papers.prefix(limit), id: \.0) { id, p in
                    Link(destination: DeepLink.paper(id: id).url) { row(p, rich: rich) }
                }
                if papers.count > limit {
                    Text(SharedStrings.Widget.more(papers.count - limit, entry.lang)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text(SharedStrings.Widget.backlog(snap.backlog.total, entry.lang)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                StaleFooter(entry: entry)
            }
        }
    }

    private func row(_ p: WidgetSnapshot.PaperEntry, rich: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                WidgetChip(spec: p.chip(today: entry.today, lang: entry.lang))
                Text(p.title).font(.caption.weight(.medium)).lineLimit(rich ? 2 : 1)
                Spacer(minLength: 0)
                Text("\(p.done)/\(p.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if rich {
                ThinProgress(done: p.done, total: p.total)
                if let next = p.next.first {
                    Text(SharedStrings.Widget.nextItem(next.text)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - 最近添加

struct RecentCardsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snap = entry.snapshot, !snap.recentIds.isEmpty {
            let limit = family == .systemLarge ? 4 : 2
            let items = snap.recentIds.prefix(limit).compactMap { id in snap.papers[id].map { (id, $0) } }
            VStack(alignment: .leading, spacing: 8) {
                Label(SharedStrings.Widget.recentKind(entry.lang), systemImage: "sparkles.rectangle.stack")
                    .font(.caption.bold()).foregroundStyle(.tint)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(items, id: \.0) { id, p in
                        Link(destination: DeepLink.paper(id: id).url) { MiniCard(entry: entry, paper: p, showTLDR: family == .systemLarge) }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            PlaceholderView(lang: entry.lang)
        }
    }
}

struct MiniCard: View {
    let entry: SnapshotEntry
    let paper: WidgetSnapshot.PaperEntry
    let showTLDR: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let img = widgetThumbnail(paper.thumb) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(height: showTLDR ? 54 : 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(paper.title).font(.caption2.weight(.semibold)).lineLimit(2)
            HStack(spacing: 4) {
                if let c = paper.category {
                    Circle().fill(WidgetPalette.color(paper.hue)).frame(width: 6, height: 6)
                    Text(c).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                WidgetChip(spec: paper.chip(today: entry.today, lang: entry.lang))
            }
            if showTLDR, let tldr = paper.tldr {
                Text(tldr).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
