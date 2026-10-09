import Foundation

/// The JSONL event stream `codex exec --json` prints on stdout, decoded leniently:
/// `thread.started`, `turn.started`, `item.started/updated/completed` (`agent_message`,
/// `reasoning`, `error`, …), `turn.completed {usage}`, `turn.failed {error}` and `error {message}`.
/// Unknown event types and non-JSON lines are skipped (counted in `skippedLines`).
package struct CodexEvents: Sendable, Equatable {
    package struct Usage: Sendable, Equatable {
        /// Everything the model read (cached tokens are a subset, as in the Responses API).
        package var inputTokens: Int
        package var cachedInputTokens: Int
        /// Everything the model wrote (reasoning tokens are a subset).
        package var outputTokens: Int
        package var reasoningOutputTokens: Int

        package init(inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0,
                     reasoningOutputTokens: Int = 0) {
            self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens; self.reasoningOutputTokens = reasoningOutputTokens
        }
    }

    package var threadID: String?
    /// `item.completed` agent messages, in order. Model-authored: never pattern-matched.
    package var agentMessages: [String] = []
    /// The newest agent-message text seen in `item.started` / `item.updated` / `item.completed`
    /// (the full text so far; the assist lane shows it as a replace). Model-authored: never
    /// pattern-matched, and not used by the card path (`agentMessages` is).
    package var latestAgentText: String?
    /// Top-level `error` events. Some are transient (stream reconnects) and followed by success.
    package var errors: [String] = []
    /// `turn.failed` → `error.message`.
    package var turnFailures: [String] = []
    /// `item.completed` items of type `error` (non-fatal warnings).
    package var itemErrors: [String] = []
    package var turnsCompleted = 0
    /// Summed over `turn.completed` events; nil when none carried usage.
    package var usage: Usage?
    package var skippedLines = 0

    package init() {}

    package var lastAgentMessage: String? { agentMessages.last }
    package var failed: Bool { !turnFailures.isEmpty }
    package var isEmpty: Bool {
        threadID == nil && agentMessages.isEmpty && errors.isEmpty && turnFailures.isEmpty
            && itemErrors.isEmpty && turnsCompleted == 0
    }

    // MARK: - Parsing

    package static func parse(_ stdout: Data) -> CodexEvents {
        var events = CodexEvents()
        for line in String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            events.feed(line: line)
        }
        return events
    }

    /// One JSONL line (`parse` feeds every line; the assist lane feeds them as they arrive).
    /// Returns the event's type and value, nil for a skipped line.
    @discardableResult
    package mutating func feed<S: StringProtocol>(line: S) -> (type: String, event: JSONValue)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let v = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              let type = v["type"]?.stringValue else {
            if !trimmed.isEmpty { skippedLines += 1 }
            return nil
        }
        apply(type: type, event: v)
        return (type, v)
    }

    private mutating func apply(type: String, event v: JSONValue) {
        switch type {
        case "thread.started":
            threadID = v["thread_id"]?.stringValue ?? threadID
        case "item.started", "item.updated":
            guard let item = v["item"], Self.isAgentMessage(item), let text = item["text"]?.stringValue else { return }
            latestAgentText = text
        case "item.completed":
            guard let item = v["item"] else { return }
            switch item["type"]?.stringValue ?? item["item_type"]?.stringValue {
            case "agent_message"?, "assistant_message"?:
                if let text = item["text"]?.stringValue {
                    agentMessages.append(text)
                    latestAgentText = text
                }
            case "error"?:
                if let m = Self.message(item) { itemErrors.append(m) }
            default:
                break
            }
        case "turn.completed":
            turnsCompleted += 1
            if let u = v["usage"], u.objectValue != nil {
                var sum = usage ?? Usage()
                sum.inputTokens += Self.int(u["input_tokens"]) ?? 0
                sum.cachedInputTokens += Self.int(u["cached_input_tokens"]) ?? 0
                sum.outputTokens += Self.int(u["output_tokens"]) ?? 0
                sum.reasoningOutputTokens += Self.int(u["reasoning_output_tokens"]) ?? 0
                usage = sum
            }
        case "turn.failed":
            turnFailures.append(Self.message(v["error"]) ?? Self.message(v) ?? "turn failed")
        case "error":
            if let m = Self.message(v) ?? Self.message(v["error"]) { errors.append(m) }
        default:
            break
        }
    }

    /// An `agent_message` (or `assistant_message`) item.
    package static func isAgentMessage(_ item: JSONValue) -> Bool {
        let type = item["type"]?.stringValue ?? item["item_type"]?.stringValue
        return type == "agent_message" || type == "assistant_message"
    }

    /// `message` as a string, or the nested `{error:{message}}` / raw JSON of an API error body.
    private static func message(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        if let s = v.stringValue { return s.isEmpty ? nil : s }
        if let m = v["message"] {
            if let s = m.stringValue, !s.isEmpty { return s }
            if m.objectValue != nil { return m.compactString() }
        }
        return nil
    }

    private static func int(_ v: JSONValue?) -> Int? {
        switch v {
        case .number(let n)? where n.isFinite && abs(n) < 9.0e15: return Int(n.rounded())
        case .string(let s)?: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    // MARK: - Final message

    /// The card object from a final message: plain JSON, a ```json fence, or the first balanced
    /// `{…}` in surrounding prose. Anything that is not a JSON object → nil.
    package static func decodeCard(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let v = object(trimmed) { return v }
        if let fenced = fencedBody(trimmed), let v = object(fenced) { return v }
        if let braces = firstBalancedObject(trimmed), let v = object(braces) { return v }
        return nil
    }

    private static func object(_ s: String) -> JSONValue? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)), v.objectValue != nil else {
            return nil
        }
        return v
    }

    /// The body of the first ``` fence (an info string such as `json` is skipped).
    private static func fencedBody(_ s: String) -> String? {
        guard let open = s.range(of: "```") else { return nil }
        var rest = s[open.upperBound...]
        if let nl = rest.firstIndex(where: \.isNewline) { rest = rest[rest.index(after: nl)...] } else { return nil }
        guard let close = rest.range(of: "```") else { return String(rest) }
        return String(rest[..<close.lowerBound])
    }

    /// The first `{ … }` whose braces balance outside JSON strings.
    private static func firstBalancedObject(_ s: String) -> String? {
        let chars = Array(s.unicodeScalars)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false
            var j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        var view = String.UnicodeScalarView()
                        view.append(contentsOf: chars[i...j])
                        return String(view)
                    }
                }
                j += 1
            }
            return nil                                  // unbalanced to the end
        }
        return nil
    }

    // MARK: - Classification

    package enum Classification: Sendable, Equatable {
        case success(card: JSONValue)
        case usageLimit(resetsAt: Date?)
        case overloaded
        case notLoggedIn
        case invalidOutput(String)
        case binaryMissing
        case generic(String)
    }

    /// The Codex error table. Only diagnostics are pattern-matched (`error` / `turn.failed`
    /// events, error items, stderr) — never the model's own messages or `last.json`, so a paper
    /// about rate limits cannot pause the queue.
    ///
    /// - Parameter lastMessage: the `-o` file's content; empty or nil falls back to the last
    ///   `agent_message` in the stream.
    package static func classify(exitCode: Int32, events: CodexEvents, lastMessage: String?, stderr: Data,
                                 now: Date = Date(), timeZone: TimeZone = .current) -> Classification {
        if exitCode == 126 || exitCode == 127 { return .binaryMissing }

        let fileText = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalText = fileText.isEmpty ? (events.lastAgentMessage ?? "") : fileText
        let completed = !events.failed && (exitCode == 0 || events.turnsCompleted > 0)
        if completed, let card = decodeCard(finalText) { return .success(card: card) }
        if !events.failed, events.turnsCompleted > 0 {
            // The turn finished, so transient errors on the way (reconnects) are not the cause:
            // its final message is simply no card.
            return invalidFinalMessage(finalText)
        }

        let text = diagnosticsText(events: events, stderr: stderr)
        if let failure = diagnosticFailure(text, now: now, timeZone: timeZone) { return failure }
        if completed, !finalText.isEmpty { return invalidFinalMessage(finalText) }
        if exitCode == 0, events.isEmpty, text.isEmpty { return .generic("empty output from codex") }
        return .generic("exit \(exitCode): " + snippet(text))
    }

    /// The error table alone, for a run without the card's success checks (the interactive assist,
    /// dive-cli §4.2): `error` / `turn.failed` events, error items and stderr — never an agent
    /// message or the `-o` file.
    package static func classifyFailure(events: CodexEvents, stderr: Data, exitCode: Int32,
                                        now: Date = Date(), timeZone: TimeZone = .current) -> Classification {
        if exitCode == 126 || exitCode == 127 { return .binaryMissing }
        let text = diagnosticsText(events: events, stderr: stderr)
        if let failure = diagnosticFailure(text, now: now, timeZone: timeZone) { return failure }
        if exitCode == 0, events.isEmpty, text.isEmpty { return .generic("empty output from codex") }
        return .generic("exit \(exitCode): " + snippet(text))
    }

    /// Everything the table may read: diagnostics events and stderr, never model text.
    private static func diagnosticsText(events: CodexEvents, stderr: Data) -> String {
        let errText = String(decoding: stderr, as: UTF8.self)
        let diagnostics = events.turnFailures + events.errors + events.itemErrors + [errText]
        return diagnostics.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Usage limit, schema, HTTP status, login and overload rows; nil when none matched.
    private static func diagnosticFailure(_ text: String, now: Date, timeZone: TimeZone) -> Classification? {
        if matches(text, usageLimitPattern) {
            return .usageLimit(resetsAt: CodexUsageLimitParser.resetDate(in: text, now: now, timeZone: timeZone))
        }
        if let r = text.range(of: schemaPattern, options: .regularExpression) {
            // Start at the line of the complaint: the API's explanation ("Invalid schema … Missing 'doi'")
            // matters most, and the 300-character snippet must not be spent on earlier lines.
            let from = text.range(of: #"(?i)invalid schema"#, options: .regularExpression)?.lowerBound ?? r.lowerBound
            let lineStart = text[..<from].lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            return .invalidOutput("schema: " + snippet(String(text[lineStart...])))
        }
        // Explicit HTTP statuses outrank wording (stderr noise may mention "login" on a 503).
        let statuses = httpStatuses(in: text)
        if statuses.contains(401) { return .notLoggedIn }
        if statuses.contains(where: { $0 == 429 || (500...599).contains($0) }) { return .overloaded }
        if matches(text, notLoggedInPattern) { return .notLoggedIn }
        if matches(text, overloadedPattern) { return .overloaded }
        return nil
    }

    private static func invalidFinalMessage(_ text: String) -> Classification {
        text.isEmpty ? .invalidOutput("empty final message")
                     : .invalidOutput("final message is not a JSON object: " + snippet(text))
    }

    /// ChatGPT-plan limits ("You've hit your usage limit …", `usage_limit_reached`, "Quota exceeded.
    /// Check your plan and billing details.").
    private static let usageLimitPattern =
        #"(?i)usage[ _]limit|hit your .*limit|rate limit.*plan|reached your .*limit|quota exceeded"#
    /// OpenAI strict-mode rejections (HTTP 400 `invalid_json_schema`) and Codex's own schema-file errors.
    private static let schemaPattern = #"(?i)invalid_json_schema|invalid schema|output[ _]schema"#
    private static let notLoggedInPattern =
        #"(?i)unauthori[sz]ed|not logged in|not signed in|\blog ?in\b|sign in|refresh token|access token|token (has )?expired|token_expired|token data is not available|no codex credentials|invalid_api_key"#
    private static let overloadedPattern =
        #"(?i)overloaded|temporarily unavailable|service unavailable|server[_ ]error|internal server error|bad gateway|gateway timeout|too many requests|stream disconnected|high demand|at capacity"#

    /// HTTP statuses named in diagnostics: "unexpected status 401 Unauthorized", "last status: 429",
    /// "HTTP 503", "status code 502".
    package static func httpStatuses(in text: String) -> Set<Int> {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b(?:status(?:\s+code)?|http(?:/\d(?:\.\d)?)?)\s*[:=]?\s*(\d{3})\b"#)
        else { return [] }
        let ns = text as NSString
        var out = Set<Int>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))) { out.insert(n) }
        }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    package static func snippet(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " | ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : (flat.isEmpty ? "no diagnostics" : flat)
    }
}

/// Reset times from Codex usage-limit messages:
/// "… Try again at 3:45 PM.", "… or try again at Oct 2nd, 2026 9:00 AM.", "try again at Oct 2, 9:00 AM",
/// "try again in 2 hours", "try again in 1 day 3 hours 5 minutes". "Try again later." → nil.
///
/// Times without a date resolve to their next occurrence in `timeZone` (Codex prints local time).
/// A time that passed less than `tolerance` ago is kept as is (the limit has just reset).
package enum CodexUsageLimitParser {
    package static let tolerance: TimeInterval = 5 * 60

    package static func resetDate(in text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        if let d = relative(text, now: now) { return d }
        return absolute(text, now: now, timeZone: timeZone)
    }

    private static let unitPattern =
        #"(\d{1,4})\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#

    private static func relative(_ text: String, now: Date) -> Date? {
        let pattern = #"(?i)try again in\s+((?:\d{1,4}\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[\s,]*(?:and\s+)?)+)"#
        guard let m = matches(pattern, in: text).first, let phrase = m[1] else { return nil }
        var seconds = 0
        for unit in matches("(?i)" + unitPattern, in: phrase) {
            guard let n = unit[1].flatMap({ Int($0) }), let u = unit[2]?.lowercased().first else { continue }
            switch u {
            case "d": seconds += n * 86_400
            case "h": seconds += n * 3600
            case "m": seconds += n * 60
            default: seconds += n
            }
        }
        return seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static let absolutePattern = #"(?i)try again (?:at|on)\s+(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:(\d{4}),?\s+)?(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?"#

    private static func absolute(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        for m in matches(absolutePattern, in: text) {
            if let d = absolute(m, now: now, timeZone: timeZone) { return d }
        }
        return nil
    }

    private static func absolute(_ m: [String?], now: Date, timeZone: TimeZone) -> Date? {
        guard let hourText = m[4], var hour = Int(hourText) else { return nil }
        let minute = m[5].flatMap { Int($0) } ?? 0
        if let meridiem = m[6]?.lowercased().first {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        } else {
            guard m[5] != nil, (0...23).contains(hour) else { return nil }     // bare "at 3" is ambiguous
        }
        guard (0...59).contains(minute) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year else { return nil }

        if let monthText = m[1]?.lowercased().prefix(3), let monthIndex = months.firstIndex(of: String(monthText)),
           let dayText = m[2], let day = Int(dayText) {
            if let y = m[3].flatMap({ Int($0) }) { return make(cal, y, monthIndex + 1, day, hour, minute) }
            for y in [year, year + 1] {
                guard let d = make(cal, y, monthIndex + 1, day, hour, minute) else { return nil }
                if d >= now.addingTimeInterval(-tolerance) { return d }
            }
            return nil
        }

        guard let month = today.month, let day = today.day,
              let todayAt = make(cal, year, month, day, hour, minute) else { return nil }
        if todayAt >= now.addingTimeInterval(-tolerance) { return todayAt }
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: todayAt) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: tomorrow)
        guard let ty = c.year, let tm = c.month, let td = c.day else { return nil }
        return make(cal, ty, tm, td, hour, minute)
    }

    private static func make(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date? {
        let comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)
        guard comps.isValidDate(in: cal) else { return nil }
        return cal.date(from: comps)
    }

    /// Capture groups per match (nil for groups that did not participate).
    private static func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }
}
