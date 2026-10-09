import Foundation
import Testing
@testable import PaperDeckCore

/// The email merge popover's duplicate question (B3; DQ §7 `MailMergeDedupeTests`): the match is
/// found from the row's metadata before anything is merged, and each of the four answers does
/// what it says — link, link + re-read (undoable), use the email's version (the library paper
/// keeps its id, checklist and notes; undoable), add separately (remembered as different).
@Suite(.serialized) struct MailMergeDedupeTests {
    static let title = "Cortical folding emerges from progenitor mechanics"

    /// The text both copies print when the intake should see them as one work (a page signature).
    static let sharedText = DedupeKit.body(seed: "folding text")

    /// A PDF with `body` (enough text for a page signature), or the mail kit's short one.
    static func pdf(title: String, doi: String? = nil, body: String?) -> Data {
        guard let body else { return MailMergeKit.pdfData(title: title, doi: doi) }
        return DedupeKit.pdfData(title: title, doi: doi, body: body, pages: 2, tag: UUID().uuidString)
    }

    /// A finished library paper with the user's work on it, whose authors and year are known.
    static func finishedPaper(_ env: MailMergeKit.Env, title: String = MailMergeDedupeTests.title, doi: String? = nil,
                              body: String? = nil) async throws -> Paper {
        let url = env.root.appendingPathComponent("Downloads/library-\(UUID().uuidString.prefix(6)).pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pdf(title: title, doi: doi, body: body).write(to: url)
        let s = await env.engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
        await env.settle()
        let id = try #require(s.added.first)
        let pk = try await env.paper(id).pk
        _ = try await env.db.modifyPaper(pk: pk, now: env.clock.value) { p in
            p.authors = ["Ada Lovelace", "Grace Hopper"]
            p.year = 2025
        }
        _ = try await env.engine.setNotes(paperID: id, "Folding model — compare with Fig. 2.")
        _ = try await env.engine.setStatus(paperID: id, .done)
        return try await env.paper(id)
    }

    /// An email card from a person with one row (an attachment stored, unless `stored` is nil).
    static func card(_ env: MailMergeKit.Env, title: String = MailMergeDedupeTests.title, doi: String? = nil,
                     stored: Data?) async throws -> MailItem {
        let item = MailMergeKit.item(1, pdf: stored == nil ? .needsPDF : .hasPDF, title: title, doi: doi, year: 2025,
                                     authors: ["Lovelace, Ada"])
        let (_, rows) = try await MailMergeKit.insert(env, MailMergeKit.message(from: "advisor@example.edu"), items: [item],
                                                      attachments: stored.map { [0: $0] } ?? [:])
        return try #require(rows.first)
    }

    /// The defaults never replace or move a paper on a weak match; an identifier rules out "separate".
    @Test func theAnswersAndTheirDefaults() {
        func paper(_ status: PaperStatus, deleted: Bool = false) -> Paper {
            var p = Paper(pk: 1, sha256: "e", fileSize: 1, ids: PaperIDs(), title: "E", folder: "Papers/E", pdfName: "E.pdf",
                          originalName: "e.pdf", status: status)
            if deleted { p.deletedAt = Date(timeIntervalSince1970: 0) }
            return p
        }
        let weak = MailDupRules.choices(existing: paper(.done), band: .possible, relation: .newerVersion, newerSide: .new,
                                        identity: false)
        #expect(weak.default == .addSeparately && weak.choices.first == .addSeparately && weak.choices.count == 4)
        let newer = MailDupRules.choices(existing: paper(.toRead), band: .likely, relation: .newerVersion, newerSide: .new,
                                         identity: false)
        #expect(newer.default == .useThisVersion && newer.choices == [.useThisVersion, .link, .addSeparately])
        let done = MailDupRules.choices(existing: paper(.done), band: .likely, relation: .sameVersion, newerSide: nil,
                                        identity: false)
        #expect(done.default == .reread)
        let reading = MailDupRules.choices(existing: paper(.reading), band: .likely, relation: .sameWork, newerSide: nil,
                                           identity: false)
        #expect(reading.default == .link && !reading.choices.contains(.reread))
        let deleted = MailDupRules.choices(existing: paper(.toRead, deleted: true), band: .certain, relation: .sameWork,
                                           newerSide: nil, identity: true)
        #expect(deleted.default == .reread && !deleted.choices.contains(.addSeparately))
        let notice = MailDupRules.choices(existing: paper(.done), band: .likely, relation: .correction, newerSide: .existing,
                                          identity: false)
        #expect(notice.choices == [.addSeparately, .link] && notice.default == .addSeparately)
        let noticeID = MailDupRules.choices(existing: paper(.done), band: .certain, relation: .comment, newerSide: nil, identity: true)
        #expect(noticeID.choices == [.link] && noticeID.default == .link)
        #expect(MailDupChoice.allCases.map(\.kind) == [.skip, .rereadEarlier, .keepNew, .keepBoth])
    }

    @Test func theMatchIsShownBeforeMergingAndNothingChangesUntilAnAnswer() async throws {
        try await MailMergeKit.run { env in
            let e = try await Self.finishedPaper(env)
            let item = try await Self.card(env, stored: MailMergeKit.pdfData(title: Self.title))
            let match = try #require(await env.engine.mailDuplicateMatch(itemID: item.id))
            #expect(match.existingPaperID == e.id && match.band == .likely && !match.identity)
            #expect(match.choices.count == 4 && match.defaultChoice == .reread)      // a finished paper, same work
            #expect(match.existing.title == Self.title && match.existing.status == .done)
            #expect(!match.evidence.isEmpty && !match.headline.isEmpty)
            // Looking it up changed nothing: the row still waits, no paper was added.
            #expect(try await env.item(item.id).status == .pending)
            #expect(try await env.db.livePapers().count == 1)
            // An unrelated row: no question.
            let other = try await Self.card(env, title: "Deep learning predicts protein structure", stored: nil)
            #expect(await env.engine.mailDuplicateMatch(itemID: other.id) == nil)
            // With the duplicate check off: no question either.
            env.settings.value.dedupe.enabled = false
            #expect(await env.engine.mailDuplicateMatch(itemID: item.id) == nil)
        }
    }

    @Test func linkAndRereadThenUndoTheReread() async throws {
        try await MailMergeKit.run { env in
            let e = try await Self.finishedPaper(env)
            let first = try await Self.card(env, stored: MailMergeKit.pdfData(title: Self.title))
            let linked = try await env.engine.resolveMailDuplicate(itemID: first.id, paperID: e.id, choice: .link,
                                                                   options: MailMergeOptions(priority: .high))
            #expect(linked.paperID == e.id && linked.undoToken == nil)
            let row = try await env.item(first.id)
            #expect(row.status == .linked && row.paperID == e.id)
            let afterLink = try await env.paper(e.id)
            #expect(afterLink.status == .done && afterLink.priority == e.priority && afterLink.sha256 == e.sha256)
            #expect(try await env.db.paperSources(paperPK: e.pk).count == 1)
            // A second email: link and re-read.
            let second = try await Self.card(env, stored: nil)
            let reread = try await env.engine.resolveMailDuplicate(itemID: second.id, paperID: e.id, choice: .reread,
                                                                   options: MailMergeOptions())
            let back = try await env.paper(e.id)
            #expect(back.status == .toRead && back.doneAt == nil && back.scheduleMode != .none)
            #expect(try await env.db.readingCycles(paperPK: e.pk).count == 2)
            #expect(try await env.item(second.id).paperID == e.id)
            #expect(try await env.engine.undo(token: try #require(reread.undoToken)))
            let undone = try await env.paper(e.id)
            #expect(undone.status == .done && undone.doneAt == e.doneAt)
            // An answered row can't be answered again.
            await #expect(throws: DupResolutionError.reviewClosed(second.id)) {
                _ = try await env.engine.resolveMailDuplicate(itemID: second.id, paperID: e.id, choice: .link, options: MailMergeOptions())
            }
        }
    }

    /// Both copies print the same text: the merge's intake opens a (possible) review of the pair,
    /// which the answer closes as "keep both".
    @Test func addSeparatelyIsRememberedAsDifferent() async throws {
        try await MailMergeKit.run { env in
            let e = try await Self.finishedPaper(env, body: Self.sharedText)
            let item = try await Self.card(env, stored: Self.pdf(title: Self.title, body: Self.sharedText))
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .addSeparately,
                                                                options: MailMergeOptions(readWithAI: false))
            let id = try #require(out.paperID)
            #expect(id != e.id)
            let n = try await env.paper(id)
            #expect(n.isLive)
            #expect(try await env.item(item.id).paperID == id)
            #expect(try await env.db.dupPair(n.pk, e.pk)?.decision == "distinct")
            #expect(try await env.db.openDupReviews(involving: n.pk).isEmpty)
            let closedID = try #require(out.reviewID)
            let closed = try #require(try await env.db.dupReview(id: closedID))
            #expect(closed.state == .resolved && closed.choice == "keep_both" && closed.origin == .mail)
            #expect(out.undoToken != nil)
            // A library check doesn't ask about the pair again.
            #expect(try await env.engine.checkDuplicates().opened.isEmpty)
        }
    }

    @Test func useThisVersionReplacesTheFileAndKeepsTheUsersWork() async throws {
        try await MailMergeKit.run { env in
            let e = try await Self.finishedPaper(env)
            let item = try await Self.card(env, stored: MailMergeKit.pdfData(title: Self.title))
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .useThisVersion,
                                                                options: MailMergeOptions())
            #expect(out.paperID == e.id && out.undoToken != nil)
            await env.settle()
            let kept = try await env.paper(e.id)
            // The email's own notes (its prefill) are merged under the user's.
            #expect(kept.isLive && kept.sha256 != e.sha256 && kept.notes.hasPrefix(e.notes) && kept.status == .done)
            #expect(try await env.db.livePapers().map(\.id) == [e.id])
            let row = try await env.item(item.id)
            #expect(row.paperID == e.id && row.status != .pending)
            #expect(try await env.db.paperSources(paperPK: e.pk).count == 1)
            // Undo: the earlier file is back, the email's copy a paper of its own again.
            #expect(try await env.engine.undo(token: try #require(out.undoToken)))
            await env.settle()
            #expect(try await env.paper(e.id).sha256 == e.sha256)
        }
    }

    /// The same with the intake's own review of the pair (both copies print the same text).
    @Test func useThisVersionResolvesTheMergesOwnReview() async throws {
        try await MailMergeKit.run { env in
            let e = try await Self.finishedPaper(env, body: Self.sharedText)
            let item = try await Self.card(env, stored: Self.pdf(title: Self.title, body: Self.sharedText))
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .useThisVersion,
                                                                options: MailMergeOptions())
            let reviewID = try #require(out.reviewID)
            let review = try #require(try await env.db.dupReview(id: reviewID))
            #expect(review.origin == .mail && review.state == .resolved && review.choice == "keep_new")
            await env.settle()
            #expect(try await env.paper(e.id).sha256 != e.sha256)
            #expect(try await env.db.livePapers().map(\.id) == [e.id])
            #expect(try await env.item(item.id).paperID == e.id)
        }
    }

    @Test func useThisVersionOfAnIdentifierMatchGoesThroughThePark() async throws {
        try await MailMergeKit.run { env in
            let doi = "10.1038/s41586-026-07777-7"
            let e = try await Self.finishedPaper(env, doi: doi)
            let item = try await Self.card(env, doi: doi, stored: MailMergeKit.pdfData(title: Self.title, doi: doi))
            let match = try #require(await env.engine.mailDuplicateMatch(itemID: item.id))
            #expect(match.identity && match.band == .certain && !match.choices.contains(.addSeparately))
            let out = try await env.engine.resolveMailDuplicate(itemID: item.id, paperID: e.id, choice: .useThisVersion,
                                                                options: MailMergeOptions())
            #expect(out.paperID == e.id && out.reviewID != nil && out.undoToken != nil)
            await env.settle()
            let kept = try await env.paper(e.id)
            #expect(kept.sha256 != e.sha256 && kept.notes.hasPrefix(e.notes) && kept.ids.doi == doi)
            let row = try await env.item(item.id)
            #expect(row.status == .linked && row.paperID == e.id)
            #expect(!MailMergeKit.mailFileExists(env, item.pdfPath))
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
        }
    }
}
