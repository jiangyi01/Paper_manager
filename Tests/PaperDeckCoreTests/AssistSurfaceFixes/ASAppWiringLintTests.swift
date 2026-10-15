import Foundation
import Testing

/// The app-target halves of the assist-surfaces fixes (hunt wave 2). The test target doesn't link the
/// app, so these read its sources (`LintRepo`, read-only); the rules themselves are tested in Core
/// (`ASExplainPanelFixTests`, `ASAskFixTests`, `ASStatusFixTests`).
@Suite("Assist surfaces: app wirings")
struct ASAppWiringLintTests {
    static func source(_ path: String) throws -> String {
        try String(contentsOf: LintRepo.url(path), encoding: .utf8)
    }

    /// The body of the first `signature` in `text` (balanced braces).
    static func body(_ signature: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: signature), "\(signature) not found")
        guard let open = text[start.upperBound...].firstIndex(of: "{") else { return "" }
        var depth = 0
        var i = open
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 } else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return text[open...i] }
            }
            i = text.index(after: i)
        }
        return text[open...]
    }

    static let overlay = "Sources/PaperDeck/Explain/CaptureOverlayController.swift"

    /// assist-surfaces-3: Tab's language is this request's only — every opening of the overlay
    /// follows the setting again.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theOverlaysLanguageIsResetForEachOpening() throws {
        let text = try Self.source(Self.overlay)
        let show = try Self.body("func show(mode: AssistSettings.OverlayMode)", in: text)
        #expect(show.contains("model.language = nil"), "show(mode:) must reset Tab's language")
        // Before any capture of this opening reads it.
        let reset = try #require(show.range(of: "model.language = nil"))
        let firstPanel = try #require(show.range(of: "for screen in NSScreen.screens"))
        #expect(reset.lowerBound < firstPanel.lowerBound)
    }

    /// assist-surfaces-10: a click queued behind an earlier opening's freeze is that opening's: it is
    /// dropped once the overlay closed, even when it is up again.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func aQueuedClickBelongsToItsOverlaySession() throws {
        let text = try Self.source(Self.overlay)
        #expect(text.contains("private var session = 0"))
        #expect(try Self.body("func show(mode: AssistSettings.OverlayMode)", in: text).contains("session += 1"))
        #expect(try Self.body("func dismiss()", in: text).contains("session += 1"))
        let choose = try Self.body("private func choose(_ choice: Choice, lens: Bool)", in: text)
        let queued = try #require(choose.range(of: "guard let pending = freezeTask"))
        let after = choose[queued.upperBound...]
        #expect(after.contains("let gen = session"))
        #expect(after.contains("guard let self, self.isShown, self.session == gen else { return }"))
        // The generation is checked before the queued click touches the overlay or sends.
        let guardAt = try #require(after.range(of: "self.session == gen"))
        let capturing = try #require(after.range(of: "self.model.capturing = false"))
        let finish = try #require(after.range(of: "self.finish(choice"))
        #expect(guardAt.lowerBound < capturing.lowerBound && guardAt.lowerBound < finish.lowerBound)
        // A capture already being prepared is cancelled by the dismiss itself (`finishTask`).
        #expect(try Self.body("func dismiss()", in: text).contains("finishTask?.cancel()"))
    }

    /// assist-surfaces-4: "Remove from This Question" re-files the session and its window under the
    /// new set of papers; the window's title counts what is left; the cap note is the cap's only.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func aRemovedPaperRefilesTheSessionAndItsWindow() throws {
        let session = try Self.source("Sources/PaperDeck/Views/Ask/AskSession.swift")
        #expect(session.contains("private(set) var key: String"))
        #expect(!session.contains("    let key: String"))
        let setPapers = try Self.body("func setPapers(_ ids: [String])", in: session)
        for line in ["key = AskSessions.key(ids)", "AskSessions.rekey(self, from: oldKey, state: $0)", "onPapersChange?(oldKey, filed)"] {
            #expect(setPapers.contains(line), "setPapers: \(line)")
        }
        let rekey = try Self.body("static func rekey(_ session: AskSession, from old: String, state: AppState) -> Bool", in: session)
        #expect(rekey.contains("byState[sid]?[old] = nil") && rekey.contains("byState[sid, default: [:]][session.key] = session"))
        // A session kept under a key never answers for a selection it no longer covers.
        let find = try Self.body("static func session(for paperIDs: [String], state: AppState) -> AskSession", in: session)
        #expect(find.contains("if s.paperIDs == paperIDs { return s }"))

        let controller = try Self.source("Sources/PaperDeck/Windows/AskWindowController.swift")
        #expect(controller.contains("private var key: String"))
        #expect(controller.contains("session.onPapersChange = { [weak self, weak session] oldKey, filed in"))
        let changed = try Self.body("private func papersChanged(_ session: AskSession, from oldKey: String, filed: Bool)", in: controller)
        for line in ["if Self.open[oldKey] === self { Self.open[oldKey] = nil }", "key = session.key",
                     "if filed, Self.open[session.key] == nil { Self.open[session.key] = self }",
                     "window.title = L.QA.windowTitle(session.paperIDs.count)"] {
            #expect(changed.contains(line), "papersChanged: \(line)")
        }
        #expect(try Self.body("func windowWillClose(_ notification: Notification)", in: controller)
            .contains("if Self.open[key] === self { Self.open[key] = nil }"))
        #expect(controller.contains("let capped = unique.count > kept.count ? (kept: kept.count, selected: unique.count) : nil"))

        let view = try Self.source("Sources/PaperDeck/Views/Ask/AskWindowView.swift")
        #expect(view.contains("if let capped, session.paperIDs.count == capped.kept {"))
        #expect(view.contains("Text(L.QA.capNote(capped.kept, capped.selected))"))
        #expect(!view.contains("selectedCount > session.paperIDs.count"), "the old check blamed the cap for a removal")
        #expect(!view.contains(".task(id: session.key)"), "a re-keyed session would load twice")
    }

    /// assist-surfaces-7: the footers' "today n" is published at launch, on a provider or cap change
    /// and on a day change — through the lane's zero-quota snapshot, never a detection.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func todaysCountIsPublishedWithoutATurn() throws {
        let engine = try Self.source("Sources/PaperDeckCore/Engine/Engine.swift")
        let start = try Self.body("package func start() async -> MaintenanceReport", in: engine)
        let restore = try #require(start.range(of: "await restoreAssistCounters()"))
        let publish = try #require(start.range(of: "await assist.publishSnapshot()"))
        #expect(restore.lowerBound < publish.lowerBound, "published after the counts are restored")

        let store = try Self.source("Sources/PaperDeck/App/SettingsStore.swift")
        #expect(store.contains("|| assist.dailyHardCap != oldValue.dailyHardCap { onAssistQuotaChange?() }"))
        #expect(store.contains("if assist.mode != oldValue.mode || assist.dailySoftCap != oldValue.dailySoftCap"))
        let delegate = try Self.source("Sources/PaperDeck/App/AppDelegate.swift")
        #expect(delegate.contains("settings.onAssistQuotaChange = { Task { await engine.assist.publishSnapshot() } }"))
        let refresher = try Self.source("Sources/PaperDeck/Services/DerivedRefresher.swift")
        let timeChanged = try Self.body("private func timeChanged(catchUpAfter delay: Duration?)", in: refresher)
        #expect(timeChanged.contains("Task { await engine.assist.publishSnapshot() }"))
        #expect(refresher.contains("events.on(.dayChanged) { [weak self] in self?.timeChanged("))
        // No surface asks for a detection to show the count.
        let callers = try LintRepo.grep(#"assist\.status\(\)"#, under: "Sources/PaperDeck")
        #expect(callers.isEmpty, "\(callers)")
    }

    /// assist-surfaces-8: Save to Notes only for an answer it can save; QA / Explain refusals are
    /// sentences in the toast.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func saveToNotesFollowsTheEnginesRuleAndErrorsAreWorded() throws {
        let thread = try Self.source("Sources/PaperDeck/Views/Ask/AskThreadView.swift")
        let actions = try Self.body("private var actions: some View", in: thread)
        let gate = try #require(actions.range(of: "if !message.canSaveToNotes {"))
        for save in ["session.saveToNotes(messageID: message.id)", "L.QA.saveToNotesOf", "L.QA.saveToNotes,"] {
            let at = try #require(actions.range(of: save), "\(save)")
            #expect(gate.lowerBound < at.lowerBound, "\(save) is behind the rule")
        }
        let service = try Self.source("Sources/PaperDeckCore/QA/QAService.swift")
        #expect(service.contains("guard m.canSaveToNotes else { throw QAError.notAnAnswer(messageID) }"))
        let state = try Self.source("Sources/PaperDeck/App/AppState.swift")
        let report = try Self.body("func report(_ error: Error)", in: state)
        #expect(report.contains("else if let e = error as? QAError { message = e.message(settings.language) }"))
        #expect(report.contains("else if let e = error as? ExplainOperationError { message = e.message(settings.language) }"))
    }

    /// assist-surfaces-9: Cancel and ✕ on a notice go through `dismissNotice`, which puts a privacy
    /// confirmation's question back into the composer.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func dismissingAConfirmationKeepsTheQuestion() throws {
        let notices = try Self.source("Sources/PaperDeck/Views/Ask/AskNotices.swift")
        #expect(notices.contains("Button { session.dismissNotice() } label: { Image(systemName: \"xmark\") }"))
        #expect(notices.contains("Button(L.cancel) { session.dismissNotice() }"))
        #expect(!notices.contains("Button(L.cancel) { session.notice = nil }"))
        #expect(!notices.contains("Button { session.notice = nil } label: { Image(systemName: \"xmark\") }"))
        let session = try Self.source("Sources/PaperDeck/Views/Ask/AskSession.swift")
        let dismiss = try Self.body("func dismissNotice()", in: session)
        #expect(dismiss.contains("draft = QASendPlan.draftAfterDismissing(confirming: q, draft: draft, messages: messages)"))
        #expect(dismiss.contains("notice = nil"))
    }

    /// assist-surfaces-2 / -6: the Ask session remembers sends through Core's plan; the Explain
    /// pipeline hands the panel the text its locator used.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theSurfacesUseCoresRules() throws {
        let session = try Self.source("Sources/PaperDeck/Views/Ask/AskSession.swift")
        #expect(session.contains("lastAsk = QASendPlan.sent(intent, send, threadID: thread?.id)"))
        #expect(session.contains("start(send, intent: intent, ticket: ticket)"))
        let pipeline = try Self.source("Sources/PaperDeck/Explain/ExplainPipeline.swift")
        #expect(pipeline.contains("let located = around ?? selection"))
        #expect(pipeline.contains("PaperLocator.locate(windowTitle: capture.windowTitle, ocrText: located, engine: engine)"))
        #expect(pipeline.contains("selectionIsExact: exact, locatedText: located,"))
        let match = try Self.source("Sources/PaperDeck/Explain/ExplainPanelView+Match.swift")
        #expect(!match.contains("excerpt: state.excerpt"), "a term's correction was filed under the term only")
    }
}
