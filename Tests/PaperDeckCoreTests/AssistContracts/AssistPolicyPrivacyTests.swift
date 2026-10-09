import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0 contract (READING_ASSIST_PLAN §2, §5, §9.1): `paper_policy` CRUD, the engine operations
/// and the one privacy rule (`AssistPrivacy.verdict`) every assist surface uses.
@Suite struct AssistPolicyPrivacyTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func paper(_ n: Int, doi: String? = nil) -> Paper {
        Paper(sha256: String(repeating: String(n % 10), count: 64), fileSize: 1, ids: PaperIDs(doi: doi),
              title: "Paper \(n)", folder: "Papers/p\(n)", pdfName: "p\(n).pdf", originalName: "p\(n).pdf")
    }

    // MARK: Database

    @Test func policyRowsAreStoredUpdatedAndRemovedWhenEmpty() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(Self.paper(1))
        #expect(try await db.paperPolicy(paperPK: p.pk) == nil)
        try await db.setPaperPolicy(paperPK: p.pk, PaperPolicy(confidential: true, setBy: .user, setAt: Self.t0))
        let stored = try #require(try await db.paperPolicy(paperPK: p.pk))
        #expect(stored.confidential && !stored.neverAI && stored.setBy == .user && stored.setAt == Self.t0)
        try await db.setPaperPolicy(paperPK: p.pk, PaperPolicy(confidential: true, neverAI: true, setBy: .mail, setAt: Self.t0))
        #expect(try await db.paperPolicy(paperPK: p.pk)?.neverAI == true)
        #expect(try await db.paperPolicy(paperPK: p.pk)?.setBy == .mail)
        let q = try await db.insertPaper(Self.paper(2))
        #expect(try await db.paperPolicies(paperPKs: [p.pk, q.pk]).keys.sorted() == [p.pk])
        // Both off: no row.
        try await db.setPaperPolicy(paperPK: p.pk, PaperPolicy(setAt: Self.t0))
        #expect(try await db.paperPolicy(paperPK: p.pk) == nil)
        await #expect(throws: DatabaseError.notFound("paper pk 999")) {
            try await db.setPaperPolicy(paperPK: 999, PaperPolicy(neverAI: true))
        }
        // Hard delete cascades.
        try await db.setPaperPolicy(paperPK: q.pk, PaperPolicy(neverAI: true))
        try await db.hardDelete(pk: q.pk)
        #expect(try await db.paperPolicies(paperPKs: [q.pk]).isEmpty)
    }

    @Test func aPolicyChangeIsAnnouncedOnlyWhenSomethingChanged() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(Self.paper(1))
        let stream = db.changes.subscribe()
        let collector = Task { () -> [LibraryChange] in
            var out: [LibraryChange] = []
            for await c in stream { out.append(c); if out.count == 1 { break } }
            return out
        }
        try await db.setPaperPolicy(paperPK: p.pk, PaperPolicy())          // nothing to remove: no change
        try await db.setPaperPolicy(paperPK: p.pk, PaperPolicy(confidential: true))
        let got = await collector.value
        #expect(got == [.paper(pk: p.pk)])
    }

    @Test func counterRowsAreQuietAndRestorable() async throws {
        let db = try Database.inMemory()
        let stream = db.changes.subscribe()
        let collector = Task { () -> Int in var n = 0; for await _ in stream { n += 1 }; return n }
        try await db.setCounterKV("assist.count.2026-10-01.claude", 3)
        try await db.setCounterKV("assist.count.2026-10-01.claude", 4)
        try await db.setCounterKV("dedupe.ai.count.2026-10-01", 1)
        try await db.setKV("assist.mode.unrelated", "x")                     // an ordinary kv write is announced
        #expect(try await db.kvRows(prefix: "assist.count") == ["assist.count.2026-10-01.claude": "4"])
        #expect(try await db.kvRows(prefix: "dedupe.ai.count") == ["dedupe.ai.count.2026-10-01": "1"])
        try await db.removeCounterKVs(["assist.count.2026-10-01.claude"])
        #expect(try await db.kvRows(prefix: "assist.count").isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        collector.cancel()
        #expect(await collector.value == 1)
    }

    // MARK: Engine

    private static func engine() async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deps = Engine.Dependencies(loadSettings: { EngineSettings(metadataLookup: false) }, now: { Self.t0 }, fetcher: nil,
                                       claude: MockAgentProvider(behavior: .notLoggedIn),
                                       codex: MockAgentProvider(behavior: .notLoggedIn), sidecarDelay: .milliseconds(10),
                                       cliFacts: .inMemory(), loadMailSettings: { MailSettings() },
                                       mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()])
        return (try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps), root)
    }

    @Test func theEngineSetsPoliciesAndBuildsThePrivacyInputs() async throws {
        let (engine, root) = try await Self.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try await engine.db.insertPaper(Self.paper(1))
        #expect(try await engine.paperPolicy(paperID: plain.id) == nil)
        #expect(try await engine.assistPrivacy(paperID: plain.id, hostBundleID: nil) == .ok)
        #expect(try await engine.assistPrivacy(paperID: plain.id, hostBundleID: "com.apple.mail") == .confirm([.messagingHost]))

        let saved = try await engine.setPaperPolicy(paperID: plain.id, confidential: true, neverAI: false)
        #expect(saved?.confidential == true && saved?.setAt == Self.t0)
        #expect(try await engine.assistPrivacy(paperID: plain.id, hostBundleID: nil) == .confirm([.markedConfidential]))
        _ = try await engine.setPaperPolicy(paperID: plain.id, confidential: true, neverAI: true)
        #expect(try await engine.assistPrivacy(paperID: plain.id, hostBundleID: nil) == .blocked)
        #expect(try await engine.setPaperPolicy(paperID: plain.id, confidential: false, neverAI: false) == nil)
        await #expect(throws: PaperOperationError.paperNotFound("nope")) {
            _ = try await engine.setPaperPolicy(paperID: "nope", confidential: true, neverAI: false)
        }

        // A person's email without an identifier; an alert's paper with a DOI.
        let (person, _) = try await engine.db.insertMailMessage(
            MailMessage(accountID: "a", internetMessageID: "<p@x>", fromAddress: "pi@lab.example", senderKind: .person,
                        subject: "draft", receivedAt: Self.t0), items: [])
        var held = Self.paper(2)
        held.aiNote = ImportAnnotation.unpublishedHoldNote
        let manuscript = try await engine.db.insertPaper(held)
        try await engine.db.insertPaperSource(paperPK: manuscript.pk, PaperProvenance(
            mailMessageID: person.id, internetMessageID: "<p@x>", addedAt: Self.t0))
        let inputs = try await engine.privacyInputs(paperID: manuscript.id)
        #expect(inputs.provenance == [PaperSourceSummary(personSourced: true, identified: false)])
        #expect(try await engine.assistPrivacy(paperID: manuscript.id, hostBundleID: nil)
                == .confirm([.mailUnpublished, .personSourcedNoID]))

        let (alert, _) = try await engine.db.insertMailMessage(
            MailMessage(accountID: "a", internetMessageID: "<a@x>", fromAddress: "toc@journal.example", senderKind: .alert,
                        subject: "TOC", receivedAt: Self.t0), items: [])
        let published = try await engine.db.insertPaper(Self.paper(3, doi: "10.1/pub"))
        try await engine.db.insertPaperSource(paperPK: published.pk, PaperProvenance(
            mailMessageID: alert.id, internetMessageID: "<a@x>", addedAt: Self.t0))
        #expect(try await engine.assistPrivacy(paperID: published.id, hostBundleID: nil) == .ok)
        await engine.shutdown()
    }

    // MARK: The rule (pure)

    @Test func theVerdictTable() {
        let none: [PaperSourceSummary] = []
        let person = [PaperSourceSummary(personSourced: true, identified: false)]
        let personIdentified = [PaperSourceSummary(personSourced: true, identified: true)]
        let alert = [PaperSourceSummary(personSourced: false, identified: false)]
        typealias V = AssistPrivacy.Verdict
        let rows: [(PaperPolicy?, String?, [PaperSourceSummary], String?, V)] = [
            (nil, nil, none, nil, .ok),
            (nil, nil, none, "com.apple.Preview", .ok),
            (nil, nil, none, "com.apple.mail", .confirm([.messagingHost])),
            (nil, nil, none, "COM.TINYSPECK.SLACKMACGAP", .confirm([.messagingHost])),
            (nil, ImportAnnotation.unpublishedHoldNote, none, nil, .confirm([.mailUnpublished])),
            (nil, "something_else", none, nil, .ok),
            (nil, nil, person, nil, .confirm([.personSourcedNoID])),
            (nil, nil, personIdentified, nil, .ok),
            (nil, nil, alert, nil, .ok),
            (PaperPolicy(confidential: true), nil, none, nil, .confirm([.markedConfidential])),
            (PaperPolicy(confidential: true), ImportAnnotation.unpublishedHoldNote, person + personIdentified,
             "com.microsoft.Outlook", .confirm([.markedConfidential, .mailUnpublished, .personSourcedNoID, .messagingHost])),
            (PaperPolicy(neverAI: true), nil, none, nil, .blocked),
            (PaperPolicy(confidential: true, neverAI: true), ImportAnnotation.unpublishedHoldNote, person, "com.apple.mail", .blocked),
            (PaperPolicy(), nil, none, nil, .ok),
        ]
        for (i, r) in rows.enumerated() {
            #expect(AssistPrivacy.verdict(policy: r.0, aiNote: r.1, provenance: r.2, hostBundleID: r.3) == r.4, "row \(i)")
        }
    }
}
