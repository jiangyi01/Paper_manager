import Foundation

/// Zero-quota stand-in for Claude (agent.mode=mock, `--selftest`, tests).
/// Cards are deterministic functions of the stdin blocks and always pass
/// `CardSanitizer`; the UI marks them with a MOCK badge (`ai.provider="mock"`).
/// Mail-triage requests (`MailTriageSchema.isTriageRequest`) get a deterministic triage
/// instead (`triage(for:)`), which passes `MailTriageSanitizer`.
/// Failure modes can be scripted per call to exercise AgentQueue.
package actor MockAgentProvider: AgentProvider {
    package enum Behavior: Sendable, Equatable {
        case success
        /// Sleeps for the whole request timeout, then reports what the watchdog would: `.timeout`.
        case hang
        case usageLimit(resetsAt: Date?)
        case invalidOutput
        case notLoggedIn
    }

    package nonisolated let id = "mock"

    private var fallback: Behavior
    private var script: [Behavior]
    private let delay: Duration
    package private(set) var calls = 0
    package private(set) var lastRequest: CardRequest?

    /// `script` is consumed one behavior per `generateCard`; afterwards `behavior` applies.
    package init(behavior: Behavior = .success, script: [Behavior] = [], delay: Duration = .zero) {
        self.fallback = behavior; self.script = script; self.delay = delay
    }

    package func setBehavior(_ b: Behavior) { fallback = b }
    package func enqueue(_ b: Behavior...) { script += b }

    package func detect() async -> ProviderStatus {
        if (script.first ?? fallback) == .notLoggedIn { return .notLoggedIn(ProviderReason.loggedOut.code) }
        return .ready(plan: "mock", version: "0.0.0-mock", path: "mock")
    }

    package func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        calls += 1
        lastRequest = r
        let behavior = script.isEmpty ? fallback : script.removeFirst()
        let clock = ContinuousClock()
        let start = clock.now
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return .cancelled }
        }
        switch behavior {
        case .success:
            let card = MailTriageSchema.isTriageRequest(r) ? Self.triage(for: r) : Self.card(for: r)
            let elapsed = start.duration(to: clock.now).components
            return .success(card: card, meta: RunMeta(
                model: "mock", durationMs: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
                costUSD: 0, inputTokens: r.stdin.count / 4, outputTokens: card.compactString().utf8.count / 4,
                numTurns: 1, variant: nil))
        case .hang:
            do { try await Task.sleep(for: r.timeout) } catch { return .cancelled }
            return .timeout
        case .usageLimit(let resetsAt):
            return .usageLimit(resetsAt: resetsAt)
        case .invalidOutput:
            return .invalidOutput("mock provider: structured_output is null")
        case .notLoggedIn:
            return .notLoggedIn
        }
    }

    // MARK: - Deterministic card

    /// Title from `<metadata>` (else the paper's first line), five checklist
    /// steps spread over the pages, category = first value of the schema enum.
    package static func card(for r: CardRequest) -> JSONValue {
        let input = String(decoding: r.stdin, as: UTF8.self)
        let metadata = block("metadata", in: input)
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let paper = block("paper", in: input) ?? ""

        let pageMarkers = paper.components(separatedBy: "[[p. ").dropFirst()
            .compactMap { Int($0.prefix { $0.isNumber }) }
        let declared = metadata?["page_count"]?.doubleValue.flatMap { $0.isFinite && $0 >= 1 && $0 < 10_000 ? Int($0) : nil }
        let pages = (declared ?? pageMarkers.max()).map { min(max($0, 1), 10_000) }
        let source = metadata?["source"]?.stringValue ?? "none"
        let firstLine = paper.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("[[p.") }
        let title = metadata?["title"]?.stringValue ?? firstLine.map { String($0.prefix(200)) } ?? "Untitled paper"
        let category = r.schema["properties"]?["category"]?["enum"]?.arrayValue?.first?.stringValue
            ?? ReadingCard.newCategoryToken

        let estimated = min(max((pages ?? 12) * 4, 30), 120)
        let plan: [(task: String, section: String, kind: String, share: Int)] = [
            ("Read abstract; skim all figure titles", "Abstract", "overview", 10),
            ("Introduction: note the open question and the main claim", "Introduction", "other", 15),
            ("Results: write a one-line takeaway per main figure", "Results", "figure", 40),
            ("Methods: data sources, key parameters and statistical tests", "Methods", "method", 20),
            ("Discussion: note stated limitations and future work", "Discussion", "discussion", 15),
        ]
        var remaining = estimated
        let steps: [JSONValue] = plan.enumerated().map { i, s in
            let minutes = i == plan.count - 1 ? remaining : estimated * s.share / 100
            remaining -= minutes
            let page: JSONValue = pages.map { .number(Double(min($0, 1 + i * max($0 - 1, 0) / (plan.count - 1)))) } ?? .null
            return .object(["task": .string(s.task), "section": .string(s.section), "page": page,
                            "minutes": .number(Double(minutes)), "kind": .string(s.kind)])
        }

        let shortTitle = title.count > 60 ? String(title.prefix(59)) + "…" : title
        let extracted: JSONValue = source == "none"
            ? .object(["title": .string(title), "authors": .array([]), "year": .null, "venue": .null, "doi": .null])
            : .null
        let newCategory: JSONValue = category == ReadingCard.newCategoryToken
            ? .object(["name": .string("Uncategorized"), "description": .string("Mock category for demos")])
            : .null

        return .object([
            "extracted_metadata": extracted,
            "tldr": .string("MOCK card for \u{201C}\(shortTitle)\u{201D}, generated locally without AI."),
            "summary": .string("This is a deterministic mock reading card produced by PaperDeck for UI demos and tests. No model read the paper; the card only reflects its metadata and page count. Enable Claude in Settings to get a real summary."),
            "contributions": .array([.string("Provides a placeholder card for UI testing"),
                                     .string("Exercises the checklist and scheduling pipeline")]),
            "method": .string("No analysis performed (mock provider)."),
            "results": .array([.string("Mock output; enable Claude to generate a real reading card.")]),
            "limitations": .array([.object(["text": .string("Generated without reading the paper"),
                                            "source": .string("inferred")])]),
            "key_terms": .array([.object(["term": .string("Mock card"),
                                          "definition": .string("A placeholder reading card created without an AI model.")])]),
            "resources": .array([]),
            "paper_type": .string("other"),
            "category": .string(category),
            "new_category": newCategory,
            "tags": .array([.string("mock"), .string("demo"), .string("paperdeck")]),
            "difficulty": .string("medium"),
            "estimated_minutes": .number(Double(estimated)),
            "checklist": .array(steps),
            "text_quality": .string("good"),
        ])
    }

    // MARK: - Deterministic mail triage

    /// From the triage stdin: an email that mentions reading / presenting (en/zh) is a request
    /// (journal club / lab meeting → `journal_club`), an alert with candidates is an
    /// `alert_digest`; every candidate becomes a paper (≤ `max_alert_papers` for alerts). No due
    /// date, priority normal — the mock never invents commitments.
    package static func triage(for r: CardRequest) -> JSONValue {
        let input = String(decoding: r.stdin, as: UTF8.self)
        let email = (block("email", in: input) ?? "").trimmingCharacters(in: .newlines)
        let parts = email.components(separatedBy: "\n\n")
        let header = parts.first.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let body = parts.dropFirst().joined(separator: "\n\n")
        let candidates = block("candidates", in: input)
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }?.arrayValue ?? []
        let preferences = block("preferences", in: input)
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let maxAlert = preferences?["max_alert_papers"]?.intValue ?? 8

        let subject = header?["subject"]?.stringValue ?? ""
        let senderKind = header?["sender_kind"]?.stringValue ?? "person"
        let text = (subject + "\n" + body).lowercased()
        let range = NSRange(location: 0, length: (text as NSString).length)
        let asksToRead = readingRequest.firstMatch(in: text, range: range) != nil
            || ["读一下", "看一下", "读", "汇报"].contains { text.contains($0) }
        let journalClub = text.contains("journal club") || text.contains("lab meeting") || text.contains("组会")

        let kind: String
        if senderKind == "alert" {
            kind = candidates.isEmpty ? "not_paper" : "alert_digest"
        } else if journalClub {
            kind = "journal_club"
        } else if asksToRead {
            kind = "advisor_request"
        } else {
            kind = candidates.isEmpty ? "not_paper" : "fyi"
        }
        let request = kind == "journal_club" || kind == "advisor_request"
        let has = request || kind == "alert_digest"
        let relevance = request ? "requested" : kind == "alert_digest" ? "highlighted" : "listed"
        let papers: [JSONValue] = candidates.prefix(senderKind == "alert" ? max(0, maxAlert) : 20).map { c in
            .object([
                "ref": c["id"] ?? .null, "title": c["title"] ?? .null, "doi": c["doi"] ?? .null,
                "arxiv_id": c["arxiv_id"] ?? .null, "relevance": .string(relevance),
                "why": .string("MOCK triage: listed in the email"), "confidence": .number(0.8),
            ])
        }
        let shortSubject = subject.count > 60 ? String(subject.prefix(59)) + "…" : subject
        let requester: JSONValue = request ? (header?["from_name"].flatMap { $0.isNull ? nil : $0 } ?? .null) : .null
        return .object([
            "has_reading_request": .bool(has),
            "request_kind": .string(kind),
            "summary": .string("MOCK triage of \u{201C}\(shortSubject)\u{201D}, generated locally without AI."),
            "requester": requester,
            "due_date": .null,
            "due_evidence": .null,
            "priority": .string("normal"),
            "papers": .array(papers),
        ])
    }

    private static let readingRequest = try! NSRegularExpression(
        pattern: #"\b(?:read|reading|take a look|have a look|present|review)\b"#)

    private static func block(_ tag: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
    }
}
