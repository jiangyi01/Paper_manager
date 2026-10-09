import Foundation
import Synchronization
import Testing
@testable import PaperDeckCore

@Suite struct BinaryLocatorTests {
    private static let home = "/Users/tester"
    private static let good = "2.1.284 (Claude Code)\n"

    /// A fake machine: executables, their `--version` output, login-shell output, directory listings.
    private final class FakeMachine: Sendable {
        struct State {
            var executables: Set<String> = []
            var versions: [String: String] = [:]
            var loginShell: String?
            var listings: [String: [String]] = [:]
            var versionCalls: [String] = []
            var loginShellCalls = 0
        }
        let state: Mutex<State>
        init(_ s: State) { state = Mutex(s) }

        func set(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
        var versionCalls: [String] { state.withLock { $0.versionCalls } }
        var loginShellCalls: Int { state.withLock { $0.loginShellCalls } }

        var probe: BinaryLocator.Probe {
            BinaryLocator.Probe(
                isExecutable: { path in self.state.withLock { $0.executables.contains(path) } },
                versionOutput: { path in
                    self.state.withLock { s in
                        s.versionCalls.append(path)
                        return s.versions[path]
                    }
                },
                loginShellLookup: {
                    self.state.withLock { s in
                        s.loginShellCalls += 1
                        return s.loginShell
                    }
                },
                listDirectory: { dir in self.state.withLock { $0.listings[dir] ?? [] } }
            )
        }
    }

    private func machine(_ valid: [String], versions extra: [String: String] = [:],
                         loginShell: String? = nil, listings: [String: [String]] = [:]) -> FakeMachine {
        var s = FakeMachine.State()
        for p in valid { s.executables.insert(p); s.versions[p] = Self.good }
        for (p, v) in extra { s.executables.insert(p); s.versions[p] = v }
        s.loginShell = loginShell
        s.listings = listings
        return FakeMachine(s)
    }

    @Test func overrideWinsWhenValid() async {
        let m = machine(["/custom/claude", Self.home + "/.local/bin/claude"])
        let locator = BinaryLocator(home: Self.home, override: "/custom/claude", probe: m.probe)
        #expect(await locator.locate() == .init(path: "/custom/claude", version: "2.1.284"))
    }

    @Test func invalidOverrideFallsThroughToFixedPaths() async {
        let m = machine([Self.home + "/.local/bin/claude"], versions: ["/custom/claude": "garbage"])
        let locator = BinaryLocator(home: Self.home, override: "/custom/claude", probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/.local/bin/claude")
    }

    @Test func tildeOverrideIsExpanded() async {
        let m = machine([Self.home + "/bin/claude"])
        let locator = BinaryLocator(home: Self.home, override: "~/bin/claude", probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/bin/claude")
    }

    @Test func fixedPathOrder() async {
        let m = machine(["/opt/homebrew/bin/claude", Self.home + "/.local/bin/claude", Self.home + "/.bun/bin/claude"])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/.local/bin/claude")
        #expect(BinaryLocator.fixedCandidates(home: Self.home) == [
            Self.home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            Self.home + "/.claude/local/claude", Self.home + "/.npm-global/bin/claude", Self.home + "/.bun/bin/claude",
        ])
    }

    @Test func versionMustMatchClaudeCode() async {
        let m = machine(["/usr/local/bin/claude"], versions: [
            Self.home + "/.local/bin/claude": "1.0.0 (Something Else)\n",
            "/opt/homebrew/bin/claude": "claude 2.1.284\n",
        ])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == "/usr/local/bin/claude")
    }

    @Test func nonExecutableCandidatesAreNotRun() async {
        let m = machine([])
        m.set { $0.versions[Self.home + "/.local/bin/claude"] = Self.good }   // present but not executable
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate() == nil)
        #expect(m.versionCalls.isEmpty)
    }

    @Test func loginShellLookupTakesLastAbsoluteLine() async {
        let nvm = Self.home + "/.nvm/versions/node/v22/bin/claude"
        let m = machine([nvm], loginShell: "Welcome banner\n/not/this/one\n  \(nvm)  \nclaude: aliased\n")
        m.set { $0.executables.remove("/not/this/one") }
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == nvm)
        #expect(m.loginShellCalls == 1)
    }

    @Test func loginShellIsSkippedWhenAFixedPathWorks() async {
        let m = machine([Self.home + "/.local/bin/claude"], loginShell: "/elsewhere/claude\n")
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        _ = await locator.locate()
        #expect(m.loginShellCalls == 0)
    }

    @Test func claudeDesktopFallbackPicksNewestVersion() async {
        let root = Self.home + "/Library/Application Support/Claude/claude-code"
        func bundled(_ v: String) -> String { root + "/" + v + "/claude.app/Contents/MacOS/claude" }
        let m = machine([bundled("2.1.200"), bundled("2.1.30")],
                        versions: [bundled("2.1.284"): "2.1.284 (Claude Code)\n"],
                        listings: [root: ["2.1.200", "2.1.284", "2.1.30", ".DS_Store"]])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == bundled("2.1.284"))
    }

    @Test func resultIsCachedUntilInvalidated() async {
        let path = Self.home + "/.local/bin/claude"
        let m = machine([path])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        _ = await locator.locate()
        _ = await locator.locate()
        #expect(m.versionCalls == [path])
        await locator.invalidate()
        #expect(await locator.current == nil)
        _ = await locator.locate()
        #expect(m.versionCalls == [path, path])
    }

    @Test func revalidatePicksUpAnUpdatedSymlinkTarget() async {
        let path = Self.home + "/.local/bin/claude"
        let m = machine([path])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.version == "2.1.284")
        m.set { $0.versions[path] = "2.1.285 (Claude Code)\n" }
        #expect(await locator.locate()?.version == "2.1.284")                    // cached
        #expect(await locator.locate(revalidate: true) == .init(path: path, version: "2.1.285"))
        m.set { $0.executables.remove(path) }
        #expect(await locator.locate(revalidate: true) == nil)
    }

    @Test func concurrentCallersShareOneResolution() async {
        let path = "/usr/local/bin/claude"
        let m = machine([path])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        await withTaskGroup(of: BinaryLocator.Binary?.self) { group in
            for _ in 0..<8 { group.addTask { await locator.locate() } }
            for await b in group { #expect(b?.path == path) }
        }
        #expect(m.versionCalls.filter { $0 == path }.count == 1)
    }

    @Test func settingOverrideDropsTheCache() async {
        let m = machine([Self.home + "/.local/bin/claude", "/custom/claude"])
        let locator = BinaryLocator(home: Self.home, probe: m.probe)
        #expect(await locator.locate()?.path == Self.home + "/.local/bin/claude")
        await locator.setOverride("/custom/claude")
        #expect(await locator.locate()?.path == "/custom/claude")
    }

    @Test func pureHelpers() {
        #expect(BinaryLocator.parseVersion("2.1.284 (Claude Code)\n") == "2.1.284")
        #expect(BinaryLocator.parseVersion("  10.0.1 (Claude Code) extra") == "10.0.1")
        #expect(BinaryLocator.parseVersion("v2.1.284 (Claude Code)") == nil)
        #expect(BinaryLocator.parseVersion("2.1 (Claude Code)") == nil)
        #expect(BinaryLocator.parseVersion("") == nil)
        #expect(BinaryLocator.lastAbsolutePath(in: "a\n/x/claude\n/y/claude\nnope") == "/y/claude")
        #expect(BinaryLocator.lastAbsolutePath(in: "claude not found") == nil)
    }

    /// Real processes: the cached path is the symlink, never its target.
    @Test func liveProbeKeepsTheSymlinkPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-locator-\(UUID().uuidString)")
        let versions = dir.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = versions.appendingPathComponent("2.1.284")
        try "#!/bin/sh\necho '2.1.284 (Claude Code)'\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // A loaded machine can fail a `--version` run (a slow spawn, a just-written script still busy
        // in a child forked meanwhile): probe again with a fresh locator before judging (ENV-1).
        var located: BinaryLocator.Binary?
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            located = await BinaryLocator(home: dir.path, override: link.path, probe: .live).locate()
            if located?.version == "2.1.284" { break }
        }
        let found = try #require(located)
        #expect(found.path == link.path)
        #expect(found.version == "2.1.284")
        #expect(found.directory == dir.path)
    }
}
