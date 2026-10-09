import SwiftUI
import PaperDeckCore

/// Renders a `DeadlineLabel` chip (§8 DDLChip table). The text always carries the
/// meaning; colour, the pin, the dotted frame and the triangle only reinforce it.
struct DDLChip: View {
    let spec: ChipSpec
    /// Tooltip for the at-risk triangle (`DeadlineLabel.atRiskHint`). Nil → generic hint.
    var atRiskHint: String?

    init(spec: ChipSpec) {
        self.spec = spec
        self.atRiskHint = nil
    }

    init(spec: ChipSpec, atRiskHint: String?) {
        self.spec = spec
        self.atRiskHint = atRiskHint
    }

    var body: some View {
        let look = DDLChipLook(spec.style)
        HStack(spacing: 3) {
            if spec.style == .overdue {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9.5, weight: .bold))
            }
            if spec.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(spec.text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            if spec.atRisk {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(look.warningInk)
            }
        }
        .foregroundStyle(look.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(look.fill))
        .overlay { border(look) }
        .fixedSize()
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private func border(_ look: DDLChipLook) -> some View {
        if spec.provisional {
            // Dotted frame: tiny dashes with round caps.
            Capsule().strokeBorder(look.ink.opacity(0.85),
                                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [0.1, 2.8]))
        } else if spec.style == .unscheduled {
            Capsule().strokeBorder(Color.secondary.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else if spec.style == .later {
            Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
        }
    }

    private var tooltip: String {
        var lines: [String] = []
        if spec.atRisk { lines.append(atRiskHint ?? L.cardsAtRiskGeneric) }
        if spec.pinned { lines.append(L.cardsPinnedHelp) }
        if spec.provisional { lines.append(L.cardsProvisionalHelp) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [L.cardsDeadlineA11y(spec.text)]
        if spec.pinned { parts.append(L.cardsPinnedA11y) }
        if spec.provisional { parts.append(L.cardsProvisionalA11y) }
        if spec.atRisk { parts.append(atRiskHint ?? L.cardsAtRiskGeneric) }
        return parts.joined(separator: ", ")
    }
}

/// Colours per chip style (light/dark aware; filled styles pair with high-contrast ink).
private struct DDLChipLook {
    var ink: Color
    var fill: Color
    var warningInk: Color

    private static let orangeWarning = ChipPalette.dynamic(light: 0xB85A00, dark: 0xFFA94D)

    init(_ style: ChipSpec.Style) {
        warningInk = Self.orangeWarning
        switch style {
        case .done:
            ink = ChipPalette.dynamic(light: 0x1B7F3B, dark: 0x62D384)
            fill = .clear
        case .unscheduled:
            ink = .secondary
            fill = .clear
        case .overdue:
            ink = .white
            fill = ChipPalette.dynamic(light: 0xC62828, dark: 0xD4382E)
        case .today:
            ink = Color(red: 0.23, green: 0.11, blue: 0)
            fill = ChipPalette.dynamic(light: 0xFF9F0A, dark: 0xF5970A)
            warningInk = ink
        case .tomorrow:
            ink = ChipPalette.dynamic(light: 0x8A4300, dark: 0xFFB866)
            fill = ChipPalette.dynamic(light: 0xFF9F0A, dark: 0xFF9F0A, lightAlpha: 0.20, darkAlpha: 0.24)
        case .soon:
            ink = ChipPalette.dynamic(light: 0x6A5200, dark: 0xF2D36E)
            fill = ChipPalette.dynamic(light: 0xFFD60A, dark: 0xFFD60A, lightAlpha: 0.26, darkAlpha: 0.20)
        case .thisWeek:
            ink = Color.primary.opacity(0.78)
            fill = Color.primary.opacity(0.08)
        case .later:
            ink = .secondary
            fill = .clear
        }
    }
}

extension PaperRow {
    /// The §8 DDLChip spec for this paper as seen on `today`.
    func cardChipSpec(today: LocalDate, lang: UILang) -> ChipSpec {
        DeadlineLabel.chip(
            deadline: paper.scheduleMode == .none ? nil : paper.deadline,
            done: paper.status == .done,
            doneAt: paper.doneAt.map { LocalDate($0, calendar: .current) },
            pinned: paper.scheduleMode == .pinned,
            provisional: paper.provisional,
            atRisk: atRisk,
            today: today, lang: lang, calendar: .current)
    }

    /// Tooltip text for the at-risk triangle (nil when the paper is not at risk).
    func cardAtRiskHint(today: LocalDate, lang: UILang) -> String? {
        guard atRisk else { return nil }
        return DeadlineLabel.atRiskHint(finish: finish, today: today, lang: lang, calendar: .current)
    }
}
