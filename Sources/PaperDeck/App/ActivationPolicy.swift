import AppKit

/// PaperDeck lives in the menu bar (`.accessory`). While the library, onboarding, Help, a reader or
/// an Ask window is on screen it is a regular app (Dock icon, ⌘-Tab, Dock drops), so a new user can find the window
/// again; when the last of them closes it goes back to the menu bar only.
enum ActivationPolicy {
    /// Windows that make PaperDeck a regular app (set as their `identifier`).
    static let library = NSUserInterfaceItemIdentifier("PaperDeckLibraryWindow")
    static let onboarding = NSUserInterfaceItemIdentifier("PaperDeckOnboardingWindow")
    static let help = NSUserInterfaceItemIdentifier("PaperDeckHelpWindow")
    /// The built-in reader's windows (Slice C, C4).
    static let reader = ReaderWindowController.windowIdentifier
    /// The Ask windows (several papers, Slice C, C3).
    static let ask = NSUserInterfaceItemIdentifier("PaperDeckAskWindow")
    private static let regularWindows: Set<NSUserInterfaceItemIdentifier> = [library, onboarding, help, reader, ask]

    /// `closing`: a window in `windowWillClose` (still visible at that moment).
    static func update(closing: NSWindow? = nil) {
        let regular = NSApp.windows.contains { w in
            w !== closing && w.isVisible && w.identifier.map(regularWindows.contains) == true
        }
        let wanted: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// Before showing one of those windows.
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
}
