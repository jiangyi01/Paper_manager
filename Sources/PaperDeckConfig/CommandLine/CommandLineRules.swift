import Foundation

/// The app binary's command-line decisions that need no AppKit (pure). `CLIRunner`, `SelfTest` and
/// `AppDelegate` call them; the unit tests check them (the test target doesn't link the app).
package enum CommandLineRules {
    /// What the arguments ask for.
    package enum Launch: Equatable, Sendable {
        /// The normal GUI: no argument, a single-dash AppKit / LaunchServices argument
        /// (`-NSDocumentRevisionsDebugMode YES`, `-AppleLanguages (en)`, `-psn_…`), an argument that
        /// isn't an option, or `--gui-root DIR`.
        case gui
        /// A headless command (one of `CLIRunner.commands`).
        case command(String)
        /// A command-line mistake: print `error: <message>` and exit 2. A mistyped option never
        /// falls through to the GUI on the real library.
        case refuse(String)
    }

    /// `--gui-root DIR`: the GUI on an isolated library (development and testing).
    package static let guiRoot = "--gui-root"

    /// `argv` as the process got it (`argv[0]` is the executable). Only the first argument decides:
    /// a command, `--gui-root DIR`, or any other `--…` (refused). A present `--now` must parse.
    package static func launch(_ argv: [String], commands: Set<String>) -> Launch {
        let args = Array(argv.dropFirst())
        guard let first = args.first else { return .gui }
        if commands.contains(first) {
            if let problem = dateProblem(args, flag: "--now") { return .refuse(problem) }
            return .command(first)
        }
        if first == guiRoot {
            guard args.count > 1, !args[1].isEmpty, !args[1].hasPrefix("-") else {
                return .refuse("\(guiRoot) needs a folder: \(guiRoot) DIR (see --help)")
            }
            return .gui
        }
        if first.hasPrefix("--") { return .refuse("unknown option \(first) (see --help)") }
        return .gui
    }

    // MARK: Dates

    /// `2026-09-29T10:00:00Z` / `2026-09-29T10:00:00+02:00` (ISO 8601 with a zone), or local time
    /// without a zone (`2026-09-29T10:00:00`); nil otherwise.
    package static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        let lf = DateFormatter()
        lf.locale = Locale(identifier: "en_US_POSIX")
        lf.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return lf.date(from: s)
    }

    /// Why `flag` (present in `args`) isn't a date; nil when it is absent or parses. `CLIArgs` reads
    /// a flag's value as the next argument unless that starts with `--`.
    package static func dateProblem(_ args: [String], flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            return "\(flag) needs a date, e.g. \(flag) 2026-09-29T10:00:00"
        }
        let value = args[i + 1]
        return date(value) == nil
            ? "\(flag) '\(value)' is not a date (use 2026-09-29T10:00:00, or ISO 8601 with a zone such as 2026-09-29T10:00:00Z)"
            : nil
    }

    // MARK: --selftest

    /// `--selftest MODE` modes that need no library (pure rules, scratch defaults).
    package static let selftestPureModes = ["mail-notify", "app-rules", "strings", "settings", "onboarding", "dedupe", "qa"]
    /// Modes that open an engine on `--root` (`all` when no mode is given).
    package static let selftestEngineModes = ["import", "schedule", "agent", "storage", "all", "mail"]

    /// Why `mode` is not a self-test (checked before any engine opens); nil for a known mode or none.
    package static func selftestProblem(_ mode: String?) -> String? {
        guard let mode, !selftestPureModes.contains(mode), !selftestEngineModes.contains(mode) else { return nil }
        return "unknown selftest '\(mode)' (\((selftestEngineModes + selftestPureModes).joined(separator: "|")))"
    }

    // MARK: Single instance

    /// What a launch does when another PaperDeck already holds the single-instance lock.
    package enum LockHeld: Equatable, Sendable {
        /// The normal launch: hand the running copy the "open" (`paperdeck://today`) and quit quietly.
        case handOff
        /// `--gui-root`: say why on stderr and exit non-zero — the running copy is someone's real
        /// library, and the isolated run can't start next to it.
        case refuse(String)
    }

    package static let guiRootLockedMessage = "another PaperDeck is running; quit it first — \(guiRoot) isolates the library only, not settings or the single-instance lock"

    package static func whenLockHeld(guiRoot: Bool) -> LockHeld {
        guiRoot ? .refuse(guiRootLockedMessage) : .handOff
    }
}
