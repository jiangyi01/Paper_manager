import Foundation

/// Which reading-assist surfaces ship in this build (READING_ASSIST_PLAN §6). Each flag is the
/// owning slice's own `isAvailable` constant, flipped in that slice's file when it lands; the
/// Lead-owned insertion points (menus, the Settings tab, the inspector's policy toggles, the
/// detail tabs) read them here, so a slice never edits a Lead file to switch itself on. Until a
/// flag is true its surface is hidden — no inert "coming soon" items. Lead-owned.
enum AssistRollout {
    /// Explain (Slice A): the Explain menu, the menu-bar items, the hotkey, Services.
    static var explain: Bool { ExplainCoordinator.isAvailable }
    /// Settings ▸ Explain & Ask (Slice A).
    static var assistSettings: Bool { AssistSettingsTab.isAvailable }
    /// The Ask tab (Slice C).
    static var ask: Bool { AskTab.isAvailable }
    /// Duplicate reviews (Slice B): Library ▸ Check for Duplicates….
    static var dedupe: Bool { DedupeUIModel.isAvailable }
    /// Multi-select (Slice C): Edit ▸ Select ▸ ….
    static var selection: Bool { SelectionModel.isAvailable }
    /// The AI duplicate judge (Slice B3): its UI ships with Settings ▸ Explain & Ask (without
    /// `assist.mode` no judge turn can run). Off by default even then, and only ever on a click.
    static var dedupeJudge: Bool { DedupeUIModel.judgeShips }
    /// The inspector's "Unpublished / confidential" and "Never use AI" toggles: they matter once
    /// any surface that can send a paper's content to an AI ships (Explain, Ask, the AI duplicate
    /// judge) — not with the local duplicate check, which never sends anything.
    static var policyToggles: Bool { explain || ask || dedupeJudge }
}
