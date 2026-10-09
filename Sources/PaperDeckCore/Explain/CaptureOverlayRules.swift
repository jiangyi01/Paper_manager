import CoreGraphics
import Foundation

// The overlay's decisions, pure so they are tested without a window (fix-capture-ux): what a key
// does (CUX-10), when the system pulls the overlay away (CUX-3) and where the HUD pill sits (CUX-14).
// `CaptureOverlayController` (App) only forwards events here and acts on the answer.

/// The overlay's keys.
package enum CaptureOverlayKeys {
    package enum Action: Sendable, Equatable {
        /// Esc: close, nothing sent.
        case dismiss
        /// Space: frame ↔ lens.
        case toggleMode
        /// Return / keypad Enter: the clipboard offer (the key press is the gesture).
        case explainOffer
        /// Tab: this request's answer language.
        case toggleLanguage
        /// Taken and ignored (a held Space repeating would flip the mode back and forth).
        case swallow
        /// Not the overlay's: the panel's normal handling.
        case pass
    }

    /// Keypad Enter (Return is `HotKeySpec.Key.returnKey`).
    package static let keypadEnter = 0x4C

    package static func action(keyCode: Int, isRepeat: Bool) -> Action {
        switch keyCode {
        case HotKeySpec.Key.escape: return .dismiss
        case HotKeySpec.Key.space: return isRepeat ? .swallow : .toggleMode
        case HotKeySpec.Key.returnKey, keypadEnter: return isRepeat ? .swallow : .explainOffer
        case HotKeySpec.Key.tab: return isRepeat ? .swallow : .toggleLanguage
        default: return .pass
        }
    }

    /// The language after a Tab (CUX-10): the other one of what this request would use now — the
    /// earlier Tab's choice, else the setting (`.ui` follows the interface), not always 中 first.
    package static func language(afterTab current: UILang?, setting: AssistSettings.ExplainLanguage, ui: UILang) -> UILang {
        ExplainLanguageToggle.toggled(current ?? ExplainLanguageToggle.initial(setting, ui: ui))
    }
}

/// When the system takes the overlay's ground away (CUX-3).
package enum CaptureOverlayLifecycle {
    /// One display as the overlay saw it (id, AppKit frame).
    package struct Display: Sendable, Equatable {
        package var id: UInt32
        package var frame: CGRect

        package init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
    }

    package enum Event: Sendable, Equatable {
        /// Another Space became active: the frozen still shows the old one, and the window under a
        /// later release would be on the new one (its app and title wouldn't match the pixels).
        case activeSpaceChanged
        /// The display configuration notification, with the displays when the overlay opened and now.
        case screensChanged(opened: [Display], now: [Display])
        /// The displays went to sleep (the still is stale, a new one would be black).
        case displaysSlept
        /// Another user took the console (fast user switching), or the screen locked.
        case sessionResigned
    }

    package enum Reaction: Sendable, Equatable {
        /// Close the overlay: nothing is sent, the still is dropped.
        case dismiss
        /// Nothing changed that matters (a spurious configuration notification).
        case keep
    }

    package static func reaction(to event: Event) -> Reaction {
        switch event {
        case .activeSpaceChanged, .displaysSlept, .sessionResigned:
            return .dismiss
        case .screensChanged(let opened, let now):
            // The stills and the panels are per display: any display added, removed, moved or resized
            // means they no longer line up.
            let key: (Display) -> UInt32 = { $0.id }
            return opened.sorted { key($0) < key($1) } == now.sorted { key($0) < key($1) } ? .keep : .dismiss
        }
    }
}

/// The HUD pill (CUX-14): at the top edge of the active display, just under the menu bar / notch; it
/// steps to the bottom edge while the pointer is in its band (so a box can start where it was) and
/// back when the pointer reaches the bottom band; hidden while a box is being drawn.
package enum CaptureHUD {
    package enum Edge: String, Sendable, Equatable { case top, bottom }

    /// The pill's height and its distance from the edge (points).
    package static let height: CGFloat = 40
    package static let margin: CGFloat = 8
    /// The pointer this close to the pill's band (points) moves it away.
    package static let clearance: CGFloat = 36
    /// The offer chip sits this far from the bottom edge (points).
    package static let bottomInset: CGFloat = 48

    /// The band (display-local points, y down) the pill occupies at `edge`, widened by `clearance`.
    package static func zone(_ edge: Edge, displaySize: CGSize, topInset: CGFloat) -> CGRect {
        let h = height + clearance
        switch edge {
        case .top: return CGRect(x: 0, y: 0, width: displaySize.width, height: topInset + margin + h)
        case .bottom:
            let top = displaySize.height - bottomInset - margin - h
            return CGRect(x: 0, y: top, width: displaySize.width, height: displaySize.height - top)
        }
    }

    /// The edge after the pointer moved to `cursor` (display-local; nil: off this display).
    package static func edge(current: Edge, cursor: CGPoint?, displaySize: CGSize, topInset: CGFloat) -> Edge {
        guard let cursor else { return current }
        guard zone(current, displaySize: displaySize, topInset: topInset).contains(cursor) else { return current }
        let other: Edge = current == .top ? .bottom : .top
        // Both bands under the pointer (a tiny display): stay.
        return zone(other, displaySize: displaySize, topInset: topInset).contains(cursor) ? current : other
    }

    /// The pill is drawn (and takes the mouse) only while no box is being drawn.
    package static func isShown(dragging: Bool) -> Bool { !dragging }
}
