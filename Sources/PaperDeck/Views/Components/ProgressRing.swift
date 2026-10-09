import SwiftUI

/// Checklist progress ring (§8 卡片「环形进度（Shape）」). Accent while in progress,
/// green with a check when complete, an empty track without a checklist.
struct ProgressRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.5

    init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    init(done: Int, total: Int, size: CGFloat, lineWidth: CGFloat? = nil) {
        self.done = done
        self.total = total
        self.size = size
        self.lineWidth = lineWidth ?? max(1.5, size * 0.16)
    }

    private var fraction: Double { total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0 }
    private var complete: Bool { total > 0 && done >= total }
    private static let doneGreen = ChipPalette.dynamic(light: 0x1B7F3B, dark: 0x62D384)

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.13), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(complete ? Self.doneGreen : Color.accentColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if complete {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .heavy))
                    .foregroundStyle(Self.doneGreen)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.cardsChecklistA11y(done: done, total: total))
    }
}
