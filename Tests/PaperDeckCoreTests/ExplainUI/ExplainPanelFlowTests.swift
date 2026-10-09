import Foundation
import Testing
@testable import PaperDeckCore

/// One explanation panel end to end over a real engine, its real `AssistLane` and gate, and the
/// zero-quota mock backend: a gesture's ticket → local preparation → privacy → one turn → stored.
/// Also the refusals that send nothing, follow-ups on the panel's session, stop and replace, the
/// reader anchor kept with the explanation, pin and save to notes.
@MainActor
@Suite("Explain UI: a panel, end to end (mock lane)", .timeLimit(.minutes(1)))
struct ExplainPanelFlowTests {
    typealias K = ExplainUITestKit

    @Test func aClipboardExplanationStreamsAndIsStored() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let services = K.services(w)
        let panel = K.panel(services)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .done)
        let turn = try #require(panel.current)
        #expect(turn.text.hasPrefix("Mock explanation."))
        #expect(turn.isComplete && turn.recordID != nil && !turn.stopped)
        #expect(await w.mock.turns == 1)
        // The request: the panel's session, Explain's surface, the prompt's text, no image.
        let r = try #require(await w.mock.lastRequest)
        #expect(r.surface == .explain && r.session == .reuse(threadKey: panel.threadKey) && r.image == nil)
        #expect(r.turnText.contains("kind=\"explain\"") && r.turnText.contains(K.excerpt))
        // Stored: unmatched, with the panel's thread, the action and the language.
        let stored = try await w.engine.explanations(paperID: nil, limit: 10)
        #expect(stored.count == 1)
        let rec = try #require(stored.first)
        #expect(rec.id == turn.recordID && rec.threadID == panel.threadKey && rec.turn == 0 && rec.source == .clipboard)
        #expect(rec.action == "explain" && rec.lang == .zh && rec.paperID == nil && rec.excerpt == K.excerpt)
        #expect(rec.answer == turn.text && rec.meta.provider == "mock")
        #expect(!panel.canSaveToNotes, "unmatched: nothing to save into")
    }

    @Test func offRefusesWithoutSendingAndAFreshClickSendsAfterTurningOn() async throws {
        let w = try await K.world(mode: .off)
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w))
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.off))
        #expect(panel.pending == .explain && panel.turns.isEmpty)
        #expect(await w.mock.turns == 0)
        // Turning it on sends nothing by itself; the next click does.
        w.box.update { $0.assist.mode = .mock }
        #expect(await w.mock.turns == 0)
        panel.retry(ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(panel.phase == .done && panel.turns.count == 1)
        #expect(await w.mock.turns == 1)
    }

    @Test func aConfidentialPaperAsksOnceAndANeverAIPaperIsNeverSent() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let secret = try await K.paper(w.engine, title: "Unpublished")
        try await w.engine.setPaperPolicy(paperID: secret.id, confidential: true, neverAI: false)
        let panel = K.panel(K.services(w, match: PaperMatch(paperID: secret.id, page: 2, via: .text, score: 0.9)))
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.confirmPrivacy([.markedConfidential])))
        #expect(await w.mock.turns == 0 && panel.turns.isEmpty)
        // [Send Anyway] with that click's ticket: the held turn goes out.
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        #expect(panel.phase == .done && panel.privacyConfirmed)
        #expect(await w.mock.turns == 1)
        // The confirmation covers this panel's capture: a follow-up doesn't ask again.
        await panel.perform(.ask("Why?"), ticket: K.ticket(.followUp))
        #expect(panel.phase == .done && panel.turns.count == 2)
        #expect(await w.mock.turns == 2)
        let rec = try #require(try await w.engine.explanations(paperID: secret.id, limit: 10).first)
        #expect(rec.matchVia == .text && rec.page == 2 && rec.question == "Why?" && rec.turn == 1)

        // Never use AI: blocked, and no confirmation can lift it.
        let never = try await K.paper(w.engine, title: "Never")
        try await w.engine.setPaperPolicy(paperID: never.id, confidential: false, neverAI: true)
        let blocked = K.panel(K.services(w, match: PaperMatch(paperID: never.id, via: .text, score: 1)))
        await blocked.perform(.explain, ticket: K.ticket())
        #expect(blocked.phase == .refused(.blocked))
        blocked.confirm(ticket: K.ticket(.action))
        try await Self.settle(blocked)
        #expect(blocked.phase == .refused(.blocked))
        #expect(await w.mock.turns == 2)
    }

    @Test func aPaperWhosePrivacyCantBeReadIsNeverSent() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let services = K.services(w, match: PaperMatch(paperID: "gone-paper", via: .text, score: 0.9))
        #expect(await services.privacy(paperID: "gone-paper", hostBundleID: nil) == nil, "fail closed, never .ok")
        #expect(await services.privacy(paperID: nil, hostBundleID: "com.tinyspeck.slackmacgap") == .confirm([.messagingHost]))
        #expect(await services.privacy(paperID: nil, hostBundleID: "com.apple.Preview") == .ok)
        let panel = K.panel(services)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.privacyUnchecked) && panel.pending == .explain)
        let turns = await w.mock.turns
        #expect(turns == 0)
    }

    @Test func aMailWindowCaptureAsksFirstEvenWithoutAPaper() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w), capture: ExplainCapture(source: .clipboard, text: K.excerpt, hostBundleID: "com.apple.mail"))
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.confirmPrivacy([.messagingHost])))
        #expect(await w.mock.turns == 0)
    }

    @Test func aTicketPaysForOneTurnOnly() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w))
        let ticket = K.ticket()
        await panel.perform(.explain, ticket: ticket)
        #expect(panel.phase == .done)
        await panel.perform(.simpler, ticket: ticket)              // the same ticket again
        #expect(panel.phase == .refused(.expired))
        #expect(panel.pending == .simpler && panel.turns.count == 1, "the refused turn leaves no empty answer")
        #expect(await w.mock.turns == 1)
        // A ticket for another surface pays for nothing either.
        await panel.perform(.simpler, ticket: ConsentTicket.mint(.ask, surface: .qa, now: K.t0))
        let turnsNow1 = await w.mock.turns
        #expect(panel.phase == .refused(.expired) && turnsNow1 == 1)
        // A ticket older than its validity.
        w.box.advance(ConsentTicket.validity + 5)
        await panel.perform(.simpler, ticket: K.ticket(.action, at: K.t0))
        let turnsNow2 = await w.mock.turns
        #expect(panel.phase == .refused(.expired) && turnsNow2 == 1)
    }

    @Test func followUpsShareThePanelsSessionAndCarryTheHistory() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w))
        await panel.perform(.explain, ticket: K.ticket())
        await panel.perform(.defineTerms, ticket: K.ticket(.action))
        panel.followUp = "  What is τ?  "
        panel.askFollowUp(ticket: K.ticket(.followUp))
        try await Self.settle(panel)
        #expect(panel.followUp.isEmpty && panel.turns.map(\.index) == [0, 1, 2])
        #expect(panel.turns.map(\.kind) == [.explain, .defineTerms, .ask("What is τ?")])
        let r = try #require(await w.mock.lastRequest)
        #expect(r.session == .reuse(threadKey: panel.threadKey))
        // The stateless fallback's history: the two earlier turns, user then assistant, neutralized.
        #expect(r.history.count == 4 && r.history.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(r.history[0].text.contains("kind=\"explain\"") && r.history[1].text.hasPrefix("Mock explanation."))
        #expect(!r.history.contains { $0.text.contains("</selection>") }, "earlier blocks can't close a tag")
        let stored = try await w.engine.db.explanations(threadID: panel.threadKey)
        #expect(stored.map(\.turn) == [0, 1, 2] && stored.map(\.action) == ["explain", "terms", "ask"])
        #expect(stored.last?.question == "What is τ?")
        // An empty field sends nothing.
        panel.followUp = "   "
        panel.askFollowUp(ticket: K.ticket(.followUp))
        try await Self.settle(panel)
        #expect(await w.mock.turns == 3)
    }

    @Test func stopKeepsThePartialTextAndStoresNothing() async throws {
        let w = try await K.world(behavior: .hang)
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w))
        panel.run(.explain, ticket: K.ticket())
        try await Self.wait { panel.phase.isBusy && panel.current != nil }
        try await Self.wait { if case .sending = panel.phase { return true }; return panel.phase == .streaming }
        await panel.stop()
        try await Self.settle(panel)
        #expect(panel.phase == .done)
        #expect(panel.current?.stopped == true && panel.current?.recordID == nil)
        #expect(try await w.engine.explanations(paperID: nil, limit: 5).isEmpty)
    }

    @Test func aNewTurnReplacesTheRunningOne() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        await w.mock.enqueue(.hang)                        // the first turn never answers
        let panel = K.panel(K.services(w))
        panel.run(.explain, ticket: K.ticket())
        try await Self.wait { panel.current != nil }
        panel.run(.simpler, ticket: K.ticket(.action))     // a chip while it waits: latest wins
        try await Self.settle(panel)
        #expect(panel.phase == .done)
        #expect(panel.turns.map(\.kind) == [.simpler], "the replaced turn had no text: it is dropped")
        #expect(panel.current?.isComplete == true)
        #expect(await w.mock.turns == 2)
        #expect(try await w.engine.explanations(paperID: nil, limit: 5).map(\.action) == ["simpler"])
    }

    @Test func aReaderExplanationKeepsItsAnchorAndCanBeSavedToNotes() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let paper = try await K.paper(w.engine, notes: "My notes")
        let anchor = ReaderAnchor(paperID: paper.id, kind: .region, page: 4, printedLabel: "1202",
                                  rect: CGRect(x: 100, y: 380, width: 200, height: 120),
                                  pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: K.excerpt)
        let panel = K.panel(K.services(w), capture: ExplainCapture(source: .reader, text: anchor.text), anchor: anchor)
        #expect(panel.paperID == paper.id && panel.page == 4)
        await panel.perform(.explain, ticket: K.ticket(.reader))
        let id = try #require(panel.current?.recordID)
        let rec = try #require(try await w.engine.db.explanation(id: id))
        #expect(rec.paperID == paper.id && rec.page == 4 && rec.matchVia == .reader && rec.matchScore == 1 && rec.source == .reader)
        #expect(await w.engine.explanationReaderAnchor(id: id) == anchor)
        // Save to notes: appended with the page; once only.
        #expect(panel.canSaveToNotes)
        try await panel.saveToNotes()
        #expect(!panel.canSaveToNotes && panel.current?.savedToNotes == true)
        let notes = try #require(try await w.engine.db.paper(id: paper.id)?.notes)
        #expect(notes.hasPrefix("My notes\n\n— Explain · p. 4 · "))
        #expect(notes.contains(K.excerpt) && notes.contains("Mock explanation."))
        try await panel.saveToNotes()
        #expect(try await w.engine.db.paper(id: paper.id)?.notes == notes)
        // Pin: every stored turn of the panel, and the next turns are stored pinned.
        await panel.setPinned(true)
        #expect(try await w.engine.db.explanation(id: id)?.pinned == true)
        await panel.perform(.simpler, ticket: K.ticket(.action))
        let next = try #require(panel.current?.recordID)
        #expect(try await w.engine.db.explanation(id: next)?.pinned == true)
        // A pruned explanation's anchor goes with the maintenance pass.
        try await w.engine.db.setExplanationPinned(id: id, false)
        _ = try await w.engine.pruneExplanations(olderThan: K.t0.addingTimeInterval(86_400))
        #expect(await w.engine.pruneExplanationReaderAnchors() == 0, "saved to notes: kept, and so is its anchor")
        #expect(await w.engine.explanationReaderAnchor(id: id) == anchor)
    }

    @Test func anchorsOfExplanationsThatAreGoneArePruned() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let paper = try await K.paper(w.engine)
        let anchor = ReaderAnchor(paperID: paper.id, kind: .selection, page: 2, rect: CGRect(x: 10, y: 10, width: 50, height: 20),
                                  pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: "x")
        await w.engine.saveExplanationReaderAnchor(anchor, explanationID: "GONE-1")
        #expect(await w.engine.explanationReaderAnchor(id: "gone-1") == anchor, "keys are lowercased")
        #expect(await w.engine.pruneExplanationReaderAnchors() == 1)
        #expect(await w.engine.explanationReaderAnchor(id: "gone-1") == nil)
    }

    @Test func closingThePanelEndsItsSession() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w))
        await panel.perform(.explain, ticket: K.ticket())
        await panel.close()
        #expect(await w.mock.closedSessions.contains(panel.threadKey))
    }

    @Test func askBeforeEverySendHoldsEachTurnForItsOwnClick() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        w.box.update { $0.assist.explainAskBeforeSend = true }
        let panel = K.panel(K.services(w))
        await panel.perform(.explain, ticket: K.ticket())
        let turnsNow3 = await w.mock.turns
        #expect(panel.phase == .refused(.askBeforeSend) && turnsNow3 == 0)
        panel.confirm(ticket: K.ticket(.action))
        try await Self.settle(panel)
        let turnsNow4 = await w.mock.turns
        #expect(panel.phase == .done && turnsNow4 == 1)
        await panel.perform(.simpler, ticket: K.ticket(.action))
        let turnsNow5 = await w.mock.turns
        #expect(panel.phase == .refused(.askBeforeSend) && turnsNow5 == 1, "every send asks")
    }

    @Test func anEmptyCaptureSendsNothing() async throws {
        let w = try await K.world()
        defer { Task { await w.close() } }
        let panel = K.panel(K.services(w), capture: ExplainCapture(source: .clipboard))
        await panel.perform(.explain, ticket: K.ticket())
        let turnsNow6 = await w.mock.turns
        #expect(panel.phase == .refused(.emptyCapture) && turnsNow6 == 0)
    }

    // MARK: Helpers

    /// Waits for the turn a `run` started to finish (its task, then not busy).
    static func settle(_ panel: ExplainPanelState) async throws {
        await panel.settled()
        try await wait { !panel.phase.isBusy }
    }

    static func wait(_ cond: @MainActor () -> Bool) async throws {
        var n = 0
        while !cond() && n < 1_000 {
            try await Task.sleep(for: .milliseconds(10))
            n += 1
        }
        #expect(cond(), "timed out waiting")
    }
}
