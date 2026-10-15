import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Mail privacy fixes, mail-ai-privacy-5: without Screen Recording no other app's window title can
/// be read, so webmail in a browser looked like any page — text copied there (copy, then ⌃⌥E) or
/// sent via Services went out without the "Send Anyway" step the guide promises. Now a browser (or a
/// browser's web app) whose title can't be read counts as a page that may be webmail
/// (`AssistPrivacy.Reason.unknownBrowserPage`) for text triggers and captures alike; native mail
/// apps are unchanged (known by bundle id), and a readable title is judged as before. Synthetic
/// hosts and the zero-quota mock lane only — nothing reads the real screen or window server.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MPFUnknownBrowserPageTests {
    typealias K = ExplainUITestKit

    // MARK: The rule (pure)

    @Test(arguments: [
        ("com.google.Chrome", nil, true),
        ("com.apple.Safari", "", true),
        ("com.apple.Safari", "   ", true),
        ("org.mozilla.firefox", nil, true),
        ("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", nil, true),     // a browser's web app
        ("com.google.Chrome", "Attention Is All You Need - arXiv", false),          // readable: judged by its title
        ("com.google.Chrome", "Inbox (3) - me@example.org - Gmail", false),         // readable: messaging instead
        ("com.apple.mail", nil, false),                                             // native mail: messaging
        ("com.apple.Preview", nil, false),                                          // not a browser
        (nil, nil, false),
    ] as [(String?, String?, Bool)])
    func unidentifiedBrowserPages(_ bundle: String?, _ title: String?, _ expected: Bool) {
        #expect(MailWindow.isUnidentifiedBrowserPage(bundleID: bundle, windowTitle: title) == expected,
                "\(String(describing: bundle)) \(String(describing: title))")
    }

    @Test func textSurroundingsAndTheCombinedVerdict() {
        // Copied in Chrome (no title without Screen Recording), explained with Preview in front.
        let copied = CaptureSurroundings.text([.init(bundleID: "com.apple.Preview", title: "paper.pdf"),
                                               .init(bundleID: "com.google.Chrome")])
        #expect(copied?.showsUnidentifiedBrowserPage == true && copied?.showsMessaging == false)
        let capture = ExplainCapture(source: .clipboard, text: "x", hostBundleID: "com.apple.Preview", surroundings: copied)
        #expect(ExplainPrivacyRules.showsUnidentifiedBrowserPage(capture, surroundings: copied))
        #expect(ExplainPrivacyRules.combine([.ok], messaging: false, unknownBrowserPage: true) == .confirm([.unknownBrowserPage]))
        #expect(ExplainPrivacyRules.combine([.confirm([.markedConfidential])], messaging: true, unknownBrowserPage: true)
                == .confirm([.markedConfidential, .messagingHost, .unknownBrowserPage]))
        #expect(ExplainPrivacyRules.combine([.blocked], messaging: false, unknownBrowserPage: true) == .blocked)
        #expect(ExplainPrivacyRules.combine([nil], messaging: false, unknownBrowserPage: true) == nil)
        // A readable non-mail page, a native mail app, PaperDeck's own windows: as before.
        let titled = CaptureSurroundings.text([.init(bundleID: "com.google.Chrome", title: "2406.12345v2.pdf")])
        #expect(titled?.showsUnidentifiedBrowserPage == false && titled?.showsMessaging == false)
        let mail = CaptureSurroundings.text([.init(bundleID: "com.apple.mail")])
        #expect(mail?.showsUnidentifiedBrowserPage == false && mail?.showsMessaging == true)
        let own = CaptureSurroundings.text([.init(bundleID: "com.example.paperdeck", shows: .papers(["p"]))])
        #expect(own?.showsUnidentifiedBrowserPage == false)
        // The single-host verdict (`ExplainContext.privacy`) too.
        let context = ExplainContext()
        #expect(context.privacy(hostBundleID: "com.apple.Safari", windowTitle: nil) == .confirm([.unknownBrowserPage]))
        #expect(context.privacy(hostBundleID: "com.apple.Safari", windowTitle: "Nature Neuroscience - Safari") == .ok)
    }

    // MARK: The panel (mock lane)

    static func services(_ w: K.World) -> ExplainEngineServices {
        ExplainEngineServices(engine: w.engine, prepare: { capture, anchor in
            ExplainPrepared(selection: capture.text ?? anchor?.text, image: capture.image, content: .text,
                            match: ExplainPreparation.knownMatch(anchor: anchor, surroundings: capture.surroundings),
                            selectionIsExact: true,
                            surroundings: ExplainPreparation.sentSurroundings(capture.surroundings, sentUnit: nil))
        }, build: { spec in K.prompt(spec) })
    }

    /// The finding's case: webmail text in Chrome sent via Services without Screen Recording (the
    /// calling app's window has no readable title) asks first and sends nothing until confirmed.
    @Test func servicesTextFromAnUnreadableBrowserPageAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings.text([.init(bundleID: "com.google.Chrome")])
        let capture = ExplainCapture(source: .services, text: K.excerpt, hostBundleID: "com.google.Chrome", surroundings: s)
        let panel = K.panel(Self.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.service))
        #expect(panel.phase == .refused(.confirmPrivacy([.unknownBrowserPage])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
        panel.confirm(ticket: K.ticket(.action))
        try await P3FPrivacyPanelFlowTests.settle(panel)
        let sent = await w.mock.turns
        #expect(panel.phase == .done && sent == 1)
    }

    /// Copied in Safari (title unreadable), explained from the clipboard while Preview is in front.
    @Test func textCopiedInAnUnreadableBrowserAsksFirst() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings.text([.init(bundleID: "com.apple.Preview", title: "paper.pdf"), .init(bundleID: "com.apple.Safari")])
        let capture = ExplainCapture(source: .clipboard, text: K.excerpt, hostBundleID: "com.apple.Preview", surroundings: s)
        let panel = K.panel(Self.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.clipboard))
        #expect(panel.phase == .refused(.confirmPrivacy([.unknownBrowserPage])), "\(panel.phase)")
        #expect(await w.mock.turns == 0)
    }

    /// The same text from a browser whose title is readable (Screen Recording on) and shows a paper
    /// is sent as before.
    @Test func aReadableNonMailBrowserPageIsSentAsBefore() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let s = CaptureSurroundings.text([.init(bundleID: "com.google.Chrome", title: "Attention Is All You Need - arXiv")])
        let capture = ExplainCapture(source: .clipboard, text: K.excerpt, hostBundleID: "com.google.Chrome",
                                     windowTitle: "Attention Is All You Need - arXiv", surroundings: s)
        let panel = K.panel(Self.services(w), capture: capture)
        await panel.perform(.explain, ticket: K.ticket(.clipboard))
        try await P3FPrivacyPanelFlowTests.settle(panel)
        let sent = await w.mock.turns
        #expect(panel.phase == .done && sent == 1, "\(panel.phase)")
    }
}
