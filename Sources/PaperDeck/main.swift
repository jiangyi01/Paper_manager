import AppKit
import PaperDeckCore

// A child that closes its stdin early (claude, pdftotext) must not kill us.
signal(SIGPIPE, SIG_IGN)

// Headless modes (--version, --selftest, --doctor, …) never touch the GUI.
if let code = CLIRunner.runIfRequested(CommandLine.arguments) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
