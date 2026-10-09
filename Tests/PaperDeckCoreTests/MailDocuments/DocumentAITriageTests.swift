import Foundation
import Testing
@testable import PaperDeckCore

/// An AI triage the user asked for (「让 AI 分析」, mock provider) never sends a person's
/// manuscript card to 「无阅读需求」 unless the model found no paper at all — the capture's
/// document floor (`MailHeuristics.keepsDocumentPending`) holds for AI results too.
@Suite struct DocumentAITriageTests {
    typealias K = MailSyncKit

    private static func answer(_ kind: String, request: Bool, confidence: Double = 0.3) -> JSONValue {
        .object([
            "has_reading_request": .bool(request), "request_kind": .string(kind),
            "summary": .string("Shares a manuscript draft."), "requester": .null, "due_date": .null, "due_evidence": .null,
            "priority": .string("normal"),
            "papers": .array([.object(["ref": .string("c1"), "title": .null, "doi": .null, "arxiv_id": .null,
                                       "relevance": .string("requested"), "why": .string("The draft"),
                                       "confidence": .number(confidence)])]),
        ])
    }

    private func run(_ answer: JSONValue, _ check: (K.Env, MailMessage, MailMessage) async throws -> Void) async throws {
        let provider = K.ScriptedTriage(answer)
        try await K.run(mode: .mock, mock: provider) { env in
            await env.source().add("r1", try DocKit.advisorManuscriptEML(messageID: "<doc-ai@wustl.edu>"))
            // The same advisor, no document or shared link: the old rule applies.
            await env.source().add("r2", DocKit.eml(messageID: "<plain-ai@wustl.edu>", body: "Lunch on Friday?"))
            await env.sync()
            for id in ["<doc-ai@wustl.edu>", "<plain-ai@wustl.edu>"] {
                try await env.engine.requestMailAI(messageID: try await env.message(id).id)
            }
            #expect(await K.eventually {
                let a = try? await env.message("<doc-ai@wustl.edu>").triageState
                let b = try? await env.message("<plain-ai@wustl.edu>").triageState
                return a == .done && b == .done
            })
            try await check(env, try await env.message("<doc-ai@wustl.edu>"), try await env.message("<plain-ai@wustl.edu>"))
            #expect(await provider.calls == 2)
        }
    }

    @Test func anOtherOrLowConfidenceVerdictKeepsTheManuscriptPending() async throws {
        try await run(Self.answer("other", request: true, confidence: 0.9)) { _, doc, plain in
            #expect(doc.triageSource == .ai && doc.triage?.requestKind == .other)
            #expect(doc.state == .pending && doc.handledAt == nil)
            #expect(plain.state == .noRequest)                            // "other" isn't a kept kind
        }
        // The model asks for the draft but grounds it with low confidence (below minConfidence).
        try await run(Self.answer("advisor_request", request: true, confidence: 0.2)) { _, doc, _ in
            #expect(doc.triage?.requestKind == .advisorRequest && (doc.triage?.confidence ?? 1) < 0.5)
            #expect(doc.state == .pending)
        }
    }

    @Test func notPaperStillMovesIt() async throws {
        try await run(Self.answer("not_paper", request: false)) { _, doc, plain in
            #expect(doc.state == .noRequest && doc.handledAt != nil)
            #expect(plain.state == .noRequest)
        }
    }

    @Test func theRule() {
        let other = MailTriage(hasReadingRequest: false, requestKind: .other, summary: "x", priority: .normal, confidence: 0.4)
        let none = MailTriage(hasReadingRequest: false, requestKind: .notPaper, summary: "x", priority: .low, confidence: 0.9)
        let doc = MailItem(ord: 1, cand: "c1", origin: .document)
        let share = MailItem(ord: 1, cand: "c1", origin: .shareLink)
        let link = MailItem(ord: 1, cand: "c1", origin: .link)
        typealias C = MailTriageCoordinator
        #expect(C.keepsDocumentPending(other, items: [doc], senderKind: .advisor))
        #expect(C.keepsDocumentPending(other, items: [link, share], senderKind: .person))
        #expect(!C.keepsDocumentPending(other, items: [link], senderKind: .advisor))
        #expect(!C.keepsDocumentPending(none, items: [doc], senderKind: .advisor))
        #expect(!C.keepsDocumentPending(other, items: [doc], senderKind: .alert))
        #expect(!C.keepsDocumentPending(other, items: [doc], senderKind: .manual))
    }
}
