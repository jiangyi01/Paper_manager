import Foundation
import Testing
@testable import PaperDeckConfig

/// The app-target wirings of the CLI / build-identity / onboarding fixes (the test target doesn't
/// link the app, so these read its sources; `--selftest onboarding` checks the behaviour too).
/// Read-only over the repository (`LintRepo`).
@Suite("CLI, identity and onboarding wirings", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct CLIWiringLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    /// The body of the first `func <name>(` in `source` (balanced braces), or nil. `marker`
    /// overrides the text to look for (a protocol requirement of the same name comes first).
    static func functionBody(_ source: String, _ name: String, marker: String? = nil) -> String? {
        guard let start = source.range(of: marker ?? "func \(name)("),
              let open = source.range(of: "{", range: start.lowerBound..<source.endIndex) else { return nil }
        var depth = 0
        var i = open.lowerBound
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 } else if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<i]) }
            }
            i = source.index(after: i)
        }
        return nil
    }

    // MARK: portability-cli-1

    /// `--doctor` / `--doctor --mail-only` (and the mail dry run) never migrate a database: the
    /// read-only inspection open at every call site, no `Database.open(` left.
    @Test func diagnosticsOpenTheDatabaseReadOnly() throws {
        let doctor = try Self.text("Sources/PaperDeck/CLI/Doctor.swift")
        #expect(!doctor.contains("Database.open("), "Doctor must not use the migrating open")
        #expect(doctor.components(separatedBy: "Database.openForInspection(url: paths.database)").count == 3,
                "both Doctor call sites (full doctor and mail) use the inspection open")
        let mail = try #require(Self.functionBody(doctor, "mail"))
        #expect(mail.contains("found.level < 2") && mail.contains("needs upgrade"), "an old schema degrades, no mail-table read")
        let mailCLI = try Self.text("Sources/PaperDeck/CLI/MailCLI.swift")
        #expect(!mailCLI.contains("Database.open("))
    }

    // MARK: portability-cli-9

    @Test func theRunnerRefusesUnknownOptionsBeforeTheGUI() throws {
        let runner = try Self.text("Sources/PaperDeck/CLI/CLIRunner.swift")
        let body = try #require(Self.functionBody(runner, "runIfRequested"))
        let gate = try #require(body.range(of: "CommandLineRules.launch(argv, commands: commands)"))
        let parse = try #require(body.range(of: "CLIArgs(argv)"))
        #expect(gate.lowerBound < parse.lowerBound)
        #expect(body.contains("case .refuse(let message): return fail(message)"))
        #expect(runner.contains("value(key).flatMap(CommandLineRules.date)"), "CLIArgs.date parses like the gate")
    }

    @Test func anUnknownSelftestModeIsRefusedBeforeAnEngineOpens() throws {
        let selftest = try Self.text("Sources/PaperDeck/CLI/SelfTest.swift")
        let body = try #require(Self.functionBody(selftest, "run"))
        let check = try #require(body.range(of: "CommandLineRules.selftestProblem(args.positional)"))
        let open = try #require(body.range(of: "openEngine("))
        #expect(check.lowerBound < open.lowerBound)
        // Every mode the dispatcher knows is in the rules' lists (and nothing else is).
        let regex = try NSRegularExpression(pattern: #"(?:args\.positional == |mode == |case )"([a-z-]+)""#)
        let ns = body as NSString
        let used = Set(regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        let known = Set(CommandLineRules.selftestPureModes + CommandLineRules.selftestEngineModes)
        #expect(used == known, "dispatcher \(used.sorted()) vs rules \(known.sorted())")
    }

    // MARK: portability-cli-2 (extra 1)

    @Test func guiRootRefusesWhileTheLockIsHeld() throws {
        let delegate = try Self.text("Sources/PaperDeck/App/AppDelegate.swift")
        let body = try #require(Self.functionBody(delegate, "applicationWillFinishLaunching"))
        #expect(body.contains("CommandLineRules.whenLockHeld(guiRoot: rootOverride != nil)"))
        let refuse = try #require(body.range(of: "case .refuse(let message):"))
        let after = body[refuse.upperBound...].prefix(300)
        #expect(after.contains("FileHandle.standardError.write") && after.contains("exit(1)"))
        #expect(!after.contains("DeepLink.today"), "--gui-root never brings the running copy forward")
    }

    // MARK: portability-cli-10 (and the --gui-root help line)

    @Test func theUsageListsEveryImplementedFlag() throws {
        let runner = try Self.text("Sources/PaperDeck/CLI/CLIRunner.swift")
        for flag in ["[--library-only [--widths \"720, 900, 1280\"] [--no-mail-demo]]", "[--mail-widths \"720, 900, 1280\" [--mail-widths-only]]",
                     "[--provider-state ready]", "[--default-settings] [--defaults-suite NAME] [--now ISO]",
                     "PaperDeck --gui-root DIR", "settings (the defaults domain) and the single-instance lock"] {
            #expect(runner.contains(flag), "usage lacks \(flag)")
        }
        let guide = try Self.text("docs/USER_GUIDE.md")
        #expect(guide.contains("--library-only") && guide.contains("--default-settings") && guide.contains("--gui-root DIR"))
    }

    // MARK: portability-cli-5

    @Test func aProviderCardNeverSwitchesReading() throws {
        let model = try Self.text("Sources/PaperDeck/Views/Onboarding/OnboardingModel.swift")
        let select = try #require(Self.functionBody(model, "selectAI"))
        #expect(!select.contains("selectProvider") && !select.contains("setAIReading(true)"),
                "a card click must not change the provider or turn reading on")
        #expect(select.contains("state?.setAIReading(false)"), "'Not now' still turns reading off (live / revisit)")
        let turnOn = try #require(Self.functionBody(model, "turnOnAI"))
        #expect(turnOn.contains("state?.selectProvider(k)") && turnOn.contains("state?.setAIReading(true)"))
        let pages = try Self.text("Sources/PaperDeck/Views/Onboarding/OnboardingPages.swift")
        #expect(pages.contains("Button(L.Onb.switchReading(to: k)) { model.turnOnAI() }"))
        let onboardingTest = try Self.text("Sources/PaperDeck/CLI/SelfTestOnboarding.swift")
        #expect(onboardingTest.contains("live: with reading on, a provider card never switches the running provider"))
    }

    // MARK: portability-cli-7

    @Test func theAppLocationFactParsesTheQuarantineFlags() throws {
        let sources = try Self.text("Sources/PaperDeck/Views/Help/FactSources.swift")
        let body = try #require(Self.functionBody(sources, "appLocation", marker: "func appLocation() async -> AppLocationFact {"))
        #expect(body.contains("AppLocationFact.isQuarantined(attribute: Self.quarantineAttribute(path))"))
        #expect(!body.contains("getxattr(path, \"com.apple.quarantine\", nil, 0, 0, 0) >= 0"), "presence alone isn't quarantine")
    }

    // MARK: portability-cli-8

    @Test func theBuildStampsTheWidgetID() throws {
        let script = try Self.text("build_app.sh")
        #expect(script.contains("plutil -replace PDWidgetBundleIdentifier -string \"$WIDGET_ID\" \"$PL\""))
        #expect(script.contains("plutil -replace PDWidgetBundleIdentifier -string \"$WIDGET_ID\" \"$WPL\""))
        let check = try Self.text("tools/check_build_config.sh")
        #expect(check.contains("stamp PDWidgetBundleIdentifier \"$PL\""))
    }
}

/// portability-cli-2: BUILDING.md no longer promises a separate copy for another bundle id.
@Suite("Docs: one library for every bundle id", .enabled(if: LintRepo.hasSources, "the docs aren't next to the tests"))
struct BundleIDDocsTests {
    @Test func buildingSaysEveryBundleIDSharesOneLibrary() throws {
        let doc = try String(contentsOf: LintRepo.url("docs/BUILDING.md"), encoding: .utf8)
        let flat = doc.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        #expect(!flat.contains("Keep the default unless you need a second, separate copy"))
        for needle in ["**It does not make a separate copy.**", "single-instance lock", "two copies can't run at the same time",
                       "`--gui-root` isolates the library only, not settings", "`paperdeck:` URL scheme"] {
            #expect(flat.contains(needle), "BUILDING.md lacks \(needle)")
        }
        let env = try String(contentsOf: LintRepo.url("build.local.env.example"), encoding: .utf8)
        #expect(env.contains("It is not a\n# separate copy"))
    }
}
