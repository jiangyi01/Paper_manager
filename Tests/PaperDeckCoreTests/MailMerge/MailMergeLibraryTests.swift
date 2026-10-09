import Foundation
import Testing
@testable import PaperDeckCore

/// card.json provenance, the rebuild that restores it, per-item import results, `.mail` never
/// moving sources, and mail retention.
@Suite struct MailMergeLibraryTests {
    private typealias Kit = MailMergeKit

    private static func provenance(_ n: Int) -> PaperProvenance {
        PaperProvenance(mailMessageID: "3f2a1c9e-0000-4000-8000-00000000000\(n)", internetMessageID: "<m\(n)@wustl.edu>",
                        fromAddress: "prof.x@wustl.edu", fromName: "Prof. X", subject: "组会 papers #\(n)",
                        receivedAt: Date(timeIntervalSince1970: 1_790_000_000.25 + Double(n)),
                        webLink: nil, requestKind: .journalClub, summary: "Read it.", dueHint: LocalDate(year: 2026, month: 10, day: n),
                        addedAt: Date(timeIntervalSince1970: 1_790_100_000 + Double(n)))
    }

    private static func sidecar(provenance: [PaperProvenance]) -> CardSidecar {
        let p = Paper(sha256: "abc", fileSize: 10, title: "T", folder: "Papers/T", pdfName: "T.pdf", originalName: "t.pdf",
                      addedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        return CardSidecar(paper: p, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil,
                           provenance: provenance)
    }

    @Test func sidecarProvenanceRoundTripsAndIsOmittedWhenEmpty() throws {
        let with = Self.sidecar(provenance: [Self.provenance(1), Self.provenance(2)])
        let data = try with.encoded()
        let decoded = try CardSidecar.decoded(from: data)
        #expect(decoded == with)
        #expect(try decoded.encoded() == data)
        #expect(decoded.toModels(folder: "Papers/T").provenance == [Self.provenance(1), Self.provenance(2)])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((json["provenance"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["kind", "mailMessageID", "internetMessageID", "fromAddress", "fromName", "subject",
                                    "receivedAt", "webLink", "requestKind", "summary", "dueHint", "addedAt"])
        #expect(first["webLink"] is NSNull && first["receivedAt"] as? String == "2026-09-21T14:13:21.250Z")
        #expect(json["schema"] as? String == "paperdeck.card/1")

        let without = try Self.sidecar(provenance: []).encoded()
        #expect(!String(decoding: without, as: UTF8.self).contains("provenance"))
    }

    @Test func sidecarProvenanceDecodingIsLenient() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Self.sidecar(provenance: []).encoded()) as? [String: Any])
        json["provenance"] = [
            ["kind": "email", "subject": "ok", "addedAt": "2026-09-29T10:00:00Z", "requestKind": "bogus", "dueHint": "not-a-day"],
            "garbage",
            ["subject": 42, "receivedAt": "2026-09-28T10:00:00Z"],
        ]
        let s = try CardSidecar.decoded(from: JSONSerialization.data(withJSONObject: json))
        let models = s.provenance.map(\.model)
        #expect(models.count == 2)
        #expect(models[0].subject == "ok" && models[0].requestKind == nil && models[0].dueHint == nil)
        #expect(models[1].kind == "email" && models[1].subject == nil)
        #expect(models[1].addedAt == models[1].receivedAt)                     // falls back to receivedAt

        json["provenance"] = "nope"
        #expect(try CardSidecar.decoded(from: JSONSerialization.data(withJSONObject: json)).provenance.isEmpty)
    }

    @Test func rebuildKeepsProvenance() async throws {
        let first = try await Kit.make()
        let root = first.root
        defer { try? FileManager.default.removeItem(at: root) }
        let (m1, items) = try await Kit.insert(first, Kit.message(subject: "First email"), items: [Kit.item(1)],
                                               attachments: [0: Kit.pdfData(title: "Rebuilt paper", doi: "10.1038/s41586-024-08351-7")])
        let id = try #require(try await first.engine.mergeMailItem(itemID: items[0].id,
                                                                  options: MailMergeOptions(priority: .high, readWithAI: false)))
        // A second email linked to the same paper.
        let (m2, more) = try await Kit.insert(first, Kit.message(kind: .person, subject: "Second"), items: [
            Kit.item(1, origin: .link, pdf: .inLibrary, doi: "10.1038/s41586-024-08351-7", paperID: id),
        ])
        first.clock.value = Kit.start.addingTimeInterval(61.5)
        _ = try await first.engine.mergeMailItem(itemID: more[0].id, options: MailMergeOptions())
        await first.engine.ctx.writeManifest()                                  // categories survive via the manifest
        await first.settle()
        let pk = try await first.paper(id).pk
        #expect(try await first.db.paperSources(paperPK: pk).compactMap(\.mailMessageID) == [m1.id, m2.id])
        let before = try await first.engine.dumpCanonical()
        #expect(String(decoding: before, as: UTF8.self).contains("\"subject\" : \"Second\""))
        let now = first.clock.value
        await first.engine.shutdown()
        await first.engine.db.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: first.paths.database.path + suffix)
        }

        let second = try await Kit.make(root: root, now: now)
        let report = try await second.engine.rebuildFromSidecars()
        #expect(report.papers == 1 && report.skipped.isEmpty)
        let after = try await second.engine.dumpCanonical()
        if before != after {
            let b = String(decoding: before, as: UTF8.self).split(separator: "\n")
            let a = String(decoding: after, as: UTF8.self).split(separator: "\n")
            let diff = zip(b, a).first { $0.0 != $0.1 }
            Issue.record("canonical dumps differ: \(diff?.0 ?? "") ≠ \(diff?.1 ?? "")")
        }
        #expect(after == before)
        let rebuilt = try await second.paper(id)
        #expect(try await second.db.paperSources(paperPK: rebuilt.pk).map(\.subject) == ["First email", "Second"])
        await second.engine.shutdown()
        await second.engine.db.close()
    }

    @Test func batchResultsNameEveryItemInOrder() async throws {
        try await Kit.run { env in
            let a = try Kit.writeUserPDF(env, name: "a.pdf", title: "Alpha paper", doi: "10.1000/alpha")
            let first = await env.engine.intake.ingest([.file(a)], options: ImportOptions(origin: .drop, ai: .skip))
            let alpha = try #require(first.added.first)
            #expect(first.items == [ImportItemResult(source: a, outcome: .added(paperID: alpha))])

            let b = try Kit.writeUserPDF(env, name: "b.pdf", title: "Beta paper")
            let notPDF = env.root.appendingPathComponent("Downloads/c.pdf")
            try Data("plain text".utf8).write(to: notPDF)
            let copyOfA = env.root.appendingPathComponent("Downloads/a-copy.pdf")
            try FileManager.default.copyItem(at: a, to: copyOfA)
            let sameWork = try Kit.writeUserPDF(env, name: "alpha-v2.pdf", title: "Alpha paper v2", doi: "10.1000/alpha")
            let summary = await env.engine.intake.ingest([.file(b), .file(notPDF), .file(copyOfA), .file(sameWork)],
                                                         options: ImportOptions(origin: .drop, ai: .skip))
            await env.settle()
            #expect(summary.items.map(\.source) == [b, notPDF, copyOfA, sameWork])
            guard summary.items.count == 4 else { return }
            if case .added(let id) = summary.items[0].outcome { #expect(summary.added == [id]) } else { Issue.record("b not added") }
            #expect(summary.items[1].outcome == .rejected(reason: "Not a PDF"))
            #expect(summary.items[2].outcome == .duplicate(paperID: alpha) && !summary.items[2].linked)
            #expect(summary.items[3].outcome == .sameWork(existingPaperID: alpha))
            #expect(await env.engine.intake.pendingIDs().count == 1)             // the normal drop still asks
            #expect(summary.items[3].outcome.paperID == alpha && summary.items[1].outcome.failureReason == "Not a PDF")
        }
    }

    @Test func mailOriginNeverMovesSourcesAndAnnotatesByURL() async throws {
        try await Kit.run(Kit.settings(importMode: .move)) { env in
            let moved = try Kit.writeUserPDF(env, name: "moved.pdf", title: "Moved by a normal drop")
            let kept = try Kit.writeUserPDF(env, name: "kept.pdf", title: "Kept by a mail merge")
            let trashed = Kit.Box<[URL]>([])
            let enrich = env.engine.enrich
            let intake = IntakeActor(ctx: env.engine.ctx, enrich: enrich,
                                     trashSource: { url in trashed.value.append(url); return true })
            _ = await intake.ingest([.file(moved)], options: ImportOptions(origin: .drop, ai: .skip))
            let annotation = ImportAnnotation(priority: .high, category: "From Mail", notesPrefill: "note",
                                              sameWorkPolicy: .link)
            // The key is compared standardized (".." segments, symlinked temp dirs).
            let key = URL(fileURLWithPath: kept.deletingLastPathComponent().path + "/../Downloads/kept.pdf")
            let summary = await intake.ingest([.file(kept)], options: ImportOptions(origin: .mail, ai: .skip,
                                                                                   annotations: [key: annotation]))
            await env.settle()
            #expect(trashed.value.map(\.lastPathComponent) == ["moved.pdf"])
            #expect(FileManager.default.fileExists(atPath: kept.path))
            let p = try await env.paper(try #require(summary.added.first))
            #expect(p.priority == .high && p.notes == "note" && p.categoryPK != nil)
            #expect(p.deadline != nil && p.scheduleMode == .auto)                 // placed with its priority
        }
    }

    @Test func retentionPurgesHandledCardsAndTheirCopies() async throws {
        var mail = MailSettings()
        mail.retentionDays = 30
        try await Kit.run(mail: mail) { env in
            let old = Kit.start.addingTimeInterval(-31 * 86_400)
            var handled = Kit.message(kind: .person, subject: "Handled long ago", state: .dismissed)
            handled.handledAt = old
            let (h, hItems) = try await Kit.insert(env, handled, items: [Kit.item(1)], attachments: [0: Kit.pdfData(title: "x")])
            var recent = Kit.message(kind: .person, subject: "Handled yesterday", state: .dismissed)
            recent.handledAt = Kit.start.addingTimeInterval(-86_400)
            let (r, rItems) = try await Kit.insert(env, recent, items: [Kit.item(1)], attachments: [0: Kit.pdfData(title: "y")])
            let (p, _) = try await Kit.insert(env, Kit.message(kind: .person, subject: "Still pending"), items: [])
            var snoozed = Kit.message(kind: .person, subject: "Snoozed", state: .snoozed)
            snoozed.snoozedUntil = Kit.start.addingTimeInterval(-60)
            let (s, _) = try await Kit.insert(env, snoozed, items: [])
            var downloading = Kit.item(1, origin: .link, pdf: .downloading, url: "https://arxiv.org/abs/2604.09554")
            downloading.ids.arxivID = "2604.09554"
            let (_, dItems) = try await Kit.insert(env, Kit.message(kind: .alert, subject: "Mid-download"), items: [downloading])

            let report = try await Maintenance(engine: env.engine, trash: { _ in false }).mailRetention(atLaunch: true)
            #expect(report.purgedBodies == 1 && report.removedFiles == 1 && report.woken == 1 && report.resetDownloads == 1)

            let purged = try await env.message(h.id)
            #expect(purged.bodyPurged && purged.bodyText == nil && purged.snippet == nil && purged.subject == "Handled long ago")
            #expect(!Kit.mailFileExists(env, hItems[0].pdfPath))
            let item = try await env.item(hItems[0].id)
            #expect(item.pdfPath == nil && item.pdfState == .needsPDF)
            #expect(!FileManager.default.fileExists(atPath: env.paths.mailFiles.appendingPathComponent(h.id).path))

            #expect(try await env.message(r.id).bodyText != nil)
            #expect(Kit.mailFileExists(env, rItems[0].pdfPath))
            #expect(try await env.message(p.id).bodyText != nil)
            #expect(try await env.message(s.id).state == .pending)
            #expect(try await env.item(dItems[0].id).pdfState == .downloadable)

            // Launch maintenance runs it too; retentionDays ≤ 0 keeps everything.
            var keep = MailSettings()
            keep.retentionDays = 0
            env.mail.value = keep
            env.clock.value = Kit.start.addingTimeInterval(90 * 86_400)
            let launch = await Maintenance(engine: env.engine, trash: { _ in false }).onLaunch()
            #expect(launch.mail.purgedBodies == 0 && launch.errors.isEmpty)
            #expect(try await env.message(r.id).bodyText != nil)
        }
    }
}

/// IntakeActor's per-file AI decisions (`BatchAIPolicy`, annotation overrides).
@Suite struct MailMergeIntakePolicyTests {
    @Test func aiPoliciesHoldAndWant() {
        #expect(IntakeActor.holds(.automatic, count: 3) == false && IntakeActor.holds(.automatic, count: 4))
        #expect(IntakeActor.holds(.queueHeld, count: 1) && IntakeActor.holds(.hold, count: 1))
        #expect(!IntakeActor.holds(.queueAll, count: 50) && !IntakeActor.holds(.skip, count: 50))
        #expect(IntakeActor.wants(.queueHeld, autoRead: false) && IntakeActor.wants(.queueAll, autoRead: false))
        #expect(!IntakeActor.wants(.automatic, autoRead: false) && IntakeActor.wants(.hold, autoRead: true))
        #expect(!IntakeActor.wants(.skip, autoRead: true))
    }

    @Test func annotationOverridesTheBatchPolicyPerFile() async throws {
        try await MailMergeKit.run(MailMergeKit.settings(autoRead: false)) { env in
            let a = try MailMergeKit.writeUserPDF(env, name: "a.pdf", title: "Read this one", doi: "10.1000/aa")
            let b = try MailMergeKit.writeUserPDF(env, name: "b.pdf", title: "Not this one", doi: "10.1000/bb")
            let summary = await env.engine.intake.ingest([.file(a), .file(b)], options: ImportOptions(
                origin: .mail, ai: .skip, annotations: [a: ImportAnnotation(aiPolicy: .queueAll, aiPriority: 1)]))
            await env.settle()
            let ids = summary.items.compactMap(\.outcome.paperID)
            #expect(ids.count == 2)
            let first = try await env.paper(ids[0]), second = try await env.paper(ids[1])
            #expect(try await env.db.activeJob(paperPK: first.pk)?.priority == 1)
            #expect(try await env.db.activeJob(paperPK: second.pk) == nil)
        }
    }
}
