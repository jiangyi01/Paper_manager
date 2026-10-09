import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fix B3-4 (and T-1, V9): the email popover's answers for a paper in Recently Deleted.
/// "Link and re-read" (the default for a deleted, finished paper) restored the paper outside the
/// undo record: Undo reverted the re-read but left the paper restored. A plain link that restored
/// it had no Undo at all. Both now put it back in Recently Deleted, like the decision sheet.
@Suite("Phase 2 fixes RD: mail popover of a deleted paper", .serialized)
struct RDMailDedupeFixTests {
    @Test func rereadOfADeletedPaperUndoesTheRestoreToo() async throws {
        try await MailMergeKit.run { env in
            let e = try await MailMergeDedupeTests.finishedPaper(env)
            _ = try await env.engine.softDelete(paperID: e.id)
            #expect(try await env.paper(e.id).isDeleted)
            let item = try await MailMergeDedupeTests.card(env, stored: nil)
            let match = try #require(await env.engine.mailDuplicateMatch(itemID: item.id))
            #expect(match.defaultChoice == .reread)
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .reread,
                                                                options: MailMergeOptions())
            let reread = try await env.paper(e.id)
            #expect(reread.isLive && reread.status == .toRead)
            #expect(try await env.engine.undo(token: try #require(out.undoToken)))
            let after = try await env.paper(e.id)
            #expect(after.isDeleted, "Undo left the paper restored out of Recently Deleted")
            #expect(after.status == .done && after.doneAt == e.doneAt)
        }
    }

    @Test func aLinkThatRestoredThePaperIsUndoable() async throws {
        try await MailMergeKit.run { env in
            let e = try await MailMergeDedupeTests.finishedPaper(env)
            _ = try await env.engine.softDelete(paperID: e.id)
            let item = try await MailMergeDedupeTests.card(env, stored: nil)
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .link,
                                                                options: MailMergeOptions())
            #expect(try await env.paper(e.id).isLive)
            #expect(try await env.item(item.id).paperID == e.id)
            let token = try #require(out.undoToken, "a link that restored the paper must be undoable")
            #expect(try await env.engine.undo(token: token))
            #expect(try await env.paper(e.id).isDeleted)
            // A plain link of a live paper still changes nothing in the library (no Undo).
            let live = try await MailMergeDedupeTests.finishedPaper(env, title: "Another paper about cortical folding mechanics")
            let second = try await MailMergeDedupeTests.card(env, title: live.title, stored: nil)
            let plain = try await env.engine.resolveMailDuplicate(itemID: second.id, paperID: live.id, choice: .link,
                                                                  options: MailMergeOptions())
            #expect(plain.undoToken == nil)
        }
    }

    /// T-1 (V9): with the duplicate check off, the popover's answer is refused and nothing changes.
    @Test func anAnswerIsRefusedWithTheDuplicateCheckOff() async throws {
        try await MailMergeKit.run { env in
            let e = try await MailMergeDedupeTests.finishedPaper(env)
            let item = try await MailMergeDedupeTests.card(env, stored: nil)
            env.settings.value.dedupe.enabled = false
            for choice in MailDupChoice.allCases {
                await #expect(throws: DupResolutionError.choiceUnavailable(choice.rawValue)) {
                    _ = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: choice,
                                                                  options: MailMergeOptions())
                }
            }
            #expect(try await env.item(item.id).status == .pending)
            let after = try await env.paper(e.id)
            #expect(after.status == .done && after.isLive)
            #expect(try await env.db.livePapers().count == 1)
        }
    }
}
