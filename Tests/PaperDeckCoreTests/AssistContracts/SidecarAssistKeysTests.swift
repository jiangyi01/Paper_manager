import Foundation
import Testing
@testable import PaperDeckCore

/// card.json's optional reading-assist keys (READING_ASSIST_PLAN §5; R-B-5, R-B-7): `policy`,
/// `readingCycles` and `distinctFrom` — written only when non-empty (other cards keep their exact
/// bytes), read leniently, and restored by a rebuild (the canonical dump is unchanged). Plus the
/// assist's daily housekeeping (`Maintenance.assistRetention`).
@Suite(.serialized) struct SidecarAssistKeysTests {
    private typealias Kit = OpsTestKit

    static func card(_ env: OpsTestKit.Env, _ id: String) async throws -> [String: Any] {
        await env.engine.ctx.sidecars.flush()
        let p = try await Kit.paper(env, id)
        let data = try Data(contentsOf: env.engine.ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theKeysAreWrittenOnlyWhenNonEmptyAndARebuildRestoresThem() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "Alpha")
            let b = try await Kit.addPaper(env, title: "Beta")
            let c = try await Kit.addPaper(env, title: "Gamma")
            await env.engine.ctx.syncSidecar(pk: c.pk)
            await env.engine.ctx.sidecars.flush()
            let cBytes = try Data(contentsOf: env.engine.ctx.folderURL(c).appendingPathComponent(CardSidecar.fileName))

            _ = try await env.engine.setPaperPolicy(paperID: a.id, confidential: true, neverAI: false)
            let t0 = Kit.start.addingTimeInterval(-86_400 * 40)
            try await env.db.insertReadingCycle(paperPK: a.pk, ReadingCycle(n: 1, startedAt: t0, doneAt: t0.addingTimeInterval(3_600)))
            try await env.db.insertReadingCycle(paperPK: a.pk, ReadingCycle(n: 2, startedAt: Kit.start, reason: "reread"))
            try await env.db.setDupPair(a.pk, b.pk, decision: "distinct", relation: nil, decidedBy: "user", at: Kit.start)
            for p in [a, b, c] { await env.engine.ctx.syncSidecar(pk: p.pk) }

            let ca = try await Self.card(env, a.id)
            let policy = try #require(ca["policy"] as? [String: Any])
            #expect(policy["confidential"] as? Bool == true && policy["neverAI"] as? Bool == false && policy["setBy"] as? String == "user")
            let cycles = try #require(ca["readingCycles"] as? [[String: Any]])
            #expect(cycles.map { $0["n"] as? Int } == [1, 2] && cycles[1]["reason"] as? String == "reread")
            #expect(ca["distinctFrom"] as? [String] == [b.id])
            let cb = try await Self.card(env, b.id)
            #expect(cb["distinctFrom"] as? [String] == [a.id] && cb["policy"] == nil && cb["readingCycles"] == nil)
            // A paper with none of them: byte-identical card.json.
            let cNow = try Data(contentsOf: env.engine.ctx.folderURL(c).appendingPathComponent(CardSidecar.fileName))
            #expect(cNow == cBytes)

            // The index rebuilt from the cards: the canonical dump (which now carries the three keys) is unchanged.
            let before = try await env.engine.dumpCanonical()
            #expect(String(decoding: before, as: UTF8.self).contains("\"distinctFrom\""))
            _ = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            #expect(try await env.engine.dumpCanonical() == before)
            let ra = try await Kit.paper(env, a.id), rb = try await Kit.paper(env, b.id)
            #expect(try await env.db.paperPolicy(paperPK: ra.pk)?.confidential == true)
            #expect(try await env.db.readingCycles(paperPK: ra.pk).map(\.n) == [1, 2])
            #expect(try await env.db.dupPair(ra.pk, rb.pk)?.decision == "distinct")
            #expect(try await env.db.dupPairPartnerIDs(paperPK: rb.pk) == [a.id])

            // Both flags off: the key is gone again.
            _ = try await env.engine.setPaperPolicy(paperID: a.id, confidential: false, neverAI: false)
            #expect(try await Self.card(env, a.id)["policy"] == nil)
        }
    }

    @Test func theKeysAreReadLeniently() throws {
        let base = CardSidecar(paper: Paper(id: "aaaa", sha256: "bbbb", fileSize: 1, title: "T", folder: "Papers/T", pdfName: "T.pdf",
                                            originalName: "T.pdf", addedAt: Kit.start, updatedAt: Kit.start),
                               checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: try base.encoded()) as? [String: Any])
        #expect(json["policy"] == nil && json["readingCycles"] == nil && json["distinctFrom"] == nil)
        json["policy"] = ["neverAI": true, "setBy": "martian"]
        json["readingCycles"] = [["n": "x"], ["n": 2, "startedAt": "not a date"], ["n": 2, "startedAt": "2026-09-01T10:00:00Z"],
                                 ["n": 0]]
        json["distinctFrom"] = ["AAAA", 5, "CCCC", ""]
        let decoded = try CardSidecar.decoded(from: try JSONSerialization.data(withJSONObject: json))
        let m = decoded.toModels(folder: "Papers/T")
        #expect(m.policy?.neverAI == true && m.policy?.confidential == false && m.policy?.setBy == .rebuild)
        #expect(m.policy?.setAt == Kit.start)                                  // no date: the card's updatedAt
        #expect(m.readingCycles.map(\.n) == [2] && m.readingCycles.first?.startedAt == Kit.start)   // first n=2 wins
        #expect(m.distinctFrom == ["cccc"])                                    // itself, a number and "" dropped
        // A policy with neither flag restores nothing.
        json["policy"] = ["confidential": false, "neverAI": false]
        #expect(try CardSidecar.decoded(from: try JSONSerialization.data(withJSONObject: json)).toModels(folder: "x").policy == nil)
    }

    @Test func aDuplicateDecisionRewritesBothCards() async throws {
        try await DedupeKit.run { env in
            let (e, n, review) = try await DupResolutionTests.held(env)
            _ = try await env.engine.resolveDuplicate(reviewID: review.id, .keepBoth(linkAsRelated: false))
            await env.engine.ctx.sidecars.flush()
            func distinct(_ p: Paper) throws -> [String]? {
                let data = try Data(contentsOf: env.engine.ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName))
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["distinctFrom"] as? [String]
            }
            #expect(try distinct(try await env.paper(e.id)) == [n.id])
            #expect(try distinct(try await env.paper(n.id)) == [e.id])
        }
    }

    // MARK: Daily housekeeping

    @Test func assistRetentionPrunesEarlierDaysCountersOnly() async throws {
        try await Kit.run { env in
            let today = LocalDate.today(now: Kit.start, calendar: Kit.calendar)
            let yesterday = today.adding(days: -1)
            for (key, v) in [("assist.count.\(today.iso).claude", 3), ("assist.count.\(yesterday.iso).claude", 7),
                             ("assist.count.2025-01-01.codex", 1), ("dedupe.ai.count.\(yesterday.iso)", 2),
                             ("dedupe.ai.count.\(today.iso)", 1), ("assist.count.garbage", 9)] {
                try await env.db.setCounterKV(key, v)
            }
            let report = try await env.engine.maintenance.assistRetention()
            #expect(report.removedCounters == 3)
            let left = try await env.db.kvRows(prefix: "assist.count.").keys.sorted()
                + (try await env.db.kvRows(prefix: "dedupe.ai.count.").keys.sorted())
            #expect(left == ["assist.count.\(today.iso).claude", "assist.count.garbage", "dedupe.ai.count.\(today.iso)"])
            // Launch maintenance runs it too.
            let launch = await env.engine.maintenance.onLaunch()
            #expect(launch.errors.isEmpty && launch.assist.removedCounters == 0)
            #expect(Maintenance.isEarlierCounterDay("assist.count.2026-09-28.claude", prefix: "assist.count", today: today))
            #expect(!Maintenance.isEarlierCounterDay("assist.count.\(today.iso)", prefix: "assist.count", today: today))
        }
    }
}
