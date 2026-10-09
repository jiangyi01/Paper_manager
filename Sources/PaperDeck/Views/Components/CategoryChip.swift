import SwiftUI
import PaperDeckCore

/// Coloured category chip (§8 卡片「分类/标签」). Nil → a neutral 「未分类」 chip.
struct CategoryChip: View {
    let category: PaperCategory?
    let lang: UILang

    init(category: PaperCategory?, lang: UILang) {
        self.category = category
        self.lang = lang
    }

    var body: some View {
        if let category {
            let ink = ChipPalette.color(hue: category.hue)
            HStack(spacing: 4) {
                Circle().fill(ink).frame(width: 6, height: 6)
                Text(category.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(ChipPalette.fill(hue: category.hue)))
            .help(category.description ?? category.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L.cardsCategoryA11y(category.name))
        } else {
            Text(L.cardsUncategorized)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .accessibilityLabel(L.cardsCategoryA11y(L.cardsUncategorized))
        }
    }
}
