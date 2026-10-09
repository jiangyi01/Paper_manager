import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ClaudeEnvelopeTests {
    private static let la = TimeZone(identifier: "America/Los_Angeles")!

    /// 2026-09-30 10:00 in Los Angeles.
    private static let now: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        return cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
    }()

    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/agent"))
        return try Data(contentsOf: url)
    }

    private func classify(_ name: String, ext: String = "json", exit: Int32 = 1, stderr: String = "") throws
        -> ClaudeEnvelope.Classification {
        ClaudeEnvelope.classify(exitCode: exit, stdout: try fixture(name, ext), stderr: Data(stderr.utf8),
                                now: Self.now, timeZone: Self.la)
    }

    private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, zone: TimeZone = la) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: parse

    @Test func successEnvelopeFields() throws {
        let env = try #require(ClaudeEnvelope.parse(try fixture("envelope-success")))
        #expect(env.type == "result")
        #expect(env.subtype == "success")
        #expect(env.isError == false)
        #expect(env.isSuccess)
        #expect(env.totalCostUSD == 0.185031)
        #expect(env.durationMs == 41233)
        #expect(env.numTurns == 2)
        #expect(env.inputTokens == 12 + 41876)
        #expect(env.outputTokens == 1834)
        #expect(env.model == "claude-sonnet-4-6")
        #expect(env.sessionID == "3f0c7a52-0f6e-4a39-9a55-1f8d2f4b7c11")
        #expect(env.apiErrorStatus == nil)
        #expect(env.structuredOutput?["tldr"]?.stringValue?.isEmpty == false)
    }

    @Test func successClassifiesWithTheStructuredOutput() throws {
        guard case .success(let card) = try classify("envelope-success", exit: 0) else {
            Issue.record("expected success"); return
        }
        let sanitized = try CardSanitizer.sanitize(card, pageCount: 14)
        #expect(sanitized.category == "AI Agents for Science")
        #expect(sanitized.checklist.count == 6)
    }

    @Test func leadingWarningLinesFallBackToLastJSONLine() throws {
        let data = try fixture("stdout-leading-warning", "txt")
        #expect((try? JSONDecoder().decode(JSONValue.self, from: data)) == nil)
        let env = try #require(ClaudeEnvelope.parse(data))
        #expect(env.isSuccess)
        guard case .success = try classify("stdout-leading-warning", ext: "txt", exit: 0) else {
            Issue.record("expected success"); return
        }
    }

    @Test func nullStructuredOutputIsInvalid() throws {
        let env = try #require(ClaudeEnvelope.parse(try fixture("envelope-success-null-structured")))
        #expect(env.structuredOutput == nil)
        #expect(!env.isSuccess)
        #expect(env.isSuccessWithoutStructuredOutput)
        guard case .invalidOutput(let msg) = try classify("envelope-success-null-structured", exit: 0) else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(msg.contains("structured_output"))
    }

    @Test func retriesExhaustedIsInvalid() throws {
        let env = try #require(ClaudeEnvelope.parse(try fixture("envelope-max-structured-retries")))
        #expect(!env.isSuccessWithoutStructuredOutput)
        guard case .invalidOutput(let msg) = try classify("envelope-max-structured-retries") else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(msg.contains("error_max_structured_output_retries"))
    }

    @Test func maxTurns() throws {
        #expect(try classify("envelope-max-turns") == .maxTurns)
    }

    @Test func sessionLimit429WithResetTime() throws {
        #expect(try classify("envelope-429-session") == .usageLimit(resetsAt: localDate(2026, 9, 30, 15, 45)))
    }

    @Test func weeklyLimitWithDate() throws {
        #expect(try classify("envelope-weekly-limit") == .usageLimit(resetsAt: localDate(2026, 10, 2, 9)))
    }

    @Test func legacyEpochLimit() throws {
        #expect(try classify("envelope-legacy-limit") == .usageLimit(resetsAt: Date(timeIntervalSince1970: 1759244400)))
    }

    @Test func overloaded529() throws {
        #expect(try classify("envelope-529") == .overloaded)
    }

    @Test func notLoggedIn() throws {
        #expect(try classify("envelope-not-logged-in") == .notLoggedIn)
    }

    @Test(arguments: [Int32(126), 127])
    func missingBinaryExitCodes(code: Int32) {
        let cls = ClaudeEnvelope.classify(exitCode: code, stdout: Data(), stderr: Data("zsh: command not found".utf8))
        #expect(cls == .binaryMissing)
    }

    @Test func stderrOnlyDiagnostics() {
        let cases: [(String, ClaudeEnvelope.Classification)] = [
            ("Error: Not logged in · Please run /login", .notLoggedIn),
            ("OAuth token refresh failed — run /login", .notLoggedIn),
            ("Failed to authenticate: OAuth session expired and could not be refreshed", .notLoggedIn),
            ("API Error: 529 {\"type\":\"overloaded_error\"}", .overloaded),
            ("Claude AI usage limit reached|1759244400", .usageLimit(resetsAt: Date(timeIntervalSince1970: 1759244400))),
            ("5-hour limit reached ∙ resets 3pm", .usageLimit(resetsAt: localDate(2026, 9, 30, 15))),
            ("You've reached your Opus limit · resets Oct 2, 9am", .usageLimit(resetsAt: localDate(2026, 10, 2, 9))),
            ("Usage: claude [options] [command] [prompt]\nerror: unknown option '--safe-mode'", .generic(
                "exit 1: Usage: claude [options] [command] [prompt] | error: unknown option '--safe-mode'")),
        ]
        for (stderr, expected) in cases {
            let cls = ClaudeEnvelope.classify(exitCode: 1, stdout: Data(), stderr: Data(stderr.utf8),
                                              now: Self.now, timeZone: Self.la)
            #expect(cls == expected, "\(stderr)")
        }
    }

    @Test func statusCodesWinWithoutText() {
        func env(_ status: Int) -> Data {
            Data("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"API Error\",\"api_error_status\":\(status)}".utf8)
        }
        #expect(ClaudeEnvelope.classify(exitCode: 1, stdout: env(429), stderr: Data()) == .usageLimit(resetsAt: nil))
        #expect(ClaudeEnvelope.classify(exitCode: 1, stdout: env(529), stderr: Data()) == .overloaded)
        #expect(ClaudeEnvelope.classify(exitCode: 1, stdout: env(401), stderr: Data()) == .notLoggedIn)
        #expect(ClaudeEnvelope.classify(exitCode: 1, stdout: env(403), stderr: Data()) == .notLoggedIn)
    }

    /// A non-error run's `result` is model prose about the paper — never error text.
    @Test func modelTextIsNotPatternMatched() {
        let stdout = Data("""
        {"type":"result","subtype":"success","is_error":false,"result":"The API rate limit reached 429 and the server was overloaded. Not logged in users…","structured_output":null}
        """.utf8)
        guard case .invalidOutput = ClaudeEnvelope.classify(exitCode: 0, stdout: stdout, stderr: Data()) else {
            Issue.record("model prose must not be classified as an error"); return
        }
    }

    @Test func isErrorBlocksSuccessEvenWithStructuredOutput() {
        let stdout = Data("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"boom\",\"structured_output\":{\"tldr\":\"x\"}}".utf8)
        guard case .generic(let msg) = ClaudeEnvelope.classify(exitCode: 1, stdout: stdout, stderr: Data()) else {
            Issue.record("expected generic"); return
        }
        #expect(msg.contains("boom"))
    }

    @Test func unparseableAndEmptyOutput() {
        guard case .generic(let a) = ClaudeEnvelope.classify(exitCode: 0, stdout: Data(), stderr: Data()) else {
            Issue.record("expected generic"); return
        }
        #expect(a.contains("empty"))
        guard case .generic(let b) = ClaudeEnvelope.classify(exitCode: 1, stdout: Data("segfault\n".utf8),
                                                             stderr: Data("trace".utf8)) else {
            Issue.record("expected generic"); return
        }
        #expect(b.contains("exit 1"))
        #expect(b.contains("segfault"))
    }

    @Test func lenientScalarsNeverTrap() throws {
        let stdout = Data("""
        {"subtype":"success","is_error":"false","total_cost_usd":"0.5","duration_ms":1e300,"num_turns":"3","api_error_status":null,"usage":{"input_tokens":-1e300,"output_tokens":"12"},"modelUsage":null,"structured_output":{"tldr":"x"}}
        """.utf8)
        let env = try #require(ClaudeEnvelope.parse(stdout))
        #expect(env.isError == false)
        #expect(env.totalCostUSD == 0.5)
        #expect(env.durationMs == nil)
        #expect(env.numTurns == 3)
        #expect(env.outputTokens == 12)
        #expect(env.model == nil)
        #expect(env.isSuccess)
    }

    @Test func nonEnvelopeJSONIsRejected() {
        #expect(ClaudeEnvelope.parse(Data("{\"hello\":1}".utf8)) == nil)
        #expect(ClaudeEnvelope.parse(Data("[1,2]".utf8)) == nil)
        #expect(ClaudeEnvelope.parse(Data()) == nil)
    }
}
