import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The overlay's decisions (fix-capture-ux), pure: the keys and Tab's language (CUX-10), what the
/// system pulling the ground away does (CUX-3: a Space switch, a display change, sleep, another
/// session), and where the HUD pill sits (CUX-14).
@Suite struct OverlayRulesTests {
    // MARK: CUX-10 keys

    @Test func keysMapToTheirActionsAndHeldKeysDontRepeat() {
        typealias K = HotKeySpec.Key
        #expect(CaptureOverlayKeys.action(keyCode: K.escape, isRepeat: false) == .dismiss)
        #expect(CaptureOverlayKeys.action(keyCode: K.space, isRepeat: false) == .toggleMode)
        #expect(CaptureOverlayKeys.action(keyCode: K.returnKey, isRepeat: false) == .explainOffer)
        #expect(CaptureOverlayKeys.action(keyCode: CaptureOverlayKeys.keypadEnter, isRepeat: false) == .explainOffer)
        #expect(CaptureOverlayKeys.action(keyCode: K.tab, isRepeat: false) == .toggleLanguage)
        #expect(CaptureOverlayKeys.action(keyCode: K.e, isRepeat: false) == .pass)
        // Holding Space no longer flips box ↔ lens back and forth; a held Return or Tab doesn't repeat.
        #expect(CaptureOverlayKeys.action(keyCode: K.space, isRepeat: true) == .swallow)
        #expect(CaptureOverlayKeys.action(keyCode: K.returnKey, isRepeat: true) == .swallow)
        #expect(CaptureOverlayKeys.action(keyCode: K.tab, isRepeat: true) == .swallow)
        // Esc always closes.
        #expect(CaptureOverlayKeys.action(keyCode: K.escape, isRepeat: true) == .dismiss)
    }

    @Test func tabTogglesFromTheLanguageInEffect() {
        // English answers (the setting, or `.ui` with an English interface): the first Tab gives 中.
        #expect(CaptureOverlayKeys.language(afterTab: nil, setting: .en, ui: .zh) == .zh)
        #expect(CaptureOverlayKeys.language(afterTab: nil, setting: .ui, ui: .en) == .zh)
        // Chinese in effect: the first Tab gives EN.
        #expect(CaptureOverlayKeys.language(afterTab: nil, setting: .zh, ui: .en) == .en)
        #expect(CaptureOverlayKeys.language(afterTab: nil, setting: .ui, ui: .zh) == .en)
        // After a Tab, the next one goes back.
        #expect(CaptureOverlayKeys.language(afterTab: .zh, setting: .en, ui: .en) == .en)
        #expect(CaptureOverlayKeys.language(afterTab: .en, setting: .en, ui: .en) == .zh)
    }

    // MARK: CUX-3 lifecycle

    @Test func aSpaceSwitchSleepOrAnotherSessionClosesTheOverlay() {
        for e in [CaptureOverlayLifecycle.Event.activeSpaceChanged, .displaysSlept, .sessionResigned] {
            #expect(CaptureOverlayLifecycle.reaction(to: e) == .dismiss, "\(e)")
        }
    }

    @Test func aDisplayChangeClosesItButASpuriousNotificationDoesNot() {
        let main = CaptureOverlayLifecycle.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let side = CaptureOverlayLifecycle.Display(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        // The same displays (in any order): keep.
        #expect(CaptureOverlayLifecycle.reaction(to: .screensChanged(opened: [main, side], now: [side, main])) == .keep)
        // Unplugged, plugged in, moved, resized: the stills and the panels no longer line up.
        #expect(CaptureOverlayLifecycle.reaction(to: .screensChanged(opened: [main, side], now: [main])) == .dismiss)
        #expect(CaptureOverlayLifecycle.reaction(to: .screensChanged(opened: [main], now: [main, side])) == .dismiss)
        var moved = side
        moved.frame.origin.x = 1440
        #expect(CaptureOverlayLifecycle.reaction(to: .screensChanged(opened: [main, side], now: [main, moved])) == .dismiss)
        var scaled = main
        scaled.frame.size = CGSize(width: 1728, height: 1117)
        #expect(CaptureOverlayLifecycle.reaction(to: .screensChanged(opened: [main], now: [scaled])) == .dismiss)
    }

    // MARK: CUX-14 HUD

    static let display = CGSize(width: 1440, height: 900)

    @Test func theHUDStepsAwayFromThePointerAndBack() {
        let inset: CGFloat = 32                            // a notched display
        // Far from both edges: it stays where it is.
        #expect(CaptureHUD.edge(current: .top, cursor: CGPoint(x: 720, y: 450), displaySize: Self.display, topInset: inset) == .top)
        // The pointer comes up to it (to start a box over the page's top): it goes to the bottom.
        #expect(CaptureHUD.edge(current: .top, cursor: CGPoint(x: 720, y: 60), displaySize: Self.display, topInset: inset) == .bottom)
        // While at the bottom, moving around the top keeps it there; reaching the bottom band brings it back.
        #expect(CaptureHUD.edge(current: .bottom, cursor: CGPoint(x: 720, y: 30), displaySize: Self.display, topInset: inset) == .bottom)
        #expect(CaptureHUD.edge(current: .bottom, cursor: CGPoint(x: 100, y: 880), displaySize: Self.display, topInset: inset) == .top)
        // Off this display: unchanged.
        #expect(CaptureHUD.edge(current: .bottom, cursor: nil, displaySize: Self.display, topInset: inset) == .bottom)
        // A display so small both bands meet: it stays.
        let tiny = CGSize(width: 300, height: 120)
        #expect(CaptureHUD.edge(current: .top, cursor: CGPoint(x: 10, y: 60), displaySize: tiny, topInset: 0) == .top)
    }

    @Test func theHUDBandsSitAtTheEdgesBelowTheNotch() {
        let top = CaptureHUD.zone(.top, displaySize: Self.display, topInset: 32)
        #expect(top.minY == 0 && top.maxY == 32 + CaptureHUD.margin + CaptureHUD.height + CaptureHUD.clearance)
        let bottom = CaptureHUD.zone(.bottom, displaySize: Self.display, topInset: 32)
        #expect(bottom.maxY == Self.display.height && bottom.minY > Self.display.height / 2)
        #expect(!top.intersects(bottom))
        #expect(CaptureHUD.isShown(dragging: false) && !CaptureHUD.isShown(dragging: true))
    }
}
