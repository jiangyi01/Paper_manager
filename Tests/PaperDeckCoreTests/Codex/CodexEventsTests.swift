import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct CodexEventsTests {
    private static func fixture(_ name: String, _ ext: String = "jsonl") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/codex"))
        return try Data(contentsOf: url)
    }

    private static func classify(_ name: String, exit: Int32 = 1, last: String? = nil, stderr: String = "",
                                 now: Date = Date()) throws -> CodexEvents.Classification {
        CodexEvents.classify(exitCode: exit, events: CodexEvents.parse(try fixture(name)), lastMessage: last,
                             stderr: Data(stderr.utf8), now: now)
    }

    private static func events(_ lines: [String]) -> CodexEvents {
        CodexEvents.parse(Data(lines.joined(separator: "\n").utf8))
    }

    // MARK: parse

    @Test func parsesTheSuccessStream() throws {
        let e = CodexEvents.parse(try Self.fixture("jsonl-success"))
        #expect(e.threadID == "0199a213-81c0-7800-8aa1-bbab2a035a53")
        #expect(e.agentMessages.count == 1)                  // the reasoning item is not a message
        #expect(e.turnsCompleted == 1)
        #expect(!e.failed)
        #expect(e.usage == .init(inputTokens: 41888, cachedInputTokens: 20480, outputTokens: 1834,
                                 reasoningOutputTokens: 912))
        #expect(e.errors.isEmpty && e.turnFailures.isEmpty && e.skippedLines == 0)
    }

    @Test func parsesFailuresAndSkipsNoise() {
        let e = Self.events([
            "Reading additional input from stdin...",
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"item.started","item":{"id":"i0","type":"command_execution","command":"ls"}}"#,
            #"{"type":"some.future.event","x":1}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"error","message":"model metadata missing"}}"#,
            #"{"type":"error","message":"boom"}"#,
            #"{"type":"turn.failed","error":{"message":"boom"}}"#,
            "{not json",
        ])
        #expect(e.threadID == "t1")
        #expect(e.errors == ["boom"] && e.turnFailures == ["boom"] && e.itemErrors == ["model metadata missing"])
        #expect(e.failed && e.turnsCompleted == 0 && e.usage == nil)
        #expect(e.skippedLines == 2)
    }

    @Test func usageIsSummedAndLenient() {
        let e = Self.events([
            #"{"type":"turn.completed","usage":{"input_tokens":"100","cached_input_tokens":10,"output_tokens":5}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1e2,"output_tokens":null}}"#,
            #"{"type":"turn.completed"}"#,
        ])
        #expect(e.turnsCompleted == 3)
        #expect(e.usage == .init(inputTokens: 200, cachedInputTokens: 10, outputTokens: 5, reasoningOutputTokens: 0))
    }

    // MARK: final message

    @Test func decodeCardIsLenient() {
        #expect(CodexEvents.decodeCard(#"{"a":1}"#) == .object(["a": .number(1)]))
        #expect(CodexEvents.decodeCard("  \n```json\n{\"a\":\"x\"}\n```\n") == .object(["a": .string("x")]))
        #expect(CodexEvents.decodeCard("```\n{\"a\":2}\n```") == .object(["a": .number(2)]))
        #expect(CodexEvents.decodeCard(#"Sure! {"a":"}{","b":{"c":[1]}} Hope this helps {x}"#)
                == .object(["a": .string("}{"), "b": .object(["c": .array([.number(1)])])]))
        #expect(CodexEvents.decodeCard(#"{"a":"quote \" and brace }"}"#) == .object(["a": .string("quote \" and brace }")]))
        #expect(CodexEvents.decodeCard("[1,2]") == nil)
        #expect(CodexEvents.decodeCard("\"text\"") == nil)
        #expect(CodexEvents.decodeCard("") == nil)
        #expect(CodexEvents.decodeCard("no json {here") == nil)
    }

    // MARK: classify

    @Test func successFromTheLastMessageFileWins() throws {
        let file = String(decoding: try Self.fixture("last-message-card", "json"), as: UTF8.self)
        let other = #"{"tldr":"stale"}"#
        let e = Self.events([#"{"type":"item.completed","item":{"type":"agent_message","text":"\#(other.replacingOccurrences(of: "\"", with: "\\\""))"}}"#,
                             #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#])
        guard case .success(let card) = CodexEvents.classify(exitCode: 0, events: e, lastMessage: file, stderr: Data())
        else { Issue.record("expected success"); return }
        #expect(card["category"] == .string("AI Agents for Science"))
    }

    @Test func successFallsBackToTheStream() throws {
        for name in ["jsonl-success", "jsonl-success-fenced", "jsonl-reconnect-then-success"] {
            guard case .success(let card) = try Self.classify(name, exit: 0, last: "  \n") else {
                Issue.record("\(name): expected success"); continue
            }
            #expect(card["tldr"]?.stringValue?.isEmpty == false, "\(name)")
        }
    }

    /// Model-authored text (messages, reasoning, the -o file) is never pattern-matched.
    @Test func modelTextNeverTriggersErrorClasses() {
        let e = Self.events([
            #"{"type":"item.completed","item":{"type":"reasoning","text":"You've hit your usage limit"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"You've hit your usage limit. 401 Unauthorized, 503, not logged in"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#,
        ])
        guard case .invalidOutput(let m) = CodexEvents.classify(exitCode: 0, events: e, lastMessage: nil, stderr: Data())
        else { Issue.record("expected invalidOutput"); return }
        #expect(m.hasPrefix("final message is not a JSON object"))
    }

    @Test func proseAnswerIsInvalidOutput() throws {
        guard case .invalidOutput(let m) = try Self.classify("jsonl-prose-answer", exit: 0) else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(m.contains("I can't help"))
        let empty = Self.events([#"{"type":"item.completed","item":{"type":"agent_message","text":""}}"#,
                                 #"{"type":"turn.completed"}"#])
        #expect(CodexEvents.classify(exitCode: 0, events: empty, lastMessage: "", stderr: Data())
                == .invalidOutput("empty final message"))
    }

    /// Reconnect notices along a turn that completed do not turn a bad answer into "overloaded".
    @Test func transientErrorsBeforeACompletedTurnAreIgnored() {
        let e = Self.events([
            #"{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}"#,
            #"{"type":"item.completed","item":{"type":"error","message":"You've hit your usage limit (warning)"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Here you go"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#,
        ])
        #expect(CodexEvents.classify(exitCode: 0, events: e, lastMessage: nil, stderr: Data("503".utf8))
                == .invalidOutput("final message is not a JSON object: Here you go"))
        // Exit 0 without turn events but with an -o file that is not JSON.
        #expect(CodexEvents.classify(exitCode: 0, events: CodexEvents(), lastMessage: "oops", stderr: Data())
                == .invalidOutput("final message is not a JSON object: oops"))
    }

    @Test func usageLimitWithTodaysTime() throws {
        let now = Self.local(2026, 9, 30, 10, 0)
        #expect(try Self.classify("jsonl-usage-limit", now: now) == .usageLimit(resetsAt: Self.local(2026, 9, 30, 15, 45)))
        #expect(try Self.classify("jsonl-usage-limit-date", now: now)
                == .usageLimit(resetsAt: Self.local(2026, 10, 2, 9, 0)))
    }

    @Test func plainRateLimitVersusPlanLimit() {
        let e = Self.events([#"{"type":"turn.failed","error":{"message":"exceeded retry limit, last status: 429 Too Many Requests"}}"#])
        #expect(CodexEvents.classify(exitCode: 1, events: e, lastMessage: nil, stderr: Data()) == .overloaded)
        let plan = Self.events([#"{"type":"turn.failed","error":{"message":"429: rate limit reached for your plan; Try again later."}}"#])
        #expect(CodexEvents.classify(exitCode: 1, events: plan, lastMessage: nil, stderr: Data()) == .usageLimit(resetsAt: nil))
        let quota = Self.events([#"{"type":"error","message":"Quota exceeded. Check your plan and billing details."}"#])
        #expect(CodexEvents.classify(exitCode: 1, events: quota, lastMessage: nil, stderr: Data()) == .usageLimit(resetsAt: nil))
    }

    @Test func schemaErrors() throws {
        guard case .invalidOutput(let m) = try Self.classify("jsonl-schema-error") else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(m.hasPrefix("schema: unexpected status 400") && m.contains("Invalid schema for response_format")
                && m.contains("Missing 'doi'"))
        let file = CodexEvents.classify(exitCode: 1, events: CodexEvents(), lastMessage: nil,
                                        stderr: Data("Output schema file /x/schema.json is not valid JSON: EOF".utf8))
        guard case .invalidOutput(let m2) = file else { Issue.record("expected invalidOutput"); return }
        #expect(m2.hasPrefix("schema: "))
    }

    @Test func authErrors() throws {
        #expect(try Self.classify("jsonl-401") == .notLoggedIn)
        for text in ["Your access token could not be refreshed. Please log out and sign in again.",
                     "Token data is not available.", "Not logged in",
                     "no Codex credentials were found. Run codex login or provide an API key"] {
            let e = Self.events([#"{"type":"turn.failed","error":{"message":"\#(text)"}}"#])
            #expect(CodexEvents.classify(exitCode: 1, events: e, lastMessage: nil, stderr: Data()) == .notLoggedIn, "\(text)")
        }
        // stderr alone (the CLI died before any event)
        #expect(CodexEvents.classify(exitCode: 1, events: CodexEvents(), lastMessage: nil,
                                     stderr: Data("Error: Not logged in\n".utf8)) == .notLoggedIn)
    }

    @Test func transientServerErrors() throws {
        #expect(try Self.classify("jsonl-5xx") == .overloaded)
        for text in ["Selected model is at capacity. Please try a different model.",
                     "We're currently experiencing high demand, which may cause temporary errors.",
                     "stream disconnected before completion: idle timeout waiting for SSE",
                     "Server overloaded; retry later.", "unexpected status 502 Bad Gateway: <html>login</html>"] {
            let e = Self.events([#"{"type":"turn.failed","error":{"message":"\#(text)"}}"#])
            #expect(CodexEvents.classify(exitCode: 1, events: e, lastMessage: nil, stderr: Data()) == .overloaded, "\(text)")
        }
    }

    @Test func otherFailuresAreGeneric() {
        #expect(CodexEvents.classify(exitCode: 127, events: CodexEvents(), lastMessage: nil, stderr: Data()) == .binaryMissing)
        #expect(CodexEvents.classify(exitCode: 126, events: CodexEvents(), lastMessage: "{\"a\":1}", stderr: Data())
                == .binaryMissing)
        #expect(CodexEvents.classify(exitCode: 0, events: CodexEvents(), lastMessage: nil, stderr: Data())
                == .generic("empty output from codex"))
        let clap = CodexEvents.classify(exitCode: 2, events: CodexEvents(), lastMessage: nil,
                                        stderr: Data("error: unexpected argument '--frobnicate' found\n".utf8))
        #expect(clap == .generic("exit 2: error: unexpected argument '--frobnicate' found"))
        let plan = Self.events([#"{"type":"turn.failed","error":{"message":"To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus."}}"#])
        guard case .generic(let m) = CodexEvents.classify(exitCode: 1, events: plan, lastMessage: nil, stderr: Data()) else {
            Issue.record("expected generic"); return
        }
        #expect(m.contains("upgrade to Plus"))
        // A failed turn never counts as success, even with a parseable message.
        let failed = Self.events([#"{"type":"item.completed","item":{"type":"agent_message","text":"{\"a\":1}"}}"#,
                                  #"{"type":"turn.failed","error":{"message":"interrupted"}}"#])
        #expect(CodexEvents.classify(exitCode: 1, events: failed, lastMessage: nil, stderr: Data())
                == .generic("exit 1: interrupted"))
    }

    @Test func httpStatusExtraction() {
        #expect(CodexEvents.httpStatuses(in: "unexpected status 401 Unauthorized") == [401])
        #expect(CodexEvents.httpStatuses(in: "exceeded retry limit, last status: 429 Too Many Requests") == [429])
        #expect(CodexEvents.httpStatuses(in: "HTTP 503; http/1.1 502; status code: 500") == [503, 502, 500])
        #expect(CodexEvents.httpStatuses(in: "read 5000 tokens in 401 ms").isEmpty)
    }

    // MARK: usage-limit reset times

    private static func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func resetTimes() {
        let now = Self.local(2026, 9, 30, 10, 0)
        func parse(_ s: String) -> Date? { CodexUsageLimitParser.resetDate(in: s, now: now) }
        #expect(parse("You've hit your usage limit. Try again at 3:45 PM.") == Self.local(2026, 9, 30, 15, 45))
        #expect(parse("try again at 9:00 AM") == Self.local(2026, 10, 1, 9, 0))           // passed → tomorrow
        #expect(parse("try again at 9:58 AM") == Self.local(2026, 9, 30, 9, 58))          // within tolerance
        #expect(parse("try again at 12:30 AM") == Self.local(2026, 10, 1, 0, 30))
        #expect(parse("or try again at Oct 2nd, 2026 9:00 AM.") == Self.local(2026, 10, 2, 9, 0))
        #expect(parse("try again at Oct 2, 9:00 AM") == Self.local(2026, 10, 2, 9, 0))
        #expect(parse("try again at Jan 3rd, 9:00 PM") == Self.local(2027, 1, 3, 21, 0))  // next occurrence
        #expect(parse("try again at Jan 5th, 2027 12:30 AM") == Self.local(2027, 1, 5, 0, 30))
        #expect(parse("try again at 17:05") == Self.local(2026, 9, 30, 17, 5))
        #expect(parse("try again in 2 hours") == now.addingTimeInterval(7200))
        #expect(parse("Try again in 1 day 3 hours 5 minutes.") == now.addingTimeInterval(86_400 + 10_800 + 300))
        #expect(parse("try again in 45 mins") == now.addingTimeInterval(2700))
        #expect(parse("try again in 2h 30m") == now.addingTimeInterval(9000))
        #expect(parse("Try again later.") == nil)
        #expect(parse("try again at 13:61") == nil)
        #expect(parse("try again at 3") == nil)                                        // ambiguous
        #expect(parse("no time here") == nil)
    }
}
