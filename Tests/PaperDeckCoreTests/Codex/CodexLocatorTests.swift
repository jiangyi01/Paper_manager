import Foundation
import Synchronization
import Testing
@testable import PaperDeckCore

/// A fake machine only — no real `codex` or login shell is ever run here.
@Suite struct CodexLocatorTests {
    private static let home = "/Users/tester"
    private static let good = "codex-cli 0.153.4\n"
    private static let chatGPTBundled = "/Applications/ChatGPT.app/Contents/Resources/codex"

    private final class CXMachine: Sendable {
        struct State {
            var executables: Set<String> = []
            var versions: [String: String] = [:]
            var loginShell: String?
            var versionCalls: [String] = []
            var lookups: [String] = []
        }
        let state: Mutex<State>
        init(_ s: State) { state = Mutex(s) }

        func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
        var versionCalls: [String] { state.withLock { $0.versionCalls } }
        var lookups: [String] { state.withLock { $0.lookups } }

        var probe: BinaryLocator.Probe {
            BinaryLocator.Probe(
                isExecutable: { path in self.state.withLock { $0.executables.contains(path) } },
                versionOutput: { path in
                    self.state.withLock { s in
                        s.versionCalls.append(path)
                        return s.versions[path]
                    }
                },
                loginShellLookup: { Issue.record("the claude lookup must not be used for codex"); return nil },
                listDirectory: { _ in [] },
                commandLookup: { name in
                    self.state.withLock { s in
                        s.lookups.append(name)
                        return s.loginShell
                    }
                })
        }
    }

    private func machine(_ valid: [String], versions extra: [String: String] = [:],
                         loginShell: String? = nil) -> CXMachine {
        var s = CXMachine.State()
        for p in valid { s.executables.insert(p); s.versions[p] = Self.good }
        for (p, v) in extra { s.executables.insert(p); s.versions[p] = v }
        s.loginShell = loginShell
        return CXMachine(s)
    }

    @Test func candidateLists() {
        #expect(CodexLocator.fixedCandidates(home: Self.home) == [
            "/opt/homebrew/bin/codex", Self.home + "/.local/bin/codex", "/usr/local/bin/codex",
            Self.home + "/.npm-global/bin/codex", Self.home + "/.bun/bin/codex",
        ])
        #expect(CodexLocator.desktopCandidates(home: Self.home) == [
            Self.chatGPTBundled, Self.home + "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ])
    }

    @Test func overrideWinsWhenValid() async {
        let m = machine(["/custom/codex", "/opt/homebrew/bin/codex"])
        let locator = CodexLocator(home: Self.home, overrideSource: { "/custom/codex" }, probe: m.probe)
        #expect(await locator.locate() == .init(path: "/custom/codex", version: "0.153.4"))
    }

    @Test func invalidOverrideFallsThroughToFixedPaths() async {
        let m = machine([Self.home + "/.local/bin/codex"], versions: ["/custom/codex": "2.1.284 (Claude Code)\n"])
        let locator = CodexLocator(home: Self.home, overrideSource: { "/custom/codex" }, probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/.local/bin/codex")
    }

    @Test func tildeOverrideIsExpanded() async {
        let m = machine([Self.home + "/bin/codex"])
        let locator = CodexLocator(home: Self.home, overrideSource: { " ~/bin/codex " }, probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/bin/codex")
        #expect(await locator.currentOverride() == "~/bin/codex")
    }

    @Test func homebrewComesFirst() async {
        let m = machine([Self.home + "/.local/bin/codex", "/opt/homebrew/bin/codex", Self.chatGPTBundled])
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == "/opt/homebrew/bin/codex")
        #expect(m.lookups.isEmpty)
    }

    @Test func loginShellRunsBeforeTheDesktopBundle() async {
        let nvm = Self.home + "/.nvm/versions/node/v22/bin/codex"
        let m = machine([nvm, Self.chatGPTBundled], loginShell: "Welcome!\n/not/this\n  \(nvm)  \ncodex: aliased\n")
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == nvm)
        #expect(m.lookups == ["codex"])
    }

    @Test func desktopBundleIsTheLastResort() async {
        let m = machine([Self.chatGPTBundled], loginShell: nil)
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate() == .init(path: Self.chatGPTBundled, version: "0.153.4"))
        #expect(m.lookups == ["codex"])
        let codexApp = "/Applications/Codex.app/Contents/Resources/codex"
        let m2 = machine([codexApp])
        #expect(await CodexLocator(home: Self.home, probe: m2.probe).locate()?.path == codexApp)
    }

    @Test func nothingFound() async {
        let m = machine([])
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate() == nil)
        #expect(m.versionCalls.isEmpty)                         // nothing executable → nothing run
    }

    @Test func versionMustBeCodexCLI() async {
        let m = machine(["/usr/local/bin/codex"], versions: [
            "/opt/homebrew/bin/codex": "2.1.284 (Claude Code)\n",
            Self.home + "/.local/bin/codex": "codex 0.153.4\n",
        ])
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == "/usr/local/bin/codex")
    }

    @Test func versionParsing() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-version-0.153.4", withExtension: "txt",
                                                 subdirectory: "Fixtures/codex"))
        #expect(CodexLocator.parseVersion(try String(contentsOf: url, encoding: .utf8)) == "0.153.4")
        #expect(CodexLocator.parseVersion("codex-cli 0.154.0-alpha.3\n") == "0.154.0-alpha.3")
        #expect(CodexLocator.parseVersion("WARNING: proceeding without PATH update\ncodex-cli 1.2.3\n") == "1.2.3")
        #expect(CodexLocator.parseVersion("codex-cli 1.2\n") == nil)
        #expect(CodexLocator.parseVersion("codex-cli 1.2.3x\n") == nil)
        #expect(CodexLocator.parseVersion("0.153.4\n") == nil)
        #expect(CodexLocator.parseVersion("my-codex-cli 0.153.4\n") == nil)
        #expect(CodexLocator.parseVersion("") == nil)
    }

    @Test func resultIsCachedUntilInvalidated() async {
        let path = "/opt/homebrew/bin/codex"
        let m = machine([path])
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        _ = await locator.locate()
        _ = await locator.locate()
        #expect(m.versionCalls == [path])
        await locator.invalidate()
        #expect(await locator.current == nil)
        _ = await locator.locate()
        #expect(m.versionCalls == [path, path])
    }

    @Test func revalidatePicksUpAnUpdate() async {
        let path = "/opt/homebrew/bin/codex"
        let m = machine([path])
        let locator = CodexLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.version == "0.153.4")
        m.set { $0.versions[path] = "codex-cli 0.154.0\n" }
        #expect(await locator.locate()?.version == "0.153.4")                  // cached
        #expect(await locator.locate(revalidate: true) == .init(path: path, version: "0.154.0"))
        m.set { $0.executables.remove(path) }
        #expect(await locator.locate(revalidate: true) == nil)
    }

    @Test func changedOverrideIsPickedUpWithoutRelaunch() async {
        let box = Mutex<String?>(nil)
        let m = machine(["/opt/homebrew/bin/codex", "/custom/codex"])
        let locator = CodexLocator(home: Self.home, overrideSource: { box.withLock { $0 } }, probe: m.probe)
        #expect(await locator.locate()?.path == "/opt/homebrew/bin/codex")
        box.withLock { $0 = "/custom/codex" }
        #expect(await locator.locate()?.path == "/custom/codex")
        box.withLock { $0 = "" }
        #expect(await locator.locate()?.path == "/opt/homebrew/bin/codex")
    }

    @Test func probeWithoutCommandLookupFallsBackToTheLoginShellClosure() async {
        let probe = BinaryLocator.Probe(isExecutable: { _ in false }, versionOutput: { _ in nil },
                                        loginShellLookup: { "/from/closure\n" }, listDirectory: { _ in [] })
        #expect(await probe.loginShellLookup(command: "codex") == "/from/closure\n")
    }

    /// The live lookup refuses anything but a plain command word (returns without spawning a shell).
    @Test func liveLookupRejectsShellMetacharacters() async {
        for bad in ["", "codex; rm -rf ~", "codex$(id)", "a b", "codex`x`", String(repeating: "c", count: 40)] {
            #expect(await BinaryLocator.Probe.liveLoginShellLookup(bad) == nil)
        }
        #expect(BinaryLocator.Probe.live.commandLookup != nil)
    }
}
