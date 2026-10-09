import SwiftUI
import PaperDeckCore

/// The floating bar over the card grid while two or more papers are selected (READING_ASSIST_PLAN
/// §6.4 C1, §7 "Selection"; DQ §5.3): `12 selected · Status · Priority · Category · DDL · Tags ·
/// Read with AI… · Ask · Check for Duplicates · Export · Move to Recently Deleted · ✕`. In Recently Deleted:
/// `Restore 12 · Delete 12 Permanently… · ✕`. A glass capsule on screen (`.material` in offscreen
/// renders); it falls back to icons only, then to one Actions menu, when the column is narrow.
/// `CardGridView` places it. Owned by Slice C.
struct SelectionBar: View {
    let state: AppState
    var style: PanelChromeStyle = .glass

    var body: some View {
        let rows = state.selection.targetRows
        if rows.count >= 2 {
            let menus = BatchMenus(state: state, rows: rows)
            ViewThatFits(in: .horizontal) {
                bar(menus, count: rows.count, titles: true)
                bar(menus, count: rows.count, titles: false)
                compact(menus, count: rows.count)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func bar(_ menus: BatchMenus, count: Int, titles: Bool) -> some View {
        HStack(spacing: titles ? 6 : 2) {
            countLabel(count)
            Divider().frame(height: 18)
            if menus.allDeleted {
                menus.restoreButton(short: true)
                menus.deleteNowButton(short: true)
            } else {
                menus.statusMenu
                menus.priorityMenu
                menus.categoryMenu
                menus.deadlineMenu
                menus.tagsMenu
                Divider().frame(height: 18)
                menus.rereadButton(short: true)
                AskAcrossButton(state: state, rows: menus.rows, short: true)
                menus.duplicatesButton
                menus.exportMenu
                menus.trashButton(short: true)
            }
            Divider().frame(height: 18)
            menus.clearButton.labelStyle(.iconOnly)
        }
        .labelStyle(BarLabelStyle(titles: titles))
        .modifier(BarControls())
        .selectionBarChrome(style)
        .fixedSize()
    }

    /// The narrowest form: the count, one Actions menu (every action), ✕.
    private func compact(_ menus: BatchMenus, count: Int) -> some View {
        HStack(spacing: 6) {
            countLabel(count)
            Menu {
                if menus.allDeleted {
                    menus.restoreButton()
                    menus.deleteNowButton()
                } else {
                    menus.statusMenu
                    menus.priorityMenu
                    menus.categoryMenu
                    menus.deadlineMenu
                    menus.tagsMenu
                    Divider()
                    menus.rereadButton()
                    AskAcrossButton(state: state, rows: menus.rows)
                    menus.duplicatesButton
                    menus.exportMenu
                    Divider()
                    menus.trashButton()
                }
            } label: {
                Label(L.Select.actions, systemImage: "ellipsis.circle")
            }
            menus.clearButton.labelStyle(.iconOnly)
        }
        .labelStyle(BarLabelStyle(titles: true))
        .modifier(BarControls())
        .selectionBarChrome(style)
        .fixedSize()
    }

    private func countLabel(_ count: Int) -> some View {
        Text(L.Select.selected(count))
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .padding(.leading, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Titles + icons, or icons only (the full title stays in each control's help and accessibility label).
private struct BarLabelStyle: LabelStyle {
    let titles: Bool

    func makeBody(configuration: Configuration) -> some View {
        if titles {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        } else {
            configuration.icon
        }
    }
}

private struct BarControls: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            // One weight for the bar's buttons and menus: a borderless button otherwise draws dimmed
            // next to the menus whenever the window isn't key, as if it were disabled.
            .foregroundStyle(.primary)
            .controlSize(.regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
    }
}

extension View {
    /// The bar's capsule: Liquid Glass on screen, regular material where glass can't be captured.
    func selectionBarChrome(_ style: PanelChromeStyle) -> some View {
        modifier(SelectionBarChrome(style: style))
    }
}

private struct SelectionBarChrome: ViewModifier {
    let style: PanelChromeStyle

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        case .material:
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}
