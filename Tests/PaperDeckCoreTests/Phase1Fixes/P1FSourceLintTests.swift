import Foundation
import Testing

/// Phase 1 fixes checked in the sources (the test target doesn't link the app; `LintRepo`):
/// - F4: the contract lints' patterns catch the syntax that slipped through (`mint (`, a method
///   reference, a direct streaming `SpawnedChild.spawn`);
/// - F6: every test that makes something hang on purpose runs under a `.timeLimit`;
/// - F7: nothing but Edit ▸ Select All claims ⌘A (a key equivalent would take it from text fields);
/// - F1 / F10 / F11: the App wiring of the held-paper note, the undo expiry and the capped,
///   cached multi-inspector.
@Suite("Phase 1 fixes: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P1FSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    static func matches(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    // MARK: F4

    @Test func theContractPatternsCatchTheBypassSyntax() {
        let mint = AssistContractGrepTests.mintPattern
        for bypass in ["let t = ConsentTicket.mint (.action, surface: .qa)", "let f = ConsentTicket.mint",
                       "ConsentTicket . mint(.box, surface: .explain)", "    .mint(.ask, surface: .qa)",
                       "submit(r, ticket: .mint(.box, surface: .explain))"] {
            #expect(Self.matches(mint, bypass), "\(bypass)")
        }
        for innocent in ["a ticket is minted at the gesture", "let mintage = 1", "peppermint"] {
            #expect(!Self.matches(mint, innocent), "\(innocent)")
        }
        let primitive = AssistContractGrepTests.spawnPrimitivePattern
        for bypass in ["let c = try SpawnedChild.spawn(r, grace: g, mode: .streaming(onLine: { _ in }))",
                       "try SpawnedChild . spawn(r, grace: g)", "let make = SpawnedChild.spawn",
                       "SpawnedChild(pid: 1, stdoutFD: 0, stderrFD: 0, stdinFD: -1)",
                       "mode: .streaming(onLine: handler)", "mode: .streaming"] {
            #expect(Self.matches(primitive, bypass), "\(bypass)")
        }
        #expect(!Self.matches(primitive, "private let child: SpawnedChild"))
        let wrapper = AssistContractGrepTests.streamingProcessPattern
        for bypass in ["try StreamingProcess.spawn(r)", "StreamingProcess .spawn(r)", "let s = StreamingProcess.spawn",
                       "StreamingProcess(child: c, lines: l)"] {
            #expect(Self.matches(wrapper, bypass), "\(bypass)")
        }
        #expect(AssistContractGrepTests.processLayer == ["Sources/PaperDeckCore/Agent/ProcessRunner.swift",
                                                         "Sources/PaperDeckCore/Assist/StreamingProcess.swift"])
    }

    // MARK: F6

    /// A test using a hanging mock (`.hang`) has a time limit — on itself or on its suite.
    @Test func hangingTestsHaveATimeLimit() throws {
        let me = "Tests/PaperDeckCoreTests/Phase1Fixes/P1FSourceLintTests.swift"
        var missing: [String] = []
        var checked = 0
        for path in LintRepo.swiftFiles(under: "Tests") where path != me {
            let source = try Self.text(path)
            guard source.contains("@Test"), Self.matches(#"\.hang\b"#, source) else { continue }
            let chunks = source.components(separatedBy: "@Test")
            let suiteLimited = chunks[0].contains("@Suite(") && Self.matches(#"@Suite\([^\n]*\.timeLimit\("#, chunks[0])
            for chunk in chunks.dropFirst() where Self.matches(#"\.hang\b"#, chunk) {
                checked += 1
                let attribute = chunk.components(separatedBy: "func ").first ?? ""
                if !suiteLimited && !attribute.contains(".timeLimit(") {
                    let name = chunk.components(separatedBy: "func ").dropFirst().first?.prefix { $0 != "(" } ?? "?"
                    missing.append("\(path): \(name)")
                }
            }
        }
        #expect(checked >= 8, "found only \(checked) hanging tests: is the scan still seeing them?")
        #expect(missing.isEmpty, "add .timeLimit(.minutes(1)):\n\(missing.joined(separator: "\n"))")
    }

    // MARK: F7

    @Test func onlyEditSelectAllClaimsCommandA() throws {
        let forbidden = [
            #"keyboardShortcut\(\s*(KeyEquivalent\(\s*)?"[aA]""#,          // SwiftUI buttons and menus
            #"KeyEquivalent\(\s*"[aA]"\s*\)"#,
            #"keyEquivalent\s*[:=]\s*"[aA]""#,                               // NSMenuItem
            #"\bkey\s*:\s*"[aA]""#,                                           // the status menu's item(key:)
            #"onKeyPress\(\s*(characters:\s*)?"[aA]""#,
        ]
        var hits: [LintRepo.Hit] = []
        for p in forbidden { hits += try LintRepo.grep(p, under: "Sources/PaperDeck") }
        #expect(hits.isEmpty, "only Edit ▸ Select All may use ⌘A:\n\(hits.map(\.description).joined(separator: "\n"))")
        // The menu helper's key argument: exactly one "a" — Select All, sent down the responder chain.
        let helperA = try LintRepo.grep(#"\bitem\(.*,\s*"[aA]"\s*[,)]"#, under: "Sources/PaperDeck")
        #expect(helperA.count == 1, "\(helperA.map(\.description).joined(separator: "\n"))")
        #expect(helperA.first?.path == "Sources/PaperDeck/Windows/LibraryWindowController.swift"
                && helperA.first?.text.contains("item(L.Shell.menuSelectAll, #selector(NSText.selectAll(_:)), \"a\")") == true)
        // The grid takes it only as that command, while it has the focus.
        let grid = try Self.text("Sources/PaperDeck/Views/Library/CardGridView.swift")
        #expect(grid.contains(".onCommand(#selector(NSResponder.selectAll(_:)), perform: multiSelect ? { state.selection.selectAllVisible() } : nil)"))
    }

    // MARK: F1 (App)

    @Test func theRereadSheetAndToastNameTheHeldPapers() throws {
        let actions = try Self.text("Sources/PaperDeck/Views/Library/BatchActions.swift")
        let confirm = try #require(actions.range(of: "static func confirmReread("))
        let body = String(actions[confirm.upperBound...].prefix(1600))
        let preview = try #require(body.range(of: "state.engine.rereadHolds(paperIDs: ids)"))
        let present = try #require(body.range(of: "CardSheetPresenter.present"))
        #expect(preview.lowerBound < present.lowerBound, "the held papers are looked up before the sheet shows")
        #expect(body.contains("count: rows.count - held.count, held: held"))
        #expect(body.contains("L.Select.rereadHeld(outcome.held)") && body.contains("state.post(Toast(kind: .info"))
        #expect(actions.contains("if let note = L.Select.rereadHeld(held)"))
        #expect(actions.contains(".disabled(nothingToRead)"))
        let strings = try Self.text("Sources/PaperDeck/App/L10n+select.swift")
        let held = try #require(strings.range(of: "static func rereadHeld("))
        let words = String(strings[held.upperBound...].prefix(2200))
        for needle in ["可能未发表", "possibly unpublished", "待查重确认", "under duplicate review", "标为保密", "marked confidential",
                       "不使用 AI", "Never use AI", "open them to confirm", "请逐篇打开确认"] {
            #expect(words.contains(needle), "\(needle)")
        }
    }

    // MARK: F10 (App)

    @Test func everyUndoToastExpiresWithItsRecord() throws {
        let app = try Self.text("Sources/PaperDeck/App/AppState.swift")
        let post = try #require(app.range(of: "    func post(_ toast: Toast) {"))
        let postBody = String(app[post.upperBound...].prefix(900))
        #expect(postBody.contains("scheduleUndoExpiry(toast)"), "post() must schedule the [Undo] expiry")
        let schedule = try #require(app.range(of: "private func scheduleUndoExpiry(_ toast: Toast) {"))
        let scheduleBody = String(app[schedule.upperBound...].prefix(900))
        #expect(scheduleBody.contains("Task.sleep(for: .seconds(Toast.undoButtonLifetime))"))
        #expect(scheduleBody.contains("withUndoExpired(note: L.Select.undoExpired)") && scheduleBody.contains("self.post(expired)"))
        #expect(app.contains("undoExpiry[id]?.cancel()"))
        // A click that reaches the engine too late says so.
        let undo = try #require(app.range(of: "case .undo(let token):"))
        let undoBody = String(app[undo.upperBound...].prefix(400))
        #expect(undoBody.contains("engine.undo(token: token)) != true") && undoBody.contains("L.Select.undoUnavailable"))
        // Batch toasts still carry `.undo(token:)` (so the rule reaches them).
        let selection = try Self.text("Sources/PaperDeck/App/SelectionModel.swift")
        #expect(selection.contains("buttons: [Toast.Button(title: L.Select.undo, action: .undo(token: token))]"))
    }

    // MARK: F11 (App)

    @Test func theMultiInspectorIsCappedAndTheSectionsAreCached() throws {
        let inspector = try Self.text("Sources/PaperDeck/Views/Library/MultiInspector.swift")
        #expect(inspector.contains("static let listLimit = 50"))
        #expect(inspector.contains("SelectionLogic.capped(rows, limit: Self.listLimit)"))
        #expect(inspector.contains("LazyVStack(alignment: .leading, spacing: 4)") && inspector.contains("ForEach(listed.shown)"))
        #expect(inspector.contains("L.Select.morePapers(listed.more)"))
        #expect(!inspector.contains("ForEach(rows)"), "the list must not draw one row per selected paper")
        let selection = try Self.text("Sources/PaperDeck/App/SelectionModel.swift")
        #expect(selection.components(separatedBy: "CardGridLayout.sections(").count == 2,
                "the grid's sections are computed in one place (the cache)")
        #expect(selection.contains("if let c = sectionsCache, c.generation == generation { return (c.rows, c.ids) }"))
        let app = try Self.text("Sources/PaperDeck/App/AppState.swift")
        #expect(app.contains("if let cached = visibleRowsCache, cached.generation == rowsGeneration { return cached.rows }"))
        // Every input of visibleRows bumps the generation.
        for decl in ["private(set) var snapshot: LibrarySnapshot? { didSet { rowsGeneration &+= 1 } }",
                     "var sidebar: SidebarItem = .today { didSet { rowsGeneration &+= 1 } }",
                     "private(set) var searchResults: [String]? { didSet { rowsGeneration &+= 1 } }",
                     "var sort: SortOrder = .deadline { didSet { rowsGeneration &+= 1 } }"] {
            #expect(app.contains(decl), "\(decl)")
        }
    }
}
