import CoreGraphics
import Foundation

/// The coordinator's consent, shortcut and privacy decisions, pure (phase-3 fix F5: the test target
/// doesn't link the app, so these rules live in Core with real tests and `ExplainCoordinator` /
/// `ExplainBootstrap` / `ExplainServiceProvider` only act on what they return). Nothing here mints a
/// ticket or starts a turn.
package enum ExplainTriggerRules {
    // MARK: The global shortcut

    /// What one press of the global shortcut does. There is deliberately no "send" case: the
    /// shortcut alone never sends anything (F4) — a turn needs ⏎ or a click after it.
    package enum HotKeyAction: Sendable, Equatable {
        /// Open the overlay in this mode (a warm Claude may start: no turn, no quota).
        case open(AssistSettings.OverlayMode)
        /// The overlay is up: switch frame ↔ lens.
        case toggleMode
        /// Pressed twice quickly while the overlay is up: show the "Explain copied text ⏎" offer
        /// (even for a clipboard explained before). Sending still needs ⏎ or a click on the offer.
        case showOffer
    }

    /// A second press within this many seconds is a double tap.
    package static let doubleTap: TimeInterval = 0.4

    /// The action of a press at `now`; `lastPress`: the previous press (nil: none yet).
    package static func onHotKey(overlayShown: Bool, lastPress: Date?, now: Date,
                                 defaultMode: AssistSettings.OverlayMode) -> HotKeyAction {
        guard overlayShown else { return .open(defaultMode) }
        if let lastPress, now >= lastPress, now.timeIntervalSince(lastPress) < doubleTap { return .showOffer }
        return .toggleMode
    }

    /// A warm Claude may be started when the shortcut arms Explain: the switch on and "Keep Claude
    /// ready" on (the lane's gate still checks the spawn).
    package static func prewarms(_ s: AssistSettings) -> Bool { s.mode != .off && s.keepWarmSeconds > 0 }

    // MARK: The clipboard offer

    /// ⏎ / a click on the offer reads the pasteboard only while it still holds what was offered
    /// (something copied since — even by another app — is not sent unseen).
    package static func offerIsCurrent(_ offer: ClipboardOffer?, changeCount: Int) -> Bool {
        guard let offer else { return false }
        return offer.changeCount == changeCount
    }

    /// The offer a double tap shows: whatever the pasteboard holds now — even if it was explained
    /// before — by its change count and type names only (nil: nothing to offer, or a concealed item).
    package static func offerOnDoubleTap(changeCount: Int, types: [String]) -> ClipboardOffer? {
        ClipboardOffer.make(changeCount: changeCount, lastConsumed: nil, types: types)
    }

    // MARK: Starting a capture

    /// How long after a capture the next one is ignored: a released box 1 s (plan §2), any other
    /// gesture `ExplainDebounce.click`.
    package static func debounce(for capture: ExplainCapture) -> TimeInterval {
        capture.source == .region && capture.focus == nil ? ExplainDebounce.box : ExplainDebounce.click
    }

    /// How a capture starts in its panel.
    package enum Start: Sendable, Equatable {
        /// The gesture was made in PaperDeck (a box, a lens click, ⏎ on the offer, a drop, the
        /// reader's toolbar, a menu click, a panel button): its ticket sends the first turn now.
        case send
        /// A Services request (F10): the panel opens with the selection held at [Send]; that click or
        /// ⏎ in the panel is the gesture. Another app can call a service without the user, so the
        /// invocation itself never sends.
        case holdForSend
    }

    /// By the ticket's gesture: only a Services invocation (`.service`) is held — a later click in
    /// the panel (e.g. "Not this paper") on the same Services capture is a gesture in PaperDeck.
    package static func start(for gesture: ConsentTicket.Gesture) -> Start {
        gesture == .service ? .holdForSend : .send
    }

    /// What the coordinator adds to a capture that arrives without `surroundings`.
    package enum SurroundingsSource: Sendable, Equatable {
        /// Nothing: the reader's toolbar knows its paper exactly.
        case none
        /// Every window in the captured region (box, lens, a click's band): `begin`'s `near` rect.
        case region
        /// The frontmost app's window (Services: the app that called the service; a drop: the app
        /// the image was dragged from, which stays frontmost during a drag).
        case frontWindow
        /// The frontmost window and the app the pasteboard was last written in (the clipboard).
        case copiedFrom
    }

    package static func surroundings(for source: ExplainSource) -> SurroundingsSource {
        switch source {
        case .region, .lens: return .region
        case .services, .drop: return .frontWindow
        case .clipboard, .screenshot: return .copiedFrom
        case .reader: return .none
        }
    }

    /// The capture's point in `region` (global Quartz points, top-left origin): the click for a
    /// click's band, else the centre.
    package static func point(in region: CGRect, focus: ExplainFocus?) -> CGPoint {
        let r = region.standardized
        guard let focus else { return CGPoint(x: r.midX, y: r.midY) }
        return CGPoint(x: r.minX + focus.unit.x * r.width, y: r.minY + focus.unit.y * r.height)
    }
}

/// Which app the pasteboard's current contents were copied in (F1 / F4: copied in Mail, explained
/// with the overlay over Preview, still asks first). The coordinator notes every app activation with
/// the pasteboard's change count at that moment — the count only, never the contents, and only
/// while Explain & Ask is on; in memory only. The last write happened while the app of the latest
/// activation before the count reached its value was active. Pure.
package struct ClipboardSourceTracker: Sendable, Equatable {
    package struct Activation: Sendable, Equatable {
        package var bundleID: String?
        package var changeCount: Int

        package init(bundleID: String?, changeCount: Int) { self.bundleID = bundleID; self.changeCount = changeCount }
    }

    /// The activations kept (newest last).
    package static let keep = 16
    package private(set) var activations: [Activation] = []

    package init() {}

    /// `bundleID` became the active app while the pasteboard's count was `changeCount`.
    package mutating func noteActivation(bundleID: String?, changeCount: Int) {
        if let last = activations.last, last.bundleID == bundleID { return }      // the same app again
        activations.append(Activation(bundleID: bundleID, changeCount: changeCount))
        if activations.count > Self.keep { activations.removeFirst(activations.count - Self.keep) }
    }

    /// The app that was active when the pasteboard last changed to `changeCount` — the latest
    /// activation noted before the count reached it. nil: unknown (it changed before the first
    /// activation kept).
    package func source(of changeCount: Int) -> Activation? {
        activations.last { $0.changeCount < changeCount }
    }
}

/// The decisions in reading a capture that aren't OCR (`LiveExplainServices.prepare` acts on them):
/// which paper is already known, and which windows are under what is actually sent. Pure.
package enum ExplainPreparation {
    /// The paper known without locating it: the reader toolbar's exact anchor, else PaperDeck's own
    /// reader under the capture's point (F2: its paper and page, whatever the OCR text would match).
    package static func knownMatch(anchor: ReaderAnchor?, surroundings: CaptureSurroundings?) -> PaperMatch? {
        if let anchor { return PaperMatch(paperID: anchor.paperID, page: anchor.page, via: .reader, score: 1) }
        guard let reader = surroundings?.reader else { return nil }
        return PaperMatch(paperID: reader.paperID, page: reader.page, via: .reader, score: 1)
    }

    /// `crop` (pixels of an image of `size`) as a fraction of the image (0…1, top-left origin).
    package static func unit(_ crop: CGRect, of size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let r = crop.standardized
        return CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }

    /// The surroundings of what is sent: a clicked paragraph's crop (`sentUnit`) only has the
    /// windows under it; nil keeps the whole capture's (the panel then reads the capture's own).
    package static func sentSurroundings(_ s: CaptureSurroundings?, sentUnit: CGRect?) -> CaptureSurroundings? {
        guard let s, let sentUnit else { return nil }
        return s.restricted(toUnit: sentUnit)
    }
}
