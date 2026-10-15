import Foundation
import Testing

/// The app-target halves of the ui-runtime fixes (hunt wave 1). The test target doesn't link the
/// app, so these read its sources (`LintRepo`, read-only); the rules are `UIRuntimeCoreTests`, the
/// runtime checks `--selftest app-rules` (`SelfTestAppRulesUI.swift`).
@Suite("UI runtime fixes: app wirings")
struct UIRuntimeWiringLintTests {
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

    static func position(_ needle: String, in text: Substring) throws -> String.Index {
        try #require(text.range(of: needle), "\(needle) not found").lowerBound
    }

    static let appDelegate = "Sources/PaperDeck/App/AppDelegate.swift"

    /// ui-runtime-1: the mismatch alert's Go back / Choose another folder / Quit never terminate
    /// synchronously inside the bootstrap task (deadlock); the launch stops before the refresher and
    /// the queued opens.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theMismatchAlertQuitsFromTheRunLoop() throws {
        let delegate = try Self.source(Self.appDelegate)
        let relaunch = try Self.source("Sources/PaperDeck/App/Relaunch.swift")
        #expect(!delegate.contains("NSApp.terminate(nil)"))
        #expect(!relaunch.contains("NSApp.terminate(nil)"))
        let quitSoon = try Self.body("static func quitSoon()", in: relaunch)
        #expect(quitSoon.contains("NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)"))
        #expect(try Self.body("static func now()", in: relaunch).contains("quitSoon()"))

        let resolve = try Self.body("private func resolveMismatch(_ check: LibraryIdentityCheck, engine: Engine) async -> Bool", in: delegate)
        #expect(resolve.contains("Relaunch.quitSoon()"))
        let bootstrap = try Self.body("private func bootstrap() async", in: delegate)
        let check = try Self.position("await resolveMismatch(mismatch, engine: engine)", in: bootstrap)
        let stop = try Self.position("return", in: bootstrap[check...])
        #expect(stop < (try Self.position("refresher?.start()", in: bootstrap)))
        #expect(stop < (try Self.position("handleOpen(opens)", in: bootstrap)))
        // Opens arriving meanwhile wait for the check, and are dropped once the alert chose to quit.
        let open = try Self.body("private func handleOpen(_ urls: [URL])", in: delegate)
        #expect(open.contains("guard !quittingAtLaunch else { return }"))
        #expect(open.contains("guard let state, acceptingOpens else {"))
        #expect(try Self.position("acceptingOpens = true", in: bootstrap) > check)
    }

    /// ui-runtime-2: the grid and the multi-inspector decode the file the versioned URL names and
    /// load again when the URL changes.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func thumbnailsFollowTheirVersionedURL() throws {
        let card = try Self.source("Sources/PaperDeck/Views/Components/PaperCardView.swift")
        #expect(try Self.body("private static func decode(_ url: URL) async -> Decoded?", in: card)
                    .contains("ThumbnailStore.unversioned(url)"))
        let multi = try Self.source("Sources/PaperDeck/Views/Library/MultiInspector.swift")
        let thumb = try Self.body("private struct Thumb: View", in: multi)
        #expect(!thumb.contains("guard image == nil"), "a new URL must not keep the old image")
        #expect(thumb.contains(".task(id: url)"))
    }

    /// ui-runtime-3: the Help Center's mail facts use the status the inbox shows and the reachable flag.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func mailFactsUseTheShownStatus() throws {
        let collector = try Self.source("Sources/PaperDeck/Views/Help/SetupFactsCollector.swift")
        let mail = try Self.body("private var mail: MailFact", in: collector)
        #expect(mail.contains("info: infos[a.id]"))
        #expect(!mail.contains("status: info?.status"))
    }

    /// ui-runtime-4: the Paper menu is in the menu bar with every key the card menu shows.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func thePaperMenuCarriesTheCardMenusShortcuts() throws {
        let menu = try Self.source("Sources/PaperDeck/Windows/PaperMenu.swift")
        let start = try #require(menu.range(of: "static let entries: [Entry] = ["))
        let end = try #require(menu[start.upperBound...].range(of: "\n    ]\n"))
        let entries = menu[start.upperBound..<end.lowerBound]
        for line in [
            "Entry(command: .openPDF, key: \"o\", modifiers: .command)",
            "Entry(command: .openInPreview, key: \"o\", modifiers: [.command, .option])",
            "Entry(command: .toggleDone, key: \"d\", modifiers: .command)",
            "Entry(command: .priorityHigh, key: \"1\", modifiers: [.command, .option])",
            "Entry(command: .priorityNormal, key: \"2\", modifiers: [.command, .option])",
            "Entry(command: .priorityLow, key: \"3\", modifiers: [.command, .option])",
            "Entry(command: .postponeDay, key: \"p\", modifiers: [.command, .shift])",
            "Entry(command: .readWithAI, key: \"r\", modifiers: [.command, .option])",
            "Entry(command: .revealInFinder, key: \"r\", modifiers: [.command, .shift])",
            "Entry(command: .moveToTrash, key: deleteKey, modifiers: .command)",
        ] {
            #expect(entries.contains(line), "\(line)")
        }
        #expect(menu.contains("static let deleteKey = \"\\u{8}\""))
        // Validation: the rules decide (library key, no text editing, a selection).
        let validate = try Self.body("func validateMenuItem(_ item: NSMenuItem) -> Bool", in: menu)
        #expect(validate.contains("PaperCommandRules.isEnabled(command, PaperMenu.context("))
        #expect(try Self.body("static func isEditingText(_ responder: NSResponder?) -> Bool", in: menu)
                    .contains("responder is NSText || responder is NSTextField"))
        let library = try Self.source("Sources/PaperDeck/Windows/LibraryWindowController.swift")
        let build = try Self.body("private static func build(target: LibraryMenuTarget)", in: library)
        #expect(build.contains("PaperMenu.make(target: target.paper)"))
        let shell = try Self.source("Sources/PaperDeck/App/L10n+shell.swift")
        #expect(shell.contains("static var menuPaper: String { zh ? \"论文\" : \"Paper\" }"))
    }

    /// ui-runtime-5: notes waiting for their debounce are written before the engine shuts down.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func quittingWritesPendingNotes() throws {
        let delegate = try Self.source(Self.appDelegate)
        let terminate = try Self.body("func applicationShouldTerminate(_ sender: NSApplication)", in: delegate)
        let flush = try Self.position("await pendingSaves?.flushAll()", in: terminate)
        #expect(flush < (try Self.position("await engine.shutdown()", in: terminate)))
        let notes = try Self.source("Sources/PaperDeck/Views/Detail/NotesEditor.swift")
        let changed = try Self.body("private func textChanged(_ new: String)", in: notes)
        #expect(changed.contains("holdForQuit(new)"))
        #expect(try Self.body("private func holdForQuit(_ value: String)", in: notes)
                    .contains("state.pendingSaves.set(pendingKey)"))
        #expect(try Self.body("private func save(_ value: String)", in: notes).contains("state.pendingSaves.clear(pendingKey)"))
    }

    /// ui-runtime-6: a minimized regular window keeps the app in the Dock.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func minimizedWindowsKeepTheAppRegular() throws {
        let policy = try Self.source("Sources/PaperDeck/App/ActivationPolicy.swift")
        #expect(policy.contains("(isVisible || isMiniaturized) && identifier.map(regularWindows.contains) == true"))
        #expect(try Self.body("static func update(closing: NSWindow? = nil)", in: policy).contains("isMiniaturized: w.isMiniaturized"))
    }

    /// ui-runtime-7: a language switch rebuilds the menu bar and retitles the windows titled once.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func aLanguageSwitchReachesTheMenuBarAndTitles() throws {
        let delegate = try Self.source(Self.appDelegate)
        let observe = try Self.body("private func observeLanguage()", in: delegate)
        #expect(observe.contains("_ = LangStore.shared.lang"))
        #expect(observe.contains("self.languageDidChange()") && observe.contains("self.observeLanguage()"))
        #expect(try Self.body("func applicationDidFinishLaunching(_ notification: Notification)", in: delegate).contains("observeLanguage()"))
        let changed = try Self.body("private func languageDidChange()", in: delegate)
        for call in ["LibraryMainMenu.relocalize()", "libraryWindow?.relocalizeTitle()", "help?.relocalizeTitle()",
                     "onboarding?.relocalizeTitle()", "AskWindowController.relocalizeTitles()",
                     "ExplainHistoryWindowController.relocalizeTitle()"] {
            #expect(changed.contains(call), "\(call)")
        }
        let library = try Self.source("Sources/PaperDeck/Windows/LibraryWindowController.swift")
        #expect(try Self.body("static func relocalize()", in: library).contains("install(target)"))
        let ask = try Self.source("Sources/PaperDeck/Windows/AskWindowController.swift")
        #expect(try Self.body("static func relocalizeTitles()", in: ask).contains("L.QA.windowTitle(controller.paperCount)"))
        let history = try Self.source("Sources/PaperDeck/Explain/ExplainHistoryView.swift")
        #expect(try Self.body("static func relocalizeTitle()", in: history).contains("L.Explain.historyTitle"))
    }
}
