import Foundation
import Testing

/// The Explain UI's App wiring, checked in the sources (the test target doesn't link the app): it
/// ships behind one flag (flipped by the phase-3 integration); tickets are minted only at gestures, in the planned
/// files; the panel and overlay are non-activating, key, on every Space; the shortcut goes through
/// Carbon with a nonisolated trampoline; nothing asks for Screen Recording or captures the screen
/// directly; the renders never send; every string has distinct en / zh text; the drop routing
/// changes nothing while Explain is hidden; the reader hands its exact anchor over.
@Suite("Explain UI: App sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct ExplainUISourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let explain = "Sources/PaperDeck/Explain"
    static let core = "Sources/PaperDeckCore/ExplainUI"
    /// The lane's App files outside `Explain/` (the capture lane's `Explain/Capture/` is not checked here).
    static let files = ["Sources/PaperDeck/Views/Detail/ExplanationsSection.swift", "Sources/PaperDeck/Views/Settings/AssistSettingsTab.swift",
                        "Sources/PaperDeck/App/L10n+explain.swift", "Sources/PaperDeck/App/L10n+assist.swift",
                        "Sources/PaperDeck/Drop/DropIntake.swift", "Sources/PaperDeck/CLI/ExplainRenders.swift"]
    static var mine: [String] {
        LintRepo.swiftFiles(under: explain).filter { !$0.hasPrefix(explain + "/Capture/") } + files
            + LintRepo.swiftFiles(under: "Sources/PaperDeck/Reader")
    }

    /// The lines of one file or every Swift file under a folder that match `pattern`.
    static func grep(_ pattern: String, in path: String) throws -> [LintRepo.Hit] {
        guard path.hasSuffix(".swift") else { return try LintRepo.grep(pattern, under: path) }
        let regex = try NSRegularExpression(pattern: pattern)
        return try text(path).components(separatedBy: "\n").enumerated().compactMap { i, line in
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil ? nil : LintRepo.Hit(path: path, line: i + 1, text: line)
        }
    }

    /// Phase 3 flipped it (R-UI-6): Explain ships; everything it installs still goes through the flag.
    @Test func explainShipsAndEveryPieceFollowsTheFlag() throws {
        let c = try Self.text("\(Self.explain)/ExplainCoordinator.swift")
        #expect(c.contains("static let isAvailable = true"))
        let boot = try Self.text("\(Self.explain)/ExplainBootstrap.swift")
        for fn in ["static func installServices() {", "static func install(_ state: AppState) {"] {
            let start = try #require(boot.range(of: fn))
            #expect(String(boot[start.upperBound...].prefix(120)).contains("guard ExplainCoordinator.isAvailable"), "\(fn)")
        }
        // The hidden pieces show only when Explain ships (or in the renders).
        #expect(try Self.text("\(Self.explain)/ExplainSettingsSection.swift")
            .contains("static var shown: Bool { ExplainCoordinator.isAvailable || previewOverride }"))
        #expect(try Self.text("Sources/PaperDeck/Views/Detail/ExplanationsSection.swift")
            .contains("private var shown: Bool { ExplainCoordinator.isAvailable || Self.previewOverride }"))
        let overrides = try LintRepo.grep(#"(previewOverride|previewScreenRecording|previewStatus)\s*=\s*"#, under: "Sources")
            .filter { !$0.text.contains("static var") }
        #expect(overrides.allSatisfy { $0.path == "Sources/PaperDeck/CLI/ExplainRenders.swift" || $0.path.hasPrefix("Sources/PaperDeck/CLI/") },
                "\(overrides)")
        #expect(overrides.contains { $0.path == "Sources/PaperDeck/CLI/ExplainRenders.swift" })
    }

    @Test func ticketsAreMintedOnlyAtGestures() throws {
        let pattern = #"\bmint\b|ConsentTicket\s*\.\s*mint"#
        let allowed: [String: Set<String>] = [
            "\(Self.explain)/ExplainPanelView.swift": [".action", ".followUp", ".ask", ".retry", ".capOverride"],
            "\(Self.explain)/CaptureOverlayController.swift": [".clipboard", ".lens", ".box"],
            "\(Self.explain)/ExplainServiceProvider.swift": [".service"],
            "Sources/PaperDeck/Drop/DropIntake.swift": [".drop"],
            "Sources/PaperDeck/Reader/SelectionToolbar.swift": [".reader"],
        ]
        var hits: [LintRepo.Hit] = []
        for path in Self.mine { hits += try Self.grep(pattern, in: path) }
        hits += try LintRepo.grep(pattern, under: Self.core)
        for h in hits {
            // Doc comments may name the gestures; only calls count.
            guard h.text.contains("ConsentTicket.mint(") else {
                #expect(h.text.trimmingCharacters(in: .whitespaces).hasPrefix("//"), "\(h)")
                continue
            }
            let gestures = try #require(allowed[h.path], "a ticket minted outside the gesture files: \(h)")
            #expect(gestures.contains { h.text.contains("mint(\($0)") } || h.text.contains("mint(state.turns.isEmpty ? .ask : .followUp")
                        || h.text.contains("mint(lens ? .lens : .box"), "\(h)")
            #expect(h.text.contains("surface: .explain"), "\(h)")
        }
        #expect(hits.contains { $0.path.hasSuffix("CaptureOverlayController.swift") })
        #expect(hits.contains { $0.path.hasSuffix("ExplainPanelView.swift") && $0.text.contains(".capOverride") })
        // Core never mints; the coordinator, the pipeline, the history and the renders don't either.
        #expect(try LintRepo.grep(pattern, under: Self.core).isEmpty)
        for f in ["ExplainCoordinator", "ExplainBootstrap", "ExplainPipeline", "ExplainHistoryView", "ExplainSettingsSection",
                  "ExplainPanelController", "HotKeyCenter", "ScreenPermission"] {
            #expect(try Self.grep(#"ConsentTicket\.mint\("#, in: "\(Self.explain)/\(f).swift").isEmpty, "\(f)")
        }
        #expect(try Self.grep(#"ConsentTicket\.mint\("#, in: "Sources/PaperDeck/CLI/ExplainRenders.swift").isEmpty)
    }

    @Test func thePanelIsNonActivatingKeyAndOnEverySpace() throws {
        let p = try Self.text("\(Self.explain)/ExplainPanelController.swift")
        for needle in ["styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]",
                       "override var canBecomeKey: Bool { true }", "override var canBecomeMain: Bool { false }",
                       "p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]",
                       "p.level = .floating", "p.hidesOnDeactivate = false", "override func cancelOperation(_ sender: Any?) { onCancel?() }",
                       "panel.orderFrontRegardless()", "panel.makeKey()", "PanelPlacement.frame(size: size, anchor: anchor, visibleFrame: vf)"] {
            #expect(p.contains(needle), "\(needle)")
        }
        #expect(!p.contains("NSApp.activate"), "the PDF app stays frontmost")
        let o = try Self.text("\(Self.explain)/CaptureOverlayController.swift")
        for needle in ["styleMask: [.borderless, .nonactivatingPanel]", "p.level = .screenSaver",
                       "p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]",
                       "override var canBecomeKey: Bool { true }"] {
            #expect(o.contains(needle), "\(needle)")
        }
        #expect(!o.contains("NSApp.activate"))
        // The view closes on Esc and words the ~30 Hz stream from the Core buffer.
        let v = try Self.text("\(Self.explain)/ExplainPanelView.swift")
        #expect(v.contains(".onExitCommand { actions.close() }"))
        let state = try Self.text("\(Self.core)/ExplainPanelState.swift")
        #expect(state.contains("try? await Task.sleep(for: ExplainTextBuffer.flushInterval)"))
    }

    @Test func theShortcutGoesThroughCarbonWithANonisolatedTrampoline() throws {
        let h = try Self.text("\(Self.explain)/HotKeyCenter.swift")
        #expect(h.contains("nonisolated private func explainHotKeyTrampoline("))
        #expect(h.contains("MainActor.assumeIsolated { CarbonHotKeyCenter.shared.fire(id) }"))
        #expect(h.contains("if let problem = HotKeySpec.validate(key) { return .invalid(problem) }"))
        #expect(h.contains("status == OSStatus(eventHotKeyExistsErr) ? .inUse : .failed(status)"))
        for api in ["RegisterEventHotKey", "InstallEventHandler", "UnregisterEventHotKey"] {
            let hits = try LintRepo.grep(api, under: "Sources").filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(hits.allSatisfy { $0.path == "\(Self.explain)/HotKeyCenter.swift" }, "\(api): \(hits)")
        }
        // Registered only by the coordinator (installed only when Explain ships).
        let registers = try LintRepo.grep(#"\.register\(settings\.explainHotKey"#, under: "Sources")
        #expect(registers.map(\.path) == ["\(Self.explain)/ExplainCoordinator.swift"])
        // The recorder listens in our own window only (a local monitor: no permission).
        let rec = try Self.text("\(Self.explain)/HotKeyRecorderView.swift")
        #expect(rec.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)") && !rec.contains("addGlobalMonitorForEvents"))
    }

    @Test func nothingAsksForScreenRecordingOrCapturesDirectly() throws {
        let forbidden = #"CGRequestScreenCaptureAccess|CGPreflightScreenCaptureAccess|SCShareableContent|SCScreenshotManager|SCStream|CGWindowListCreateImage|CGDisplayCreateImage"#
        let permission = "\(Self.explain)/ScreenPermission.swift"
        var hits: [LintRepo.Hit] = []
        for path in Self.mine where path != permission { hits += try Self.grep(forbidden, in: path) }
        hits += try LintRepo.grep(forbidden, under: Self.core)
        #expect(hits.isEmpty, "\(hits)")
        // ScreenPermission holds exactly the two system calls (the capture lane's members), and no
        // Explain UI file calls them: the UI goes through the injected capturer.
        let system = try Self.grep(forbidden, in: permission).filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
        #expect(system.map { $0.text.trimmingCharacters(in: .whitespaces) } == [
            "static var isGranted: Bool { CGPreflightScreenCaptureAccess() }",
            "static func request() -> Bool { CGRequestScreenCaptureAccess() }",
        ], "\(system)")
        var direct: [LintRepo.Hit] = []
        for path in Self.mine where path != permission { direct += try Self.grep(#"ScreenPermission\.(isGranted|request\(\))"#, in: path) }
        #expect(direct.isEmpty, "\(direct)")
        // The status and the request go through the injected capturer, from a click only.
        let perm = try Self.text("\(Self.explain)/ScreenPermission.swift")
        #expect(perm.contains("let granted = await capturer.request()"))
        let settings = try Self.text("\(Self.explain)/ExplainSettingsSection.swift")
        #expect(settings.contains("Self.previewScreenRecording ?? ExplainBootstrap.coordinator?.capturer.preflight()"))
        // No Explain file starts a process or talks to a backend; the lane is reached only through Core.
        var lane: [LintRepo.Hit] = []
        for path in Self.mine {
            lane += try Self.grep(#"StreamingProcess|\bAssistBackend\b|\.assist\.submit|Process\(\)|posix_spawn"#, in: path)
        }
        #expect(lane.isEmpty, "\(lane)")
        let services = try Self.text("\(Self.core)/ExplainEngineServices.swift")
        #expect(services.contains("await engine.assist.submit(request, ticket: ticket)"))
        #expect(try LintRepo.grep(#"queue:\s*nil"#, under: Self.explain).isEmpty, "callback APIs on the main queue only")
    }

    @Test func theRendersNeverSend() throws {
        let r = try Self.text("Sources/PaperDeck/CLI/ExplainRenders.swift")
        #expect(r.contains("assistBackends: [MockAssistBackend()]") && r.contains("initial.assist.mode = .mock"))
        #expect(r.contains("claude: MockAgentProvider(behavior: .notLoggedIn)") && r.contains("codex: MockAgentProvider(behavior: .notLoggedIn)"))
        for call in [".run(", ".perform(", ".retry(", ".confirm(", ".askFollowUp(", "registerHotKey", "installServices",
                     "ExplainBootstrap.install", "servicesProvider", ".preflight()", ".request()", ".freeze("] {
            #expect(!r.contains(call), "\(call)")
        }
        #expect(r.contains("ExplainSettingsSection.previewScreenRecording = false"))
    }

    @Test func everyStringHasDistinctEnglishAndChinese() throws {
        for file in ["Sources/PaperDeck/App/L10n+explain.swift", "Sources/PaperDeck/App/L10n+assist.swift"] {
            let source = try Self.text(file)
            let pairs = ReaderSourceLintTests.pairs(source)
            #expect(pairs.count >= (file.hasSuffix("explain.swift") ? 150 : 4), "\(file): \(pairs.count) pairs")
            for p in pairs {
                #expect(!p.zh.isEmpty && !p.en.isEmpty, "\(p)")
                #expect(p.zh != p.en, "en = zh: \(p.en)")
                #expect(p.zh.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) },
                        "no Chinese in the zh string: \(p.zh)")
                // (The EN | 中 toggle's own label may be named in English help.)
                #expect(!p.en.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) && $0 != "中" },
                        "Chinese in the en string: \(p.en)")
            }
            let accessors = source.components(separatedBy: "\n").filter { $0.contains("static var ") || $0.contains("static func ") }
                .filter { !$0.contains("private static var zh") && !$0.contains("static var all: [String]") }
            for line in accessors where !line.contains("zh ?") {
                let start = try #require(source.range(of: line))
                let body = source[start.upperBound...].prefix(700)
                #expect(body.contains("zh ?"), "\(file): \(line)")
            }
            #expect(source.range(of: InstitutionLintTests.pattern, options: [.regularExpression, .caseInsensitive]) == nil)
        }
    }

    @Test func dropsChangeNothingWhileExplainIsHidden() throws {
        let d = try Self.text("Sources/PaperDeck/Drop/DropIntake.swift")
        #expect(d.contains("+ (AssistRollout.explain ? imageDataTypes : [])"))
        let guardLine = try #require(d.range(of: "static func isExplainImageDrag(_ pb: NSPasteboard) -> Bool {"))
        #expect(String(d[guardLine.upperBound...].prefix(120)).contains("guard AssistRollout.explain else { return false }"))
        #expect(d.contains("var isAcceptable: Bool { importable > 0 || explainImages }"))
        #expect(d.contains("s.explainImages = isExplainImageDrag(pb)"))
        // The import path itself is untouched: PDFs and folders are still what `collect` takes.
        #expect(d.contains("if isFolder(url) || isPDF(url) { items.append(.file(url)) } else { ignored.append(url.lastPathComponent) }"))
        // A received promise copy is removed after reading (nothing kept).
        #expect(d.contains("try? FileManager.default.removeItem(at: dir)"))
    }

    @Test func theSettingsTabKeepsItsTwoLinesAndPlacesExplainBesideAsk() throws {
        let tab = try Self.text("Sources/PaperDeck/Views/Settings/AssistSettingsTab.swift")
        #expect(tab.contains("        Form {\n            AssistSwitchSection(state: state)\n            QASettingsSection(state: state)\n        }"))
        #expect(tab.contains("if ExplainSettingsSection.shown { ExplainSettingsSection(state: state) }"))
        let section = try Self.text("\(Self.explain)/ExplainSettingsSection.swift")
        for key in ["explainDefaultMode", "explainLanguage", "explainDepth", "explainAskBeforeSend", "explainHistoryDays",
                    "dailySoftCap", "keepWarmSeconds = $0 ? 180 : 0", "HotKeyRecorderView(state: state)",
                    "ScreenPermission.openSystemSettings()"] {
            #expect(section.contains(key), "\(key)")
        }
        #expect(!section.contains("assist.mode") && !section.contains(".mode ="), "the shared switch stays the only on / off")
    }

    @Test func theReaderHandsItsExactAnchorToTheCoordinator() throws {
        let t = try Self.text("Sources/PaperDeck/Reader/SelectionToolbar.swift")
        #expect(t.contains("coordinator.begin(capture: capture(anchor, image: image), ticket: ticket, anchor: anchor, kind: action.kind,"))
        #expect(t.contains("image: isRegion ? model.regionImage() : nil"))
        #expect(t.contains("case .terms: .defineTerms") && t.contains("case .translate: .translate"))
        #expect(!t.contains("private(set) static var last"), "the A2 shim is gone")
        let m = try Self.text("Sources/PaperDeck/Reader/ReaderModel.swift")
        #expect(m.contains("return ReaderPDF.renderRegion(r.rect, of: page)"), "the box is drawn from the PDF (2–3×, /Rotate)")
        #expect(m.contains("func show(anchor: ReaderAnchor) {"))
        let router = try Self.text("Sources/PaperDeck/Reader/ReaderRouter.swift")
        #expect(router.contains("ReaderWindowController.show(state: state, row: row, anchor: anchor)"))
        // History opens the reader at the stored anchor.
        let history = try Self.text("\(Self.explain)/ExplainHistoryView.swift")
        #expect(history.contains("if let exact = await app.engine.explanationReaderAnchor(id: first.id) {"))
        #expect(history.contains("let back = try? await app.engine.explanationAnchor(id: first.id)"))
        let open = try Self.text("\(Self.explain)/ExplainPanelView.swift")
        #expect(open.contains("ReaderRouter(state: app).openReader(row, anchor: anchor)"))
    }

    @Test func servicesQueueUntilTheLibraryIsOpen() throws {
        let s = try Self.text("\(Self.explain)/ExplainServiceProvider.swift")
        for sel in ["@objc func explainText(", "@objc func askText(", "@objc func explainSelection(", "@objc func translateSelection("] {
            #expect(s.contains(sel), "\(sel)")
        }
        #expect(s.contains("guard let coordinator else {\n            pending.append(r)"))
        // "Ask PaperDeck…" opens the panel and sends nothing.
        let ask = try #require(s.range(of: "@objc func askText("))
        #expect(!String(s[ask.upperBound...].prefix(400)).contains("mint"))
        #expect(s.contains("case .ask(let capture):\n            coordinator.openForQuestion(capture: capture)"))
    }
}
