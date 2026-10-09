import Foundation
import Testing

/// Phase 2's switch-on (Lead), checked in the sources (the test target doesn't link the app): Ask
/// ships, Settings ▸ Explain & Ask's form keeps two lines — the shared switch (which places Settings ▸
/// Explain once Explain ships, phase 3) and Settings ▸ Ask —, Preview stays the default opener while the reader is one click away, and the lanes'
/// change requests are placed (R-RD-1…4, R-RD-6, R-QA-3…6, R-QA-9, R-B3-1).
@Suite("Phase 2 integration: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P2IntegrationLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    /// The body of `func name` / `var name` up to the next declaration at the same indentation.
    static func body(_ source: String, after marker: String, length: Int = 1_200) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker)")
        return String(source[start.upperBound...].prefix(length))
    }

    /// Phase 2 shipped Ask with Explain hidden; phase 3 flipped Explain on (R-UI-6, `P3IntegrationLintTests`).
    @Test func askShipsAndExplainFollows() throws {
        #expect(try Self.text("Sources/PaperDeck/Views/Detail/AskTab.swift").contains("static let isAvailable = true"))
        #expect(try Self.text("Sources/PaperDeck/Explain/ExplainCoordinator.swift").contains("static let isAvailable = true"))
        let rollout = try Self.text("Sources/PaperDeck/App/AssistRollout.swift")
        #expect(rollout.contains("static var dedupeJudge: Bool { DedupeUIModel.judgeShips }"))   // R-B3-1
        #expect(rollout.contains("static var policyToggles: Bool { explain || ask || dedupeJudge }"))
        // The judge ships with the settings tab, off by default and only on a click (B's own checks).
        #expect(try Self.text("Sources/PaperDeck/App/DedupeUIModel.swift")
            .contains("static var judgeShips: Bool { isAvailable && judgeIsAvailable && AssistRollout.assistSettings }"))
    }

    @Test func theSettingsTabShowsOnlyTheSwitchAndAsk() throws {
        let tab = try Self.text("Sources/PaperDeck/Views/Settings/AssistSettingsTab.swift")
        #expect(tab.contains("static let isAvailable = true"))
        let form = try Self.body(tab, after: "        Form {", length: 200)
        let closing = try #require(form.range(of: "\n        }"))
        let lines = form[..<closing.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(lines == ["AssistSwitchSection(state: state)", "QASettingsSection(state: state)"], "\(lines)")
        // The switch writes assist.mode only on the user's toggle, records the consent the card records,
        // and never starts anything (no ticket, no engine call).
        let section = try Self.body(tab, after: "struct AssistSwitchSection: View {", length: 4_000)
        #expect(section.contains("static var consentVersion: Int { AskEnableCard.consentVersion }"))
        #expect(section.contains("a.consentVersion = max(a.consentVersion, Self.consentVersion)"))
        #expect(!section.contains("mint") && !section.contains("engine."))
        // assist.mode stays off by default (Core's default; BlockTagsAndSettingsTests checks the loader).
        #expect(try Self.text("Sources/PaperDeckCore/Engine/AssistSettings.swift").contains("package init(mode: AssistMode = .off,"))
    }

    @Test func previewStaysTheDefaultAndTheReaderIsOneClickAway() throws {
        let state = try Self.text("Sources/PaperDeck/App/AppState.swift")
        let hook = try #require(state.range(of: "if ReaderRouter.opensInReader(opener: settings.pdfOpener) {"))     // R-RD-1
        let preview = try #require(state.range(of: "if settings.pdfOpener == \"preview\","))
        #expect(hook.lowerBound < preview.lowerBound)
        #expect(try Self.text("Sources/PaperDeck/App/SettingsStore.swift").contains("Keys.pdfOpener: \"preview\""))
        // "Open in PaperDeck Reader" in the card menu while another app is the opener (R-RD-6).
        let menu = try Self.text("Sources/PaperDeck/Views/Library/PaperContextMenu.swift")
        #expect(menu.contains("if ReaderRouter.isAvailable && state.settings.pdfOpener != ReaderRoute.Opener.paperDeck {"))
        #expect(menu.contains("ReaderRouter(state: state).openReader(row, page: nil, quote: nil)"))
        let strings = try Self.text("Sources/PaperDeck/App/L10n+reader.swift")
        #expect(strings.contains("static var openInReader: String { zh ? \"在 PaperDeck 阅读器中打开\" : \"Open in PaperDeck Reader\" }"))
        // Checklist "p. N" chips open at their page (R-RD-2, closes R-C1-5).
        let checklist = try Self.text("Sources/PaperDeck/Views/Detail/ChecklistView.swift")
        #expect(checklist.components(separatedBy: "state.openPDF(row, page: item.page)").count == 3)
        #expect(!checklist.contains("state.openPDF(row) }"))
        // Reader windows (R-RD-3) and Ask windows keep the Dock icon and menu bar.
        let policy = try Self.text("Sources/PaperDeck/App/ActivationPolicy.swift")
        #expect(policy.contains("[library, onboarding, help, reader, ask]"))
        let askWindow = try Self.text("Sources/PaperDeck/Windows/AskWindowController.swift")
        for needle in ["w.identifier = ActivationPolicy.ask", "ActivationPolicy.becomeRegular()", "ActivationPolicy.update(closing: window)"] {
            #expect(askWindow.contains(needle), "\(needle)")
        }
    }

    @Test func theAskEntryPointsArePlaced() throws {
        #expect(try Self.text("Sources/PaperDeck/App/AppDelegate.swift").contains("AskRouter.install(state)"))          // R-QA-6
        let host = try Self.text("Sources/PaperDeck/Views/Detail/DetailTabsHost.swift")                                  // R-QA-5
        #expect(host.contains(".onAppear { if AskFocus.shared.consume(row.id) { tab = .ask } }"))
        #expect(host.contains("if id == row.id, AskFocus.shared.consume(row.id) { tab = .ask }"))
        let bar = try Self.text("Sources/PaperDeck/Views/Library/SelectionBar.swift")                                    // R-QA-4
        #expect(bar.contains("AskAcrossButton(state: state, rows: menus.rows, short: true)"))
        #expect(bar.contains("AskAcrossButton(state: state, rows: menus.rows)"))
        #expect(try Self.text("Sources/PaperDeck/Views/Library/BatchActions.swift").contains("AskAcrossButton(state: state, rows: rows)"))
        #expect(try Self.text("Sources/PaperDeck/Views/Library/MultiInspector.swift").contains("AskAcrossButton(state: state, rows: menus.rows)"))
    }

    @Test func theCLIModesAreReachable() throws {
        let runner = try Self.text("Sources/PaperDeck/CLI/CLIRunner.swift")                                              // R-QA-3, R-RD-4
        #expect(runner.contains("\"--ask-render\","))
        #expect(runner.contains("case \"--ask-render\": return spin { await AskRenders.run(args) }"))
        for usage in ["--ask-render OUTDIR --root SCRATCH", "--selftest qa [--lang en|zh]", "[--reader-only [--no-mail-demo] [--probe-reader]]"] {
            #expect(runner.contains(usage), "\(usage)")
        }
        #expect(try Self.text("Sources/PaperDeck/CLI/SelfTest.swift").contains("if args.positional == \"qa\" { return SelfTestQA.run(args) }"))
        let renderer = try Self.text("Sources/PaperDeck/CLI/PreviewRenderer.swift")
        #expect(renderer.contains("if args.has(\"--reader-only\") {"))
        #expect(renderer.contains("try await ReaderRenders.render(state: state, engine: engine, root: root, appearance: appearance, out: out,"))
    }

    /// A finished (or failed / stopped) answer: the stored row is loaded before the live one goes, so
    /// `isRunning` never turns false over a row still saved as streaming (the `--probe-send` flake).
    @Test func aFinishedAnswerSwapsInItsStoredRowAtOnce() throws {
        let session = try Self.text("Sources/PaperDeck/Views/Ask/AskSession.swift")
        let completed = try Self.body(session, after: "        case .completed:\n", length: 200)
        let guardNewer = "            guard !Task.isCancelled else { return }\n"
        #expect(completed.hasPrefix("            await reloadThreads(qa)\n            await reloadMessages(qa)\n" + guardNewer
                                    + "            finishStreaming()\n"), "\(completed)")
        let failed = try Self.body(session, after: "        case .failed(let f, _):\n", length: 200)
        #expect(failed.hasPrefix("            await reloadMessages(qa)\n" + guardNewer + "            finishStreaming()\n"), "\(failed)")
    }

    @Test func theNotesEditorKeepsASaveToNotesBlock() throws {
        let editor = try Self.text("Sources/PaperDeck/Views/Detail/NotesEditor.swift")                                   // R-QA-9
        #expect(editor.contains("} else if !inFlight.contains(stored),"))
        #expect(editor.contains("let merged = NotesMerge.appendedBlocks(base: lastSaved, stored: stored, local: text) {"))
        #expect(editor.contains("inFlight.append(value)"))
    }

    /// R-QA-1 / R-QA-2 in Core (behaviour: `P2IntegrationTests`).
    @Test func qaJsonFollowsPolicyAndRebuild() throws {
        let policy = try Self.text("Sources/PaperDeckCore/Engine/OperationsPolicy.swift")
        let set = try Self.body(policy, after: "package func setPaperPolicy(", length: 700)
        #expect(set.contains("await syncQASidecar(paperID: paperID)"))
        let rebuild = try Self.text("Sources/PaperDeckCore/Engine/Rebuild.swift")
        #expect(rebuild.contains("_ = await restoreQASidecars(paperIDs: outcome.inserted.map(\\.id))"))
    }
}
