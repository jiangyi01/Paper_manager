import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes QA-2 (verifier v08, v09), QA-3 and QA-4's multi-paper privacy survivors (v05,
/// v06, v07): `qa.json` leaves a paper's folder whenever its verdict stops being `.ok` — however
/// that happened (a duplicate merge, a person's email, the unpublished hold, a change made while
/// Q&A wasn't bound) — and comes back when it is `.ok` again; a verdict that can't be read refuses
/// the question (fail closed: nothing stored, nothing sent); every paper of a multi-paper question
/// is checked. Mock backends only.
@Suite(.timeLimit(.minutes(2))) struct QAFixPrivacyTests {
    private typealias Kit = QATestKit

    struct Boom: Error {}

    /// A thread with one question stored straight in the database, and its `qa.json` written.
    static func threadWithSidecar(_ engine: Engine, paperID: String, at now: Date) async throws -> URL {
        let t = try await engine.db.insertQAThread(QAThread(paperIDs: [paperID], title: "t", mode: .fullText, createdAt: now))
        try await engine.db.insertQAMessage(QAMessage(threadID: t.id, role: .user, text: "q", createdAt: now))
        await engine.syncQASidecar(paperID: paperID)
        let paper = try #require(try await engine.db.paper(id: paperID))
        return engine.ctx.folderURL(paper).appendingPathComponent(QASidecar.fileName)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The watcher catches the change, its pass runs, the file follows (generous: a loaded machine).
    static func eventually(_ qa: QAService, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        await assistEventually(.seconds(20)) {
            await qa.settlePrivacy()
            return condition()
        }
    }

    static func personEmail(_ env: OpsTestKit.Env, _ p: Paper, _ mid: String) async throws {
        let (m, _) = try await env.db.insertMailMessage(
            MailMessage(accountID: "a", internetMessageID: mid, fromAddress: "pi@lab.example", senderKind: .person,
                        subject: "draft", receivedAt: env.clock.value), items: [])
        try await env.db.insertPaperSource(paperPK: p.pk, PaperProvenance(mailMessageID: m.id, internetMessageID: mid,
                                                                          addedAt: env.clock.value))
    }

    // MARK: QA-2 qa.json follows every privacy input

    /// v08: a person's email attached after the paper's Q&A.
    @Test func aPersonsEmailAttachedLaterRemovesQaJson() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(Kit.completed(await Kit.ask(env, qa, t.id, "Q?")) != nil)
            await qa.flushSidecars()
            let url = Kit.qaJSON(env, p)
            #expect(Self.exists(url))
            try await Self.personEmail(env, p, "<later@x>")
            #expect(await qa.privacy(paperIDs: [p.id]) == .confirm([.personSourcedNoID]))
            #expect(await Self.eventually(qa) { !Self.exists(url) }, "qa.json kept beside a person-sourced paper")
        }
    }

    @Test func theUnpublishedHoldRemovesQaJsonAndReleasingItBringsItBack() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let url = try await Self.threadWithSidecar(env.engine, paperID: p.id, at: env.clock.value)
            #expect(Self.exists(url))
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            #expect(await Self.eventually(qa) { !Self.exists(url) }, "qa.json kept beside a held paper")
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.aiNote = nil }
            #expect(await Self.eventually(qa) { Self.exists(url) }, "qa.json back once the hold is released")
        }
    }

    /// v09, the real merge path: the copy's "confidential" flag is carried onto the kept paper.
    @Test func aMergeThatMakesTheKeptPaperConfidentialRemovesItsQaJson() async throws {
        try await DedupeKit.run { env in
            let title = "Spatial atlas of cortical progenitor lineages"
            let body = DedupeKit.body(seed: "qa privacy pair")
            let eid = try #require(await env.ingest([try env.pdf("earlier.pdf", title: title, body: body)]).added.first)
            let nid = try #require(await env.ingest([try env.pdf("later.pdf", title: title, body: body)]).added.first)
            let review = try await env.onlyOpenReview()
            try #require(review.holdsNewPaper && review.newPaperID == nid)
            let qa = await env.engine.qaService()
            let url = try await Self.threadWithSidecar(env.engine, paperID: eid, at: env.clock.now)
            #expect(Self.exists(url))
            try await env.engine.setPaperPolicy(paperID: nid, confidential: true, neverAI: false)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            await env.settle()
            let verdict = try await env.engine.assistPrivacy(paperID: eid, hostBundleID: nil)
            try #require(verdict != .ok, "the merge carries the copy's confidential flag (verdict \(verdict))")
            let kept = try await env.paper(eid)
            let keptURL = env.engine.ctx.folderURL(kept).appendingPathComponent(QASidecar.fileName)
            #expect(await Self.eventually(qa) { !Self.exists(keptURL) && !Self.exists(url) },
                    "qa.json kept beside a now-confidential paper")
        }
    }

    /// A change made while Q&A wasn't bound (an earlier session): binding checks every paper.
    @Test func whatChangedBeforeQAWasBoundIsCaughtWhenItBinds() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let t = try await env.db.insertQAThread(QAThread(paperIDs: [p.id], title: "t", mode: .fullText, createdAt: env.clock.value))
            let m = try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .user, text: "q", createdAt: env.clock.value))
            let url = Kit.qaJSON(env, p)
            QASidecarFile.write(QASidecar(paperID: p.id, threads: [(t, [m])]), folder: url.deletingLastPathComponent(),
                                staging: env.paths.partial)
            #expect(Self.exists(url))
            try await env.db.setPaperPolicy(paperPK: p.pk, PaperPolicy(confidential: true, setAt: env.clock.value))
            let qa = await env.engine.qaService()                    // binds now
            #expect(await Self.eventually(qa) { !Self.exists(url) })
        }
    }

    // MARK: QA-3 fail closed

    /// A service bound with a privacy lookup that throws for `failing`.
    static func service(_ env: OpsTestKit.Env, failing: Set<String>,
                        blocked: Set<String> = []) async -> QAService {
        let qa = QAService(lane: env.engine.assist, load: { env.settings.value }, now: { env.clock.value })
        await qa.bind(QALibrary(ctx: env.engine.ctx, reader: { "" }, privacy: { id in
            if failing.contains(id) { throw Boom() }
            return blocked.contains(id) ? .blocked : .ok
        }))
        return qa
    }

    @Test func aVerdictThatCantBeReadRefusesTheQuestion() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await Self.service(env, failing: [p.id])
            #expect(await qa.privacy(paperIDs: [p.id]) == .blocked)
            #expect(await qa.privacyCheck(paperIDs: [p.id]) == QAService.PrivacyCheck(verdict: .ok, unchecked: [p.id]))
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await qa.privacy(threadID: t.id) == .blocked)
            for ack in [false, true] {
                let events = await Kit.ask(env, qa, t.id, "Anything?", options: QAOptions(privacyAcknowledged: ack))
                #expect(events == [.failed(.generic(QAService.privacyUncheckedCode), partial: nil)])
            }
            #expect(await mock.turns == 0)
            #expect(await qa.messages(threadID: t.id).isEmpty)
            #expect(try await env.db.qaThreads(paperID: p.id).isEmpty)
        }
    }

    @Test func oneUnreadablePaperOfSeveralRefusesAndNeverAIStillSaysSo() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let a = try await Kit.addPaper(env, title: "Alpha")
            let b = try await Kit.addPaper(env, title: "Beta")
            let c = try await Kit.addPaper(env, title: "Gamma")
            let qa = await Self.service(env, failing: [b.id])
            let t = await qa.newThread(paperIDs: [a.id, b.id, c.id], mode: .excerpts)
            #expect(await Kit.ask(env, qa, t.id, "Compare?") == [.failed(.generic(QAService.privacyUncheckedCode), partial: nil)])
            let blocked = await Self.service(env, failing: [b.id], blocked: [c.id])
            let t2 = await blocked.newThread(paperIDs: [a.id, b.id, c.id], mode: .excerpts)
            #expect(await Kit.ask(env, blocked, t2.id, "Compare?") == [.failed(.refused(.policyBlocked), partial: nil)])
            #expect(await mock.turns == 0)
        }
    }

    // MARK: QA-4 every paper of a multi-paper question (verifier v05, v06, v07)

    @Test func oneNeverAIPaperBlocksAMultiPaperQuestion() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let a = try await Kit.addPaper(env, title: "Alpha")
            let b = try await Kit.addPaper(env, title: "Beta")
            let c = try await Kit.addPaper(env, title: "Gamma")
            try await env.engine.setPaperPolicy(paperID: c.id, confidential: false, neverAI: true)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [a.id, b.id, c.id], mode: .excerpts)
            let events = await Kit.ask(env, qa, t.id, "Compare?", options: QAOptions(privacyAcknowledged: true))
            #expect(events == [.failed(.refused(.policyBlocked), partial: nil)])
            #expect(await mock.turns == 0)
            #expect(try await env.db.qaThreads(paperID: a.id).isEmpty)
        }
    }

    @Test func aConfidentialSecondPaperAsksFirstAndNoQaJsonIsWritten() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let a = try await Kit.addPaper(env, title: "Alpha")
            let b = try await Kit.addPaper(env, title: "Beta")
            try await env.engine.setPaperPolicy(paperID: b.id, confidential: true, neverAI: false)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [a.id, b.id], mode: .fullText)
            #expect(await Kit.ask(env, qa, t.id, "Compare?") == [.needsConfirmation([.markedConfidential])])
            #expect(await mock.turns == 0)
            let ok = await Kit.ask(env, qa, t.id, "Compare?", options: QAOptions(privacyAcknowledged: true), gesture: .action)
            #expect(Kit.completed(ok) != nil)
            await qa.flushSidecars()
            #expect(!Self.exists(Kit.qaJSON(env, a)) && !Self.exists(Kit.qaJSON(env, b)))
        }
    }

    @Test func aPersonsEmailWithoutAnIDNeedsConfirmation() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            try await Self.personEmail(env, p, "<v7@x>")
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await Kit.ask(env, qa, t.id, "Q?") == [.needsConfirmation([.personSourcedNoID])])
            #expect(await mock.turns == 0)
        }
    }
}
