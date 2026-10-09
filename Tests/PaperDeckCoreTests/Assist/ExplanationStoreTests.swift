import Foundation
import Testing
@testable import PaperDeckCore

/// Explain history (`explanation`, Database+Explain, OperationsExplain): insert / list / pin /
/// prune, `ON DELETE SET NULL`, the notes-append format (en / zh) and its idempotence.
@Suite struct ExplanationStoreTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        private var lang: UILang = .en
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        var uiLang: UILang { lock.withLock { lang } }
        func setLang(_ l: UILang) { lock.withLock { lang = l } }
    }

    static func engine(_ clock: Clock) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-explain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { var s = EngineSettings(metadataLookup: false); s.lang = clock.uiLang; return s },
            now: { clock.now }, calendar: cal, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
            codex: MockAgentProvider(behavior: .notLoggedIn), sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()]))
        return (engine, root)
    }

    static func paper(_ engine: Engine, notes: String = "") async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder), withIntermediateDirectories: true)
        var p = Paper(id: id, sha256: sha, fileSize: 1000, title: "A Paper", titleRank: .font, pageCount: 3, charCount: 10,
                      folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf", stage: .ready, addedAt: t0, updatedAt: t0)
        p.notes = notes
        return try await engine.db.insertPaper(p)
    }

    static func record(_ paperID: String?, at date: Date, thread: String = "panel-1", turn: Int = 0, excerpt: String? = "We regularize the attention weights.",
                       question: String? = nil, provider: String = "claude", model: String = "haiku", page: Int? = 5) -> ExplanationRecord {
        ExplanationRecord(paperID: paperID, threadID: thread, turn: turn, source: .region, action: "explain", lang: .zh, page: page,
                          excerpt: excerpt, question: question, answer: "**要点。** 注意力（attention）权重被正则化。", hadImage: true,
                          meta: AssistMeta(provider: provider, model: model, totalMs: 1234, inputTokens: 10, outputTokens: 20, costUSD: 0.001),
                          createdAt: date, matchVia: .windowTitle, matchScore: 0.8)
    }

    @Test func storeListPinAndRoundTrip() async throws {
        let clock = Clock(Self.t0)
        let (engine, root) = try await Self.engine(clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Self.paper(engine)
        var long = Self.record(p.id, at: Self.t0)
        long.excerpt = String(repeating: "e", count: 5_000)            // set after init: still capped on insert
        let saved = try await engine.saveExplanation(long)
        #expect(saved.excerpt?.count == ExplanationRecord.maxExcerpt)
        #expect(saved.paperID == p.id && saved.matchVia == .windowTitle && saved.matchScore == 0.8 && saved.hadImage)
        #expect(saved.meta.provider == "claude" && saved.meta.model == "haiku" && saved.meta.totalMs == 1234 && saved.meta.costUSD == 0.001)
        #expect(saved.createdAt == Self.t0 && saved.page == 5 && saved.lang == .zh && saved.source == .region)
        let later = try await engine.saveExplanation(Self.record(p.id, at: Self.t0.addingTimeInterval(60), turn: 1, question: "Why?"))
        let unmatched = try await engine.saveExplanation(Self.record(nil, at: Self.t0.addingTimeInterval(30), thread: "other"))
        #expect(try await engine.explanations(paperID: p.id, limit: 50).map(\.id) == [later.id, saved.id])
        #expect(try await engine.explanations(paperID: nil, limit: 50).map(\.id) == [later.id, unmatched.id, saved.id])
        #expect(try await engine.explanations(paperID: nil, limit: 1).map(\.id) == [later.id])
        #expect(try await engine.db.explanations(threadID: "panel-1").map(\.turn) == [0, 1])
        await #expect(throws: DatabaseError.duplicate("explanation \(saved.id)")) { try await engine.saveExplanation(saved) }
        await #expect(throws: DatabaseError.notFound("paper nope")) { try await engine.saveExplanation(Self.record("nope", at: Self.t0)) }
        await #expect(throws: PaperOperationError.paperNotFound("nope")) { _ = try await engine.explanations(paperID: "nope", limit: 5) }
        try await engine.setExplanationPinned(id: saved.id, true)
        #expect(try await engine.db.explanation(id: saved.id)?.pinned == true)
        await #expect(throws: ExplainOperationError.explanationNotFound("x")) { try await engine.setExplanationPinned(id: "x", true) }
        await engine.shutdown()
    }

    @Test func deletingThePaperKeepsItsExplanationsUnmatched() async throws {
        let clock = Clock(Self.t0)
        let (engine, root) = try await Self.engine(clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Self.paper(engine)
        let saved = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        try await engine.db.hardDelete(pk: p.pk)
        let after = try #require(try await engine.db.explanation(id: saved.id))
        #expect(after.paperID == nil && after.answer == saved.answer)
        await engine.shutdown()
    }

    @Test func pruneKeepsPinnedSavedAndRecentRows() async throws {
        let clock = Clock(Self.t0)
        let (engine, root) = try await Self.engine(clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Self.paper(engine)
        let old = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        let pinned = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        let toNotes = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        try await engine.setExplanationPinned(id: pinned.id, true)
        try await engine.appendExplanationToNotes(id: toNotes.id)
        clock.advance(89 * 86_400)
        let fresh = try await engine.saveExplanation(Self.record(nil, at: clock.now))
        #expect(try await engine.pruneExplanationsByRetention() == 0)   // 89 days: nothing is old enough
        clock.advance(2 * 86_400)
        #expect(try await engine.pruneExplanationsByRetention() == 1)
        let left = Set(try await engine.explanations(paperID: nil, limit: 50).map(\.id))
        #expect(left == [pinned.id, toNotes.id, fresh.id] && !left.contains(old.id))
        #expect(try await engine.pruneExplanations(olderThan: clock.now.addingTimeInterval(1)) == 1)    // fresh, unpinned
        await engine.shutdown()
    }

    @Test func savingToNotesAppendsOnceInTheUILanguage() async throws {
        let clock = Clock(Self.t0)
        let (engine, root) = try await Self.engine(clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Self.paper(engine, notes: "My notes.\n\n\n")
        let r = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        try await engine.appendExplanationToNotes(id: r.id)
        try await engine.appendExplanationToNotes(id: r.id)             // twice: still one block
        let notes = try #require(try await engine.db.paper(pk: p.pk)?.notes)
        // 1_790_000_000 = 2026-09-21 14:13:20 UTC = 09:13 in Chicago (CDT).
        #expect(notes == """
        My notes.

        — Explain · p. 5 · 2026-09-21 09:13 · Claude haiku
        > "We regularize the attention weights."
        **要点。** 注意力（attention）权重被正则化。

        """)
        #expect(try await engine.db.explanation(id: r.id)?.savedToNotesAt == Self.t0)
        // Chinese UI, a follow-up with a question, the on-device model, no page, a long excerpt.
        clock.setLang(.zh)
        var follow = Self.record(p.id, at: Self.t0, turn: 1, excerpt: String(repeating: "长 ", count: 400),
                                 question: "为什么\n要这样？", provider: "local", model: "on-device", page: nil)
        follow.answer = "因为……"
        let f = try await engine.saveExplanation(follow)
        try await engine.appendExplanationToNotes(id: f.id)
        let zh = try #require(try await engine.db.paper(pk: p.pk)?.notes)
        let block = zh.components(separatedBy: "\n\n").last ?? ""
        let lines = block.components(separatedBy: "\n")
        #expect(lines[0] == "— 讲解 · 2026-09-21 09:13 · 本机模型")
        #expect(lines[1] == "> 问：为什么 要这样？")
        #expect(lines[2].hasPrefix("> \"长 长") && lines[2].hasSuffix("…\"") && lines[2].count <= ExplainNotes.excerptLimit + 4)
        #expect(lines[3] == "因为……")
        // Unmatched explanations need a paper first; unknown ids are reported.
        let loose = try await engine.saveExplanation(Self.record(nil, at: Self.t0))
        await #expect(throws: ExplainOperationError.notMatched(loose.id)) { try await engine.appendExplanationToNotes(id: loose.id) }
        await #expect(throws: ExplainOperationError.explanationNotFound("zzz")) { try await engine.appendExplanationToNotes(id: "zzz") }
        await engine.shutdown()
    }

    @Test func aMatchedWriteNotifiesItsPaper() async throws {
        let clock = Clock(Self.t0)
        let (engine, root) = try await Self.engine(clock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await Self.paper(engine)
        let changes = engine.changes.subscribe()
        let watcher = Task { () -> Bool in
            for await c in changes { if c == .paper(pk: p.pk) { return true } }
            return false
        }
        _ = try await engine.saveExplanation(Self.record(p.id, at: Self.t0))
        #expect(await watcher.value)
        await engine.shutdown()
    }
}
