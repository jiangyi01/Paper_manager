import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fix B3-1: the judge's answer is read as typed JSON. `JSONSerialization` hands back
/// NSNumbers that Swift also bridges to `Bool` when they are exactly 0 or 1, so a fully sure
/// `"confidence": 1` (or `1.0`) used to read as 0 — nothing re-banded, the sheet said "not sure"
/// and a turn of the daily cap was wasted — and `"candidate": true` counted as candidate 1.
@Suite("Phase 2 fixes RD: judge parser")
struct RDJudgeParserFixTests {
    static func answer(confidence: String, candidate: String = "1") -> String {
        #"{"judgements":[{"candidate":\#(candidate),"verdict":"same_work","confidence":\#(confidence),"reason":"r"}]}"#
    }

    @Test(arguments: [("1", 1.0), ("1.0", 1.0), ("0", 0.0), ("0.0", 0.0), ("0.5", 0.5), ("0.99", 0.99), ("100", 1.0),
                      ("\"100%\"", 1.0), ("\"1\"", 1.0), ("\"0.5\"", 0.5), ("1e0", 1.0), ("85", 0.85)])
    func numbersReadAsNumbers(_ raw: String, _ expected: Double) throws {
        let j = try #require(DupJudgeParser.parse(Self.answer(confidence: raw), candidates: 1).first, "\(raw)")
        #expect(abs(j.confidence - expected) < 1e-9, "confidence \(raw) read as \(j.confidence)")
    }

    /// A fully sure same-work answer moves a possible match up (it used to move nothing).
    @Test func aFullySureAnswerRebands() throws {
        for raw in ["1", "1.0"] {
            let j = try #require(DupJudgeParser.parse(Self.answer(confidence: raw), candidates: 1).first)
            #expect(DupJudge.reband(.possible, j) == .likely, "confidence \(raw)")
            let v = DupAIVerdict(verdict: j.verdict, confidence: j.confidence, reason: j.reason, bandBefore: .possible,
                                 bandAfter: .likely, provider: "mock", model: "m", at: Date(timeIntervalSince1970: 0))
            #expect(v.isConfident)
        }
    }

    /// JSON booleans are not numbers: `true` is no confidence at all, and no candidate index (the
    /// judgement is dropped rather than pinned on candidate 1). Strings "true" / "false" are not
    /// numbers either.
    @Test func booleansAreNotNumbers() {
        for raw in ["true", "false", "\"true\"", "\"false\"", "null", "[1]", "{\"v\":1}"] {
            let j = DupJudgeParser.parse(Self.answer(confidence: raw), candidates: 1).first
            #expect(j?.confidence == 0, "confidence \(raw) read as \(String(describing: j?.confidence))")
        }
        for raw in ["true", "false"] {
            #expect(DupJudgeParser.parse(Self.answer(confidence: "0.9", candidate: raw), candidates: 1).isEmpty,
                    "candidate \(raw) must not count as a candidate")
        }
        // Without any candidate key, one object is candidate 1 (unchanged).
        #expect(DupJudgeParser.parse(#"{"verdict":"same_work","confidence":1}"#, candidates: 1).first?.candidate == 1)
        // Numeric candidates: 1 and 1.0 are candidate 1; 2 is out of range for one candidate.
        #expect(DupJudgeParser.parse(Self.answer(confidence: "1", candidate: "1.0"), candidates: 1).first?.candidate == 1)
        #expect(DupJudgeParser.parse(Self.answer(confidence: "1", candidate: "2"), candidates: 1).isEmpty)
        #expect(DupJudgeParser.parse(Self.answer(confidence: "1", candidate: "\"c2\""), candidates: 2).first?.candidate == 2)
    }

    /// The tolerant shapes still parse through the typed tree (a fence and prose, `judgments`, a
    /// bare array, a brace inside a string, a duplicate answer for one candidate).
    @Test func theTolerantShapesStillParse() {
        let fenced = "Here:\n```json\n{\"judgments\":[{\"candidate\":2,\"verdict\":\"different\",\"confidence\":1},"
            + "{\"candidate\":1,\"verdict\":\"same paper\",\"confidence\":1.0,\"reason\":\"title {v2}\"}]}\n```"
        let parsed = DupJudgeParser.parse(fenced, candidates: 2)
        #expect(parsed.map(\.candidate) == [1, 2])
        #expect(parsed.map(\.confidence) == [1, 1])
        #expect(parsed.first?.reason == "title {v2}")
        #expect(DupJudgeParser.parse(#"[{"verdict":"related","confidence":1}]"#, candidates: 1).first?.confidence == 1)
    }

    /// Through the engine: a mock judge answering `"confidence": 1` re-bands a possible match.
    @Test func aSureAnswerThroughTheEngineRebands() async throws {
        let mock = MockAssistBackend(behavior: .chunks([Self.answer(confidence: "1")]))
        try await DedupeKit.run(DupJudgeEngineTests.settings(), assist: mock) { env in
            let body = DedupeKit.body(seed: "mail judge")
            _ = await env.ingest([try env.pdf("journal.pdf", title: DupJudgeEngineTests.title, body: body)])
            let url = try env.pdf("attachment.pdf", title: DupJudgeEngineTests.title, body: body)
            _ = await env.ingest([url], origin: .mail, annotations: [url: ImportAnnotation(sameWorkPolicy: .link)])
            let review = try await env.onlyOpenReview()
            #expect(review.band == .possible)
            try await env.engine.setDuplicateJudgeEnabled(true)
            let judged = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            #expect(judged.band == .likely && judged.aiVerdict?.confidence == 1 && judged.aiVerdict?.isConfident == true)
        }
    }
}
