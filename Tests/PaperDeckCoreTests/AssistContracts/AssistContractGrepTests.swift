import CryptoKit
import Foundation
import Testing

/// Slice 0's source contracts (READING_ASSIST_PLAN §6.1), read from the sources the tests were
/// compiled from. A slice that needs an allowlist entry asks the Lead (this file is Lead-owned).
@Suite("Assist contracts: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct AssistContractGrepTests {
    private static func text(_ path: String) throws -> String {
        try String(contentsOf: LintRepo.url(path), encoding: .utf8)
    }

    /// A consent ticket is minted only in a UI action handler, at the user's gesture: these App files
    /// (planned per slice; a new one needs the Lead's OK) — never in Core, never anywhere else.
    static let mintAllowlist: Set<String> = [
        "Sources/PaperDeck/Explain/CaptureOverlayController.swift",     // A: box, lens, clipboard offer
        "Sources/PaperDeck/Explain/ExplainServiceProvider.swift",       // A: Services
        "Sources/PaperDeck/Explain/ExplainPanelView.swift",             // A: follow-up, action, retry
        "Sources/PaperDeck/Drop/DropIntake.swift",                      // A: an image dropped to explain
        "Sources/PaperDeck/Assist/AssistBanner.swift",                  // A: [Continue] past the soft cap
        "Sources/PaperDeck/Reader/SelectionToolbar.swift",              // C: the reader's Explain / Ask
        "Sources/PaperDeck/Views/Detail/AskTab.swift",                  // C: ask, follow-up, retry
        "Sources/PaperDeck/Views/Ask/AskWindowView.swift",              // C: ask across N papers
        "Sources/PaperDeck/Views/Dedupe/DuplicateSheet.swift",          // B: [Ask AI] in the decision sheet
        "Sources/PaperDeck/CLI/CLIRunner.swift",                        // A: --assist-smoke --yes --max-runs N
    ]
    static let mintDefinition = "Sources/PaperDeckCore/Assist/AssistModels.swift"

    /// The word `mint` as a whole word — a call with a space before its parenthesis (`mint (…)`),
    /// `ConsentTicket . mint`, a method reference (`let f = ConsentTicket.mint`) or `.mint(…)` shorthand
    /// all count (Phase 1 fix F4: `\bmint\(` missed the first three).
    static let mintPattern = #"\bmint\b|ConsentTicket\s*\.\s*mint"#

    @Test func consentTicketsAreMintedOnlyInActionHandlers() throws {
        let hits = try LintRepo.grep(Self.mintPattern)
        let definition = hits.filter { $0.path == Self.mintDefinition }
        #expect(definition.count == 1 && definition.first?.text.contains("static func mint(") == true, "\(definition)")
        let outside = hits.filter { $0.path != Self.mintDefinition && !Self.mintAllowlist.contains($0.path) }
        #expect(outside.isEmpty, "mint outside the action-handler allowlist:\n\(outside.map(\.description).joined(separator: "\n"))")
        #expect(Self.mintAllowlist.allSatisfy { $0.hasPrefix("Sources/PaperDeck/") })
        // The initializer stays private: a ticket can't be built any other way.
        let models = try Self.text(Self.mintDefinition)
        #expect(models.contains("private init(id: UUID, gesture: Gesture, surface: AssistSurface, issuedAt: Date)"))
    }

    /// `StreamingProcess.spawn(…)`, `StreamingProcess (…)`, `StreamingProcess . spawn` or a reference to it.
    static let streamingProcessPattern = #"StreamingProcess\s*(\.\s*spawn\b|\()"#
    /// The process primitive (`SpawnedChild.spawn`, `SpawnedChild(`) and its streaming mode (`.streaming(onLine:)`).
    static let spawnPrimitivePattern = #"\bSpawnedChild\s*(\.\s*spawn\b|\()|\.\s*streaming\s*\(\s*onLine\b|mode\s*:\s*\.\s*streaming\b"#
    /// The two files that may use the primitive: its definition and the streaming wrapper.
    static let processLayer: Set<String> = [
        "Sources/PaperDeckCore/Agent/ProcessRunner.swift",
        "Sources/PaperDeckCore/Assist/StreamingProcess.swift",
    ]

    /// A streaming CLI child is started only by the two subscription backends (Slice A), which run
    /// only through `AssistLane` — whose every turn and pre-spawn asks `AssistGate` first.
    @Test func noStreamingSpawnBypassesTheGate() throws {
        let spawnAllowed: Set<String> = [
            "Sources/PaperDeckCore/Assist/StreamingProcess.swift",          // the definition
            "Sources/PaperDeckCore/Assist/ClaudeAssistSession.swift",
            "Sources/PaperDeckCore/Assist/CodexAssistTurn.swift",
        ]
        let spawns = try LintRepo.grep(Self.streamingProcessPattern).filter { !spawnAllowed.contains($0.path) }
        #expect(spawns.isEmpty, "\(spawns.map(\.description).joined(separator: "\n"))")
        // Below StreamingProcess: the child-process primitive and its streaming mode are used only by
        // the process layer itself (F4: a direct `SpawnedChild.spawn(…, mode: .streaming(onLine:))`
        // from another file would skip StreamingProcess — and the backends and the gate with it).
        let primitives = try LintRepo.grep(Self.spawnPrimitivePattern).filter { !Self.processLayer.contains($0.path) }
        #expect(primitives.isEmpty, "\(primitives.map(\.description).joined(separator: "\n"))")
        // Backend turns are started only by the lane (and declared by the protocol / backends).
        let turns = try LintRepo.grep(#"\.turn\([^)]*turnIndex:"#)
            .filter { $0.path != "Sources/PaperDeckCore/Assist/AssistLane.swift" }
        #expect(turns.isEmpty, "\(turns.map(\.description).joined(separator: "\n"))")
        let lane = try Self.text("Sources/PaperDeckCore/Assist/AssistLane.swift")
        #expect(lane.contains("gate.checkTurn(") && lane.contains("gate.checkSpawn("))
        let submit = try #require(lane.range(of: "func submit("))
        let check = try #require(lane.range(of: "gate.checkTurn("))
        let run = try #require(lane.range(of: "backend.turn("))
        #expect(submit.lowerBound < check.lowerBound && check.lowerBound < run.lowerBound)
        // The App target never starts one itself.
        #expect(try LintRepo.grep("StreamingProcess", under: "Sources/PaperDeck").isEmpty)
    }

    @Test func screenRecordingIsRequestedOnlyByScreenPermission() throws {
        let hits = try LintRepo.grep("CGRequestScreenCaptureAccess")
            .filter { $0.path != "Sources/PaperDeck/Explain/ScreenPermission.swift" }
        #expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
    }

    /// No institution or field persona literal in the reading-assist code: Core holds reason codes
    /// and takes the reader from the injected closure; the App words policy through `AssistPolicyText`.
    @Test func noInstitutionOrPersonaLiteralInTheNewCode() throws {
        let institution = InstitutionLintTests.pattern
        let persona = #"computational[- ]biology|comp-bio|PhD-level"#
        let folders = ["Sources/PaperDeckCore/Assist", "Sources/PaperDeckCore/Explain", "Sources/PaperDeckCore/QA",
                       "Sources/PaperDeckCore/Dedupe", "Sources/PaperDeckCore/Batch", "Sources/PaperDeck/Assist",
                       "Sources/PaperDeck/Explain", "Sources/PaperDeck/Reader", "Sources/PaperDeck/Views/Dedupe",
                       "Sources/PaperDeck/Views/Ask"]
        var hits: [LintRepo.Hit] = []
        for folder in folders where FileManager.default.fileExists(atPath: LintRepo.url(folder).path) {
            hits += try LintRepo.grep(institution, caseInsensitive: true, under: folder)
            hits += try LintRepo.grep(persona, caseInsensitive: true, under: folder)
        }
        let files = ["assist", "explain", "dedupe", "qa", "select", "policy"].map { "Sources/PaperDeck/App/L10n+\($0).swift" }
            + ["Sources/PaperDeckCore/DB/SchemaAssist.swift", "Sources/PaperDeckCore/DB/Database+Policy.swift",
               "Sources/PaperDeckCore/Engine/OperationsPolicy.swift", "Sources/PaperDeckCore/Engine/AssistSettings.swift",
               "Sources/PaperDeckCore/Models/PaperPolicy.swift"]
        for file in files {
            let text = try Self.text(file)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                for p in [institution, persona] where line.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                    hits.append(LintRepo.Hit(path: file, line: i + 1, text: line))
                }
            }
        }
        #expect(hits.isEmpty, "\(hits.map(\.description).joined(separator: "\n"))")
        #expect(FileManager.default.fileExists(atPath: LintRepo.url("Sources/PaperDeckCore/Assist").path))
    }

    /// The two Services entries ("Explain with PaperDeck", "Ask PaperDeck…"). Before Explain shipped
    /// they carried a required context no app matches, so nothing appeared in any Services menu;
    /// phase 3 flipped `ExplainCoordinator.isAvailable` and dropped the gate together. The gate and
    /// the flag still have to agree (reverting one without the other fails here), every entry's
    /// message is a selector the provider answers, and no other required context hides them.
    @Test func infoPlistDeclaresTheServicesExactlyWhileExplainShips() throws {
        let data = try Data(contentsOf: LintRepo.url("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try #require(plist["NSServices"] as? [[String: Any]])
        #expect(services.compactMap { $0["NSMessage"] as? String }.sorted() == ["askText", "explainText"])
        let provider = try Self.text("Sources/PaperDeck/Explain/ExplainServiceProvider.swift")
        for s in services {
            #expect(s["NSPortName"] as? String == "PaperDeck")
            #expect((s["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true)
            let title: String = (s["NSMenuItem"] as? [String: String])?["default"] ?? ""
            #expect(title.contains("PaperDeck"))
            let message = s["NSMessage"] as? String ?? ""
            #expect(provider.contains("@objc func \(message)(_ pboard: NSPasteboard, userData: String?, error:"), "\(message)")
        }
        let explainShips = try !Self.text("Sources/PaperDeck/Explain/ExplainCoordinator.swift").contains("static let isAvailable = false")
        #expect(explainShips, "Explain ships in phase 3")
        let gated = services.allSatisfy { s in
            ((s["NSRequiredContext"] as? [String: Any])?["NSApplicationIdentifier"] as? [String])?
                .contains("paperdeck.services.until-explain-ships") == true
        }
        #expect(gated == !explainShips, "the Services gate must be on exactly while Explain isn't available")
        if explainShips {
            #expect(services.allSatisfy { $0["NSRequiredContext"] == nil }, "a shipped entry carries no required context")
            #expect(!(try Self.text("Resources/Info.plist")).contains("until-explain-ships"))
        }
        // The identity lines G2 pins didn't move.
        let lines = try Self.text("Resources/Info.plist").components(separatedBy: "\n")
        #expect(lines[9].contains("<string>com.") && lines[55].contains("<string>com."))
    }

    /// `./build_app.sh --dev` turns every AI switch off: card reading, Explain & Ask, the automatic judge.
    @Test func theDevBuildWritesEveryAISwitchOff() throws {
        let script = try Self.text("build_app.sh")
        let start = try #require(script.range(of: "if [ \"$DEV\" = 1 ]; then\n  defaults write"))
        let end = try #require(script.range(of: "\nfi", range: start.upperBound..<script.endIndex))
        let block = String(script[start.lowerBound..<end.lowerBound])
        #expect(block.contains("defaults write \"$BUNDLE_ID\" agent.mode off"))
        #expect(block.contains("defaults write \"$BUNDLE_ID\" assist.mode off"))
        #expect(block.contains("defaults write \"$BUNDLE_ID\" dedupe.ai.auto -bool false"))
        // Only "off" values are written there.
        let writes = block.components(separatedBy: "\n").filter { $0.contains("defaults write") }
        #expect(writes.count == 3 && writes.allSatisfy { $0.hasSuffix(" off") || $0.hasSuffix(" -bool false") })
    }

    /// The card path is pinned: CardSchema.swift byte-identical (about 20 tests and the portability
    /// golden check pin its prompt text), and `ProcessRunner.run` keeps its signature.
    /// 2026-10-02 (lead decision, phase-2 fixes): the private block-tag neutralizer now delegates to
    /// `BlockTags.neutralize` (closes the QA-1/QA-9 gap — `< /paper>`, invisible marks) — code only;
    /// the system/user prompt text is unchanged (card-system-prompt-v1 sha256 still equal).
    @Test func theCardPathIsUnchanged() throws {
        let data = try Data(contentsOf: LintRepo.url("Sources/PaperDeckCore/Agent/CardSchema.swift"))
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "63d53d898dd2af41c5b662aad8d48a289bdc81e44063b417834cecf695968a48")
        let runner = try Self.text("Sources/PaperDeckCore/Agent/ProcessRunner.swift")
        #expect(runner.contains("    package func run(_ request: Request) async throws -> Result {"))
    }

    /// The slots exist in their owners' files and the Lead's files place them.
    @Test func theSlotsArePlaced() throws {
        let slots = [
            "Sources/PaperDeck/Views/Dedupe/DuplicateRibbon.swift": "struct DuplicateRibbon: View",
            "Sources/PaperDeck/Views/Dedupe/DuplicateChip.swift": "struct DuplicateChip: View",
            "Sources/PaperDeck/Views/Settings/DedupeSettingsSection.swift": "struct DedupeSettingsSection: View",
            "Sources/PaperDeck/Views/Detail/ExplanationsSection.swift": "struct ExplanationsSection: View",
            "Sources/PaperDeck/Views/Detail/AskTab.swift": "struct AskTab: View",
            "Sources/PaperDeck/Views/Detail/DetailTabsHost.swift": "struct DetailTabsHost<Overview: View>: View",
            "Sources/PaperDeck/Views/Library/SelectionBar.swift": "struct SelectionBar: View",
            "Sources/PaperDeck/Reader/ReaderOpenerOption.swift": "struct ReaderOpenerOption: View",
            "Sources/PaperDeck/Views/Settings/AssistSettingsTab.swift": "struct AssistSettingsTab: View",
        ]
        for (file, decl) in slots { #expect(try Self.text(file).contains(decl), "\(file)") }
        let placed = [
            "Sources/PaperDeck/Views/Components/PaperCardView.swift": ["DuplicateRibbon(row: row)"],
            "Sources/PaperDeck/Views/Detail/PaperDetailView.swift": ["DetailTabsHost(state: state, row: row)",
                                                                     "DuplicateChip(state: state, row: row)",
                                                                     "ExplanationsSection(state: state, row: row)",
                                                                     "PaperPolicyToggles(state: state, row: row)"],
            "Sources/PaperDeck/Views/Settings/SettingsView.swift": ["ReaderOpenerOption()", "case .assist: AssistSettingsTab(state: state)"],
            "Sources/PaperDeck/Views/Settings/LibrarySettingsTab.swift": ["DedupeSettingsSection(state: state)"],
            "Sources/PaperDeck/Windows/LibraryWindowController.swift": ["ReadingAssistMenus.appendSelectItems(",
                                                                        "ReadingAssistMenus.appendMenus("],
            "Sources/PaperDeck/Windows/StatusBarController.swift": ["ReadingAssistMenus.appendAssistItems("],
            "Sources/PaperDeck/App/AppDelegate.swift": ["ExplainBootstrap.install(state)"],
            "Sources/PaperDeck/App/AppState.swift": ["let selection = SelectionModel()", "let dedupe = DedupeUIModel()",
                                                     "let assist = AssistUIModel()", "if dedupe.handle(e) { return }",
                                                     "engine.recentOpens.push(paperID: row.id)"],
        ]
        for (file, needles) in placed {
            let text = try Self.text(file)
            for n in needles { #expect(text.contains(n), "\(file): \(n)") }
        }
        // The Settings tab order coordinated with portability (§8).
        let tabs = try Self.text("Sources/PaperDeck/Windows/SettingsWindowController.swift")
        #expect(tabs.contains("case general, profile, plan, ai, assist, mail, library, widget"))
    }
}
