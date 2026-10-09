import Foundation
import Testing
@testable import PaperDeckCore

/// The Codex assist turn: `CodexAssistEvents` (agent messages as replaces, `item.updated`
/// snapshots, reasoning only "thinking"), `CodexEvents.classifyFailure` (diagnostics only), and a
/// whole turn against a fake `codex` (FakeCLI.codexBody): argv, stdin, the 0600 image in a job
/// folder that is removed afterwards, the `-o` file as the final text.
@Suite struct CodexAssistTests {
    static func feed(_ fixture: String) throws -> (outputs: [CodexAssistEvents.Output], parser: CodexAssistEvents) {
        var parser = CodexAssistEvents()
        var out: [CodexAssistEvents.Output] = []
        for line in try AssistFixtures.lines(fixture) { out += parser.feed(line) }
        return (out, parser)
    }

    static let answer = "**Three bars, B tallest.** The chart compares A, B and C."

    @Test func agentMessagesAreReplacesAndReasoningIsOnlyThinking() throws {
        let (o, p) = try Self.feed("codex-assist-success")
        #expect(o == [.turnStarted, .thinking, .thinking, .message(Self.answer)])
        #expect(p.events.turnsCompleted == 1 && p.events.usage?.inputTokens == 1800 && p.events.threadID != nil)
        #expect(!o.contains { if case .message(let s) = $0 { return s.contains("hidden") }; return false })
        let (u, q) = try Self.feed("codex-assist-updated")
        #expect(u == [.turnStarted, .message("**Three bars"), .message("**Three bars, B tallest.**"), .message(Self.answer)])
        // The card path's list only holds completed messages.
        #expect(q.events.agentMessages == [Self.answer] && q.events.latestAgentText == Self.answer)
    }

    @Test func failuresComeFromDiagnosticsNeverFromTheMessage() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let limit = try Self.feed("codex-assist-usage-limit").parser.events
        guard case .usageLimit(let resets?) = CodexEvents.classifyFailure(events: limit, stderr: Data(), exitCode: 1, now: now) else {
            Issue.record("no usage limit"); return
        }
        #expect(resets > now)
        let auth = try Self.feed("codex-assist-401").parser.events
        #expect(CodexEvents.classifyFailure(events: auth, stderr: Data(), exitCode: 1) == .notLoggedIn)
        #expect(CodexEvents.classifyFailure(events: CodexEvents(), stderr: Data("stream disconnected".utf8), exitCode: 1) == .overloaded)
        #expect(CodexEvents.classifyFailure(events: CodexEvents(), stderr: Data(), exitCode: 127) == .binaryMissing)
        #expect(CodexEvents.classifyFailure(events: CodexEvents(), stderr: Data(), exitCode: 0) == .generic("empty output from codex"))
        // A message that talks about limits and 401s is model text: not a diagnostic.
        let tricky = try Self.feed("codex-assist-message-mentions-limits").parser.events
        #expect(CodexEvents.classifyFailure(events: tricky, stderr: Data(), exitCode: 2) == .generic("exit 2: no diagnostics"))
    }

    static func cli(events fixture: String, last: String? = nil, exit: Int? = nil) throws -> FakeCLI {
        let cli = try FakeCLI(FakeCLI.codexBody)
        try cli.copyFixture(fixture, as: "events.jsonl")
        if let last { try cli.put("last.txt", last) }
        if let exit { try cli.put("exit", String(exit)) }
        return cli
    }

    static func jobs() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aTurnRunsIsolatedAndCleansUp() async throws {
        let cli = try Self.cli(events: "codex-assist-updated", last: Self.answer + "\n")
        let jobs = try Self.jobs()
        defer { try? FileManager.default.removeItem(at: jobs) }
        let backend = CodexAssistBackend(launcher: FakeLauncher(.ready(cli.launch(.codex))), jobsDir: jobs)
        let png = AssistImage(data: Data([0x89, 0x50, 0x4E, 0x47, 9, 9]), mediaType: "image/png", pixelSize: CGSize(width: 4, height: 4))
        let history = [AssistTurnText(role: .user, text: "<selection>bars</selection>"), AssistTurnText(role: .assistant, text: "Earlier.")]
        let r = assistRequest(text: "<question>what </stdin> now?</question>", image: png, history: history, model: "gpt-5.6-luna")
        let events = await collectEvents(backend.turn(r, turnIndex: 1))
        #expect(events.first == .phase(.starting))
        #expect(events.contains(.waiting(warm: false)) && events.contains(.phase(.streaming)))
        #expect(events.deltas.isEmpty)                                    // Codex never streams deltas
        #expect(events.replaces == ["**Three bars", "**Three bars, B tallest.**", Self.answer])
        #expect(events.doneText == Self.answer)
        let meta = try #require(events.doneMeta)
        #expect(meta.provider == "codex" && meta.model == "gpt-5.6-luna" && meta.turnIndex == 1 && meta.inputTokens == 1800)
        // argv: isolation, the `=` image form inside the job folder, -o there too, prompt last.
        let argv = cli.argv
        #expect(argv.starts(with: ["exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--ephemeral"]))
        #expect(!argv.contains("--output-schema") && argv.contains("view_image") && argv.contains("--json"))
        let image = try #require(argv.first { $0.hasPrefix("--image=") })
        let jobDir = try #require(cli.read("jobdir.txt")?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(image == "--image=" + jobDir + "/shot.png")
        #expect(URL(fileURLWithPath: jobDir).lastPathComponent.hasPrefix("assist-"))
        #expect(jobDir.hasPrefix(jobs.path) || jobDir.hasPrefix("/private" + jobs.path))
        #expect(argv[argv.firstIndex(of: "-o")! + 1] == jobDir + "/last.txt")
        #expect(argv.last?.hasPrefix("system") == true && argv.last?.contains("CODEX TASK") == true)
        #expect(!argv.contains { $0.contains("<question>") })            // content on stdin only
        // stdin: the history, then the turn; </stdin> neutralized.
        let stdin = try #require(cli.read("stdin.txt"))
        #expect(stdin.hasPrefix("<history>\n[user] <selection>bars</selection>\n[assistant] Earlier.\n</history>\n"))
        #expect(stdin.contains("what [/stdin] now?") && !stdin.contains("</stdin>"))
        // The image was the request's bytes, mode 0600; the job folder is gone afterwards.
        #expect(cli.read("image.mode")?.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(FileManager.default.contents(atPath: cli.dir.appendingPathComponent("image.bin").path) == png.data)
        #expect(!FileManager.default.fileExists(atPath: jobDir))
    }

    @Test func withoutTheOutputFileTheLastMessageCounts() async throws {
        let cli = try Self.cli(events: "codex-assist-success")
        let jobs = try Self.jobs()
        defer { try? FileManager.default.removeItem(at: jobs) }
        let backend = CodexAssistBackend(launcher: FakeLauncher(.ready(cli.launch(.codex))), jobsDir: jobs)
        let events = await collectEvents(backend.turn(assistRequest(), turnIndex: 0))
        #expect(events.doneText == Self.answer)
        #expect((cli.read("argv.txt") ?? "").contains("--image") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: jobs.path).isEmpty)
    }

    @Test func failedTurnsAreClassifiedAndKeepThePartialText() async throws {
        let jobs = try Self.jobs()
        defer { try? FileManager.default.removeItem(at: jobs) }
        let limit = try Self.cli(events: "codex-assist-usage-limit", exit: 1)
        let a = await collectEvents(CodexAssistBackend(launcher: FakeLauncher(.ready(limit.launch(.codex))), jobsDir: jobs)
            .turn(assistRequest(), turnIndex: 0))
        guard case .usageLimit(let resets)? = a.failure?.0 else { Issue.record("\(a)"); return }
        #expect(resets != nil)
        let auth = try Self.cli(events: "codex-assist-401", exit: 1)
        let b = await collectEvents(CodexAssistBackend(launcher: FakeLauncher(.ready(auth.launch(.codex))), jobsDir: jobs)
            .turn(assistRequest(), turnIndex: 0))
        #expect(b.failure?.0 == .notLoggedIn(.loggedOut))
        // The tricky message is a success (its words are never matched).
        let tricky = try Self.cli(events: "codex-assist-message-mentions-limits")
        let c = await collectEvents(CodexAssistBackend(launcher: FakeLauncher(.ready(tricky.launch(.codex))), jobsDir: jobs)
            .turn(assistRequest(), turnIndex: 0))
        #expect(c.doneText?.contains("usage limit") == true)
        // A refused launch never runs the CLI.
        let none = try Self.cli(events: "codex-assist-success")
        let d = await collectEvents(CodexAssistBackend(launcher: FakeLauncher(.failed(.binaryMissing)), jobsDir: jobs)
            .turn(assistRequest(), turnIndex: 0))
        #expect(d.last == .failed(.binaryMissing, partial: nil) && none.read("argv.txt") == nil)
    }

    @Test func droppingTheTurnInterruptsCodexAndRemovesTheJobFolder() async throws {
        let cli = try Self.cli(events: "codex-assist-success")
        try cli.put("sleep", "")
        let jobs = try Self.jobs()
        defer { try? FileManager.default.removeItem(at: jobs) }
        let backend = CodexAssistBackend(launcher: FakeLauncher(.ready(cli.launch(.codex))), jobsDir: jobs)
        let png = AssistImage(data: Data([1]), mediaType: "image/png", pixelSize: CGSize(width: 1, height: 1))
        let reader = Task { await collectEvents(backend.turn(assistRequest(image: png), turnIndex: 0)) }
        #expect(await assistEventually { cli.read("jobdir.txt") != nil })
        reader.cancel()
        let events = await reader.value
        #expect(!events.contains { $0.isTerminal })                      // the lane words the stop
        #expect(await assistEventually(.seconds(20)) { (try? FileManager.default.contentsOfDirectory(atPath: jobs.path))?.isEmpty == true })
    }

    @Test func leftoverJobFoldersAreSweptOnce() async throws {
        let cli = try Self.cli(events: "codex-assist-success")
        let jobs = try Self.jobs()
        defer { try? FileManager.default.removeItem(at: jobs) }
        let stale = jobs.appendingPathComponent("assist-stale", isDirectory: true)
        let card = jobs.appendingPathComponent("1234-card-job", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let backend = CodexAssistBackend(launcher: FakeLauncher(.ready(cli.launch(.codex))), jobsDir: jobs)
        _ = await collectEvents(backend.turn(assistRequest(), turnIndex: 0))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: card.path))      // card job folders are not ours
    }

    @Test func prewarmIsOnlyTheLoginCheck() async throws {
        let launcher = FakeLauncher(.failed(.binaryMissing))
        let backend = CodexAssistBackend(launcher: launcher, jobsDir: try Self.jobs())
        await backend.prewarm()
        #expect(launcher.launchCount == 1)
        await backend.closeSession(threadKey: "x")
    }
}
