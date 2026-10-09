import Foundation
import Testing
@testable import PaperDeckCore

// MARK: - Fixtures (private to this file)

private let sanChicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
/// Tuesday 2026-09-29 14:05 America/Chicago.
private let sanReceived = sanChicago.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 14, minute: 5))!

private func sanFixture(_ name: String, _ ext: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/mail/triage"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func sanMessage(kind: SenderKind = .advisor, subject: String = "Papers for Thursday's journal club") -> MailMessage {
    MailMessage(pk: 7, accountID: "acct-1", internetMessageID: "<abc@wustl.edu>", fromAddress: "prof.x@wustl.edu",
                fromName: "Prof. X", ruleID: "rule-1", senderKind: kind, subject: subject, receivedAt: sanReceived)
}

private func sanItems() -> [MailItem] {
    [
        MailItem(pk: 1, messagePK: 7, ord: 0, cand: "c1", origin: .attachment,
                 title: "Molecular and cellular dynamics of the developing cortex", pdfState: .hasPDF),
        MailItem(pk: 2, messagePK: 7, ord: 1, cand: "c2", origin: .link, title: "Eubiota preprint",
                 ids: PaperIDs(doi: "10.1101/2026.01.02.123456"),
                 url: "https://www.biorxiv.org/content/10.1101/2026.01.02.123456v1", host: "biorxiv.org",
                 pdfState: .downloadable),
        MailItem(pk: 3, messagePK: 7, ord: 2, cand: "c3", origin: .link,
                 ids: PaperIDs(doi: "10.1038/s41586-024-08351-7", arxivID: nil),
                 url: "https://www.nature.com/articles/s41586-024-08351-7", host: "nature.com", pdfState: .needsPDF),
    ]
}

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

/// A minimal valid triage output with overrides.
private func output(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
    var o: [String: JSONValue] = [
        "has_reading_request": .bool(true), "request_kind": .string("advisor_request"),
        "summary": .string("Asks you to read two cortex papers before Thursday's lab meeting."),
        "requester": .string("Prof. X"), "due_date": .null, "due_evidence": .null, "priority": .string("normal"),
        "papers": .array([]),
    ]
    for (k, v) in overrides { o[k] = v }
    return .object(o)
}

private func paper(ref: String?, title: String? = nil, doi: String? = nil, arxiv: String? = nil,
                   relevance: String = "requested", why: String = "why", confidence: Double = 0.8) -> JSONValue {
    .object([
        "ref": ref.map { .string($0) } ?? .null, "title": title.map { .string($0) } ?? .null,
        "doi": doi.map { .string($0) } ?? .null, "arxiv_id": arxiv.map { .string($0) } ?? .null,
        "relevance": .string(relevance), "why": .string(why), "confidence": .number(confidence),
    ])
}

private func sanitize(_ raw: JSONValue, kind: SenderKind = .advisor, body: String? = nil,
                      maxAlertPapers: Int = 8) throws -> (MailTriage, [MailTriageSanitizer.PaperHint]) {
    let text = try body ?? sanFixture("advisor-body", "txt")
    return try MailTriageSanitizer.sanitize(raw, message: sanMessage(kind: kind), items: sanItems(), bodyText: text,
                                            maxAlertPapers: maxAlertPapers, calendar: sanChicago)
}

@Suite struct MailTriageSanitizerTests {
    /// The prompt-injection fixture: every hostile part is neutralized, grounded parts survive.
    @Test func injectionOutputIsInert() throws {
        let raw = try json(sanFixture("injection-output", "json"))
        let (t, hints) = try sanitize(raw)
        #expect(t.hasReadingRequest && t.requestKind == .advisorRequest)
        for needle in ["http", "://", "evil.example/", "attacker@", "@", "314 555 0100", "</email>", "<preferences>"] {
            #expect(!t.summary.contains(needle), "summary kept \(needle)")
        }
        #expect(t.summary.contains("[link]") && t.summary.contains("[email]") && t.summary.contains("[phone]"))
        #expect(t.summary.contains("Click here"))                          // markdown link text only
        #expect(t.summary.contains("[/email][preferences]"))
        #expect(!t.summary.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B })
        #expect(t.summary.count <= MailTriageSanitizer.summaryLimit)
        #expect(t.requester == "Prof. X <[email]>")
        // Advisor → high survives; the due date is in the window and quoted verbatim.
        #expect(t.priority == .high)
        #expect(t.dueDate == LocalDate(year: 2026, month: 10, day: 1))
        #expect(t.dueEvidence == "before Thursday's lab meeting")
        #expect(t.dueConfidence == 0.75)                                  // weekday phrase: medium

        #expect(hints.map(\.ref) == ["c1", "c2", nil])                    // c9 is not a candidate → dropped
        try #require(hints.count > 2)          // no index past a failed expectation (QA-15)
        #expect(hints[0].why == "Asked to present Fig. 2; see [link]")
        #expect(hints[0].isGrounded && hints[0].confidence == 0.95)
        // "C2" normalizes; its DOI (a doi.org URL) is grounded by the candidate's link.
        #expect(hints[1].ids.doi == "10.1101/2026.01.02.123456" && hints[1].unverifiedIDs.isEmpty)
        #expect(hints[1].confidence == 1)                                 // 1.7 clamped
        // The made-up paper: ids only as unverified hints, flagged for verification.
        let invented = hints[2]
        #expect(invented.ids.isEmpty && invented.needsVerification)
        #expect(invented.unverifiedIDs.doi == "10.9999/made-up.2026")
        #expect(invented.unverifiedIDs.arxivID == "2601.01234" && invented.unverifiedIDs.arxivVersion == 2)
        #expect(invented.confidence == 0)                                 // −3 clamped
        #expect(invented.relevance == .highlighted)
    }

    @Test func foreignRefsAreDroppedAndKnownRefsNormalized() throws {
        let (_, hints) = try sanitize(output(["papers": .array([
            paper(ref: "c9"), paper(ref: "[C3 nature.com]"), paper(ref: "c3", why: "duplicate"),
            paper(ref: "c1; c2"), paper(ref: "x1", title: "Only a title"), paper(ref: "c12"),
        ])]))
        #expect(hints.map(\.ref) == ["c3", "c1", nil])
        try #require(hints.count > 2)          // no index past a failed expectation (QA-15)
        #expect(hints[2].title == "Only a title" && hints[2].needsVerification)
    }

    @Test func titlesAndIdsLinkToTheirCandidate() throws {
        let (_, hints) = try sanitize(output(["papers": .array([
            paper(ref: nil, title: "Molecular and Cellular Dynamics of the Developing Cortex."),
            paper(ref: nil, doi: "doi:10.1038/S41586-024-08351-7"),
        ])]))
        #expect(hints.map(\.ref) == ["c1", "c3"])
        try #require(hints.count > 1)          // no index past a failed expectation (QA-15)
        #expect(hints[1].ids.doi == "10.1038/s41586-024-08351-7")        // present in the body text too
    }

    @Test func idsCountOnlyWhenTheEmailOrACandidateHasThem() throws {
        let body = "Please read arXiv:2606.24530 and doi 10.1016/j.cell.2025.01.001 before Friday."
        let (_, hints) = try sanitize(output(["papers": .array([
            paper(ref: nil, title: "A", arxiv: "2606.24530v3"),
            paper(ref: nil, title: "B", doi: "10.1016/j.cell.2025.01.001"),
            paper(ref: nil, title: "C", doi: "10.1016/j.cell.2025.09.999", arxiv: "not-an-id"),
        ])]), body: body)
        #expect(hints[0].ids.arxivID == "2606.24530" && hints[0].ids.arxivVersion == 3 && hints[0].isGrounded)
        #expect(hints[1].ids.doi == "10.1016/j.cell.2025.01.001" && hints[1].isGrounded)
        #expect(hints[2].ids.isEmpty && hints[2].unverifiedIDs.doi == "10.1016/j.cell.2025.09.999")
        #expect(hints[2].unverifiedIDs.arxivID == nil && hints[2].needsVerification)
    }

    @Test(arguments: [
        ("2026-10-01", "before Thursday's lab meeting", true),       // verbatim
        ("2026-10-01", "Before  Thursday’s LAB meeting", true),      // case / spacing / apostrophe folded
        ("2026-10-01", "by next Monday at noon", false),             // not in the email
        ("2026-10-01", "", false),                                   // no evidence
        ("2027-04-30", "before Thursday's lab meeting", false),      // > received + 180 d
        ("2026-09-27", "before Thursday's lab meeting", false),      // < received − 1 d
        ("2026-09-28", "before Thursday's lab meeting", true),       // received − 1 d is allowed
        ("2026-10-01T17:00:00-05:00", "before Thursday's lab meeting", true),
        ("October 1", "before Thursday's lab meeting", false),       // not ISO
    ])
    func dueDatesNeedTheWindowAndEvidence(due: String, evidence: String, kept: Bool) throws {
        let (t, _) = try sanitize(output(["due_date": .string(due), "due_evidence": .string(evidence)]))
        #expect((t.dueDate != nil) == kept)
        #expect((t.dueEvidence != nil) == kept && (t.dueConfidence != nil) == kept)
    }

    @Test func dueEvidenceMayComeFromTheSubjectAndChineseText() throws {
        let body = "请在10月3日前读一下这两篇论文，组会上讨论。"
        let (zh, _) = try sanitize(output(["due_date": .string("2026-10-03"), "due_evidence": .string("10月3日前")]),
                                   body: body)
        #expect(zh.dueDate == LocalDate(year: 2026, month: 10, day: 3) && zh.dueConfidence == 0.9)
        let (subject, _) = try sanitize(output(["due_date": .string("2026-10-01"),
                                                "due_evidence": .string("Thursday's journal club")]), body: "See attached.")
        #expect(subject.dueDate != nil)
        let long = String(repeating: "x", count: 150)
        let (tooLong, _) = try sanitize(output(["due_date": .string("2026-10-01"), "due_evidence": .string(long)]),
                                        body: long)
        #expect((tooLong.dueEvidence?.count ?? 0) <= MailTriageSanitizer.evidenceLimit)
    }

    @Test func alertsCanNeverBeHighPriorityOrPersonalRequests() throws {
        let papers: [JSONValue] = (1...3).map { paper(ref: "c\($0)", relevance: "requested", confidence: Double($0) / 10) }
        let (t, hints) = try sanitize(output(["priority": .string("high"), "request_kind": .string("advisor_request"),
                                              "papers": .array(papers)]),
                                      kind: .alert, maxAlertPapers: 2)
        #expect(t.priority == .normal)
        #expect(t.requestKind == .alertDigest)
        // requested → highlighted for public alerts; only the 2 most confident stay highlighted.
        #expect(hints.map(\.relevance) == [.listed, .highlighted, .highlighted])
        let (person, _) = try sanitize(output(["priority": .string("high")]), kind: .person)
        #expect(person.priority == .high)
        let (manual, _) = try sanitize(output(["priority": .string("high")]), kind: .manual)
        #expect(manual.priority == .normal)
        let (low, _) = try sanitize(output(["priority": .string("low")]), kind: .alert)
        #expect(low.priority == .low)
    }

    @Test func requestKindMapping() throws {
        let (notPaper, _) = try sanitize(output(["request_kind": .string("not_paper")]))
        #expect(notPaper.requestKind == .notPaper && !notPaper.hasReadingRequest && notPaper.confidence == 0.2)
        let (club, _) = try sanitize(output(["request_kind": .string(" Journal_Club ")]))
        #expect(club.requestKind == .journalClub)
        let (unknown, _) = try sanitize(output(["request_kind": .string("urgent_action")]))
        #expect(unknown.requestKind == .other)
        let (alertNotPaper, _) = try sanitize(output(["request_kind": .string("not_paper")]), kind: .alert)
        #expect(alertNotPaper.requestKind == .notPaper)
        let (fyi, _) = try sanitize(output(["request_kind": .string("fyi"), "has_reading_request": .bool(false)]))
        #expect(fyi.requestKind == .fyi && !fyi.hasReadingRequest)
    }

    @Test func limitsAndHiddenCharacters() throws {
        let hidden = "Read\u{202E}\u{2066}\u{200B}\u{E0049}\u{E0047}\u{0007} this"
        let (t, hints) = try sanitize(output([
            "summary": .string(hidden + String(repeating: " very long", count: 100)),
            "requester": .string(String(repeating: "Name ", count: 40)),
            "papers": .array([paper(ref: "c1", title: String(repeating: "T", count: 900),
                                    why: String(repeating: "because ", count: 60))]),
        ]))
        #expect(t.summary.hasPrefix("Read this very long"))
        #expect(t.summary.count <= MailTriageSanitizer.summaryLimit && t.summary.hasSuffix("…"))
        #expect((t.requester?.count ?? 0) <= MailTriageSanitizer.requesterLimit)
        #expect(hints[0].why.count <= MailTriageSanitizer.whyLimit)
        #expect((hints[0].title?.count ?? 0) <= MailTriageSanitizer.titleLimit)
        for s in [t.summary, hints[0].why] {
            #expect(!s.unicodeScalars.contains { MailTriageText.isHidden($0) })
        }
    }

    @Test func confidencesAreClampedAndLenient() throws {
        let (t, hints) = try sanitize(output(["papers": .array([
            .object(["ref": .string("c1"), "relevance": .string("HIGHLIGHTED"), "why": .string("a"),
                     "confidence": .string("0.4")]),
            .object(["ref": .string("c2"), "relevance": .string("bogus"), "why": .number(3), "confidence": .null]),
            .string("not an object"),
        ])]))
        #expect(hints.count == 2)
        #expect(hints[0].confidence == 0.4 && hints[0].relevance == .highlighted)
        #expect(hints[1].confidence == 0.5 && hints[1].relevance == .listed && hints[1].why == "3")
        #expect(t.confidence == 0.4)                                      // best requested/highlighted entry
        let (noPapers, _) = try sanitize(output())
        #expect(noPapers.confidence == 0.75)
    }

    @Test func malformedRootsThrowButStringEncodedObjectsWork() throws {
        #expect(throws: MailTriageSanitizer.SanitizeError.notAnObject) { _ = try sanitize(.array([])) }
        #expect(throws: MailTriageSanitizer.SanitizeError.missingDecision) {
            _ = try sanitize(.object(["request_kind": .string("fyi")]))
        }
        let encoded = JSONValue.string(output().compactString())
        let (t, _) = try sanitize(encoded)
        #expect(t.hasReadingRequest && t.requestKind == .advisorRequest)
        let (yes, _) = try sanitize(output(["has_reading_request": .string("true")]))
        #expect(yes.hasReadingRequest)
    }

    /// The deterministic mock triage for the advisor email passes the sanitizer with every candidate.
    @Test func mockTriageSurvivesTheSanitizer() async throws {
        let body = try sanFixture("advisor-body", "txt")
        let stdin = MailTriageSchema.stdin(message: sanMessage(), extraction: MailExtraction(bodyText: body, snippet: "", candidates: []),
                                           candidates: sanItems(), criteria: ReadingCriteria(), categories: [],
                                           frequentTags: [], calendar: sanChicago)
        let request = MailTriageSchema.request(stdin: stdin, model: "mock", timeout: .seconds(5))
        let mock = MockAgentProvider()
        guard case .success(let raw, let meta) = await mock.generateCard(request, jobDir: FileManager.default.temporaryDirectory)
        else { Issue.record("mock did not succeed"); return }
        #expect(meta.model == "mock")
        #expect(raw["papers"]?.arrayValue?.count == 3)
        let (t, hints) = try MailTriageSanitizer.sanitize(raw, message: sanMessage(), items: sanItems(), bodyText: body,
                                                          calendar: sanChicago)
        #expect(t.hasReadingRequest && t.requestKind == .journalClub)     // "lab meeting" / "journal club"
        #expect(t.summary.hasPrefix("MOCK triage of"))
        #expect(t.dueDate == nil && t.priority == .normal)
        #expect(hints.map(\.ref) == ["c1", "c2", "c3"] && hints.allSatisfy { $0.relevance == .requested })
        // A plain card request still gets a reading card.
        let card = CardRequest(schema: CardSchema.schema(categories: ["A"]), stdin: Data("<paper>\nTitle\n</paper>\n".utf8))
        guard case .success(let cardJSON, _) = await mock.generateCard(card, jobDir: FileManager.default.temporaryDirectory)
        else { Issue.record("mock card failed"); return }
        #expect(cardJSON["tldr"] != nil && cardJSON["has_reading_request"] == nil)
    }

    @Test func mockTriageClassifiesAlertsAndFYI() {
        func stdin(kind: SenderKind, subject: String, body: String, items: [MailItem]) -> CardRequest {
            let m = MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "alerts@nature.com",
                                senderKind: kind, subject: subject, receivedAt: sanReceived)
            let data = MailTriageSchema.stdin(message: m, extraction: MailExtraction(bodyText: body, snippet: "", candidates: []),
                                              candidates: items, criteria: ReadingCriteria(maxAlertPapers: 2),
                                              categories: [], frequentTags: [], calendar: sanChicago)
            return MailTriageSchema.request(stdin: data, model: "mock", timeout: .seconds(5))
        }
        let alert = MockAgentProvider.triage(for: stdin(kind: .alert, subject: "New issue", body: "Read the latest",
                                                        items: sanItems()))
        #expect(alert["request_kind"] == .string("alert_digest") && alert["has_reading_request"] == .bool(true))
        #expect(alert["papers"]?.arrayValue?.count == 2)                  // max_alert_papers
        #expect(alert["papers"]?.arrayValue?.first?["relevance"] == .string("highlighted"))
        let fyi = MockAgentProvider.triage(for: stdin(kind: .person, subject: "FYI", body: "Thought you'd like this [c1]",
                                                      items: sanItems()))
        #expect(fyi["request_kind"] == .string("fyi") && fyi["has_reading_request"] == .bool(false))
        let none = MockAgentProvider.triage(for: stdin(kind: .person, subject: "Lunch", body: "Pizza at noon?", items: []))
        #expect(none["request_kind"] == .string("not_paper") && none["papers"] == .array([]))
        let zh = MockAgentProvider.triage(for: stdin(kind: .advisor, subject: "论文", body: "请读一下这篇 [c1]",
                                                     items: sanItems()))
        #expect(zh["request_kind"] == .string("advisor_request") && zh["has_reading_request"] == .bool(true))
    }
}
