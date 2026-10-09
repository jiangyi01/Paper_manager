import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Phase-3 fixes, privacy & consent lane: a panel end to end over a real engine, its lane and gate
/// and the zero-quota mock backend (no CLI, no screen). The preparation mirrors the app's
/// (`LiveExplainServices.prepare`): the known match from `ExplainPreparation`, the sent part's
/// surroundings. F1 (mail / chat windows ask first on every path), F2 (a capture over PaperDeck's
/// own reader gets that paper's policy), F9 (one press, one turn), F10 (Services waits for [Send]).
@MainActor
@Suite("Phase 3 fixes: privacy and consent in the panel (mock lane)", .serialized, .timeLimit(.minutes(1)))
struct P3FPrivacyPanelFlowTests {
    typealias K = ExplainUITestKit

    /// The app's preparation without OCR: the capture's text, the known match (the anchor, or
    /// PaperDeck's reader under the point) else the locator's (`located`), and the surroundings of
    /// what is sent (`sentUnit`: a clicked paragraph's crop).
    static func services(_ w: K.World, located: PaperMatch? = nil, sentUnit: CGRect? = nil) -> ExplainEngineServices {
        ExplainEngineServices(engine: w.engine, prepare: { capture, anchor in
            ExplainPrepared(selection: capture.text ?? anchor?.text, image: capture.image, content: .text,
                            match: ExplainPreparation.knownMatch(anchor: anchor, surroundings: capture.surroundings) ?? located,
                            selectionIsExact: true,
                            surroundings: ExplainPreparation.sentSurroundings(capture.surroundings, sentUnit: sentUnit))
        }, build: { spec in K.prompt(spec) })
    }

    static func region(host: String?, title: String?, surroundings: CaptureSurroundings? = nil, focus: ExplainFocus? = nil) -> ExplainCapture {
        ExplainCapture(source: .region, text: K.excerpt, hostBundleID: host, windowTitle: title, focus: focus, surroundings: surroundings)
    }

    // MARK: F1

    /// The verifier's probe: Gmail in Chrome asks first and sends nothing.
    @Test func webmailInABrowserAsksFirstAndSendsNothing() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(Self.services(w), capture: Self.region(host: "com.google.Chrome", title: "Inbox (3) - me@example.org - Gmail"))
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
        // [Send Anyway] with its own click: it goes out.
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        let sentTurns = await w.mock.turns
        #expect(panel.phase == .done && sentTurns == 1)
    }

    /// A box mostly over a PDF with a corner over Slack (the window under its centre is the PDF's).
    @Test func aBoxThatCoversAChatWindowsCornerAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let pdf = WindowList.Entry(windowID: 1, ownerPID: 200, title: "paper.pdf", bounds: CGRect(x: 0, y: 0, width: 800, height: 900))
        let slack = WindowList.Entry(windowID: 2, ownerPID: 500, title: "general", bounds: CGRect(x: 800, y: 0, width: 640, height: 900))
        let s = P3FPrivacyRulesTests.surroundings(CGRect(x: 300, y: 200, width: 600, height: 300), [pdf, slack])
        let panel = K.panel(Self.services(w), capture: Self.region(host: "com.apple.Preview", title: "paper.pdf", surroundings: s))
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
    }

    /// A clicked paragraph whose crop is all PDF is sent without asking, though its band touched Slack.
    @Test func aClickedParagraphAwayFromTheChatWindowIsSent() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let pdf = WindowList.Entry(windowID: 1, ownerPID: 200, title: "paper.pdf", bounds: CGRect(x: 0, y: 0, width: 700, height: 900))
        let slack = WindowList.Entry(windowID: 2, ownerPID: 500, title: "general", bounds: CGRect(x: 700, y: 0, width: 740, height: 900))
        let band = CGRect(x: 400, y: 300, width: 700, height: 360)
        let s = P3FPrivacyRulesTests.surroundings(band, point: CGPoint(x: 500, y: 450), [pdf, slack])
        let focus = ExplainFocus(unit: CGPoint(x: 0.14, y: 0.42))
        let paragraph = CGRect(x: 0.05, y: 0.2, width: 0.3, height: 0.4)
        let sent = K.panel(Self.services(w, sentUnit: paragraph),
                           capture: Self.region(host: "com.apple.Preview", title: "paper.pdf", surroundings: s, focus: focus))
        await sent.perform(.explain, ticket: K.ticket(.box))
        let first = await w.mock.turns
        #expect(sent.phase == .done && first == 1)
        // The same click sending its whole band (nothing under the click: a figure) asks first.
        let band2 = K.panel(Self.services(w), capture: Self.region(host: "com.apple.Preview", title: "paper.pdf", surroundings: s, focus: focus))
        await band2.perform(.explain, ticket: K.ticket(.box))
        #expect(band2.phase == .refused(.confirmPrivacy([.messagingHost])))
        #expect(await w.mock.turns == 1)
    }

    /// Copied in Mail, explained from the clipboard while Preview is in front: asks first.
    @Test func textCopiedInAMailAppAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings.text([.init(bundleID: "com.apple.Preview", title: "paper.pdf"), .init(bundleID: "com.apple.mail")])
        let capture = ExplainCapture(source: .clipboard, text: K.excerpt, hostBundleID: "com.apple.Preview", surroundings: s)
        let panel = K.panel(Self.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.clipboard))
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])))
        #expect(await w.mock.turns == 0)
    }

    // MARK: F2

    /// The verifier's case: a never-AI paper's figure explained over PaperDeck's own reader, while
    /// the window behind the reader (or the text) would match a public paper: refused, nothing sent.
    @Test func aNeverAIPaperInPaperDecksReaderIsRefusedWhateverElseMatches() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let never = try await K.paper(w.engine, title: "Never")
        try await w.engine.setPaperPolicy(paperID: never.id, confidential: false, neverAI: true)
        let pub = try await K.paper(w.engine, title: "Public")
        let reader = WindowList.Entry(windowID: 1, ownerPID: P3FPrivacyRulesTests.ownPID, title: "Never",
                                      bounds: CGRect(x: 0, y: 0, width: 800, height: 900))
        let behind = WindowList.Entry(windowID: 2, ownerPID: 200, title: "public.pdf", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let s = P3FPrivacyRulesTests.surroundings(CGRect(x: 100, y: 100, width: 200, height: 120), [reader, behind],
                                                  own: [1: .reader(paperID: never.id, page: 3)])
        let located = PaperMatch(paperID: pub.id, via: .windowTitle, score: 0.9)
        let panel = K.panel(Self.services(w, located: located),
                            capture: Self.region(host: "com.yijiang.paperdeck", title: "Never", surroundings: s))
        await panel.perform(.figure, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.blocked), "\(panel.phase)")
        #expect(panel.paperID == never.id && panel.page == 3, "the reader's paper is the match")
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(await w.mock.turns == 0)
    }

    /// The reader somewhere in the box (not under its point) still applies its paper's policy, on
    /// top of the located paper's; a confidential one asks once.
    @Test func aConfidentialPaperShownAnywhereInTheBoxAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let secret = try await K.paper(w.engine, title: "Draft")
        try await w.engine.setPaperPolicy(paperID: secret.id, confidential: true, neverAI: false)
        let s = CaptureSurroundings(hosts: [.init(bundleID: "com.apple.Preview", title: "paper.pdf"),
                                            .init(bundleID: "com.yijiang.paperdeck", shows: .papers([secret.id]))], primary: 0)
        let panel = K.panel(Self.services(w), capture: Self.region(host: "com.apple.Preview", title: "paper.pdf", surroundings: s))
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.confirmPrivacy([.markedConfidential])), "\(panel.phase)")
        let held = await w.mock.turns
        #expect(panel.paperID == nil && held == 0)
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        let sentTurns = await w.mock.turns
        #expect(panel.phase == .done && sentTurns == 1)
    }

    /// A paper on screen whose privacy can't be read (gone from the library): nothing is sent.
    @Test func aShownPaperWhosePrivacyCantBeReadSendsNothing() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings(hosts: [.init(bundleID: "com.yijiang.paperdeck", shows: .papers(["no-such-paper"]))], primary: nil)
        let panel = K.panel(Self.services(w), capture: Self.region(host: "com.apple.Preview", title: nil, surroundings: s))
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.phase == .refused(.privacyUnchecked))
        #expect(await w.mock.turns == 0)
    }

    // MARK: F10

    /// Services: the panel holds the selection at [Send]; nothing is sent until that click.
    @Test func aServicesRequestWaitsForTheSendClick() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(Self.services(w), capture: ExplainCapture(source: .services, text: K.excerpt, hostBundleID: "com.apple.Preview"))
        panel.holdForSend(.translate)
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.phase == .refused(.askBeforeSend) && panel.pending == .translate && panel.heldFor == .service)
        #expect(await w.mock.turns == 0)
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        let sentTurns = await w.mock.turns
        #expect(panel.phase == .done && sentTurns == 1 && panel.current?.kind == .translate)
        #expect(panel.heldFor == .setting)
        // "Ask before every send" on: the setting's own card names the setting again.
        w.box.update { $0.assist.explainAskBeforeSend = true }
        await panel.perform(.simpler, ticket: K.ticket(.action))
        #expect(panel.phase == .refused(.askBeforeSend) && panel.heldFor == .setting)
    }

    /// Services from a mail app: [Send] then the mail confirmation — two clicks, never none.
    @Test func aServicesRequestFromMailAsksAgainBeforeSending() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(Self.services(w), capture: ExplainCapture(source: .services, text: K.excerpt, hostBundleID: "com.apple.mail"))
        panel.holdForSend(.explain)
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])))
        #expect(await w.mock.turns == 0)
    }

    // MARK: F9

    /// A double-clicked chip (or a held ⌘-digit) is one turn; the same chip later is another. The
    /// first click's turn has already gone out (the mock answers at once) when the second arrives,
    /// so without the debounce the second would spend a ticket, a burst slot and a daily count.
    @Test func aDoubleClickedChipStartsOneTurn() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(Self.services(w))
        var now = K.t0
        panel.clock = { now }
        await panel.perform(.explain, ticket: K.ticket())
        #expect(await w.mock.turns == 1)
        panel.run(.simpler, ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(await w.mock.turns == 2)
        now = now.addingTimeInterval(0.15)
        panel.run(.simpler, ticket: K.ticket(.action))                 // the double-click's second click
        try await Self.settle(panel)
        #expect(await w.mock.turns == 2, "one press, one turn")
        now = now.addingTimeInterval(1)
        panel.run(.simpler, ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(await w.mock.turns == 3, "the same chip a second later is a new press")
        // [Try Again] double-clicked: one.
        panel.retry(ticket: K.ticket(.retry))
        try await Self.settle(panel)
        now = now.addingTimeInterval(0.1)
        panel.retry(ticket: K.ticket(.retry))
        try await Self.settle(panel)
        #expect(await w.mock.turns == 4)
        // [Send] double-clicked on a held turn: one.
        w.box.update { $0.assist.explainAskBeforeSend = true }
        now = now.addingTimeInterval(1)
        panel.run(.technical, ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(panel.phase == .refused(.askBeforeSend))
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        w.box.update { $0.assist.explainAskBeforeSend = false }
        let afterSend = await w.mock.turns
        #expect(afterSend == 5)
    }

    static func settle(_ panel: ExplainPanelState) async throws {
        await panel.settled()
        var n = 0
        while panel.phase.isBusy && n < 500 {
            try await Task.sleep(for: .milliseconds(10))
            n += 1
        }
        #expect(!panel.phase.isBusy, "timed out waiting")
    }
}
