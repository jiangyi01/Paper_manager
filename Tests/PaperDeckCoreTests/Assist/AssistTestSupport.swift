import Foundation
import Testing
@testable import PaperDeckCore

/// Shared helpers of the Slice A assist tests. No test here ever starts claude or codex: the
/// "CLIs" are `/bin/sh` scripts written into a temp folder, and every backend is reached through
/// a fake `AssistLauncher` that points at them.
enum AssistFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/assist"))
        return try Data(contentsOf: url)
    }

    static func lines(_ name: String) throws -> [Data] {
        var splitter = LineSplitter()
        var out = splitter.push(try data(name))
        if let rest = splitter.finish() { out.append(rest) }
        return out
    }

    static func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/assist"))
    }
}

/// Every event of `s` until it ends. Bounded: after `timeout` the collection is cancelled (which
/// drops the stream, so the turn is stopped) and what arrived so far is returned — a turn that
/// never ends fails its test instead of hanging the run. Cancelling the caller cancels the collection.
func collectEvents(_ s: AsyncStream<AssistEvent>, within timeout: Duration = .seconds(60)) async -> [AssistEvent] {
    let collector = Task { () -> [AssistEvent] in
        var out: [AssistEvent] = []
        for await e in s { out.append(e) }
        return out
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { collector.cancel() }
    }
    let events = await withTaskCancellationHandler { await collector.value } onCancel: { collector.cancel() }
    timer.cancel()
    return events
}

/// Polls `condition` until it holds or `timeout` passes (20 s by default: generous on a loaded
/// machine — a condition that holds returns at once, only a failure waits it out; ENV-1).
func assistEventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}

extension Array where Element == AssistEvent {
    var deltas: [String] { compactMap { if case .delta(let s) = $0 { return s }; return nil } }
    var replaces: [String] { compactMap { if case .replace(let s) = $0 { return s }; return nil } }
    var doneText: String? { for e in self { if case .done(let t, _) = e { return t } }; return nil }
    var doneMeta: AssistMeta? { for e in self { if case .done(_, let m) = e { return m } }; return nil }
    var failure: (AssistFailure, String?)? {
        for e in self { if case .failed(let f, let p) = e { return (f, p) } }
        return nil
    }
}

/// A temp folder with a fake CLI script (`/bin/sh`) and its fixtures; `PD_FAKE_DIR` points at it.
final class FakeCLI: @unchecked Sendable {
    let dir: URL
    let script: URL

    init(_ body: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-fake-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        script = dir.appendingPathComponent("fake-cli")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func put(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func copyFixture(_ fixture: String, as name: String) throws {
        try put(name, String(decoding: try AssistFixtures.data(fixture), as: UTF8.self))
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    /// The recorded argv (NUL-separated by the scripts), without argv[0].
    var argv: [String] {
        guard let raw = read("argv.txt") else { return [] }
        var parts = raw.components(separatedBy: "\0")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    var cwd: URL { dir.appendingPathComponent("agent-cwd", isDirectory: true) }

    func launch(_ provider: AIProviderKind, flags: Set<String>? = nil, extraEnv: [String: String] = [:]) -> AssistLaunch {
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        var env = ["PATH": "/usr/bin:/bin", "PD_FAKE_DIR": dir.path, "HOME": dir.path]
        env.merge(extraEnv) { _, new in new }
        let caps: Set<String>
        switch provider {
        case .claude: caps = flags ?? Set(ClaudeCodeProvider.Capabilities.assistRequired + ClaudeCodeProvider.Capabilities.optional
                                          + ["--include-partial-messages"])
        case .codex: caps = flags ?? Set(CodexProvider.Capabilities.assistRequired + CodexProvider.Capabilities.optional)
        }
        return AssistLaunch(provider: provider, executable: script.path, version: "0.0.0-fake", environment: env,
                            cwd: cwd.path, flags: caps, disabledFeatures: provider == .codex ? ["shell_tool", "view_image"] : [])
    }

    /// The fake `claude -p --input-format stream-json`: argv and env recorded; for the n-th stdin
    /// line it logs the line and replays `turn<n>.jsonl` (else `turn.jsonl`); `exit-after-<n>`
    /// exits 3 after replaying turn n (no result line needed); `sleep-<n>` sleeps (once) instead of replying.
    /// The sleep is claimed atomically (`mv`) before the line is logged, so a test that waits for
    /// `stdin.log` knows which process sleeps — a second process started right after never does.
    static let claudeBody = """
    printf '%s\\0' "$@" > "$PD_FAKE_DIR/argv.txt"
    env > "$PD_FAKE_DIR/env.txt"
    echo $$ >> "$PD_FAKE_DIR/pids.txt"
    n=0
    while IFS= read -r line; do
      n=$((n+1))
      slow=0
      if mv "$PD_FAKE_DIR/sleep-$n" "$PD_FAKE_DIR/slept-$n-$$" 2>/dev/null; then slow=1; fi
      printf '%s\\n' "$line" >> "$PD_FAKE_DIR/stdin.log"
      if [ "$slow" = 1 ]; then sleep 30; fi
      f="$PD_FAKE_DIR/turn$n.jsonl"
      [ -f "$f" ] || f="$PD_FAKE_DIR/turn.jsonl"
      cat "$f"
      if [ -f "$PD_FAKE_DIR/stderr-$n" ]; then cat "$PD_FAKE_DIR/stderr-$n" >&2; fi
      if [ -f "$PD_FAKE_DIR/exit-after-$n" ]; then exit 3; fi
    done
    echo eof >> "$PD_FAKE_DIR/eof.txt"
    """

    /// The fake `codex exec --json -o FILE [--image=PATH] PROMPT`: argv, stdin, the image (and its
    /// mode) recorded; replays `events.jsonl`; copies `last.txt` to the -o path; exits with `exit`.
    static let codexBody = """
    printf '%s\\0' "$@" > "$PD_FAKE_DIR/argv.txt"
    out=""; img=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "-o" ]; then out="$a"; fi
      case "$a" in --image=*) img="${a#--image=}";; esac
      prev="$a"
    done
    cat > "$PD_FAKE_DIR/stdin.txt"
    if [ -n "$img" ]; then cp "$img" "$PD_FAKE_DIR/image.bin"; stat -f '%Lp' "$img" > "$PD_FAKE_DIR/image.mode"; dirname "$img" > "$PD_FAKE_DIR/jobdir.txt"; fi
    if [ -f "$PD_FAKE_DIR/sleep" ]; then rm -f "$PD_FAKE_DIR/sleep"; sleep 30; fi
    cat "$PD_FAKE_DIR/events.jsonl"
    if [ -f "$PD_FAKE_DIR/stderr.txt" ]; then cat "$PD_FAKE_DIR/stderr.txt" >&2; fi
    if [ -f "$PD_FAKE_DIR/last.txt" ] && [ -n "$out" ]; then cp "$PD_FAKE_DIR/last.txt" "$out"; fi
    code=0; if [ -f "$PD_FAKE_DIR/exit" ]; then code=$(cat "$PD_FAKE_DIR/exit"); fi
    exit $code
    """
}

/// An `AssistLauncher` that hands out a fixed launch (or failure) and counts calls.
final class FakeLauncher: AssistLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var result: AssistLaunchResult
    private var launches = 0
    private var detections = 0
    private let detection: AgentQueueStatus.Provider

    init(_ result: AssistLaunchResult, detection: AgentQueueStatus.Provider = .ready(plan: "fake", version: "0")) {
        self.result = result; self.detection = detection
    }

    func set(_ r: AssistLaunchResult) { lock.withLock { result = r } }
    var launchCount: Int { lock.withLock { launches } }
    var detectCount: Int { lock.withLock { detections } }

    func assistLaunch() async -> AssistLaunchResult { lock.withLock { launches += 1; return result } }
    func assistDetect() async -> AgentQueueStatus.Provider { lock.withLock { detections += 1; return detection } }
}

/// The idle timer's clock under the test's control: `fire()` ends every pending sleep.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var requested: [Duration] = []

    var pending: Int { lock.withLock { waiters.count } }

    var sleep: @Sendable (Duration) async -> Void {
        { [self] d in
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let cancelled: Bool = lock.withLock {
                        requested.append(d)
                        if Task.isCancelled { return true }
                        waiters[id] = c
                        return false
                    }
                    if cancelled { c.resume() }
                }
            } onCancel: {
                let c: CheckedContinuation<Void, Never>? = lock.withLock { waiters.removeValue(forKey: id) }
                c?.resume()
            }
        }
    }

    func fire() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for c in all { c.resume() }
    }
}

/// A backend that plays a script per turn, records what it was asked, and notices when its
/// stream was dropped (the lane stopped the turn).
actor ScriptedBackend: AssistBackend, AssistSessionOwning {
    enum Step: Sendable { case event(AssistEvent), sleep(Duration), hang }

    nonisolated let mode: AssistMode
    private var scripts: [[Step]]
    private let fallback: [Step]
    private(set) var turns = 0
    private(set) var requests: [AssistRequest] = []
    private(set) var terminations = 0
    private(set) var closedAll = 0
    private(set) var closedSessions: [String] = []
    private(set) var prewarms = 0
    private(set) var detections = 0

    init(mode: AssistMode, scripts: [[Step]] = [], fallback: [Step] = ScriptedBackend.answer("ok")) {
        self.mode = mode; self.scripts = scripts; self.fallback = fallback
    }

    static func answer(_ text: String, model: String = "m") -> [Step] {
        [.event(.waiting(warm: false)), .event(.delta(text)),
         .event(.done(text: text, meta: AssistMeta(provider: "test", model: model)))]
    }

    nonisolated func turn(_ request: AssistRequest, turnIndex: Int) -> AsyncStream<AssistEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { c in
            let task = Task {
                let steps = await self.begin(request)
                for step in steps {
                    if Task.isCancelled { break }
                    switch step {
                    case .event(let e): c.yield(e)
                    case .sleep(let d): try? await Task.sleep(for: d)
                    case .hang: while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    }
                }
                c.finish()
            }
            c.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { Task { await self.noteTermination() } }
            }
        }
    }

    private func begin(_ r: AssistRequest) -> [Step] {
        turns += 1
        requests.append(r)
        return scripts.isEmpty ? fallback : scripts.removeFirst()
    }

    private func noteTermination() { terminations += 1 }
    func prewarm() async { prewarms += 1 }
    func closeSession(threadKey: String) async { closedSessions.append(threadKey) }
    func closeAllSessions() async { closedAll += 1 }
    func detect() async -> AgentQueueStatus.Provider { detections += 1; return .ready(plan: "test", version: "1") }
}

/// Mutable settings for a lane under test.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: EngineSettings
    init(_ mode: AssistMode) { var s = EngineSettings(); s.assist.mode = mode; settings = s }
    var value: EngineSettings { lock.withLock { settings } }
    func update(_ body: (inout EngineSettings) -> Void) { lock.withLock { body(&settings) } }
}

/// A pause that tests set (what `AgentQueue.pause(for:)` answers).
final class PauseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var until: [AIProviderKind: Date] = [:]
    func set(_ kind: AIProviderKind, _ d: Date?) { lock.withLock { until[kind] = d } }
    func get(_ kind: AIProviderKind) -> Date? { lock.withLock { until[kind] } }
}

func assistRequest(_ surface: AssistSurface = .explain, text: String = "<selection>text</selection>",
                   image: AssistImage? = nil, history: [AssistTurnText] = [], model: String = "haiku",
                   session: AssistSessionPolicy = .oneShot, limits: AssistLimits? = nil,
                   systemPrompt: String = "system") -> AssistRequest {
    AssistRequest(surface: surface, systemPrompt: systemPrompt, turnText: text, image: image, history: history,
                  model: model, effort: "low", session: session,
                  limits: limits ?? AssistLimits.defaults(for: surface, provider: .claude))
}
