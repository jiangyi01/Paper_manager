import Foundation

/// What the Screen Recording explainer's [Continue] does (phase-3 fix F11 / PR-4). macOS shows its
/// own prompt only the first time an app asks, and the request call (`ScreenPermission.request`)
/// answers false at once while that prompt is still up — so opening System Settings on that first
/// `false` put two dialogs on screen at the same moment. The first Continue only asks; a later
/// Continue with access still off (macOS shows nothing any more: the prompt was answered or
/// dismissed) opens System Settings instead. Whether PaperDeck has asked before is a device-local
/// marker (never exported, not a setting). Pure; the App's `ScreenPermission` acts on it.
package enum ScreenPermissionFlow {
    /// The device-local marker "the explainer has asked macOS once" (UserDefaults; not in the
    /// settings registry, so never exported or imported).
    package static let requestedKey = "explain.screenCapture.requested"

    /// After `request()` answered `granted`: open System Settings only when an earlier request is on
    /// record (`requestedBefore`) and access is still off.
    package static func opensSettings(granted: Bool, requestedBefore: Bool) -> Bool {
        !granted && requestedBefore
    }

    /// Notes that a request is being made now; returns whether one was made before.
    @discardableResult
    package static func noteRequest(in defaults: UserDefaults) -> Bool {
        let before = defaults.bool(forKey: requestedKey)
        if !before { defaults.set(true, forKey: requestedKey) }
        return before
    }
}
