import Foundation

/// The single JSON object `claude -p --output-format json` prints.
/// The envelope is not formally versioned, so every field is optional and
/// decoded leniently (numbers may arrive as strings, flags as "true").
package struct ClaudeEnvelope: Sendable, Equatable {
    package var type: String?
    package var subtype: String?
    package var isError: Bool?
    package var result: String?
    package var structuredOutput: JSONValue?     // nil for missing or JSON null
    package var totalCostUSD: Double?
    package var usage: JSONValue?
    package var modelUsage: JSONValue?
    package var durationMs: Int?
    package var numTurns: Int?
    package var apiErrorStatus: Int?
    package var sessionID: String?

    package init(type: String? = nil, subtype: String? = nil, isError: Bool? = nil, result: String? = nil,
                 structuredOutput: JSONValue? = nil, totalCostUSD: Double? = nil, usage: JSONValue? = nil,
                 modelUsage: JSONValue? = nil, durationMs: Int? = nil, numTurns: Int? = nil,
                 apiErrorStatus: Int? = nil, sessionID: String? = nil) {
        self.type = type; self.subtype = subtype; self.isError = isError; self.result = result
        self.structuredOutput = structuredOutput; self.totalCostUSD = totalCostUSD; self.usage = usage
        self.modelUsage = modelUsage; self.durationMs = durationMs; self.numTurns = numTurns
        self.apiErrorStatus = apiErrorStatus; self.sessionID = sessionID
    }

    /// `subtype=="success" && is_error!=true && structured_output!=null`.
    package var isSuccess: Bool { subtype == "success" && isError != true && structuredOutput != nil }

    /// The case that triggers the argv A→B switch: the run "succeeded" but the
    /// StructuredOutput tool never produced anything (possibly hidden by `--tools ""`).
    package var isSuccessWithoutStructuredOutput: Bool {
        subtype == "success" && isError != true && structuredOutput == nil
    }

    /// Prompt + cache writes + cache reads: everything the model had to read.
    package var inputTokens: Int? {
        let parts = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { Self.int(usage?[$0]) }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    package var outputTokens: Int? { Self.int(usage?["output_tokens"]) }

    /// The model that did most of the work (fallback runs list several).
    package var model: String? {
        guard let models = modelUsage?.objectValue, !models.isEmpty else { return nil }
        func weight(_ v: JSONValue) -> Double {
            Self.double(v["costUSD"]) ?? Double(Self.int(v["outputTokens"]) ?? 0)
        }
        return models.max { a, b in
            weight(a.value) != weight(b.value) ? weight(a.value) < weight(b.value) : a.key > b.key
        }?.key
    }

    // MARK: - Parsing

    /// Whole stdout first; if that fails (warning lines before/after the JSON),
    /// the last line starting with "{".
    package static func parse(_ stdout: Data) -> ClaudeEnvelope? {
        if let v = try? JSONDecoder().decode(JSONValue.self, from: stdout), let env = from(v) { return env }
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { continue }
            if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) { return from(v) }
            return nil
        }
        return nil
    }

    package static func from(_ v: JSONValue) -> ClaudeEnvelope? {
        guard let o = v.objectValue else { return nil }
        let known = ["type", "subtype", "is_error", "result", "structured_output", "session_id"]
        guard known.contains(where: { o[$0] != nil }) else { return nil }
        let structured = o["structured_output"].flatMap { $0.isNull ? nil : $0 }
        return ClaudeEnvelope(
            type: o["type"]?.stringValue,
            subtype: o["subtype"]?.stringValue,
            isError: bool(o["is_error"]),
            result: o["result"]?.stringValue,
            structuredOutput: structured,
            totalCostUSD: double(o["total_cost_usd"]),
            usage: o["usage"].flatMap { $0.isNull ? nil : $0 },
            modelUsage: o["modelUsage"].flatMap { $0.isNull ? nil : $0 },
            durationMs: int(o["duration_ms"]),
            numTurns: int(o["num_turns"]),
            apiErrorStatus: int(o["api_error_status"]),
            sessionID: o["session_id"]?.stringValue
        )
    }

    // MARK: - Classification

    package enum Classification: Sendable, Equatable {
        case success(card: JSONValue)
        case usageLimit(resetsAt: Date?)
        case overloaded
        case notLoggedIn
        case maxTurns
        case invalidOutput(String)
        case binaryMissing
        case generic(String)
    }

    /// The §3.1 error table. Model-authored text (the `result` of a non-error
    /// run) is never pattern-matched: a paper summary mentioning a "rate limit
    /// reached" must not pause the queue for an hour.
    package static func classify(exitCode: Int32, stdout: Data, stderr: Data,
                                 now: Date = Date(), timeZone: TimeZone = .current) -> Classification {
        classify(exitCode: exitCode, envelope: parse(stdout), stdout: stdout, stderr: stderr,
                 now: now, timeZone: timeZone)
    }

    package static func classify(exitCode: Int32, envelope env: ClaudeEnvelope?, stdout: Data, stderr: Data,
                                 now: Date = Date(), timeZone: TimeZone = .current) -> Classification {
        if exitCode == 126 || exitCode == 127 { return .binaryMissing }
        if let env, env.isSuccess, let card = env.structuredOutput { return .success(card: card) }

        let errText = String(decoding: stderr, as: UTF8.self)
        var diagnostics = [errText]
        if let env {
            if env.isError == true || exitCode != 0, let r = env.result { diagnostics.append(r) }
        } else {
            diagnostics.append(String(decoding: stdout, as: UTF8.self))
        }
        let text = diagnostics.joined(separator: "\n")
        let status = env?.apiErrorStatus

        if status == 429 || matches(text, usageLimitPattern) {
            return .usageLimit(resetsAt: UsageLimitParser.resetDate(in: text, now: now, timeZone: timeZone))
        }
        if status == 529 || matches(text, overloadedPattern) { return .overloaded }
        if status == 401 || status == 403 || matches(text, notLoggedInPattern) { return .notLoggedIn }

        switch env?.subtype {
        case "error_max_turns"?:
            return .maxTurns
        case "error_max_structured_output_retries"?:
            return .invalidOutput("structured output retries exhausted (error_max_structured_output_retries)")
        default:
            break
        }
        if let env, env.isSuccessWithoutStructuredOutput {
            return .invalidOutput("run succeeded but structured_output is null")
        }
        if env == nil, exitCode == 0 {
            return .generic(stdout.isEmpty ? "empty output from claude" : "unparseable output: \(snippet(text))")
        }
        let what = env?.subtype.map { "\($0): " } ?? ""
        return .generic("exit \(exitCode): \(what)\(snippet(text))")
    }

    /// How an interactive assist turn ended (`classifyTurn`).
    package enum TurnClassification: Sendable, Equatable {
        /// The answer: the result line's `result` (nil or empty → the streamed text).
        case success(text: String?)
        case failure(Classification)
    }

    /// One assist turn (dive-cli §3.3). Success = `subtype == "success" && is_error != true` — no
    /// structured output is involved. Anything else runs the §3.1 table above with EMPTY stdout,
    /// so the streamed, model-authored text is never pattern-matched: only the result line's own
    /// error text (when `is_error` is set) and stderr are. No result line at all (the process died
    /// first) → the exit code and stderr only. `exitCode` nil: the process is still running.
    package static func classifyTurn(result env: ClaudeEnvelope?, stderr: Data, exitCode: Int32?,
                                     now: Date = Date(), timeZone: TimeZone = .current) -> TurnClassification {
        if let env, env.subtype == "success", env.isError != true { return .success(text: env.result) }
        return .failure(classify(exitCode: exitCode ?? 0, envelope: env, stdout: Data(), stderr: stderr,
                                 now: now, timeZone: timeZone))
    }

    /// The §3.1 pattern plus "reached your … limit" (Opus/Sonnet weekly wording).
    private static let usageLimitPattern = #"(?i)(hit your|usage) .*limit|limit reached|reached your .*limit"#
    private static let overloadedPattern = #"(?i)overloaded"#
    private static let notLoggedInPattern =
        // 2.1.286 wording seen 2026-10-01: "Failed to authenticate: OAuth session expired and could not be refreshed".
        #"(?i)not logged in|please run /login|oauth token refresh failed|oauth (token|session) (has )?expired|failed to authenticate|could not be refreshed|invalid api key"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func snippet(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " | ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : (flat.isEmpty ? "no diagnostics" : flat)
    }

    // MARK: - Lenient scalars

    fileprivate static func double(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)? where n.isFinite: return n
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// Never traps on NaN/∞/huge values (unlike `Int(Double)`).
    fileprivate static func int(_ v: JSONValue?) -> Int? {
        guard let d = double(v), abs(d) < 9.0e15 else { return nil }
        return Int(d.rounded())
    }

    private static func bool(_ v: JSONValue?) -> Bool? {
        switch v {
        case .bool(let b)?: return b
        case .string(let s)?: return ["true", "1", "yes"].contains(s.lowercased()) ? true
            : (["false", "0", "no"].contains(s.lowercased()) ? false : nil)
        case .number(let n)?: return n != 0
        default: return nil
        }
    }
}

/// Reset times from usage-limit messages, e.g. "resets 3:45pm", "resets 3pm",
/// "resets Oct 2, 9am", "resets 9am (America/New_York)", "resets in 2h 30m",
/// and the legacy "Claude AI usage limit reached|<epoch seconds>".
///
/// Times are resolved to their next occurrence. A time that passed less than
/// `tolerance` ago is kept as is (the limit has just reset) rather than being
/// pushed a whole day or year out by a few seconds of clock skew.
package enum UsageLimitParser {
    package static let tolerance: TimeInterval = 5 * 60

    package static func resetDate(in text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        if let d = legacy(text) { return d }
        if let d = relative(text, now: now) { return d }
        return absolute(text, now: now, timeZone: timeZone)
    }

    private static func legacy(_ text: String) -> Date? {
        guard let m = firstMatch(#"limit reached\|(\d{9,13})"#, in: text), let raw = m[1], let n = Double(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    private static func relative(_ text: String, now: Date) -> Date? {
        let pattern = #"(?i)resets?\s+in\s+(?:(\d{1,3})\s*(?:h|hr|hrs|hours?))?\s*(?:(\d{1,4})\s*(?:m|min|mins|minutes?))?"#
        guard let m = firstMatch(pattern, in: text) else { return nil }
        let hours = m[1].flatMap { Int($0) } ?? 0
        let minutes = m[2].flatMap { Int($0) } ?? 0
        guard hours > 0 || minutes > 0 else { return nil }
        return now.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static let absolutePattern = #"(?i)resets?\s+(?:at\s+|on\s+)?(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]\.?m\.?)?(?:\s*\(([^)\s]{1,64})\))?"#

    /// The first "resets …" phrase that parses; earlier false positives are skipped.
    private static func absolute(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        for m in matches(absolutePattern, in: text) {
            if let d = absolute(m, now: now, timeZone: timeZone) { return d }
        }
        return nil
    }

    private static func absolute(_ m: [String?], now: Date, timeZone fallbackZone: TimeZone) -> Date? {
        guard let hourText = m[3], var hour = Int(hourText) else { return nil }
        let minute = m[4].flatMap { Int($0) } ?? 0
        if let meridiem = m[5]?.lowercased().first {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        } else {
            guard m[4] != nil, (0...23).contains(hour) else { return nil }   // bare "resets 3" is ambiguous
        }
        guard (0...59).contains(minute) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = m[6].flatMap { TimeZone(identifier: $0) ?? TimeZone(abbreviation: $0) } ?? fallbackZone
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year else { return nil }

        if let monthText = m[1]?.lowercased().prefix(3), let monthIndex = months.firstIndex(of: String(monthText)),
           let dayText = m[2], let day = Int(dayText) {
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

    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        matches(pattern, in: text).first
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
