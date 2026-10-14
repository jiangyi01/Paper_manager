import SwiftUI
import PaperDeckCore

/// One line of the 今天 list (§8 今天分区): title with the DDL chip at its end, the byline (or
/// today's plan) with the progress, and up to two unchecked checklist items that can be ticked
/// inline. Rows of papers not due yet (本周接下来) keep their steps folded: their progress
/// (`0/3 · 48′ left ›`) unfolds them. Pure SwiftUI, display + callbacks.
struct TodayRow: View {
    static let inlineItems = 2

    let row: PaperRow
    let today: LocalDate
    let lang: UILang
    /// Today's planned slice (今日计划); nil for overdue / due-today / upcoming rows.
    let minutesToday: Int?
    /// The steps start folded (upcoming papers: nothing to tick today).
    let stepsCollapsed: Bool
    let onToggle: (String) -> Void
    let onOpen: () -> Void

    /// Items ticked here but not yet confirmed by the next snapshot (instant feedback).
    @State private var ticked: Set<String> = []
    @State private var hovering = false
    @State private var stepsShown = false

    init(row: PaperRow, today: LocalDate, lang: UILang, minutesToday: Int?, stepsCollapsed: Bool = false,
         onToggle: @escaping (String) -> Void, onOpen: @escaping () -> Void) {
        self.row = row
        self.today = today
        self.lang = lang
        self.minutesToday = minutesToday
        self.stepsCollapsed = stepsCollapsed
        self.onToggle = onToggle
        self.onOpen = onOpen
    }

    private var paper: Paper { row.paper }
    private var unchecked: [ChecklistItem] { row.checklist.filter { !$0.isDone } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            subline
            items
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.75))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 5 : 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { onOpen() }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: row.checklist)
        .onChange(of: row.checklist) { _, _ in ticked.removeAll() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L.cardsTodayOpenDetailsA11y) { onOpen() }
    }

    // MARK: Parts

    /// The title, and the DDL chip at the end of its first line.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            titleText
                .frame(maxWidth: .infinity, alignment: .leading)
            DDLChip(spec: row.cardChipSpec(today: today, lang: lang),
                    atRiskHint: row.cardAtRiskHint(today: today, lang: lang))
        }
    }

    /// The byline (or today's plan) and the progress at the end of the line. On a row whose steps
    /// start folded the progress is the disclosure (`0/3 · 48′ left ›`).
    private var subline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            subtitle
            Spacer(minLength: 0)
            let open = unchecked.count
            if stepsCollapsed, open > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { stepsShown.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        progress
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(stepsShown ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(stepsShown ? L.Library.hideSteps : L.Library.showSteps(open))
                .accessibilityLabel(L.Library.stepsA11y(open, expanded: stepsShown))
            } else {
                progress.fixedSize()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ProgressRing(done: row.doneCount, total: row.totalCount, size: 14)
            Text(CardText.progress(row, lang: lang))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var titleText: some View {
        let text = CardText.displayTitle(paper)
        var marks: [Text] = []
        if !paper.aiSeen {
            marks.append(Text(Image(systemName: "circle.fill")).font(.system(size: 6)).foregroundStyle(Color.blue))
        }
        if paper.priority == .high {
            marks.append(Text(Image(systemName: "flag.fill")).font(.system(size: 10))
                .foregroundStyle(ChipPalette.dynamic(light: 0xD32F2F, dark: 0xFF6B61)))
        }
        let base = Text(text).italic(CardText.metadataPending(paper))
        let composed = marks.reduce(Text("")) { acc, mark in Text("\(acc)\(mark) ") }
        return Text("\(composed)\(base)")
            .font(.system(size: 13.5, weight: .semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(text)
            .accessibilityLabel(titleA11y(text))
    }

    private func titleA11y(_ text: String) -> String {
        var parts = [text]
        if paper.priority == .high { parts.append(L.cardsHighPriority) }
        if !paper.aiSeen { parts.append(L.cardsNewShort) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var subtitle: some View {
        if let minutes = minutesToday {
            let ddl = paper.scheduleMode == .none ? nil
                : paper.deadline.map { SharedStrings.relativeDay($0, today: today, lang: lang, calendar: .current) }
            Label {
                Text(L.cardsTodayPlanLine(minutes: minutes, deadline: ddl))
            } icon: {
                Image(systemName: "book.pages")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .labelStyle(.titleAndIcon)
        } else {
            let line = CardText.byline(paper, venue: CardText.venue(paper).name)
            if !line.isEmpty {
                Text(line)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var items: some View {
        let open = unchecked
        if !open.isEmpty, !stepsCollapsed || stepsShown {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(open.prefix(Self.inlineItems)) { item in
                    itemLine(item)
                }
                if open.count > Self.inlineItems {
                    Text(L.cardsTodayMoreItems(open.count - Self.inlineItems))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 24)
                }
            }
            .padding(.top, 4)
        }
    }

    private func itemLine(_ item: ChecklistItem) -> some View {
        let isTicked = ticked.contains(item.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                ticked.insert(item.id)
                onToggle(item.id)
            } label: {
                Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isTicked ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTicked)
            .accessibilityLabel(L.cardsTodayTickA11y(item.text))

            if let locator = Self.locator(item) {
                Text(locator)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .fixedSize()
            }
            Text(item.text)
                .font(.system(size: 12))
                .strikethrough(isTicked)
                .foregroundStyle(isTicked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text("\(item.minutes)′")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// Section chip text, e.g. `Fig. 2 · p.5`, `p.5`, `Fig. 2`.
    static func locator(_ item: ChecklistItem) -> String? {
        let section = item.section?.trimmingCharacters(in: .whitespaces)
        switch (section.flatMap { $0.isEmpty ? nil : $0 }, item.page) {
        case let (s?, p?): return "\(s) · p.\(p)"
        case let (s?, nil): return s
        case let (nil, p?): return "p.\(p)"
        default: return nil
        }
    }
}
