import Foundation
import Testing
@testable import PaperDeckCore

// mail_item rows, paper_source provenance and the ChangeHub events of every mail write.

fileprivate let t0 = Date(timeIntervalSince1970: 1_790_000_000.5)

fileprivate func message(_ n: Int, kind: SenderKind = .person) -> MailMessage {
    MailMessage(accountID: "acct", internetMessageID: "<item-\(n)@example.org>", fromAddress: "p@example.org",
                senderKind: kind, subject: "S\(n)", receivedAt: t0.addingTimeInterval(Double(n)),
                createdAt: t0, updatedAt: t0)
}

fileprivate func item(_ ord: Int, ids: PaperIDs = PaperIDs(), pdf: MailPDFState = .unknown,
                      status: MailItemStatus = .pending) -> MailItem {
    MailItem(ord: ord, cand: "c\(ord)", origin: .link, ids: ids, pdfState: pdf, status: status,
             createdAt: t0, updatedAt: t0)
}

fileprivate func paper(_ n: Int) -> Paper {
    Paper(sha256: String(format: "%064x", n), fileSize: 10, title: "Paper \(n)", folder: "Papers/p\(n)",
          pdfName: "p\(n).pdf", originalName: "p\(n).pdf")
}

@Suite struct MailDBItemTests {
    @Test func everyItemFieldRoundTrips() async throws {
        let db = try Database.inMemory()
        let full = MailItem(
            id: UUID().uuidString.lowercased(), ord: 3, cand: "c3", origin: .attachment, foundBy: .ai,
            title: "Molecular and cellular dynamics of the developing neocortex", authors: ["Li Wang", "Ana \"Q\" Müller"],
            venue: "Nature", year: 2024,
            ids: PaperIDs(doi: "10.1038/s41586-024-08351-7", arxivID: "2606.24530", arxivVersion: 2,
                          pii: "S0092867424013321", publishedDOI: "10.1016/j.cell.2024.1"),
            url: "https://www.nature.com/articles/s41586-024-08351-7",
            urlOriginal: "https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.nature.com%2F&data=x",
            host: "nature.com", metaSource: .crossref, relevance: .requested, why: "Asked to present Fig. 2",
            confidence: 0.87, pdfState: .hasPDF, pdfPath: "0f8fad5b/1.pdf", pdfSHA256: String(repeating: "e", count: 64),
            pdfBytes: 5_000_000_000, downloadError: "HTTP 403", paperID: UUID().uuidString.lowercased(),
            status: .linked, createdAt: t0, updatedAt: t0.addingTimeInterval(5))
        let bare = MailItem(ord: 4, cand: "c4", origin: .citation, createdAt: t0, updatedAt: t0)
        let (m, items) = try await db.insertMailMessage(message(1), items: [full, bare])
        var expectedFull = full, expectedBare = bare
        expectedFull.messagePK = m.pk; expectedFull.pk = items[0].pk
        expectedBare.messagePK = m.pk; expectedBare.pk = items[1].pk
        #expect(items == [expectedFull, expectedBare])
        #expect(try await db.mailItems(messagePK: m.pk) == [expectedFull, expectedBare])
        #expect(try await db.mailItem(id: full.id.uppercased()) == expectedFull)
        #expect(try await db.mailItem(id: "nope") == nil)
        try #require(items.count > 1)          // no index past a failed expectation (QA-15)
        #expect(bare.ids.isEmpty && items[1].authors.isEmpty && items[1].relevance == nil)
    }

    @Test func blankIdentifiersAreStoredAsNull() async throws {
        let db = try Database.inMemory()
        let (_, items) = try await db.insertMailMessage(message(1), items: [
            item(1, ids: PaperIDs(doi: "  ", arxivID: "", pii: "\n")),
            item(2, ids: PaperIDs(doi: " ")),
        ])
        #expect(items.allSatisfy { $0.ids.doi == nil && $0.ids.arxivID == nil && $0.ids.pii == nil })
    }

    @Test func batchReadHasEveryRequestedKey() async throws {
        let db = try Database.inMemory()
        let (a, _) = try await db.insertMailMessage(message(1), items: [item(2), item(1)])
        let (b, _) = try await db.insertMailMessage(message(2), items: [])
        let (c, _) = try await db.insertMailMessage(message(3), items: [item(1)])
        let map = try await db.mailItems(messagePKs: [a.pk, b.pk, c.pk, 999])
        #expect(map.keys.sorted() == [a.pk, b.pk, c.pk, 999].sorted())
        #expect(map[a.pk]?.map(\.cand) == ["c1", "c2"])
        #expect(map[b.pk] == [] && map[999] == [] && map[c.pk]?.count == 1)
        #expect(try await db.mailItems(messagePKs: []).isEmpty)
    }

    @Test func upsertInsertsThenUpdatesByID() async throws {
        let db = try Database.inMemory()
        let (m, _) = try await db.insertMailMessage(message(1), items: [item(1)])
        let t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(120)

        var added = item(2)
        added.messagePK = m.pk
        added.foundBy = .ai
        let inserted = try await db.upsertMailItem(added, now: t1)
        #expect(inserted.pk > 0 && inserted.createdAt == t0 && inserted.updatedAt == t1 && inserted.foundBy == .ai)
        #expect(try await db.mailMessage(pk: m.pk)?.updatedAt == t1)     // the card changed

        var edit = inserted
        edit.pdfState = .inLibrary
        edit.status = .merged
        edit.paperID = "0f8fad5b-d9cb-469f-a165-70867728950e"
        edit.createdAt = t2                                             // created_at is never rewritten
        let updated = try await db.upsertMailItem(edit, now: t2)
        #expect(updated.pk == inserted.pk && updated.createdAt == t0 && updated.updatedAt == t2)
        #expect(updated.status == .merged && updated.pdfState == .inLibrary && updated.paperID == edit.paperID)
        #expect(try await db.mailItems(messagePK: m.pk).count == 2)

        await #expect(throws: SQLiteError.self) {                        // unknown message
            try await db.upsertMailItem(MailItem(messagePK: 4242, ord: 0, cand: "c9", origin: .link))
        }
    }

    @Test func deleteItemIsIdempotent() async throws {
        let db = try Database.inMemory()
        let (m, items) = try await db.insertMailMessage(message(1), items: [item(1), item(2)])
        try await db.deleteMailItem(id: items[0].id.uppercased(), now: t0.addingTimeInterval(9))
        #expect(try await db.mailItems(messagePK: m.pk).map(\.cand) == ["c2"])
        #expect(try await db.mailMessage(pk: m.pk)?.updatedAt == t0.addingTimeInterval(9))
        try await db.deleteMailItem(id: items[0].id)
        try await db.deleteMailItem(id: "missing")
        #expect(try await db.mailItems(messagePK: m.pk).count == 1)
    }

    @Test func itemsCascadeWithTheirMessage() async throws {
        let db = try Database.inMemory()
        let (m, _) = try await db.insertMailMessage(message(1), items: [item(1), item(2)])
        let (keep, _) = try await db.insertMailMessage(message(2), items: [item(1)])
        let pk = m.pk
        let left = try await db.transaction { db in
            try db.db.run("DELETE FROM mail_message WHERE pk = ?", [.integer(pk)])
            return try db.db.scalarInt("SELECT count(*) FROM mail_item")
        }
        #expect(left == 1)
        #expect(try await db.mailItems(messagePK: keep.pk).count == 1)
    }

    @Test func openItemsNeedingAPDF() async throws {
        let db = try Database.inMemory()
        let (m, items) = try await db.insertMailMessage(message(1), items: [
            item(1, pdf: .needsPDF), item(2, pdf: .downloadable), item(3, pdf: .hasPDF), item(4, pdf: .unknown),
            item(5, pdf: .downloading), item(6, pdf: .inLibrary),
            item(7, pdf: .needsPDF, status: .skipped), item(8, pdf: .downloadable, status: .merged),
            item(9, pdf: .needsPDF, status: .linked),
        ])
        let (m2, items2) = try await db.insertMailMessage(message(2), items: [item(1, pdf: .needsPDF)])
        #expect(try await db.openMailItemsNeedingPDF().map(\.pk) == [items[0].pk, items[1].pk, items2[0].pk])
        #expect(m.pk < m2.pk)
    }

    @Test func lookupsByDOIAndArXiv() async throws {
        let db = try Database.inMemory()
        let (_, items) = try await db.insertMailMessage(message(1), items: [
            item(1, ids: PaperIDs(doi: "10.1038/S41586-024-08351-7")),
            item(2, ids: PaperIDs(doi: "10.1101/2024.05.01.592000")),             // old bioRxiv prefix
            item(3, ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"), status: .merged),
            item(4, ids: PaperIDs(arxivID: "2606.24530", arxivVersion: 3)),
            item(5, ids: PaperIDs(arxivID: "math.GT/0309136")),
            item(6, ids: PaperIDs(doi: "10.1101/2023.01.01.111111", publishedDOI: "10.1016/j.neuron.2024.7")),
        ])
        let (_, other) = try await db.insertMailMessage(message(2), items: [
            item(1, ids: PaperIDs(doi: "10.1038/s41586-024-08351-7")),
        ])
        #expect(try await db.mailItems(doi: " 10.1038/s41586-024-08351-7 ").map(\.pk) == [items[0].pk, other[0].pk])
        #expect(try await db.mailItems(doi: "10.64898/2024.05.01.592000v2").map(\.pk) == [items[1].pk])   // new prefix
        #expect(try await db.mailItems(doi: "10.1016/J.NEURON.2024.7").map(\.pk) == [items[5].pk])
        #expect(try await db.mailItems(doi: "10.9999/none").isEmpty)
        #expect(try await db.mailItems(doi: "  ").isEmpty)
        #expect(try await db.mailItems(arxivID: "2606.24530").map(\.pk) == [items[3].pk])
        #expect(try await db.mailItems(arxivID: "2606.24530v1").map(\.pk) == [items[3].pk])
        #expect(try await db.mailItems(arxivID: "MATH.gt/0309136").map(\.pk) == [items[4].pk])
        #expect(try await db.mailItems(arxivID: "").isEmpty)
    }
}

@Suite struct MailDBProvenanceTests {
    @Test func provenanceRoundTripsInAddedOrder() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(paper(1))
        let full = PaperProvenance(
            kind: "email", mailMessageID: "0f8fad5b-d9cb-469f-a165-70867728950e",
            internetMessageID: "<abc@wustl.edu>", fromAddress: "prof.x@wustl.edu", fromName: "Prof. X",
            subject: "Papers for Thursday", receivedAt: t0, webLink: "https://outlook.office.com/mail/x",
            requestKind: .advisorRequest, summary: "Read before Thursday.",
            dueHint: LocalDate(year: 2026, month: 10, day: 3), addedAt: t0.addingTimeInterval(10))
        let minimal = PaperProvenance(addedAt: t0)
        try await db.insertPaperSource(paperPK: p.pk, full)
        try await db.insertPaperSource(paperPK: p.pk, minimal)
        #expect(try await db.paperSources(paperPK: p.pk) == [minimal, full])     // oldest first
        #expect(try await db.paperSources(paperPK: 999).isEmpty)
    }

    @Test func repeatingAnEmailRefreshesInsteadOfDuplicating() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(paper(1))
        try await db.insertPaperSource(paperPK: p.pk, PaperProvenance(internetMessageID: "<a@x>", subject: "old",
                                                                      addedAt: t0))
        try await db.insertPaperSource(paperPK: p.pk, PaperProvenance(internetMessageID: "<A@X>", subject: "new",
                                                                      addedAt: t0.addingTimeInterval(99)))
        let rows = try await db.paperSources(paperPK: p.pk)
        #expect(rows.count == 1 && rows[0].subject == "new" && rows[0].addedAt == t0)
        #expect(rows[0].internetMessageID == "<a@x>")
        // Without a Message-ID every record is its own row.
        try await db.insertPaperSource(paperPK: p.pk, PaperProvenance(subject: "n1", addedAt: t0))
        try await db.insertPaperSource(paperPK: p.pk, PaperProvenance(subject: "n2", addedAt: t0))
        #expect(try await db.paperSources(paperPK: p.pk).count == 3)
    }

    @Test func provenanceFollowsThePaper() async throws {
        let db = try Database.inMemory()
        let a = try await db.insertPaper(paper(1)), b = try await db.insertPaper(paper(2))
        for pk in [a.pk, b.pk] {
            try await db.insertPaperSource(paperPK: pk, PaperProvenance(internetMessageID: "<m@x>", addedAt: t0))
        }
        await #expect(throws: SQLiteError.self) {
            try await db.insertPaperSource(paperPK: 999, PaperProvenance(addedAt: t0))
        }
        try await db.softDelete(pk: a.pk)                                // soft delete keeps it (restorable)
        #expect(try await db.paperSources(paperPK: a.pk).count == 1)
        try await db.hardDelete(pk: a.pk)                                // hard delete cascades
        #expect(try await db.paperSources(paperPK: a.pk).isEmpty)
        #expect(try await db.paperSources(paperPK: b.pk).count == 1)
        let total = try await db.transaction { db in try db.db.scalarInt("SELECT count(*) FROM paper_source") }
        #expect(total == 1)
    }
}

@Suite(.timeLimit(.minutes(1))) struct MailDBChangeTests {
    @Test func everyMailWriteIsAnnouncedAfterCommit() async throws {
        let db = try Database.inMemory()
        let p = try await db.insertPaper(paper(1))
        var events = db.changes.subscribe().makeAsyncIterator()

        let (m, items) = try await db.insertMailMessage(message(1), items: [item(1)])
        #expect(await events.next() == .mail(pk: m.pk))
        await #expect(throws: DatabaseError.self) { try await db.insertMailMessage(message(1), items: []) }
        _ = try await db.updateMailMessage(m)
        #expect(await events.next() == .mail(pk: m.pk))                  // the failed insert sent nothing
        _ = try await db.modifyMailMessage(pk: m.pk) { $0.seen = true }
        #expect(await events.next() == .mail(pk: m.pk))
        _ = try await db.upsertMailItem(items[0])
        #expect(await events.next() == .mail(pk: m.pk))
        try await db.deleteMailItem(id: "missing")                       // no-op: silent
        try await db.deleteMailItem(id: items[0].id)
        #expect(await events.next() == .mail(pk: m.pk))
        try await db.insertPaperSource(paperPK: p.pk, PaperProvenance(internetMessageID: m.internetMessageID, addedAt: t0))
        #expect(await events.next() == .paper(pk: p.pk))
        try await db.setMailCursor(accountID: "acct", MailCursor("1"))   // internal state: silent
        #expect(try await db.purgeMailBodies(handledBefore: t0) == 0)    // nothing purged: silent
        #expect(try await db.wakeSnoozedMail(now: t0) == 0)
        #expect(try await db.resetRunningTriageToQueued() == 0)
        _ = try await db.modifyMailMessage(pk: m.pk) { $0.state = .dismissed; $0.handledAt = t0 }
        #expect(await events.next() == .mail(pk: m.pk))
        #expect(try await db.purgeMailBodies(handledBefore: t0.addingTimeInterval(1)) == 1)
        #expect(await events.next() == .mailBulk)
        try await db.deleteAllMailData()
        #expect(await events.next() == .mailBulk)
        try await db.deleteAllMailData()                                 // nothing left: silent
        try await db.setKV("sentinel", "1")
        #expect(await events.next() == .settings)
    }

    @Test func burstsCoalesce() async throws {
        let db = try Database.inMemory()
        var events = db.changes.subscribe().makeAsyncIterator()

        // Many messages in one transaction → one .mailBulk.
        let batch = (1...40).map { message($0) }
        try await db.transaction { db in
            for m in batch { _ = try db.insertMailMessage(m, items: []) }
        }
        #expect(await events.next() == .mailBulk)

        // Repeated writes to one message in one transaction → one event, after the papers'.
        let first = try #require(try await db.mailMessages(states: [.pending], limit: 1).first)
        let pk = first.pk, pap = paper(1)
        let paperPK = try await db.transaction { db -> Int64 in
            _ = try db.modifyMailMessage(pk: pk) { $0.seen = true }
            _ = try db.modifyMailMessage(pk: pk) { $0.triageAttempt += 1 }
            let saved = try db.insertPaper(pap)
            try db.insertPaperSource(paperPK: saved.pk, PaperProvenance(addedAt: t0))
            return saved.pk
        }
        #expect(await events.next() == .paper(pk: paperPK))
        #expect(await events.next() == .mail(pk: pk))

        // A rolled-back transaction announces nothing.
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.transaction { db in
                _ = try db.modifyMailMessage(pk: pk) { $0.seen = false }
                throw Boom()
            }
        }
        try await db.setKV("sentinel", "1")
        #expect(await events.next() == .settings)
        #expect(try await db.mailMessage(pk: pk)?.seen == true)
    }
}
