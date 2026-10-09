import Foundation
import Testing

/// Phase 3's switch-on (Lead), checked in the sources (the test target doesn't link the app):
/// Explain ships (R-UI-6) with the lanes' change requests placed — the render command (R-UI-1), image
/// drops (R-UI-2), the Services provider at launch and the shutdown (R-UI-3), the shortcut on the
/// menu item while it is registered (R-UI-5), stale reader anchors pruned (R-UI-7), the hotkey
/// following an import (R-UI-8) — and the rules the integration adds: the global shortcut is held
/// only while `assist.mode` is on, the frame / lens layer is installed and never captures or asks by
/// itself, and Settings ▸ Explain & Ask shows the switch, Explain and Ask.
@Suite("Phase 3 integration: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P3IntegrationLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    static func body(_ source: String, after marker: String, length: Int = 1_200) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker)")
        return String(source[start.upperBound...].prefix(length))
    }

    @Test func explainShipsAndTheSwitchStaysOffByDefault() throws {
        #expect(try Self.text("Sources/PaperDeck/Explain/ExplainCoordinator.swift").contains("static let isAvailable = true"))
        #expect(try Self.text("Sources/PaperDeck/App/AssistRollout.swift").contains("static var explain: Bool { ExplainCoordinator.isAvailable }"))
        #expect(try Self.text("Sources/PaperDeckCore/Engine/AssistSettings.swift").contains("package init(mode: AssistMode = .off,"))
        #expect(try Self.text("Sources/PaperDeckCore/Engine/AssistSettings.swift").contains("mode: raw(Keys.mode, AssistMode.off),"))
        // Settings ▸ Explain & Ask: the switch places Explain, then Ask; Explain has its Help.
        let tab = try Self.text("Sources/PaperDeck/Views/Settings/AssistSettingsTab.swift")
        #expect(tab.contains("if ExplainSettingsSection.shown { ExplainSettingsSection(state: state) }"))
        let section = try Self.text("Sources/PaperDeck/Explain/ExplainSettingsSection.swift")
        #expect(section.contains("static var shown: Bool { ExplainCoordinator.isAvailable || previewOverride }"))
        #expect(section.contains("HelpButton(.explain)") && section.contains("HelpButton(.screenRecording)"))
    }

    @Test func theRenderCommandIsReachable() throws {                                                   // R-UI-1
        let runner = try Self.text("Sources/PaperDeck/CLI/CLIRunner.swift")
        #expect(runner.contains("\"--ask-render\", \"--explain-render\","))
        #expect(runner.contains("case \"--explain-render\": return spin { await ExplainRenders.run(args) }"))
        #expect(runner.contains("--explain-render OUTDIR --root SCRATCH [--lang zh|en] [--appearance light|dark]"))
    }

    @Test func imageDropsGoToExplainFirst() throws {                                                    // R-UI-2
        let route = "if DropIntake.routeImageDropToExplain(sender.draggingPasteboard, incoming: incomingDirectory(), near: window?.frame) {"
        let host = try Self.body(try Self.text("Sources/PaperDeck/Drop/DropHostingView.swift"),
                                 after: "override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {\n", length: 400)
        let firstCode = host.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.hasPrefix("//") }
        #expect(firstCode == route, "\(host)")
        let status = try Self.body(try Self.text("Sources/PaperDeck/Drop/StatusDropView.swift"),
                                   after: "override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {\n", length: 400)
        let lines = status.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") }
        #expect(Array(lines.prefix(2)) == ["highlighted = false", route], "\(status)")
        // Only an all-image drag (and only while Explain ships) is taken; the drop mints its ticket there.
        let intake = try Self.text("Sources/PaperDeck/Drop/DropIntake.swift")
        #expect(intake.contains("guard isExplainImageDrag(pb), let coordinator = ExplainBootstrap.coordinator else { return false }"))
    }

    @Test func servicesAreProvidedFromLaunchAndEverythingStopsOnQuit() throws {                        // R-UI-3
        let d = try Self.text("Sources/PaperDeck/App/AppDelegate.swift")
        let launch = try Self.body(d, after: "        settings = SettingsStore()\n", length: 300)
        #expect(launch.contains("        ExplainBootstrap.installServices()\n"), "\(launch)")
        let quit = try Self.body(d, after: "func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {", length: 600)
        let shutdown = try #require(quit.range(of: "ExplainBootstrap.shutdown()"))
        let engine = try #require(quit.range(of: "await engine.shutdown()"))
        #expect(shutdown.lowerBound < engine.lowerBound)
        #expect(d.contains("ExplainBootstrap.install(state)"))
        // The provider answers the Info.plist's messages (AssistContractGrepTests checks the plist).
        let provider = try Self.text("Sources/PaperDeck/Explain/ExplainServiceProvider.swift")
        #expect(provider.contains("@objc func explainText(") && provider.contains("@objc func askText("))
    }

    @Test func theShortcutIsHeldOnlyWhileTheSwitchIsOn() throws {
        let c = try Self.text("Sources/PaperDeck/Explain/ExplainCoordinator.swift")
        let register = try Self.body(c, after: "    func registerHotKey() {\n", length: 400)
        #expect(register.hasPrefix("        guard settings.mode != .off else {\n            hotKeys.unregister()\n            hotKeyStatus = .switchedOff\n            return\n        }\n"),
                "\(register)")
        let boot = try Self.text("Sources/PaperDeck/Explain/ExplainBootstrap.swift")
        #expect(boot.contains("static func assistModeChanged() {\n        coordinator?.registerHotKey()\n    }"))
        // The switch's change and an import's new shortcut re-register (or release) it.
        let d = try Self.text("Sources/PaperDeck/App/AppDelegate.swift")
        let closers = try Self.body(d, after: "settings.onAssistModeChange = {", length: 300)
        #expect(closers.contains("Task { await engine.assist.closeAllSessions() }") && closers.contains("ExplainBootstrap.assistModeChanged()"))
        #expect(d.contains("settings.onExplainHotKeyChange = { ExplainBootstrap.shortcutChanged() }"))
        let store = try Self.text("Sources/PaperDeck/App/SettingsStore.swift")
        #expect(store.contains("if assist.explainHotKey != oldValue.explainHotKey { onExplainHotKeyChange?() }"))
        #expect(store.contains("set(assist, AssistSettings.load(from: d)) { assist = $0 }"), "an import reloads assist (and its shortcut)")
        // The recorder shows why it isn't active.
        let rec = try Self.text("Sources/PaperDeck/Explain/HotKeyRecorderView.swift")
        #expect(rec.contains("case .switchedOff?: return (L.Explain.shortcutNeedsSwitch, .secondary)"))
        // The menu item shows the shortcut only while it is registered (R-UI-5).
        let menus = try Self.text("Sources/PaperDeck/Windows/ReadingAssistMenus.swift")
        #expect(menus.contains("guard let state, ExplainBootstrap.coordinator?.hotKeyStatus == .registered else { return nil }"))
        #expect(menus.contains("explain.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: key.flags)"))
    }

    @Test func theFrameAndLensLayerIsInstalledAndNeverCapturesOnItsOwn() throws {
        let o = try Self.text("Sources/PaperDeck/Explain/CaptureOverlayController.swift")
        #expect(o.contains("static var captureLayer: ((LayerContext) -> AnyView)? = { ctx in"))
        #expect(o.contains("AnyView(CaptureLayerView(layer: ctx.layer, overlay: ctx.controller.model, controller: ctx.controller))"))
        // One still, through the flow that never asks; a refusal shows the zero-permission card.
        #expect(o.contains("let result = await CaptureFlow.freeze(capturer, excluding: exclude)"))
        #expect(o.contains("case .failure(.permissionDenied):\n                self.model.captureAllowed = false"))
        #expect(o.components(separatedBy: ".freeze(").count == 2, "the overlay freezes in one place")
        // The gesture's ticket is created in the controller at the release, never in the layer.
        #expect(o.contains("let ticket = ConsentTicket.mint(lens ? .lens : .box, surface: .explain)"))
        let layer = try Self.text("Sources/PaperDeck/Explain/CaptureLayerView.swift")
        for forbidden in ["ConsentTicket", "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess", "SCShareableContent",
                          "SCScreenshotManager", "CGWindowListCreateImage", ".freeze(", "begin(capture"] {
            #expect(!layer.contains(forbidden), "\(forbidden)")
        }
        #expect(layer.range(of: #"\bmint\b"#, options: .regularExpression) == nil)
        // The mouse works while PaperDeck isn't the active app; a right click cancels.
        #expect(layer.contains("options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect,"))
        #expect(layer.contains("override func rightMouseDown(with event: NSEvent) { controller?.dismiss() }"))
        #expect(layer.contains("controller?.released(outcome, on: layer.displayID)"))
        // The window under the capture names its app (privacy) and title (locating), never sent raw.
        #expect(o.contains("let window = WindowTitleReader.window(at: point)"))
        #expect(o.contains("hostBundleID: window?.bundleID ?? front,"))
        // A click explains only what is under it.
        let pipeline = try Self.text("Sources/PaperDeck/Explain/ExplainPipeline.swift")
        #expect(pipeline.contains("ExplainFocusResolver.read(focus, imageSize: size)"))
    }

    @Test func staleReaderAnchorsArePrunedDaily() throws {                                              // R-UI-7
        let m = try Self.text("Sources/PaperDeckCore/Library/Maintenance.swift")
        let prune = try #require(m.range(of: "report.prunedExplanations = try await engine.pruneExplanationsByRetention()"))
        let anchors = try #require(m.range(of: "report.prunedReaderAnchors = await engine.pruneExplanationReaderAnchors()"))
        #expect(prune.upperBound <= anchors.lowerBound)
    }

    @Test func theServicesTitlesAreTheOnesTheTextsName() throws {
        // The Services menu shows Info.plist's titles (not localized): the zh texts name them as they appear.
        let plist = try Self.text("Resources/Info.plist")
        for title in ["Explain with PaperDeck", "Ask PaperDeck…"] { #expect(plist.contains("<string>\(title)</string>")) }
        let strings = try Self.text("Sources/PaperDeck/App/L10n+explain.swift")
        #expect(strings.contains("「Explain with PaperDeck」") && !strings.contains("用 PaperDeck 讲解"))
        let guide = try Self.text("Sources/PaperDeckConfig/Guide/Content/GuideContent+Tutorials.swift")
        #expect(guide.contains("「Explain with PaperDeck」") && guide.contains("「Ask PaperDeck…」"))
    }
}
