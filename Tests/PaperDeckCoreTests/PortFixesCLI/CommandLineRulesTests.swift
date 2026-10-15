import Foundation
import Testing
@testable import PaperDeckConfig

/// portability-cli-9 / portability-cli-2: the app binary's command-line decisions
/// (`CommandLineRules`, pure). A mistyped `--option` is an error (exit 2), never the GUI on the real
/// library; single-dash AppKit arguments still reach AppKit; `--gui-root` needs a folder and, while
/// another PaperDeck holds the single-instance lock, refuses instead of bringing that copy forward;
/// an unknown `--selftest` mode and an unparsable `--now` are refused before anything runs.
@Suite("Command-line rules")
struct CommandLineRulesTests {
    static let commands: Set<String> = ["--version", "--help", "-h", "--selftest", "--doctor", "--mail-dry-run",
                                        "--plan-reminders", "--migrate-dry-run", "--export-settings"]
    static func launch(_ args: String...) -> CommandLineRules.Launch {
        CommandLineRules.launch(["/Applications/PaperDeck.app/Contents/MacOS/PaperDeck"] + args, commands: commands)
    }

    @Test func theGUIStillOpensForNoArgumentsAndAppKitArguments() {
        #expect(Self.launch() == .gui)
        #expect(Self.launch("-NSDocumentRevisionsDebugMode", "YES") == .gui)
        #expect(Self.launch("-AppleLanguages", "(en)") == .gui)
        #expect(Self.launch("-psn_0_12345") == .gui)
        #expect(Self.launch("--gui-root", "/tmp/pd-scratch") == .gui)
        #expect(Self.launch("--gui-root", "~/pd-test", "-AppleLanguages", "(zh)") == .gui)
    }

    @Test func commandsAreCommands() {
        #expect(Self.launch("--doctor") == .command("--doctor"))
        #expect(Self.launch("--doctor", "--mail-only") == .command("--doctor"))
        #expect(Self.launch("-h") == .command("-h"))
        #expect(Self.launch("--plan-reminders", "--root", "/tmp/x", "--now", "2026-09-29T10:00:00") == .command("--plan-reminders"))
        #expect(Self.launch("--mail-dry-run", "m.eml", "--now", "2026-09-29T10:00:00Z") == .command("--mail-dry-run"))
        #expect(Self.launch("--mail-dry-run", "m.eml", "--now", "2026-09-29T10:00:00+02:00") == .command("--mail-dry-run"))
    }

    @Test func aMistypedOptionIsRefusedNotTheGUI() {
        for typo in ["--doctr", "--export-setting", "--gui-rot", "--selftests", "--", "--Doctor"] {
            guard case .refuse(let message) = Self.launch(typo, "/tmp/scratch") else {
                Issue.record("\(typo) must be refused"); continue
            }
            #expect(message == "unknown option \(typo) (see --help)")
        }
    }

    @Test func guiRootNeedsAFolder() {
        for args in [["--gui-root"], ["--gui-root", ""], ["--gui-root", "--doctor"], ["--gui-root", "-NSFoo"]] {
            guard case .refuse(let message) = CommandLineRules.launch(["PaperDeck"] + args, commands: Self.commands) else {
                Issue.record("\(args) must be refused"); continue
            }
            #expect(message.contains("--gui-root needs a folder"))
        }
    }

    @Test func anUnparsableNowIsAnError() {
        guard case .refuse(let bad) = Self.launch("--plan-reminders", "--root", "/tmp/x", "--now", "tomorrow") else {
            Issue.record("an unparsable --now must be refused"); return
        }
        #expect(bad.contains("--now 'tomorrow' is not a date"))
        guard case .refuse(let missing) = Self.launch("--migrate-dry-run", "--now", "--json") else {
            Issue.record("--now without a value must be refused"); return
        }
        #expect(missing.contains("--now needs a date"))
        guard case .refuse = Self.launch("--mail-dry-run", "m.eml", "--now") else {
            Issue.record("a trailing --now must be refused"); return
        }
        #expect(CommandLineRules.dateProblem(["--doctor"], flag: "--now") == nil)
    }

    @Test func datesParseAsBefore() throws {
        let zoned = try #require(CommandLineRules.date("2026-09-29T10:00:00Z"))
        #expect(zoned.timeIntervalSince1970 == 1_790_676_000)
        let local = try #require(CommandLineRules.date("2026-09-29T10:00:00"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        #expect(c.year == 2026 && c.month == 9 && c.day == 29 && c.hour == 10 && c.minute == 0)
        for bad in ["", "tomorrow", "2026-09-29", "29/09/2026 10:00"] { #expect(CommandLineRules.date(bad) == nil, "\(bad)") }
    }

    @Test func selftestModesAreCheckedFirst() {
        #expect(CommandLineRules.selftestProblem(nil) == nil)                       // all
        for mode in CommandLineRules.selftestPureModes + CommandLineRules.selftestEngineModes {
            #expect(CommandLineRules.selftestProblem(mode) == nil, "\(mode)")
        }
        let problem = CommandLineRules.selftestProblem("imprt")
        #expect(problem?.hasPrefix("unknown selftest 'imprt' (") == true)
        #expect(problem?.contains("import|schedule|agent|storage|all|mail") == true)
    }

    @Test func aHeldLockRefusesGuiRootButHandsOffANormalLaunch() {
        #expect(CommandLineRules.whenLockHeld(guiRoot: false) == .handOff)
        guard case .refuse(let message) = CommandLineRules.whenLockHeld(guiRoot: true) else {
            Issue.record("--gui-root must not hand off to the running copy"); return
        }
        #expect(message.hasPrefix("another PaperDeck is running; quit it first"))
        #expect(message.contains("--gui-root isolates the library only, not settings"))
    }
}
