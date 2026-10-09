import SwiftUI
import PaperDeckCore

/// Up to `limit` `#tag` chips plus `+N` for the rest (§8 卡片「最多 2 个 #tag，多余的显示 +N」).
/// When the row is too narrow it drops tags into the `+N` count instead of clipping them.
struct TagChips: View {
    let tags: [Tag]
    var limit: Int = 2

    init(tags: [Tag], limit: Int = 2) {
        self.tags = tags
        self.limit = max(0, limit)
    }

    var body: some View {
        if !tags.isEmpty {
            let shown = min(limit, tags.count)
            ViewThatFits(in: .horizontal) {
                ForEach((0...shown).reversed(), id: \.self) { k in
                    row(showing: k)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L.cardsTagsA11y(tags.map(\.name)))
        }
    }

    private func row(showing k: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(k), id: \.name) { tag in
                Text("#" + tag.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .fixedSize()
            }
            if tags.count > k {
                Text("+\(tags.count - k)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help(tags.dropFirst(k).map { "#" + $0.name }.joined(separator: "  "))
            }
        }
    }
}
