import Foundation
import Testing
@testable import PaperDeckCore

// mail_message rows: round-trip, Message-ID dedupe, update/modify, queries, counts,
// retention purge, clear-all and sync cursors.

fileprivate let t0 = Date(timeIntervalSince1970: 1_790_000_000.25)     // exact in milliseconds
fileprivate let day: TimeInterval = 86_400

/// Every field set to a non-default value.
fileprivate func fullMessage() -> MailMessage {
    MailMessage(
        id: UUID().uuidString.lowercased(), accountID: "gmail-1", sourceRef: "INBOX:1700000000:42",
        internetMessageID: "<CAF=abc.123@mail.gmail.com>", fromAddress: "prof.x@wustl.edu",
        fromName: "Prof. \"X\" 王", ruleID: "rule-advisor", senderKind: .advisor, authState: .pass,
        subject: "组会论文 — papers for Thursday 📄", receivedAt: t0,
        webLink: "https://mail.google.com/mail/u/0/#search/rfc822msgid:abc",
        snippet: "Please read [c1] before Thursday", bodyText: "Hi,\nplease read [c1] and [c2] before Thursday.\n\u{0}end",
        bodyPurged: false, state: .snoozed, userTouched: true, snoozedUntil: t0.addingTimeInterval(day),
        triageState: .done, triageSource: .ai,
        triage: MailTriage(hasReadingRequest: true, requestKind: .journalClub, summary: "Read two papers; present Fig. 2.",
                           requester: "Prof. X", dueDate: LocalDate(year: 2026, month: 10, day: 3),
                           dueEvidence: "before Thursday", dueConfidence: 0.85, priority: .high, confidence: 0.93),
        triageAttempt: 2, triageNotBefore: t0.addingTimeInterval(60), triageError: "rate limited once",
        triageProvider: "mock", triageModel: "haiku", triageMs: 1234, triageInputTokens: 2345,
        triageOutputTokens: 345, triageStdinBytes: 9876, seen: true, createdAt: t0.addingTimeInterval(1),
        updatedAt: t0.addingTimeInterval(2), handledAt: t0.addingTimeInterval(3))
}

fileprivate func message(_ n: Int, state: MailState = .pending, kind: SenderKind = .person,
                         received: Date? = nil, request: Bool? = nil) -> MailMessage {
    MailMessage(accountID: "acct", internetMessageID: "<m\(n)@example.org>", fromAddress: "p\(n)@example.org",
                senderKind: kind, subject: "Subject \(n)", receivedAt: received ?? t0.addingTimeInterval(Double(n)),
                snippet: "snippet \(n)", bodyText: "body \(n)", state: state,
                triage: request.map { MailTriage(hasReadingRequest: $0, requestKind: $0 ? .advisorRequest : .fyi,
                                                 summary: "s\(n)") },
                createdAt: t0, updatedAt: t0)
}

fileprivate func item(_ ord: Int, doi: String? = nil) -> MailItem {
    MailItem(ord: ord, cand: "c\(ord)", origin: .link, ids: PaperIDs(doi: doi), createdAt: t0, updatedAt: t0)
}

@Suite struct MailDBMessageTests {
    @Test func everyMessageFieldRoundTrips() async throws {
        let db = try Database.inMemory()
        let m = fullMessage()
        let (saved, items) = try await db.insertMailMessage(m, items: [])
        var expected = m
        expected.pk = saved.pk
        #expect(saved == expected)
        #expect(items.isEmpty)
        #expect(try await db.mailMessage(pk: saved.pk) == expected)
        #expect(try await db.mailMessage(id: m.id.uppercased()) == expected)
        #expect(try await db.mailMessage(internetMessageID: " <caf=ABC.123@mail.gmail.com> ") == expected)
        #expect(try await db.mailMessage(internetMessageID: "") == nil)
        #expect(try await db.mailMessage(pk: 999) == nil)

        // All optionals nil, every flag false.
        let bare = MailMessage(accountID: "manual", internetMessageID: "<bare@x>", fromAddress: "a@b.c",
                               senderKind: .manual, subject: "", receivedAt: t0, createdAt: t0, updatedAt: t0)
        let (bareSaved, _) = try await db.insertMailMessage(bare, items: [])
        var bareExpected = bare
        bareExpected.pk = bareSaved.pk
        #expect(bareSaved == bareExpected)
        #expect(bareSaved.triage == nil && bareSaved.handledAt == nil && bareSaved.triageState == MailTriageState.none)
    }

    @Test func triageJSONKeepsEveryField() async throws {
        let db = try Database.inMemory()
        let triage = try #require(fullMessage().triage)
        let (saved, _) = try await db.insertMailMessage(fullMessage(), items: [])
        #expect(saved.triage == triage)
        let json = try await db.transaction { db in
            try db.db.scalarString("SELECT triage_json FROM mail_message WHERE pk = ?", [.integer(saved.pk)])
        }
        let text = try #require(json)
        #expect(text.contains("\"dueDate\":\"2026-10-03\"") && text.contains("\"requestKind\":\"journal_club\""))
        #expect(text.contains("\"priority\":1"))
    }

    @Test func duplicateMessageIDIsRejectedAtomically() async throws {
        let db = try Database.inMemory()
        let (first, _) = try await db.insertMailMessage(message(1), items: [item(1)])
        var again = message(2)
        again.internetMessageID = "<M1@EXAMPLE.ORG>"                    // same Message-ID, other case
        await #expect(throws: DatabaseError.duplicate("mail message \(first.pk)")) {    // no Message-ID in errors
            try await db.insertMailMessage(again, items: [item(1), item(2)])
        }
        #expect(try await db.mailMessage(internetMessageID: "<m1@example.org>")?.pk == first.pk)
        #expect(try await db.mailMessages(states: Set(MailState.allCases), limit: 10).count == 1)
        #expect(try await db.mailItems(messagePK: first.pk).count == 1)

        // A failing item rolls the message back too (one transaction).
        let a = item(1), dup = MailItem(id: a.id, ord: 2, cand: "c2", origin: .link)
        await #expect(throws: SQLiteError.self) { try await db.insertMailMessage(message(3), items: [a, dup]) }
        #expect(try await db.mailMessage(internetMessageID: "<m3@example.org>") == nil)
    }

    @Test func insertAssignsKeysAndKeepsTheItemOrder() async throws {
        let db = try Database.inMemory()
        var i2 = item(2), i1 = item(1)
        i2.messagePK = 777; i1.pk = 555                                  // ignored
        let (m, items) = try await db.insertMailMessage(message(1), items: [i2, i1])
        #expect(m.pk > 0)
        #expect(items.map(\.cand) == ["c2", "c1"])                       // the given order
        #expect(items.allSatisfy { $0.messagePK == m.pk && $0.pk > 0 })
        #expect(Set(items.map(\.pk)).count == 2 && !items.contains(where: { $0.pk == 555 }))
        #expect(try await db.mailItems(messagePK: m.pk).map(\.cand) == ["c1", "c2"])   // display order
    }

    @Test func updateRewritesTheRowAndStampsUpdatedAt() async throws {
        let db = try Database.inMemory()
        let (m, _) = try await db.insertMailMessage(message(1), items: [])
        var edit = m
        edit.state = .dismissed
        edit.handledAt = t0.addingTimeInterval(10)
        edit.userTouched = true
        let later = t0.addingTimeInterval(100)
        let saved = try await db.updateMailMessage(edit, now: later)
        var expected = edit
        expected.updatedAt = later
        #expect(saved == expected)
        #expect(try await db.mailMessage(pk: m.pk) == expected)

        var ghost = m
        ghost.pk = 999
        ghost.internetMessageID = "<ghost@x>"
        await #expect(throws: DatabaseError.notFound("mail message 999")) { try await db.updateMailMessage(ghost) }

        let (other, _) = try await db.insertMailMessage(message(2), items: [])
        var clash = other
        clash.internetMessageID = "<m1@example.org>"
        await #expect(throws: DatabaseError.duplicate("mail message \(m.pk)")) {
            try await db.updateMailMessage(clash)
        }
        #expect(try await db.mailMessage(pk: other.pk) == other)
    }

    @Test func modifyIsAtomicReadModifyWrite() async throws {
        let db = try Database.inMemory()
        let (m, _) = try await db.insertMailMessage(message(1), items: [])
        let pk = m.pk
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = try await db.modifyMailMessage(pk: pk) { $0.triageAttempt += 1 } }
            }
            try await group.waitForAll()
        }
        #expect(try await db.mailMessage(pk: pk)?.triageAttempt == 50)

        // A throwing body leaves the row untouched; the pk inside the body can't be retargeted.
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.modifyMailMessage(pk: pk) { $0.state = .merged; throw Boom() }
        }
        #expect(try await db.mailMessage(pk: pk)?.state == .pending)
        let later = t0.addingTimeInterval(500)
        let saved = try await db.modifyMailMessage(pk: pk, now: later) { $0.pk = 12345; $0.seen = true }
        #expect(saved.pk == pk && saved.seen && saved.updatedAt == later)
        await #expect(throws: DatabaseError.notFound("mail message 424242")) {
            try await db.modifyMailMessage(pk: 424242) { $0.seen = true }
        }

        // Composes with other writes in one transaction: a later failure rolls it back.
        await #expect(throws: SQLiteError.self) {
            try await db.transaction { db in
                try db.modifyMailMessage(pk: pk) { $0.state = .dismissed }
                try db.upsertMailItem(MailItem(messagePK: 999, ord: 0, cand: "c1", origin: .link))   // FK violation
            }
        }
        #expect(try await db.mailMessage(pk: pk)?.state == .pending)
    }

    @Test func messagesByStateNewestFirst() async throws {
        let db = try Database.inMemory()
        let a = try await db.insertMailMessage(message(1, received: t0), items: []).0
        let b = try await db.insertMailMessage(message(2, state: .snoozed, received: t0.addingTimeInterval(day)), items: []).0
        let c = try await db.insertMailMessage(message(3, received: t0.addingTimeInterval(2 * day)), items: []).0
        _ = try await db.insertMailMessage(message(4, state: .dismissed, received: t0.addingTimeInterval(3 * day)), items: [])
        #expect(try await db.mailMessages(states: [.pending], limit: 10).map(\.pk) == [c.pk, a.pk])
        #expect(try await db.mailMessages(states: [.pending, .snoozed], limit: 10).map(\.pk) == [c.pk, b.pk, a.pk])
        #expect(try await db.mailMessages(states: [.pending, .snoozed], limit: 2).map(\.pk) == [c.pk, b.pk])
        #expect(try await db.mailMessages(states: [.noRequest], limit: 10).isEmpty)
        #expect(try await db.mailMessages(states: [], limit: 10).isEmpty)
        #expect(try await db.mailMessages(states: [.pending], limit: 0).isEmpty)
    }

    @Test func countsPendingAndRequests() async throws {
        let db = try Database.inMemory()
        let empty = try await db.mailCounts()
        #expect(empty.pending == 0 && empty.requests == 0)
        let rows: [MailMessage] = [
            message(1, kind: .advisor, request: true),                   // request
            message(2, kind: .person, request: true),                    // request
            message(3, kind: .alert, request: true),                     // alerts are not "requests"
            message(4, kind: .manual, request: true),
            message(5, kind: .advisor, request: false),
            message(6, kind: .advisor),                                  // not triaged yet
            message(7, state: .snoozed, kind: .advisor, request: true),  // not pending
            message(8, state: .dismissed, kind: .person, request: true),
            message(9, state: .noRequest, kind: .person, request: false),
        ]
        for m in rows { _ = try await db.insertMailMessage(m, items: []) }
        let counts = try await db.mailCounts()
        #expect(counts.pending == 6 && counts.requests == 2)
    }

    @Test func triageQueueQueriesAndRecovery() async throws {
        let db = try Database.inMemory()
        var q1 = message(1); q1.triageState = .queued; q1.triageNotBefore = t0.addingTimeInterval(300)
        var q2 = message(2); q2.triageState = .queued
        var h = message(3); h.triageState = .held
        var r = message(4); r.triageState = .running
        var d = message(5); d.triageState = .done
        var ask = message(6); ask.triageState = .awaitingConsent
        var pks: [String: Int64] = [:]
        for (name, m) in [("q1", q1), ("q2", q2), ("h", h), ("r", r), ("d", d), ("ask", ask)] {
            pks[name] = try await db.insertMailMessage(m, items: []).0.pk
        }
        #expect(try await db.mailMessages(triageStates: [.queued, .held], limit: 10).map(\.pk)
                == [pks["q2"]!, pks["h"]!, pks["q1"]!])                  // no backoff first, then by time
        #expect(try await db.mailMessages(triageStates: [.awaitingConsent], limit: 10).map(\.pk) == [pks["ask"]!])
        #expect(try await db.mailMessages(triageStates: [], limit: 10).isEmpty)

        #expect(try await db.resetRunningTriageToQueued(now: t0.addingTimeInterval(9)) == 1)
        #expect(try await db.mailMessage(pk: pks["r"]!)?.triageState == .queued)
        #expect(try await db.resetRunningTriageToQueued() == 0)
    }

    @Test func snoozedMailWakesUpWhenDue() async throws {
        let db = try Database.inMemory()
        var due = message(1, state: .snoozed); due.snoozedUntil = t0.addingTimeInterval(day)
        var later = message(2, state: .snoozed); later.snoozedUntil = t0.addingTimeInterval(3 * day)
        let a = try await db.insertMailMessage(due, items: []).0
        let b = try await db.insertMailMessage(later, items: []).0
        let now = t0.addingTimeInterval(2 * day)
        #expect(try await db.wakeSnoozedMail(now: now) == 1)
        let woke = try #require(try await db.mailMessage(pk: a.pk))
        #expect(woke.state == .pending && woke.snoozedUntil == nil && woke.updatedAt == now)
        #expect(try await db.mailMessage(pk: b.pk)?.state == .snoozed)
        #expect(try await db.wakeSnoozedMail(now: now) == 0)
    }

    @Test func purgeClearsBodiesOfHandledMailOnly() async throws {
        let db = try Database.inMemory()
        let cutoff = t0.addingTimeInterval(30 * day)
        var oldDismissed = message(1, state: .dismissed, request: true); oldDismissed.handledAt = t0
        var recentMerged = message(2, state: .merged); recentMerged.handledAt = t0.addingTimeInterval(40 * day)
        let oldPending = message(3)                                      // never handled: kept
        var oldSnoozed = message(4, state: .snoozed); oldSnoozed.handledAt = t0
        let noRequestUnstamped = message(5, state: .noRequest)            // handled_at unset → updated_at (t0)
        var pks: [Int64] = []
        for m in [oldDismissed, recentMerged, oldPending, oldSnoozed, noRequestUnstamped] {
            pks.append(try await db.insertMailMessage(m, items: [item(1)]).0.pk)
        }
        let now = t0.addingTimeInterval(60 * day)
        #expect(try await db.purgeMailBodies(handledBefore: cutoff, now: now) == 2)

        for (i, pk) in pks.enumerated() {
            let m = try #require(try await db.mailMessage(pk: pk))
            let purged = i == 0 || i == 4
            #expect(m.bodyPurged == purged && (m.bodyText == nil) == purged && (m.snippet == nil) == purged, "\(i)")
            #expect(m.subject == "Subject \(i + 1)")                    // provenance fields stay
            #expect(try await db.mailItems(messagePK: pk).count == 1)
        }
        let dismissed = try #require(try await db.mailMessage(pk: pks[0]))
        #expect(dismissed.triage?.summary == "s1" && dismissed.updatedAt == now)
        #expect(try await db.purgeMailBodies(handledBefore: cutoff, now: now) == 0)   // idempotent
    }

    @Test func purgedBodiesNeverComeBack() async throws {
        let db = try Database.inMemory()
        var m = message(1, state: .dismissed)
        m.handledAt = t0
        let (saved, _) = try await db.insertMailMessage(m, items: [])
        let stale = saved                                                // read before the purge
        #expect(try await db.purgeMailBodies(handledBefore: t0.addingTimeInterval(day)) == 1)
        let written = try await db.updateMailMessage(stale)              // body/snippet in the stale copy
        #expect(written.bodyPurged && written.bodyText == nil && written.snippet == nil)
        let flipped = try await db.modifyMailMessage(pk: saved.pk) { $0.bodyPurged = false; $0.bodyText = "again" }
        #expect(flipped.bodyPurged && flipped.bodyText == nil)

        // Inserting an already-purged message stores no body either.
        var purged = message(2)
        purged.bodyPurged = true
        let (p2, _) = try await db.insertMailMessage(purged, items: [])
        #expect(p2.bodyText == nil && p2.snippet == nil && p2.bodyPurged)
    }

    @Test func deleteAllMailDataKeepsLibraryAndOtherSettings() async throws {
        let db = try Database.inMemory()
        let paper = try await db.insertPaper(Paper(sha256: String(repeating: "c", count: 64), fileSize: 1,
                                                   title: "Library paper", folder: "Papers/x", pdfName: "x.pdf",
                                                   originalName: "x.pdf"))
        let (m, _) = try await db.insertMailMessage(message(1), items: [item(1), item(2)])
        _ = try await db.insertMailMessage(message(2), items: [item(1)])
        try await db.insertPaperSource(paperPK: paper.pk, PaperProvenance(mailMessageID: m.id,
                                                                          internetMessageID: m.internetMessageID,
                                                                          addedAt: t0))
        try await db.setMailCursor(accountID: "gmail-1", MailCursor("7:100"))
        try await db.setMailCursor(accountID: "folder-1", MailCursor("ledger"))
        try await db.setKV("mail.triage.day", #"{"day":"2026-09-30","n":4}"#)
        try await db.setKV("plan.skipDays", "[]")

        try await db.deleteAllMailData()
        #expect(try await db.mailMessages(states: Set(MailState.allCases), limit: 10).isEmpty)
        #expect(try await db.mailItems(messagePKs: [m.pk]) == [m.pk: []])
        let orphanItems = try await db.transaction { db in try db.db.scalarInt("SELECT count(*) FROM mail_item") }
        #expect(orphanItems == 0)
        #expect(try await db.mailCursor(accountID: "gmail-1") == nil)
        #expect(try await db.mailCursor(accountID: "folder-1") == nil)
        #expect(try await db.kv("mail.triage.day") != nil)              // today's AI quota count is not reset
        #expect(try await db.kv("plan.skipDays") == "[]")
        #expect(try await db.paperSources(paperPK: paper.pk).count == 1) // provenance belongs to the library
        #expect(try await db.livePapers().count == 1)
        try await db.deleteAllMailData()                                 // idempotent
    }

    @Test func cursorsArePerAccount() async throws {
        let db = try Database.inMemory()
        #expect(try await db.mailCursor(accountID: "a") == nil)
        try await db.setMailCursor(accountID: "a", MailCursor("uidvalidity=7;uid=100"))
        try await db.setMailCursor(accountID: "b", MailCursor("x"))
        #expect(try await db.mailCursor(accountID: "a") == MailCursor("uidvalidity=7;uid=100"))
        try await db.setMailCursor(accountID: "a", MailCursor("uidvalidity=7;uid=120"))
        #expect(try await db.mailCursor(accountID: "a")?.value == "uidvalidity=7;uid=120")
        #expect(try await db.kv("mail.cursor.a") == "uidvalidity=7;uid=120")
        try await db.setMailCursor(accountID: "a", nil)
        #expect(try await db.mailCursor(accountID: "a") == nil)
        #expect(try await db.mailCursor(accountID: "b") == MailCursor("x"))
        try await db.setMailCursor(accountID: "a", nil)                   // removing twice is fine
    }
}
