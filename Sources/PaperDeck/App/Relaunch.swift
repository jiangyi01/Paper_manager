import AppKit
import PaperDeckCore

/// "Restart Now" (Settings ▸ Library ▸ Change…, the Library page, the mismatch alert): quits and
/// reopens this same app bundle.
@MainActor enum Relaunch {
    /// A detached `/bin/sh` waits until this process has exited (so the single-instance lock is
    /// free), then `open`s our own bundle path — nothing else. Then the app quits normally
    /// (`applicationShouldTerminate` flushes the engine). A bare binary (no .app) only quits.
    static func now() {
        if let command = command(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                Log.app.error("relaunch helper failed to start: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        NSApp.terminate(nil)
    }

    /// The helper's script (nil for anything but an `.app` bundle). The path is single-quoted, so
    /// no character in it is interpreted by the shell.
    static func command(pid: Int32, bundlePath: String) -> String? {
        guard bundlePath.hasSuffix(".app"), bundlePath.hasPrefix("/") else { return nil }
        let quoted = "'" + bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Give up after ~60 s (a hung quit must never leave a helper waiting forever).
        return "i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \(quoted)"
    }
}
