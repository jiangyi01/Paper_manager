import Foundation
import Testing
@testable import PaperDeckCore

/// `ClaudeStreamParser` on the synthetic stream-json fixtures (Fixtures/assist, SOURCES.txt) and
/// `ClaudeEnvelope.classifyTurn`: deltas, the retry restart, the assistant repair, ignored noise,
/// and errors classified from the result line / stderr only — never from the model's text.
@Suite struct ClaudeStreamParserTests {
    static func run(_ fixture: String) throws -> (outputs: [ClaudeStreamParser.Output], parser: ClaudeStreamParser) {
        var parser = ClaudeStreamParser()
        var outputs: [ClaudeStreamParser.Output] = []
        for line in try AssistFixtures.lines(fixture) { outputs += parser.feed(line) }
        return (outputs, parser)
    }

    static func deltas(_ o: [ClaudeStreamParser.Output]) -> [String] {
        o.compactMap { if case .delta(let s) = $0 { return s }; return nil }
    }

    static func result(_ o: [ClaudeStreamParser.Output]) -> ClaudeEnvelope? {
        for x in o { if case .result(let e) = x { return e } }
        return nil
    }

    static let full = "**Three bars, B tallest.** The chart compares A, B and C; B is about twice A."

    @Test func deltasConcatenateToTheResult() throws {
        let (o, p) = try Self.run("claude-turn-success")
        #expect(Self.deltas(o).count == 4)
        #expect(Self.deltas(o).joined() == Self.full && p.text == Self.full)
        #expect(!o.contains { if case .replace = $0 { return true }; return false })   // assistant == streamed
        let env = try #require(Self.result(o))
        #expect(env.result == Self.full && env.totalCostUSD == 0.0012 && env.outputTokens == 42)
        #expect(env.inputTokens == 12 + 2048)
        guard case .started(let sid, let model, let tools)? = o.first else { Issue.record("\(o)"); return }
        #expect(sid == "00000000-0000-4000-8000-000000000001" && model == "claude-haiku-4-5" && tools.isEmpty)
        #expect(ClaudeEnvelope.classifyTurn(result: env, stderr: Data(), exitCode: nil) == .success(text: Self.full))
    }

    @Test func aSecondMessageStartRestartsTheText() throws {
        let (o, p) = try Self.run("claude-turn-retry")
        let restart = try #require(o.firstIndex(of: .replace("")))
        #expect(Self.deltas(Array(o[..<restart])).joined() == "Partial answer")
        #expect(Self.deltas(Array(o[restart...])).joined() == Self.full && p.text == Self.full)
    }

    @Test func theAssistantLineRepairsAMissedDelta() throws {
        let (o, p) = try Self.run("claude-turn-missed-delta")
        #expect(o.contains(.replace(Self.full)) && p.text == Self.full)
    }

    @Test func thinkingRateLimitControlAndNonJSONLinesAreIgnored() throws {
        let (o, p) = try Self.run("claude-turn-thinking-noise")
        #expect(Self.deltas(o).joined() == Self.full)
        #expect(!Self.deltas(o).contains { $0.contains("hidden") })
        #expect(!o.contains { if case .replace = $0 { return true }; return false })
        #expect(p.skippedLines == 1)
        #expect(p.typeSequence.contains("rate_limit_event") && p.typeSequence.contains("control_request"))
        // Types only, never values.
        #expect(p.typeSequence.allSatisfy { !$0.contains("hidden") && !$0.contains("Three") })
    }

    @Test func randomChunkingThroughTheSplitterGivesTheSameOutputs() throws {
        let data = try AssistFixtures.data("claude-turn-thinking-noise")
        let (expected, _) = try Self.run("claude-turn-thinking-noise")
        for seed in [3, 11, 2026] as [UInt64] {
            var rng = LineSplitterTests.Rng(state: seed)
            var splitter = LineSplitter()
            var parser = ClaudeStreamParser()
            var got: [ClaudeStreamParser.Output] = []
            var offset = 0
            while offset < data.count {
                let n = min(data.count - offset, Int.random(in: 1...41, using: &rng))
                for line in splitter.push(data.subdata(in: offset..<(offset + n))) { got += parser.feed(line) }
                offset += n
            }
            if let rest = splitter.finish() { got += parser.feed(rest) }
            #expect(got == expected, "seed \(seed)")
        }
    }

    @Test func modelTextAboutLimitsIsNeverClassified() throws {
        let (o, _) = try Self.run("claude-turn-model-mentions-limits")
        let env = try #require(Self.result(o))
        let tricky = Self.deltas(o).joined()
        #expect(tricky.contains("usage limit") && tricky.contains("not logged in"))
        #expect(ClaudeEnvelope.classifyTurn(result: env, stderr: Data(), exitCode: nil) == .success(text: tricky))
        // Even if the process then died without stderr, the streamed text is not read.
        #expect(ClaudeEnvelope.classifyTurn(result: nil, stderr: Data(), exitCode: 0)
                == .failure(.generic("empty output from claude")))
    }

    @Test func resultLineErrorsAreClassified() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)          // 2026-09-21 09:13 in Chicago
        let limit = try #require(Self.result(try Self.run("claude-turn-429").outputs))
        guard case .failure(.usageLimit(let resets?)) = ClaudeEnvelope.classifyTurn(result: limit, stderr: Data(), exitCode: nil, now: now) else {
            Issue.record("429 not a usage limit"); return
        }
        #expect(resets > now)
        let login = try #require(Self.result(try Self.run("claude-turn-not-logged-in").outputs))
        #expect(ClaudeEnvelope.classifyTurn(result: login, stderr: Data(), exitCode: nil) == .failure(.notLoggedIn))
        let busy = try Self.run("claude-turn-overloaded")
        #expect(Self.deltas(busy.outputs) == ["The chart"])
        #expect(ClaudeEnvelope.classifyTurn(result: Self.result(busy.outputs), stderr: Data(), exitCode: nil) == .failure(.overloaded))
        let turns = try #require(Self.result(try Self.run("claude-turn-max-turns").outputs))
        #expect(ClaudeEnvelope.classifyTurn(result: turns, stderr: Data(), exitCode: nil) == .failure(.maxTurns))
        // No result line: the exit code and stderr only.
        #expect(ClaudeEnvelope.classifyTurn(result: nil, stderr: Data("Error: not logged in".utf8), exitCode: 1)
                == .failure(.notLoggedIn))
        #expect(ClaudeEnvelope.classifyTurn(result: nil, stderr: Data(), exitCode: 127) == .failure(.binaryMissing))
    }

    @Test func initReportsToolsAndOversizeIsFlagged() throws {
        let (o, _) = try Self.run("claude-turn-tools-on")
        guard case .started(_, _, let tools)? = o.first else { Issue.record("\(o)"); return }
        #expect(tools == ["Bash", "Read"])
        var p = ClaudeStreamParser()
        #expect(p.feed(LineSplitter.oversizeMarker) == [.oversize])
    }

    @Test func beginTurnResetsTheTextButKeepsTheSession() throws {
        var p = ClaudeStreamParser()
        for line in try AssistFixtures.lines("claude-turn-success") { _ = p.feed(line) }
        p.beginTurn()
        #expect(p.text.isEmpty && p.sessionID != nil)
        var out: [ClaudeStreamParser.Output] = []
        for line in try AssistFixtures.lines("claude-turn-followup") { out += p.feed(line) }
        #expect(Self.deltas(out).joined() == "B is the tallest bar.")
        #expect(!out.contains(.replace("")))                          // a new turn's first message_start is no retry
    }
}
