import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PaperDeckCore

/// Explain's pure UI rules: the phase table, the ~30 Hz text buffer, turn kinds and chips, the
/// language and model choice, the debounce, the shortcut rules, the panel placement, the clipboard
/// offer and copied-text cleanup, image encoding and drop routing, and history grouping.
@Suite("Explain UI: pure rules")
struct ExplainUIRulesTests {
    // MARK: Phases

    @Test func everyLaneFailureHasItsPanelState() {
        let t = Date(timeIntervalSince1970: 100)
        #expect(ExplainFlow.phase(after: .cancelled) == nil)
        #expect(ExplainFlow.phase(after: .usageLimit(resetsAt: t)) == .limited(until: t))
        #expect(ExplainFlow.phase(after: .usageLimit(resetsAt: nil)) == .limited(until: nil))
        #expect(ExplainFlow.phase(after: .notLoggedIn(.loggedOut)) == .needsLogin(.loggedOut))
        #expect(ExplainFlow.phase(after: .overloaded) == .error(.overloaded))
        #expect(ExplainFlow.phase(after: .timeout) == .error(.timeout))
        #expect(ExplainFlow.phase(after: .binaryMissing) == .error(.notInstalled))
        #expect(ExplainFlow.phase(after: .unsupported(missingFlags: ["--x"])) == .error(.unsupported))
        #expect(ExplainFlow.phase(after: .invalidOutput("output_cap")) == .error(.outputCap))
        #expect(ExplainFlow.phase(after: .invalidOutput("json")) == .error(.invalidOutput))
        #expect(ExplainFlow.phase(after: .generic("x")) == .error(.failed))
        let verdicts: [(AssistGate.Verdict, ExplainPhase)] = [
            (.disabled, .refused(.off)), (.wrongProvider, .refused(.off)), (.consentMissing, .refused(.expired)),
            (.consentReused, .refused(.expired)), (.consentExpired, .refused(.expired)), (.paused(until: t), .limited(until: t)),
            (.burst, .refused(.burst)), (.dailySoftCap(50), .refused(.softCap(50))), (.dailyHardCap(150), .refused(.hardCap(150))),
            (.budgetExhausted, .refused(.budget)), (.policyBlocked, .refused(.blocked)), (.allowed, .error(.failed)),
        ]
        for (v, p) in verdicts { #expect(ExplainFlow.phase(after: .refused(v)) == p, "\(v)") }
    }

    @Test func streamEventsMoveThePhase() {
        #expect(ExplainFlow.phase(for: .waiting(warm: false), current: .locating) == .sending(.starting))
        #expect(ExplainFlow.phase(for: .phase(.waitingForFirstToken), current: .sending(.starting)) == .sending(.waiting))
        #expect(ExplainFlow.phase(for: .phase(.stillWaiting), current: .sending(.waiting)) == .sending(.stillWaiting))
        #expect(ExplainFlow.phase(for: .phase(.stillWaiting), current: .streaming) == .streaming, "a late watchdog doesn't undo text")
        #expect(ExplainFlow.phase(for: .waiting(warm: true), current: .streaming) == .streaming)
        #expect(ExplainFlow.phase(for: .delta("x"), current: .sending(.waiting)) == .streaming)
        #expect(ExplainFlow.phase(for: .replace("x"), current: .sending(.waiting)) == .streaming)
        #expect(ExplainFlow.phase(for: .done(text: "x", meta: AssistMeta(provider: "mock", model: "")), current: .streaming) == .done)
        #expect(ExplainFlow.phase(for: .failed(.cancelled, partial: "p"), current: .streaming) == .done)
        #expect(ExplainFlow.phase(for: .failed(.timeout, partial: nil), current: .streaming) == .error(.timeout))
    }

    @Test func privacyRefusesOrAsksOnce() {
        #expect(ExplainFlow.phase(privacy: .ok, confirmed: false) == nil)
        #expect(ExplainFlow.phase(privacy: .blocked, confirmed: true) == .refused(.blocked), "never AI can't be confirmed away")
        #expect(ExplainFlow.phase(privacy: .confirm([.mailUnpublished]), confirmed: false) == .refused(.confirmPrivacy([.mailUnpublished])))
        #expect(ExplainFlow.phase(privacy: .confirm([.mailUnpublished]), confirmed: true) == nil)
        #expect(ExplainRefusal.confirmPrivacy([]).isConfirmable && ExplainRefusal.askBeforeSend.isConfirmable)
        #expect(ExplainRefusal.softCap(1).isConfirmable)
        for r: ExplainRefusal in [.off, .blocked, .hardCap(1), .burst, .budget, .expired, .emptyCapture, .privacyUnchecked] {
            #expect(!r.isConfirmable, "\(r)")
        }
        #expect(ExplainPhase.streaming.isBusy && ExplainPhase.locating.isBusy && ExplainPhase.capturing.isBusy)
        #expect(!ExplainPhase.done.isBusy && !ExplainPhase.refused(.off).isBusy && !ExplainPhase.armed(.frame).isBusy)
        #expect(ExplainPhase.error(.timeout).canRetry && !ExplainPhase.error(.unsupported).canRetry)
        #expect(!ExplainPhase.refused(.hardCap(1)).canRetry && ExplainPhase.refused(.expired).canRetry)
    }

    // MARK: Text buffer

    @Test func deltasAreDrawnAtMostOncePerFlush() {
        var b = ExplainTextBuffer()
        let first = b.append("Hel"), second = b.append("lo"), empty = b.append("")
        #expect(first, "the first delta schedules a flush")
        #expect(!second && !empty, "later ones wait for it")
        #expect(b.shown.isEmpty && b.full == "Hello")
        let drawn = b.flush()
        #expect(drawn && b.shown == "Hello" && b.pending.isEmpty)
        let again = b.flush()
        #expect(!again, "nothing new")
        let next = b.append(", world")
        #expect(next)
        b.replace("Authoritative")
        #expect(b.shown == "Authoritative" && b.pending.isEmpty)
        _ = b.append(" more")
        b.finish(nil)
        #expect(b.shown == "Authoritative more" && !b.flushScheduled, "a stop keeps what arrived")
        b.finish("Final")
        #expect(b.shown == "Final")
        b.reset()
        #expect(b == ExplainTextBuffer())
        #expect(ExplainTextBuffer.flushInterval == .milliseconds(33), "about 30 redraws a second")
    }

    @Test func anyChunkingAddsUpToTheSameText() {
        let text = "注意力（attention）权重 — the blastema signal, 92 %, τ → 0. " + String(repeating: "abc ", count: 50)
        var g = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var b = ExplainTextBuffer()
            var rest = Substring(text)
            var flushes = 0
            while !rest.isEmpty {
                let n = Int.random(in: 1...7, using: &g)
                if b.append(String(rest.prefix(n))) { flushes += 1 }
                rest = rest.dropFirst(n)
                if Bool.random(using: &g) { b.flush() }
            }
            b.finish(nil)
            #expect(b.shown == text)
            #expect(flushes <= text.count)
        }
    }

    // MARK: Kinds, chips, language, model

    @Test func turnKindsRoundTripTheirStoredCode() {
        let kinds: [ExplainTurnKind] = [.explain, .simpler, .technical, .defineTerms, .figure, .translate, .ask("Why τ?")]
        for k in kinds { #expect(ExplainTurnKind(actionCode: k.actionCode, question: k.question) == k) }
        #expect(Set(kinds.map(\.actionCode)).count == kinds.count)
        #expect(ExplainTurnKind(actionCode: "nope", question: nil) == nil)
        #expect(ExplainTurnKind.ask("q").question == "q" && ExplainTurnKind.explain.question == nil)
    }

    @Test func chipsHaveDistinctKeysAndTheFigureNeedsAnImage() {
        #expect(ExplainChip.allCases.map(\.keyDigit) == ["1", "2", "3", "4", "5"])
        #expect(ExplainChip.available(hasImage: false) == [.simpler, .technical, .terms, .translate])
        #expect(ExplainChip.available(hasImage: true) == ExplainChip.allCases)
        #expect(ExplainChip.forKey("4", hasImage: false) == nil && ExplainChip.forKey("4", hasImage: true) == .figure)
        #expect(ExplainChip.terms.kind == .defineTerms && ExplainChip.translate.kind == .translate)
    }

    @Test func theDefaultLanguageIsChineseWithTerms() {
        #expect(AssistSettings().explainLanguage == .zh)
        #expect(ExplainLanguageToggle.initial(.zh, ui: .en) == .zh)
        #expect(ExplainLanguageToggle.initial(.en, ui: .zh) == .en)
        #expect(ExplainLanguageToggle.initial(.ui, ui: .en) == .en && ExplainLanguageToggle.initial(.ui, ui: .zh) == .zh)
        #expect(ExplainLanguageToggle.toggled(.zh) == .en && ExplainLanguageToggle.toggled(.en) == .zh)
    }

    @Test func quickIsTheDefaultModelAndThoroughOnlyOnRequest() {
        #expect(AssistSettings().explainDepth == .quick)
        #expect(ExplainModelChoice.model(AssistSettings(mode: .claude), depth: .quick) == ("haiku", "low"))
        #expect(ExplainModelChoice.model(AssistSettings(mode: .claude), depth: .thorough) == ("sonnet", "medium"))
        #expect(ExplainModelChoice.model(AssistSettings(mode: .codex), depth: .quick) == ("gpt-5.6-luna", "low"))
        #expect(ExplainModelChoice.model(AssistSettings(mode: .mock), depth: .quick).effort == nil)
        #expect(ExplainModelChoice.model(AssistSettings(mode: .local), depth: .thorough).model == "on-device")
    }

    @Test func aDoubleClickIsOneTurn() {
        var d = ExplainDebounce()
        let t = Date(timeIntervalSince1970: 1_000)
        var got: [Bool] = []
        got.append(d.allow(at: t))
        got.append(d.allow(at: t.addingTimeInterval(0.3)))
        got.append(d.allow(at: t.addingTimeInterval(0.7)))
        got.append(d.allow(at: t.addingTimeInterval(1.2), interval: ExplainDebounce.box))
        got.append(d.allow(at: t.addingTimeInterval(1.8), interval: ExplainDebounce.box))
        got.append(d.allow(at: t))                      // a clock that moved back doesn't lock the panel
        #expect(got == [true, false, true, false, true, true])
    }

    // MARK: Shortcut

    @Test func theDefaultShortcutIsControlOptionE() {
        let k = AssistSettings.HotKey.defaultExplain
        #expect(HotKeySpec.validate(k) == nil)
        #expect(HotKeySpec.display(k) == "⌃⌥E")
        let menu = HotKeySpec.menuKeyEquivalent(k)
        #expect(menu?.key == "e" && menu?.flags == HotKeySpec.Cocoa.control | HotKeySpec.Cocoa.option)
    }

    @Test func macOSRefusedAndSystemCombinationsAreRejected() {
        typealias C = HotKeySpec.Carbon
        let e = HotKeySpec.Key.e
        func v(_ key: Int, _ mods: Int) -> HotKeySpec.Problem? { HotKeySpec.validate(.init(keyCode: key, carbonModifiers: mods)) }
        #expect(v(e, C.option) == .needsControlOrCommand, "⌥-only")
        #expect(v(e, C.option | C.shift) == .needsControlOrCommand, "⌥⇧-only")
        #expect(v(e, C.shift) == .needsControlOrCommand && v(e, 0) == .needsControlOrCommand)
        #expect(v(e, C.control) == nil && v(e, C.command | C.shift) == nil && v(e, C.control | C.option | C.command) == nil)
        for key in [HotKeySpec.Key.escape, HotKeySpec.Key.returnKey, HotKeySpec.Key.tab, HotKeySpec.Key.space,
                    HotKeySpec.Key.delete, 0x37, 0x3B] {
            #expect(v(key, C.control | C.option) == .reservedKey, "\(key)")
        }
        #expect(v(HotKeySpec.Key.q, C.command) == .systemShortcut)
        #expect(v(HotKeySpec.Key.four, C.command | C.shift) == .systemShortcut)
        #expect(v(HotKeySpec.Key.four, C.command | C.shift | C.control) == .systemShortcut)
        #expect(v(HotKeySpec.Key.q, C.command | C.option) == nil)
        #expect(v(0x7F, C.control) == .reservedKey, "an unknown key code")
        #expect(v(0x7A, C.control) == nil && HotKeySpec.display(.init(keyCode: 0x7A, carbonModifiers: C.control)) == "⌃F1")
        #expect(HotKeySpec.menuKeyEquivalent(.init(keyCode: 0x7A, carbonModifiers: C.control)) == nil, "F-keys stay out of menus")
    }

    @Test func modifierFlagsMapBothWays() {
        let all: UInt = HotKeySpec.Cocoa.command | HotKeySpec.Cocoa.shift | HotKeySpec.Cocoa.option | HotKeySpec.Cocoa.control
        #expect(HotKeySpec.carbonModifiers(cocoaFlags: all | (1 << 16) | (1 << 23)) == HotKeySpec.Carbon.all, "caps lock / fn ignored")
        for mask in 0..<16 {
            var carbon = 0
            if mask & 1 != 0 { carbon |= HotKeySpec.Carbon.command }
            if mask & 2 != 0 { carbon |= HotKeySpec.Carbon.shift }
            if mask & 4 != 0 { carbon |= HotKeySpec.Carbon.option }
            if mask & 8 != 0 { carbon |= HotKeySpec.Carbon.control }
            #expect(HotKeySpec.carbonModifiers(cocoaFlags: HotKeySpec.cocoaFlags(carbon: carbon)) == carbon)
        }
        #expect(HotKeySpec.display(.init(keyCode: 0x0E, carbonModifiers: HotKeySpec.Carbon.all)) == "⌃⌥⇧⌘E", "Apple's order")
    }

    // MARK: Placement

    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let size = CGSize(width: 420, height: 300)

    @Test func thePanelOpensBesideTheSelectionNeverOverIt() {
        let mid = CGRect(x: 400, y: 400, width: 300, height: 100)
        let right = PanelPlacement.frame(size: Self.size, anchor: mid, visibleFrame: Self.screen)
        #expect(right.side == .right && right.frame.minX >= mid.maxX && right.frame.maxY == mid.maxY)
        let nearRight = CGRect(x: 1100, y: 400, width: 300, height: 100)
        let left = PanelPlacement.frame(size: Self.size, anchor: nearRight, visibleFrame: Self.screen)
        #expect(left.side == .left && left.frame.maxX <= nearRight.minX)
        let wide = CGRect(x: 100, y: 500, width: 1240, height: 200)
        let below = PanelPlacement.frame(size: Self.size, anchor: wide, visibleFrame: Self.screen)
        #expect(below.side == .below && below.frame.maxY <= wide.minY)
        let low = CGRect(x: 100, y: 100, width: 1240, height: 200)
        let above = PanelPlacement.frame(size: Self.size, anchor: low, visibleFrame: Self.screen)
        #expect(above.side == .above && above.frame.minY >= low.maxY)
        let huge = Self.screen.insetBy(dx: 10, dy: 10)
        let inside = PanelPlacement.frame(size: Self.size, anchor: huge, visibleFrame: Self.screen)
        #expect(inside.side == .inside && Self.screen.contains(inside.frame))
        for r in [right, left, below, above] {
            #expect(Self.screen.contains(r.frame), "\(r.side)")
        }
        for (r, a) in [(right, mid), (left, nearRight), (below, wide), (above, low)] {
            #expect(!r.frame.intersects(a), "\(r.side) covers the selection")
        }
    }

    @Test func aMouseAnchorAndScreensLeftOfOrAboveMainAreHandled() {
        let leftScreen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let atMouse = PanelPlacement.frame(size: Self.size, anchor: PanelPlacement.pointAnchor(CGPoint(x: -1000, y: 700)),
                                           visibleFrame: leftScreen)
        #expect(atMouse.side == .right && leftScreen.contains(atMouse.frame) && atMouse.frame.minX > -1000)
        let corner = PanelPlacement.frame(size: Self.size, anchor: PanelPlacement.pointAnchor(CGPoint(x: -5, y: 125)),
                                          visibleFrame: leftScreen)
        #expect(leftScreen.contains(corner.frame))
        let above = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        let frames = [Self.screen, leftScreen, above]
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: -10, y: 500), frames: frames) == 1)
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 100, y: 1500), frames: frames) == 2)
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 5000, y: 100), frames: frames) == 2, "off every screen: the nearest")
        #expect(PanelPlacement.screenIndex(for: CGPoint(x: 1500, y: -40), frames: frames) == 0)
        #expect(PanelPlacement.screenIndex(for: .zero, frames: []) == nil)
        #expect(PanelPlacement.height(for: 2_000, visibleFrame: Self.screen) == 540, "60 % of the screen")
        #expect(PanelPlacement.height(for: 100, visibleFrame: Self.screen) == PanelPlacement.minHeight)
        let base = CGRect(x: 1000, y: 100, width: 420, height: 300)
        #expect(PanelPlacement.cascade(base, index: 0, visibleFrame: Self.screen) == base)
        let third = PanelPlacement.cascade(base, index: 2, visibleFrame: Self.screen)
        #expect(third.minX == 1020 && third.minY == 52 && Self.screen.contains(third))
    }

    // MARK: Clipboard

    @Test func theClipboardIsOfferedOnlyWhenItChangedAndIsNotConcealed() {
        let text = ["public.utf8-plain-text"], image = ["public.png"]
        #expect(ClipboardOffer.make(changeCount: 5, lastConsumed: 5, types: text) == nil, "already explained / our own copy")
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: 5, types: text) == ClipboardOffer(content: .text, changeCount: 6))
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: nil, types: image)?.content == .image)
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: nil, types: image + text)?.content == .text, "text wins")
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: nil, types: text + ["org.nspasteboard.ConcealedType"]) == nil)
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: nil, types: ["public.file-url"]) == nil)
        #expect(ClipboardOffer.make(changeCount: 6, lastConsumed: nil, types: []) == nil)
    }

    @Test func copiedPDFTextIsJoinedLikeTheParagraphItCameFrom() {
        #expect(ClipboardOffer.normalize("We regu-\nlarize the\nweights.") == "We regularize the weights.")
        #expect(ClipboardOffer.normalize("a state-of-the-\nart model") == "a state-of-the-art model", "a compound keeps its hyphen")
        #expect(ClipboardOffer.normalize("Fin-\nRegeneration") == "Fin- Regeneration", "an uppercase line isn't joined")
        #expect(ClipboardOffer.normalize("注意力\n机制") == "注意力机制")
        #expect(ClipboardOffer.normalize("One.\n\nTwo  \u{00A0} words.\r\nmore") == "One.\n\nTwo words. more")
        #expect(ClipboardOffer.normalize("  \n \n ") == nil)
        #expect(ClipboardOffer.normalize(String(repeating: "x", count: 5_000))?.count == ExplanationRecord.maxExcerpt)
        #expect(ClipboardOffer.preview("a\n b   c", limit: 80) == "a b c")
        #expect(ClipboardOffer.preview(String(repeating: "y", count: 100), limit: 10) == String(repeating: "y", count: 9) + "…")
    }

    // MARK: Images and drops

    @Test func imagesAreScaledDownToTheLimitNeverUp() throws {
        #expect(ExplainImageEncoder.targetSize(for: CGSize(width: 3136, height: 1000)) == CGSize(width: 1568, height: 500))
        #expect(ExplainImageEncoder.targetSize(for: CGSize(width: 1000, height: 4000)) == CGSize(width: 392, height: 1568))
        #expect(ExplainImageEncoder.targetSize(for: CGSize(width: 120, height: 40)) == CGSize(width: 120, height: 40))
        let big = try #require(ExplainImageEncoder.encode(ExplainUITestKit.image(width: 3000, height: 1200)))
        #expect(big.mediaType == "image/png" && big.pixelSize == CGSize(width: 1568, height: 627) && big.isAcceptable)
        let small = try #require(ExplainImageEncoder.encode(ExplainUITestKit.image(width: 200, height: 80)))
        #expect(small.pixelSize == CGSize(width: 200, height: 80) && small.isAcceptable)
        // A photo-like image whose PNG passes 1 MB is sent as JPEG.
        let noisy = try #require(ExplainImageEncoder.encode(ExplainUITestKit.image(width: 1400, height: 1000, noise: true)))
        #expect(noisy.mediaType == "image/jpeg" && noisy.isAcceptable)
        // File bytes (a dropped PNG), garbage, nothing.
        let fromData = try #require(ExplainImageEncoder.encode(data: big.data))
        #expect(fromData.pixelSize == big.pixelSize && fromData.isAcceptable)
        #expect(ExplainImageEncoder.encode(data: Data("not an image".utf8)) == nil)
        #expect(ExplainImageEncoder.encode(data: Data()) == nil)
    }

    @Test func onlyAllImageDropsGoToExplain() {
        #expect(ExplainDropRules.isAllImages([.png, .jpeg, .heic, .tiff]))
        #expect(!ExplainDropRules.isAllImages([.png, .pdf]), "a PDF keeps the import")
        #expect(!ExplainDropRules.isAllImages([.png, nil]), "an unknown file keeps the import")
        #expect(!ExplainDropRules.isAllImages([.folder]) && !ExplainDropRules.isAllImages([]))
        #expect(!ExplainDropRules.isAllImages([UTType("com.apple.mail.emlx")]))
        #expect(ExplainDropRules.type(ofFileNamed: "Screenshot 2026-10-02 at 09.41.12.png") == .png)
        #expect(ExplainDropRules.type(ofFileNamed: "paper.PDF") == .pdf)
        #expect(ExplainDropRules.type(ofFileNamed: "noextension") == nil)
    }

    // MARK: History

    static func record(_ thread: String, _ turn: Int, at t: TimeInterval, pinned: Bool = false, saved: Bool = false,
                       answer: String = "**Gist:** x", page: Int? = 3) -> ExplanationRecord {
        ExplanationRecord(id: "\(thread)-\(turn)", paperID: "p", threadID: thread, turn: turn, source: .reader, action: "explain",
                          lang: .en, page: page, excerpt: "e", answer: answer, meta: AssistMeta(provider: "mock", model: ""),
                          pinned: pinned, savedToNotesAt: saved ? Date(timeIntervalSince1970: t) : nil,
                          createdAt: Date(timeIntervalSince1970: t))
    }

    @Test func historyGroupsThreadsPinnedFirstThenNewest() {
        let records = [Self.record("a", 0, at: 100), Self.record("a", 1, at: 500), Self.record("b", 0, at: 300, pinned: true),
                       Self.record("c", 0, at: 400, saved: true), Self.record("a", 2, at: 450, page: nil)]
        let threads = ExplainHistory.threads(records.shuffled())
        #expect(threads.map(\.threadID) == ["b", "a", "c"])
        let a = threads[1]
        #expect(a.turns.map(\.turn) == [0, 1, 2] && a.first.turn == 0 && a.latest == Date(timeIntervalSince1970: 500))
        #expect(a.page == 3 && !a.pinned && !a.saved)
        #expect(threads[0].pinned && threads[2].saved)
        #expect(ExplainHistory.threads([]).isEmpty)
    }

    @Test func aRowSummaryIsPlainText() {
        let r = Self.record("a", 0, at: 1, answer: "**Figure 3**: days\n\n- About 92% by day 14\n- Fastest early\n1. one")
        #expect(ExplainHistory.summary(r) == "Figure 3: days · About 92% by day 14 · Fastest early · one")
        #expect(ExplainHistory.summary(Self.record("a", 0, at: 1, answer: String(repeating: "z", count: 300)), limit: 20).count == 20)
    }

    @Test func anchorsRoundTripThroughTheirStoredForm() throws {
        let a = ReaderAnchor(paperID: "P1", kind: .region, page: 4, printedLabel: "1202", rect: CGRect(x: 1.5, y: 2, width: 30, height: 40),
                             pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: "τ text")
        let json = try #require(ExplainAnchorStore.encode(a))
        #expect(ExplainAnchorStore.decode(json) == a)
        #expect(ExplainAnchorStore.decode("{nope") == nil)
        #expect(ExplainAnchorStore.key(explanationID: "ABC") == "explain.anchor.abc")
    }
}
