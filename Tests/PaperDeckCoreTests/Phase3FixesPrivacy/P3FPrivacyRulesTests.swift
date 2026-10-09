import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Phase-3 fixes, privacy & consent lane: the pure rules the coordinator, the pipeline and the panel
/// act on (F1 mail / chat windows, F2 PaperDeck's own reader, F4 the shortcut never sends, F5 the
/// coordinator's decisions in Core, F9 box debounce, F10 Services hold). Synthetic window lists
/// only — nothing reads the real screen or window server.
@Suite("Phase 3 fixes: privacy rules (pure)")
struct P3FPrivacyRulesTests {
    // MARK: Fixtures

    static let ownPID: Int32 = 100
    static let bundles: [Int32: String] = [200: "com.apple.Preview", 300: "com.apple.mail", 400: "com.google.Chrome",
                                           500: "com.tinyspeck.slackmacgap", 600: "com.apple.notificationcenterui",
                                           700: "com.example.Overlay"]
    static func bundle(_ pid: Int32) -> String? { bundles[pid] }

    static func entry(_ id: CGWindowID, pid: Int32, title: String? = nil, _ r: CGRect, layer: Int = 0, alpha: Double = 1) -> WindowList.Entry {
        WindowList.Entry(windowID: id, ownerPID: pid, ownerName: "App\(pid)", title: title, bounds: r, layer: layer, alpha: alpha)
    }

    static func surroundings(_ region: CGRect, point: CGPoint? = nil, _ entries: [WindowList.Entry], excluding: Set<CGWindowID> = [],
                             own: [CGWindowID: CaptureSurroundings.Shows] = [:]) -> CaptureSurroundings {
        CaptureSurroundings.make(region: region, point: point, entries: entries, excluding: excluding, ownPID: ownPID,
                                 ownBundleID: "com.yijiang.paperdeck", own: own, bundleID: bundle)
    }

    // MARK: F1 — mail and chat windows

    @Test(arguments: [
        ("com.google.Chrome", "Inbox (3) - me@example.org - Gmail", true),
        ("com.microsoft.edgemac", "Mail - Jane Doe - Outlook", true),
        ("com.apple.Safari", "general (Channel) - Lab - Slack", true),
        ("com.google.Chrome", "Chat | Microsoft Teams", true),
        ("com.brave.Browser", "(4) WhatsApp", true),
        ("com.google.Chrome", "Google Chat", true),
        ("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "Inbox - Gmail", true),     // a Chrome web app
        ("com.apple.Safari.WebApp.1A2B3C", "Outlook", true),                                     // a Safari web app
        ("com.apple.notificationcenterui", nil, true),                                            // a banner
        ("com.tencent.WeWorkMac", nil, true),
        ("com.google.Chrome", "Attention Is All You Need - arXiv", false),
        ("com.apple.Preview", "Inbox - Gmail", false),                                            // a PDF named so
    ] as [(String?, String?, Bool)])
    func mailAndChatWindows(_ bundle: String?, _ title: String?, _ expected: Bool) {
        #expect(MailWindow.isMessaging(bundleID: bundle, windowTitle: title) == expected, "\(String(describing: bundle)) \(String(describing: title))")
    }

    /// A box mostly over Preview with one corner over Mail: the corner is seen; a Mail window
    /// entirely hidden behind Preview isn't.
    @Test func aBoxSeesEveryWindowItCoversAndNotTheHiddenOnes() {
        let preview = Self.entry(1, pid: 200, title: "paper.pdf", CGRect(x: 0, y: 0, width: 800, height: 900))
        let mail = Self.entry(2, pid: 300, title: "Re: draft", CGRect(x: 800, y: 0, width: 640, height: 900))
        let hidden = Self.entry(3, pid: 400, title: "Inbox - Gmail", CGRect(x: 100, y: 100, width: 300, height: 300))
        let entries = [preview, mail, hidden]
        // The box's centre is over Preview; its right fifth is over Mail.
        let box = CGRect(x: 300, y: 200, width: 600, height: 300)
        let s = Self.surroundings(box, entries)
        #expect(s.primaryHost?.bundleID == "com.apple.Preview" && s.primaryHost?.title == "paper.pdf")
        #expect(s.showsMessaging, "the Mail window under the box's corner")
        #expect(s.hosts.map(\.bundleID) == ["com.apple.Preview", "com.apple.mail"], "the Gmail tab behind Preview isn't seen")
        // A box inside Preview only: nothing to ask about (the hidden webmail window doesn't count).
        let inside = Self.surroundings(CGRect(x: 120, y: 120, width: 200, height: 200), entries)
        #expect(!inside.showsMessaging && inside.hosts.count == 1)
    }

    /// Windows above the normal layer (a notification banner) are seen without hiding what is under
    /// them; Explain's own overlay and panels (`excluding`) are never part of it.
    @Test func bannersCountAndExplainsOwnWindowsDont() {
        let preview = Self.entry(1, pid: 200, title: "paper.pdf", CGRect(x: 0, y: 0, width: 1440, height: 900))
        let banner = Self.entry(2, pid: 600, CGRect(x: 1080, y: 40, width: 340, height: 90), layer: 23)
        let panel = Self.entry(3, pid: Self.ownPID, title: "", CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 3)
        let overlay = Self.entry(4, pid: Self.ownPID, CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 1000)
        let other = Self.entry(5, pid: 700, CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 25)      // another app's overlay
        let s = Self.surroundings(CGRect(x: 900, y: 0, width: 540, height: 300), [overlay, panel, other, banner, preview],
                                  excluding: [3, 4])
        #expect(s.showsMessaging, "the banner over the box")
        #expect(s.primaryHost?.bundleID == "com.apple.Preview", "an overlay-layer window never hides the window under it")
        #expect(!s.hosts.contains { $0.bundleID == "com.yijiang.paperdeck" }, "Explain's panel and overlay are left out")
    }

    // MARK: F2 — PaperDeck's own reader and library

    @Test func aBoxOverPaperDecksReaderIsThatReadersPaper() {
        let reader = Self.entry(1, pid: Self.ownPID, title: "Secret Paper", CGRect(x: 0, y: 0, width: 800, height: 900))
        let library = Self.entry(2, pid: Self.ownPID, title: "PaperDeck", CGRect(x: 800, y: 0, width: 640, height: 900))
        let behind = Self.entry(3, pid: 200, title: "public-paper.pdf", CGRect(x: 0, y: 0, width: 1440, height: 900))
        let own: [CGWindowID: CaptureSurroundings.Shows] = [1: .reader(paperID: "p-secret", page: 4), 2: .papers(["p-focused", "p-other"])]
        let s = Self.surroundings(CGRect(x: 100, y: 100, width: 300, height: 200), [reader, library, behind], own: own)
        #expect(s.reader?.paperID == "p-secret" && s.reader?.page == 4, "the reader, not the window behind it")
        #expect(s.primaryHost?.title == "Secret Paper" && s.primaryHost?.bundleID == "com.yijiang.paperdeck")
        #expect(s.shownPaperIDs == ["p-secret"] && !s.hosts.contains { $0.title == "public-paper.pdf" })
        // A box over both: both windows' papers apply.
        let both = Self.surroundings(CGRect(x: 600, y: 100, width: 500, height: 200), [reader, library, behind], own: own)
        #expect(Set(both.shownPaperIDs) == ["p-secret", "p-focused", "p-other"])
        // The window lookup the App makes (`WindowTitleReader.window(at:)`: no owner skipped, only
        // Explain's own ids) finds the reader, not the window behind it.
        #expect(WindowList.window(at: CGPoint(x: 400, y: 300), in: [reader, library, behind], excludingPID: -1)?.windowID == 1)
        #expect(WindowList.window(at: CGPoint(x: 400, y: 300), in: [library, behind], excludingPID: -1)?.windowID == 3)
    }

    @Test func theKnownMatchIsTheAnchorElseTheReaderUnderThePoint() {
        let anchor = ReaderAnchor(paperID: "p-anchor", kind: .selection, page: 2, rect: .zero, pageBounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let reader = CaptureSurroundings(hosts: [.init(bundleID: "com.yijiang.paperdeck", shows: .reader(paperID: "p-r", page: 7))], primary: 0)
        #expect(ExplainPreparation.knownMatch(anchor: anchor, surroundings: reader)?.paperID == "p-anchor")
        let m = ExplainPreparation.knownMatch(anchor: nil, surroundings: reader)
        #expect(m?.paperID == "p-r" && m?.page == 7 && m?.via == .reader && m?.confidence == 1)
        // A reader somewhere in the box but not under its point: its policy applies, it isn't the match.
        let aside = CaptureSurroundings(hosts: [.init(bundleID: "com.apple.Preview"),
                                                .init(bundleID: "com.yijiang.paperdeck", shows: .reader(paperID: "p-r", page: 7))], primary: 0)
        #expect(ExplainPreparation.knownMatch(anchor: nil, surroundings: aside) == nil)
        #expect(ExplainPrivacyRules.shownPapers(aside, besides: nil) == ["p-r"])
        #expect(ExplainPrivacyRules.shownPapers(aside, besides: "P-R").isEmpty, "the match itself is checked once")
        #expect(ExplainPreparation.knownMatch(anchor: nil, surroundings: nil) == nil)
    }

    /// A clicked paragraph sends only its crop: only the windows under the crop count.
    @Test func aClickedParagraphOnlyCountsTheWindowsUnderItsCrop() {
        let preview = Self.entry(1, pid: 200, title: "paper.pdf", CGRect(x: 0, y: 0, width: 700, height: 900))
        let slack = Self.entry(2, pid: 500, title: "general", CGRect(x: 700, y: 0, width: 740, height: 900))
        // The click's band spans both windows; the paragraph is in its left half.
        let band = CGRect(x: 400, y: 300, width: 700, height: 360)
        let s = Self.surroundings(band, point: CGPoint(x: 500, y: 450), [preview, slack])
        #expect(s.showsMessaging && s.primaryHost?.bundleID == "com.apple.Preview")
        let paragraph = s.restricted(toUnit: CGRect(x: 0.05, y: 0.2, width: 0.3, height: 0.4))
        #expect(!paragraph.showsMessaging && paragraph.hosts.map(\.bundleID) == ["com.apple.Preview"])
        #expect(paragraph.primaryHost?.bundleID == "com.apple.Preview")
        // A crop reaching into Slack keeps it; a crop too small for any sample uses the nearest one.
        #expect(s.restricted(toUnit: CGRect(x: 0.3, y: 0.2, width: 0.5, height: 0.4)).showsMessaging)
        #expect(s.restricted(toUnit: CGRect(x: 0.9, y: 0.5, width: 0.001, height: 0.001)).showsMessaging)
        #expect(ExplainPreparation.sentSurroundings(s, sentUnit: nil) == nil, "the whole capture: the panel reads the capture's own")
        #expect(ExplainPreparation.unit(CGRect(x: 70, y: 36, width: 210, height: 144), of: CGSize(width: 700, height: 360))
                == CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4))
        // Text triggers have no grid: unchanged.
        let text = CaptureSurroundings.text([.init(bundleID: "com.apple.mail"), .init(bundleID: "com.apple.mail")])
        #expect(text?.hosts.count == 1 && text?.restricted(toUnit: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)) == text)
        #expect(CaptureSurroundings.text([]) == nil)
    }

    // MARK: Combining the verdicts

    @Test func theVerdictsCombineFailClosedNeverAIWinsAndReasonsUnite() {
        typealias R = ExplainPrivacyRules
        #expect(R.combine([.ok], messaging: false) == .ok)
        #expect(R.combine([.ok], messaging: true) == .confirm([.messagingHost]))
        #expect(R.combine([.ok, .confirm([.markedConfidential])], messaging: false) == .confirm([.markedConfidential]))
        #expect(R.combine([.confirm([.personSourcedNoID]), .confirm([.markedConfidential])], messaging: true)
                == .confirm([.markedConfidential, .personSourcedNoID, .messagingHost]))
        #expect(R.combine([.ok, .blocked], messaging: true) == .blocked, "a never-AI paper on screen blocks")
        #expect(R.combine([.blocked, nil], messaging: false) == nil, "unreadable anywhere: nothing is sent")
        #expect(R.combine([.ok, nil], messaging: false) == nil)
        // The capture's own host and title count too (a webmail tab with no surroundings).
        let webmail = ExplainCapture(source: .region, hostBundleID: "com.google.Chrome", windowTitle: "Inbox - Gmail")
        #expect(R.showsMessaging(webmail, surroundings: nil))
        let preview = ExplainCapture(source: .region, hostBundleID: "com.apple.Preview", windowTitle: "paper.pdf")
        #expect(!R.showsMessaging(preview, surroundings: nil))
        #expect(R.showsMessaging(preview, surroundings: CaptureSurroundings.text([.init(bundleID: "com.apple.mail")])))
    }

    // MARK: F4 / F5 — the shortcut, the offer

    @Test func theShortcutOpensSwitchesOrShowsTheOfferButNeverSends() {
        typealias T = ExplainTriggerRules
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(T.onHotKey(overlayShown: false, lastPress: nil, now: t0, defaultMode: .lens) == .open(.lens))
        #expect(T.onHotKey(overlayShown: false, lastPress: t0, now: t0.addingTimeInterval(0.1), defaultMode: .frame) == .open(.frame))
        #expect(T.onHotKey(overlayShown: true, lastPress: t0, now: t0.addingTimeInterval(0.2), defaultMode: .frame) == .showOffer)
        #expect(T.onHotKey(overlayShown: true, lastPress: t0, now: t0.addingTimeInterval(0.5), defaultMode: .frame) == .toggleMode)
        #expect(T.onHotKey(overlayShown: true, lastPress: nil, now: t0, defaultMode: .frame) == .toggleMode)
        #expect(T.onHotKey(overlayShown: true, lastPress: t0.addingTimeInterval(5), now: t0, defaultMode: .frame) == .toggleMode,
                "a clock that went back is no double tap")
        // The offer is read only while the pasteboard still holds what was offered.
        let offer = ClipboardOffer(content: .text, changeCount: 41)
        #expect(T.offerIsCurrent(offer, changeCount: 41) && !T.offerIsCurrent(offer, changeCount: 42) && !T.offerIsCurrent(nil, changeCount: 41))
        // A double tap offers even what was explained before — never a concealed item.
        #expect(T.offerOnDoubleTap(changeCount: 41, types: ["public.utf8-plain-text"]) == offer)
        #expect(ClipboardOffer.make(changeCount: 41, lastConsumed: 41, types: ["public.utf8-plain-text"]) == nil)
        #expect(T.offerOnDoubleTap(changeCount: 41, types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) == nil)
        // Prewarming: the switch and "Keep Claude ready" both on.
        #expect(T.prewarms(AssistSettings(mode: .claude, keepWarmSeconds: 180)))
        #expect(!T.prewarms(AssistSettings(mode: .off, keepWarmSeconds: 180)) && !T.prewarms(AssistSettings(mode: .claude, keepWarmSeconds: 0)))
    }

    @Test func servicesHoldBoxesWaitASecondAndEachSourceGetsItsSurroundings() {
        typealias T = ExplainTriggerRules
        #expect(T.start(for: .service) == .holdForSend, "a Services invocation is no gesture in PaperDeck")
        for g in ConsentTicket.Gesture.allCases where g != .service { #expect(T.start(for: g) == .send, "\(g)") }
        #expect(T.debounce(for: ExplainCapture(source: .region)) == ExplainDebounce.box)
        #expect(T.debounce(for: ExplainCapture(source: .region, focus: ExplainFocus(unit: CGPoint(x: 0.5, y: 0.5)))) == ExplainDebounce.click)
        #expect(T.debounce(for: ExplainCapture(source: .lens)) == ExplainDebounce.click)
        #expect(ExplainDebounce.box == 1.0 && ExplainDebounce.click == 0.6)
        #expect(T.surroundings(for: .region) == .region && T.surroundings(for: .lens) == .region)
        #expect(T.surroundings(for: .services) == .frontWindow && T.surroundings(for: .drop) == .frontWindow)
        #expect(T.surroundings(for: .clipboard) == .copiedFrom && T.surroundings(for: .screenshot) == .copiedFrom)
        #expect(T.surroundings(for: .reader) == .none)
        let band = CGRect(x: 100, y: 200, width: 700, height: 360)
        #expect(T.point(in: band, focus: nil) == CGPoint(x: 450, y: 380))
        #expect(T.point(in: band, focus: ExplainFocus(unit: CGPoint(x: 0.1, y: 0.5))) == CGPoint(x: 170, y: 380))
    }

    /// Copied in Mail, then the overlay over Preview: the copy's app is known from the activations.
    @Test func theClipboardsSourceIsTheAppActiveWhenItLastChanged() {
        var t = ClipboardSourceTracker()
        #expect(t.source(of: 10) == nil)
        t.noteActivation(bundleID: "com.apple.mail", changeCount: 10)
        t.noteActivation(bundleID: "com.apple.mail", changeCount: 10)                 // the same app: one entry
        t.noteActivation(bundleID: "com.apple.Preview", changeCount: 12)               // copied twice in Mail meanwhile
        #expect(t.activations.count == 2)
        #expect(t.source(of: 12)?.bundleID == "com.apple.mail", "unchanged since Preview came forward: Mail wrote it")
        #expect(t.source(of: 13)?.bundleID == "com.apple.Preview", "changed while Preview was active")
        #expect(t.source(of: 10) == nil, "before the first activation kept: unknown")
        for i in 0..<40 { t.noteActivation(bundleID: "app.\(i % 2)", changeCount: 20 + i) }
        #expect(t.activations.count == ClipboardSourceTracker.keep)
    }

    // MARK: F9 — one press, one turn

    @Test func theSameButtonTwiceQuicklyIsOnePress() {
        var d = ExplainGestureDebounce()
        let t0 = Date(timeIntervalSince1970: 1_000)
        func press(_ g: ExplainGestureDebounce.Gesture, _ dt: TimeInterval) -> Bool { d.allow(g, at: t0.addingTimeInterval(dt)) }
        #expect(press(.run(.simpler), 0))
        #expect(!press(.run(.simpler), 0.2), "a double-click")
        #expect(!press(.run(.simpler), 0.7), "a held key's repeats keep the window sliding")
        #expect(press(.run(.simpler), 1.4))
        #expect(press(.run(.technical), 1.5), "another button is a new gesture")
        #expect(press(.confirm, 1.6))
        #expect(!press(.confirm, 1.7))
        #expect(press(.retry, 1.8))
    }
}
