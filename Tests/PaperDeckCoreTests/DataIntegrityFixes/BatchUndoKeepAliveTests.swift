import Foundation
import Testing
@testable import PaperDeckCore

/// A duplicate batch's one Undo token is minted when its last row is done, while each row's own
/// removals (a skipped parked file, a replaced file's record, a merged copy's text cache and
/// thumbnail) were timed from that row. The batch keeps every row's removals until its token
/// expires (dedupe-batch-7). The deadlines are computed from injected dates — no real waits.
@Suite struct BatchUndoKeepAliveTests {
    private static let t0 = Date(timeIntervalSince1970: 1_790_694_000)

    private static func total(_ list: [(key: String, seconds: TimeInterval)], _ key: String) -> TimeInterval {
        list.filter { $0.key == key }.map(\.seconds).reduce(0, +)
    }

    @Test func everyRowIsKeptUntilTheBatchTokenExpires() {
        var keep = DupBatchKeepAlive()
        var granted: [(key: String, seconds: TimeInterval)] = []
        keep.add(keys: ["merged.a", "parked.p1"], startedAt: Self.t0)
        granted += keep.extensions(at: Self.t0.addingTimeInterval(4))        // after row 1
        #expect(Self.total(granted, "merged.a") == 4 && Self.total(granted, "parked.p1") == 4)
        keep.add(keys: ["merged.b"], startedAt: Self.t0.addingTimeInterval(4))
        granted += keep.extensions(at: Self.t0.addingTimeInterval(12))       // after row 2 (slow: 8 s)
        keep.add(keys: [], startedAt: Self.t0.addingTimeInterval(12))         // a row with nothing to keep
        let tokenMinted = Self.t0.addingTimeInterval(20)
        granted += keep.extensions(at: tokenMinted)
        #expect(keep.extensions(at: tokenMinted).isEmpty)                    // nothing granted twice

        // A row's removal was due `lifetime + 5` after it started (at the latest); with the
        // extension it is due no earlier than the token's expiry + 5.
        let tokenExpires = tokenMinted.addingTimeInterval(UndoToken.lifetime)
        for (key, start) in [("merged.a", Self.t0), ("parked.p1", Self.t0), ("merged.b", Self.t0.addingTimeInterval(4))] {
            let due = start.addingTimeInterval(UndoToken.lifetime + 5 + Self.total(granted, key))
            #expect(due >= tokenExpires.addingTimeInterval(5), "\(key)")
            #expect(Self.total(granted, key) == tokenMinted.timeIntervalSince(start), "\(key)")
        }
    }

    /// Step by step: while the batch runs, no row's removal can come due (each extension covers the
    /// time up to the latest row).
    @Test func extensionsAreGrantedAfterEveryRow() {
        var keep = DupBatchKeepAlive()
        keep.add(keys: ["merged.a"], startedAt: Self.t0)
        var total: TimeInterval = 0
        for step in 1...10 {
            let now = Self.t0.addingTimeInterval(Double(step) * 25)              // 25 s per row
            total += Self.total(keep.extensions(at: now), "merged.a")
            #expect(Self.t0.addingTimeInterval(UndoToken.lifetime + 5 + total) > now)
        }
        #expect(total == 250)
    }

    @Test func theKeysNameWhatTheUndoStepsNeed() {
        let snap = DupPaperSnapshot(paper: Paper(id: "ABC", sha256: "s", fileSize: 1, title: "T", folder: "Papers/x",
                                                 pdfName: "x.pdf", originalName: "x.pdf", addedAt: Self.t0, updatedAt: Self.t0),
                                    checklist: [], tags: [], keys: [], cycles: [], sources: [], policy: nil)
        let steps: [DupUndoStep] = [
            .reopenReview(DupReview(newPaperID: nil, existingPaperID: nil, band: .likely, score: 1, createdAt: Self.t0)),
            .intakeRestoreDiscarded(pendingID: "p1"), .intakeUndoReplace(id: "u1"),
            .recreatePaper(snap, parkedFolder: nil, mailItems: [], keptPaperID: "k", heldJob: false, links: DupMergedLinks()),
            .removeCycle(paperPK: 1, n: 2),
        ]
        #expect(DupBatchKeepAlive.cleanupKeys(steps) == ["parked.p1", "replaced.u1", "merged.abc"])
    }

    @Test func aPendingRemovalWaitsForItsExtensions() async {
        let cleanups = UndoCleanups()
        let ran = OpsTestKit.Box(false)
        await cleanups.schedule("merged.x", after: 3600) { ran.value = true }
        await cleanups.extend("merged.x", by: 12)
        await cleanups.extend("merged.x", by: 3)
        await cleanups.extend("unknown", by: 5)
        let state = await cleanups.state("merged.x")
        #expect(state.pending && state.extra == 15)
        let unknown = await cleanups.state("unknown")
        #expect(!unknown.pending && unknown.extra == 0)
        #expect(!ran.value)
    }

    /// The batch wires it: rows merged earlier in a slow batch get their copies' removals extended
    /// (an engine clock that moves on every read stands in for a slow batch).
    @Test func resolveDuplicatesExtendsTheEarlierRowsRemovals() async throws {
        let root = try OpsTestKit.newRoot()
        let ticks = Ticker(OpsTestKit.start)
        let settings = OpsTestKit.Box(OpsTestKit.settings())
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings.value }, now: { ticks.next() }, calendar: OpsTestKit.calendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(),
            sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()]))
        let env = OpsTestKit.Env(engine: engine, root: root, clock: OpsTestKit.Box(OpsTestKit.start), settings: settings)
        defer { try? FileManager.default.removeItem(at: root) }
        var reviews: [(reviewID: String, choice: DupChoice)] = []
        var copies: [Paper] = []
        for i in 1...2 {
            let kept = try await OpsTestKit.addPaper(env, title: "Atlas \(i)")
            let copy = try await OpsTestKit.addPaper(env, title: "Atlas \(i) revised")
            let review = DupReview(newPaperID: copy.id, existingPaperID: kept.id, band: .likely, score: 0.9,
                                   createdAt: ticks.next(), newPaperPK: copy.pk, existingPaperPK: kept.pk, origin: .scan)
            try await engine.db.insertDupReview(review)
            reviews.append((review.id, .keepNew(reread: false)))
            copies.append(copy)
        }
        let out = await engine.resolveDuplicates(reviews)
        #expect(out.resolved.count == 2 && out.failed.isEmpty && out.undoToken != nil)
        let first = await engine.ctx.undoCleanups.state(UndoCleanups.mergedCopyKey(copies[0].id))
        let second = await engine.ctx.undoCleanups.state(UndoCleanups.mergedCopyKey(copies[1].id))
        #expect(first.pending && second.pending)
        #expect(first.extra > second.extra && second.extra > 0)
        #expect(try await engine.undoDuplicateResolution(token: try #require(out.undoToken)))
        for c in copies { #expect(try await engine.db.paper(id: c.id) != nil) }
        await engine.shutdown()
        await engine.db.close()
    }

    /// An engine clock that moves one second on every read.
    final class Ticker: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func next() -> Date {
            lock.withLock {
                t = t.addingTimeInterval(1)
                return t
            }
        }
    }
}
