import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 1 fixes F9, F10, F11 (Core side):
/// - F9: BibTeX keys are unique even when a suffixed key ("Data" + a) equals a later entry's own
///   key ("Dataa") — probe V5, inverted;
/// - F10: a toast's [Undo] expires with the engine's record (`Toast.withUndoExpired`), and undoing a
///   batch move to Recently Deleted leaves a paper the user restored and deleted again (probe V9,
///   mutation B2);
/// - F11: the multi-inspector lists at most `limit` papers plus "+N more" (`SelectionLogic.capped`).
@Suite struct P1FBatchExportUndoListTests {
    private typealias Kit = OpsTestKit

    // MARK: F9

    static func keys(_ bib: String) -> [String] {
        bib.components(separatedBy: "\n").filter { $0.hasPrefix("@") }.map { line in
            String(line.drop { $0 != "{" }.dropFirst().prefix { $0 != "," })
        }
    }

    @Test func bibtexKeysNeverCollideWithALaterEntrysOwnKey() {
        let e = { (t: String) in BatchExport.Entry(title: t, authors: ["Li Wang"], year: 2020) }
        let keys = Self.keys(BatchExport.bibtex([e("Data study"), e("Data again"), e("Dataa study")]))
        #expect(keys == ["Wang2020Data", "Wang2020Dataa", "Wang2020Dataaa"], "\(keys)")
        // The other order: the own key first, then the suffixes skip it.
        let reversed = Self.keys(BatchExport.bibtex([e("Dataa study"), e("Data study"), e("Data again")]))
        #expect(reversed == ["Wang2020Dataa", "Wang2020Data", "Wang2020Datab"], "\(reversed)")
        // Many look-alike titles: every key unique, the first of each base unsuffixed.
        let titles = ["Data", "Dataa", "Datab", "Data", "Dataa", "Data", "Datac", "Data", "Dataaa", "Data"]
        let many = Self.keys(BatchExport.bibtex(titles.map { e($0 + " study") }))
        #expect(Set(many).count == many.count, "\(many)")
        #expect(many.prefix(3) == ["Wang2020Data", "Wang2020Dataa", "Wang2020Datab"])
    }

    // MARK: F10

    @Test func anExpiredUndoLosesItsButtonAndStickiness() throws {
        let toast = Toast(id: "batch-t", kind: .success, message: "Moved 3 papers to To Read",
                          buttons: [Toast.Button(title: "Undo", action: .undo(token: "t"))])
        #expect(toast.isSticky && toast.undoTokens == ["t"])
        let expired = try #require(toast.withUndoExpired(note: "Undo expired"))
        #expect(expired.id == toast.id && expired.buttons.isEmpty && !expired.isSticky)
        #expect(expired.message == "Moved 3 papers to To Read · Undo expired")
        #expect(expired.undoTokens == nil && expired.withUndoExpired(note: "x") == nil)
        // Other buttons stay (the toast stays sticky for them); a toast without [Undo] is left alone.
        let mixed = Toast(kind: .success, message: "m", buttons: [Toast.Button(title: "View", action: .openPaper(id: "p")),
                                                                  Toast.Button(title: "Undo", action: .undo(token: "u"))])
        let kept = try #require(mixed.withUndoExpired(note: "Undo expired"))
        #expect(kept.buttons == [Toast.Button(title: "View", action: .openPaper(id: "p"))] && kept.isSticky)
        #expect(Toast(kind: .info, message: "plain").withUndoExpired(note: "x") == nil)
        // The App's window ends no later than the engine's record.
        #expect(Toast.undoButtonLifetime <= UndoToken.lifetime && Toast.undoButtonLifetime > 0)
    }

    @Test func undoingABatchTrashLeavesAPaperTheUserDeletedAgain() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", folder: "2024_A")
            let b = try await Kit.addPaper(env, title: "B", folder: "2024_B")
            let out = try await env.engine.applyBatch(.moveToTrash, paperIDs: [a.id, b.id])
            env.advance(2)
            _ = try await env.engine.restore(paperID: a.id)
            env.advance(2)
            _ = try await env.engine.softDelete(paperID: a.id)
            #expect(try await env.engine.undoBatch(token: try #require(out.undoToken)))
            let pa = try await Kit.paper(env, a.id), pb = try await Kit.paper(env, b.id)
            #expect(pa.isDeleted && pb.isLive)                          // the user's second delete stands
        }
    }

    // MARK: F11

    @Test func theInspectorListIsCapped() {
        let ids = (0..<5_000).map { "p\($0)" }
        let capped = SelectionLogic.capped(ids, limit: 50)
        #expect(capped.shown == Array(ids.prefix(50)) && capped.more == 4_950)
        let exact = SelectionLogic.capped(Array(ids.prefix(50)), limit: 50)
        #expect(exact.shown.count == 50 && exact.more == 0)
        let few = SelectionLogic.capped(["a", "b"], limit: 50)
        #expect(few.shown == ["a", "b"] && few.more == 0)
        let none = SelectionLogic.capped(["a", "b"], limit: -1)
        #expect(none.shown.isEmpty && none.more == 2)
    }
}
