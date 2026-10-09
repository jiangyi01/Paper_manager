import Foundation

/// What a DDL chip shows. Views map `style` to colours/borders and the flags to
/// `pin.fill`, the dotted frame and the orange triangle — colour never carries
/// meaning alone, the text always does.
public struct ChipSpec: Sendable, Equatable, Hashable {
    public enum Style: String, Sendable, Equatable, Hashable, CaseIterable {
        case done           // ✓ 9/28, green text
        case unscheduled    // 未排期, grey dashed frame
        case overdue        // 逾期 N 天, red fill + icon
        case today          // 今天, orange fill
        case tomorrow       // 明天, light orange
        case soon           // Δ 2–3: 周四, light yellow
        case thisWeek       // Δ 4–6: 周一 10/5, grey fill
        case later          // Δ ≥ 7: 10/15
    }

    public var text: String
    public var style: Style
    public var pinned: Bool
    public var provisional: Bool     // text carries the ≈ prefix; draw a dotted frame
    public var atRisk: Bool

    public init(text: String, style: Style, pinned: Bool = false, provisional: Bool = false, atRisk: Bool = false) {
        self.text = text; self.style = style; self.pinned = pinned
        self.provisional = provisional; self.atRisk = atRisk
    }
}

/// The single implementation of the §8 DDLChip table, shared by the app's
/// cards, the menu bar and the widget (which evaluates it per timeline entry,
/// so `today` is always passed in rather than read from the clock).
public enum DeadlineLabel {
    /// - Parameters:
    ///   - deadline: nil for unscheduled papers (callers pass nil when schedule mode is `none`).
    ///   - done / doneAt: a read paper shows `✓ M/D` of its local completion day.
    ///   - atRisk: only meaningful for Δ ≥ 0 (an overdue paper is simply overdue).
    public static func chip(deadline: LocalDate?, done: Bool, doneAt: LocalDate?, pinned: Bool,
                            provisional: Bool, atRisk: Bool, today: LocalDate, lang: UILang,
                            calendar: Calendar = Calendar(identifier: .gregorian)) -> ChipSpec {
        if done { return ChipSpec(text: SharedStrings.doneOn(doneAt), style: .done) }
        guard let deadline else { return ChipSpec(text: SharedStrings.unscheduled(lang), style: .unscheduled) }

        let delta = deadline.days(from: today)
        let style: ChipSpec.Style
        switch delta {
        case ..<0: style = .overdue
        case 0: style = .today
        case 1: style = .tomorrow
        case 2...3: style = .soon
        case 4...6: style = .thisWeek
        default: style = .later
        }
        let base = SharedStrings.relativeDay(deadline, today: today, lang: lang, calendar: calendar)
        return ChipSpec(text: provisional ? "≈" + base : base, style: style, pinned: pinned,
                        provisional: provisional, atRisk: atRisk && delta >= 0)
    }

    /// Tooltip for the at-risk triangle, e.g. `按当前预算预计 周一 才能读完`.
    /// `finish` nil = the simulation could not fit the paper inside the horizon.
    public static func atRiskHint(finish: LocalDate?, today: LocalDate, lang: UILang,
                                  calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let label = finish.map { SharedStrings.relativeDay($0, today: today, lang: lang, calendar: calendar) }
        return SharedStrings.atRiskHint(finishLabel: label, lang)
    }
}
