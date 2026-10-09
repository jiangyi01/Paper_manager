import AppKit
import PaperDeckCore

/// The reading-assist menu items (READING_ASSIST_PLAN §6.1, §8 "Menus"), kept out of the window
/// and status-bar controllers so each of those gains one call line. Every item is added only once
/// its slice ships (`AssistRollout`); until then nothing is added and the menus look as before.
/// The actions go to the slices' models (`AppState.selection` / `.dedupe`, `ExplainBootstrap`).
/// Lead-owned (Slice 0).
enum ReadingAssistMenus {
    /// Edit ▸ Select ▸ All Papers / Deselect All (Slice C), after Edit ▸ Select All.
    static func appendSelectItems(to edit: NSMenu, state: AppState?) {
        guard AssistRollout.selection else { return }
        let target = ReadingAssistMenuTarget.shared(state)
        let sub = NSMenu(title: L.Select.submenu)
        sub.addItem(item(L.Select.allPapers, #selector(ReadingAssistMenuTarget.selectAllPapers), target: target))
        sub.addItem(item(L.Select.none, #selector(ReadingAssistMenuTarget.deselectAll), target: target))
        let holder = NSMenuItem(title: L.Select.submenu, action: nil, keyEquivalent: "")
        holder.submenu = sub
        edit.addItem(holder)
    }

    /// The Library menu (Slice B: Check for Duplicates…) and the Explain menu (Slice A), appended to
    /// `main` — call between Edit and Window.
    static func appendMenus(to main: NSMenu, state: AppState?) {
        let target = ReadingAssistMenuTarget.shared(state)
        if AssistRollout.dedupe {
            add(L.Dedupe.libraryMenu, [
                item(L.Dedupe.checkForDuplicates, #selector(ReadingAssistMenuTarget.checkForDuplicates), target: target),
            ], to: main)
        }
        if AssistRollout.explain {
            add(L.Explain.menu, explainItems(target, state: state), to: main)
        }
    }

    /// The menu-bar menu's Explain items (Slice A), beside Add PDF.
    static func appendAssistItems(to menu: NSMenu, state: AppState) {
        guard AssistRollout.explain else { return }
        menu.addItem(.separator())
        explainItems(ReadingAssistMenuTarget.shared(state), state: state).forEach(menu.addItem)
    }

    private static func explainItems(_ target: ReadingAssistMenuTarget, state: AppState?) -> [NSMenuItem] {
        let explain = item(L.Explain.explainEllipsis, #selector(ReadingAssistMenuTarget.explain), target: target)
        if let key = explainShortcut(state) {
            // Shown for reference (R-UI-5): the global shortcut fires first wherever PaperDeck is.
            explain.keyEquivalent = key.key
            explain.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: key.flags)
        }
        return [
            explain,
            item(L.Explain.explainCopiedText, #selector(ReadingAssistMenuTarget.explainCopiedText), target: target),
            item(L.Explain.history, #selector(ReadingAssistMenuTarget.explanationHistory), target: target),
        ]
    }

    /// Explain…'s shortcut while it is registered; none while the switch is off or another app holds
    /// it (LN §3: the item is then the way in, without a shortcut that wouldn't fire).
    static func explainShortcut(_ state: AppState?) -> (key: String, flags: UInt)? {
        guard let state, ExplainBootstrap.coordinator?.hotKeyStatus == .registered else { return nil }
        return HotKeySpec.menuKeyEquivalent(state.settings.assist.explainHotKey)
    }

    private static func add(_ title: String, _ items: [NSMenuItem], to main: NSMenu) {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        main.addItem(holder)
    }

    private static func item(_ title: String, _ action: Selector, target: AnyObject) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target
        return i
    }
}

/// The stub actions: they call the slices' entry points (inert until each slice fills them).
final class ReadingAssistMenuTarget: NSObject {
    private static let instance = ReadingAssistMenuTarget()
    private weak var state: AppState?

    /// The one target, pointed at the current state (menus are rebuilt per show).
    static func shared(_ state: AppState?) -> ReadingAssistMenuTarget {
        if let state { instance.state = state }
        return instance
    }

    @objc func selectAllPapers() { state?.selection.selectAllVisible() }
    @objc func deselectAll() { state?.selection.clear() }
    @objc func checkForDuplicates() {
        guard let state else { return }
        // A multi-selection checks those papers; one focused paper (or none) means the whole library.
        state.dedupe.checkSelected(ids: state.selection.isMulti ? state.selection.targetIDs : [])
    }
    @objc func explain() { ExplainBootstrap.coordinator?.arm(mode: state?.settings.assist.explainDefaultMode ?? .frame) }
    @objc func explainCopiedText() { ExplainBootstrap.coordinator?.explainClipboard() }
    @objc func explanationHistory() { ExplainBootstrap.coordinator?.showHistory() }
}
