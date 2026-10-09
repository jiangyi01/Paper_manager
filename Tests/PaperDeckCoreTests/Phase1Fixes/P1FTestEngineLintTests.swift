import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 1 fix F12 (safety): no test engine can build a real CLI backend. Every `Engine.open` in
/// the tests passes `deps:` with
/// - `claude:` and `codex:` — stand-ins, never `nil` (nil builds the real ClaudeCodeProvider /
///   CodexProvider) and never a real provider;
/// - `assistBackends:` — scripted or mock backends only (without it the engine registers the real
///   Claude / Codex assist backends for real providers, and the on-device model).
/// A test that builds the real card provider on purpose (a locator test: agent.mode off, never
/// started) says so with `// test-engine-lint: real-card-provider`; the one that checks the backend
/// factory itself with `// test-engine-lint: built-in-assist-backends`. Read-only over `Tests/`.
@Suite("Test engines use stand-ins only", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct P1FTestEngineLintTests {
    static let me = "Tests/PaperDeckCoreTests/Phase1Fixes/P1FTestEngineLintTests.swift"
    /// Files owned by another fix batch that still rely on the factory with mock providers (no CLI
    /// backend is possible there: both card providers are mocks, which this lint still checks).
    /// Remove an entry once the file passes `assistBackends: [MockAssistBackend()]`.
    static let assistBackendsPending: Set<String> = []

    struct Site: CustomStringConvertible {
        var path: String
        var line: Int
        var args: [String: String]
        var markers: Set<String>
        /// The enclosing function up to the dependencies (its parameters and locals).
        var scope: String
        var description: String { "\(path):\(line)" }
    }

    /// The text inside the parentheses that open at `open` (balanced; strings and comments aren't special-cased).
    static func balanced(_ s: String, from open: String.Index) -> Range<String.Index>? {
        var depth = 1
        var i = s.index(after: open)
        let start = i
        while i < s.endIndex {
            switch s[i] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return start..<i }
            default: break
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Top-level `label: value` arguments.
    static func arguments(_ inner: Substring) -> [String: String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        var inString = false
        for ch in inner {
            if ch == "\"" { inString.toggle() }
            if !inString {
                if "([{".contains(ch) { depth += 1 }
                if ")]}".contains(ch) { depth -= 1 }
                if ch == ",", depth == 0 { parts.append(current); current = ""; continue }
            }
            current.append(ch)
        }
        parts.append(current)
        var out: [String: String] = [:]
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = t.firstIndex(of: ":") else { continue }
            let label = t[..<colon].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            out[label] = t[t.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static func lineNumber(_ s: String, _ i: String.Index) -> Int { s[..<i].reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

    /// The match at `i` sits in a `//` comment.
    static func inComment(_ s: String, _ i: String.Index) -> Bool {
        let lineStart = s[..<i].lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
        return s[lineStart..<i].contains("//")
    }

    /// The `test-engine-lint:` markers in the five lines above `i`.
    static func markers(_ s: String, before i: String.Index) -> Set<String> {
        let lines = s[..<i].components(separatedBy: "\n").suffix(6)
        var out: Set<String> = []
        for l in lines {
            guard let r = l.range(of: "test-engine-lint: ") else { continue }
            out.insert(String(l[r.upperBound...].prefix { $0.isLetter || $0 == "-" }))
        }
        return out
    }

    /// Every `Engine.open` in the tests with the arguments of the dependencies it is given (inline,
    /// or the nearest `Engine.Dependencies(` above it in the same file).
    static func sites() throws -> (sites: [Site], unresolved: [String]) {
        var sites: [Site] = []
        var unresolved: [String] = []
        for path in LintRepo.swiftFiles(under: "Tests") where path != me {
            let s = try String(contentsOf: LintRepo.url(path), encoding: .utf8)
            var deps: [(at: String.Index, args: [String: String], markers: Set<String>, scope: String)] = []
            var from = s.startIndex
            while let r = s.range(of: "Engine.Dependencies(", range: from..<s.endIndex) {
                let open = s.index(before: r.upperBound)
                if inComment(s, r.lowerBound) { from = r.upperBound; continue }
                guard let inner = balanced(s, from: open) else { break }
                let funcStart = s.range(of: "func ", options: .backwards, range: s.startIndex..<r.lowerBound)?.lowerBound ?? s.startIndex
                deps.append((r.lowerBound, arguments(s[inner]), markers(s, before: r.lowerBound), String(s[funcStart..<r.lowerBound])))
                from = inner.upperBound
            }
            from = s.startIndex
            while let r = s.range(of: "Engine.open(", range: from..<s.endIndex) {
                let open = s.index(before: r.upperBound)
                if inComment(s, r.lowerBound) { from = r.upperBound; continue }
                guard let inner = balanced(s, from: open) else { break }
                from = s.index(after: open)
                let line = lineNumber(s, r.lowerBound)
                guard s[inner].contains("deps:") else { unresolved.append("\(path):\(line): Engine.open without deps:"); continue }
                guard let d = deps.last(where: { $0.at < inner.upperBound }) else {
                    unresolved.append("\(path):\(line): no Engine.Dependencies( found for it")
                    continue
                }
                sites.append(Site(path: path, line: line, args: d.args, markers: d.markers.union(markers(s, before: r.lowerBound)),
                                  scope: d.scope))
            }
        }
        return (sites, unresolved)
    }

    /// Whether `identifier` is declared in `source` (the enclosing function) as an optional provider
    /// (nil builds the real one) or bound to a real one.
    static func isOptionalProvider(_ identifier: String, in source: String) -> Bool {
        let id = #"\b"# + identifier
        return [#"\s*:\s*\(\s*any\s+AgentProvider\s*\)\s*\?"#, #"\s*:\s*(ClaudeCodeProvider|CodexProvider)\b"#,
                #"\s*=\s*(ClaudeCodeProvider|CodexProvider)\s*\("#].contains { tail in
            source.range(of: id + tail, options: .regularExpression) != nil
        }
    }

    @Test func everyTestEngineUsesStandInProvidersAndBackends() throws {
        let (sites, unresolved) = try Self.sites()
        #expect(unresolved.isEmpty, "\(unresolved.joined(separator: "\n"))")
        #expect(sites.count >= 30, "found only \(sites.count) engines: is the scan still seeing the kits?")
        #expect(sites.contains { $0.path == "Tests/PaperDeckCoreTests/Operations/OpsTestKit.swift" })
        var problems: [String] = []
        for site in sites {
            let source = site.scope
            let realOK = site.markers.contains("real-card-provider")
            for label in ["claude", "codex"] {
                guard let value = site.args[label] else { problems.append("\(site): no \(label): (nil builds the real provider)"); continue }
                if realOK { continue }
                if value.range(of: #"\bnil\b|ClaudeCodeProvider|CodexProvider"#, options: .regularExpression) != nil {
                    problems.append("\(site): \(label): \(value)")
                } else if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), Self.isOptionalProvider(value, in: source) {
                    problems.append("\(site): \(label): \(value) may be nil (mark a deliberate real provider)")
                }
            }
            if let backends = site.args["assistBackends"] {
                if backends.range(of: #"\bnil\b|AssistBackendFactory|ClaudeAssistBackend|CodexAssistBackend|LocalAssistBackend"#,
                                  options: .regularExpression) != nil {
                    problems.append("\(site): assistBackends: \(backends)")
                }
            } else if !site.markers.contains("built-in-assist-backends") && !Self.assistBackendsPending.contains(site.path) {
                problems.append("\(site): no assistBackends: (pass [MockAssistBackend()])")
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        // The markers stay rare: each is a deliberate, reviewed exception.
        #expect(sites.filter { $0.markers.contains("real-card-provider") }.count <= 2)
        #expect(sites.filter { $0.markers.contains("built-in-assist-backends") }.count <= 1)
    }

    /// The shared kit, at run time: no locator was built (both providers injected) and the lane has
    /// the mock only.
    @Test func theOpsKitEngineHasNoRealProviderOrBackend() async throws {
        try await OpsTestKit.run { env in
            #expect(env.engine.binaryLocator == nil && env.engine.codexLocator == nil)
            #expect(await env.engine.assist.registeredModes == [.mock])
        }
    }
}
