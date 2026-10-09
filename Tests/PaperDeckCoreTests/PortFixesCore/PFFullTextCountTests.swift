import Foundation
import Testing
@testable import PaperDeckCore

/// Portability verification F2 (core part): the Help Center's "search finds titles only after a
/// move" fact assumed every paper was indexed, so the move-to-new-Mac "re-index" step was ticked
/// before the user re-indexed. `Engine.papersMissingFullTextCount()` is the real count: live papers
/// without a full-text row whose PDF could have one (locked / scanned / unreadable / missing
/// papers never get one, so the count reaches 0 after `reindexMissingFullText`). Offline, temp
/// library, no CLI.
@Suite(.serialized) struct PFFullTextCountTests {
    typealias K = OpsTestKit

    @Test func theCountFollowsTheIndexAndReachesZeroAfterReindexing() async throws {
        try await K.run { (env: K.Env) async throws in
            #expect(try await env.engine.papersMissingFullTextCount() == 0)              // an empty library
            let cached = try await K.addPaper(env, title: "Cached text")
            try env.engine.ctx.texts.save("cortical radial glia searchable words", id: cached.id)
            let real = try await K.addPaper(env, title: "Real PDF")
            try MailSyncKit.realPDF(title: "Radial glia and the developing cortex").write(to: env.engine.ctx.pdfURL(real))
            let indexed = try await K.addPaper(env, title: "Already indexed")
            try await env.db.indexFullText(pk: indexed.pk, text: "already searchable")
            // Never indexable: flagged at import (scanned / locked / unreadable) or the file is gone.
            for (title, flag) in [("Scanned", PaperFlags.scanned), ("Locked", .locked), ("Unreadable", .unreadable),
                                  ("Missing", .missing)] {
                let p = try await K.addPaper(env, title: title)
                _ = try await env.db.modifyPaper(pk: p.pk) { $0.flags.insert(flag) }
            }
            // In Recently Deleted: not counted.
            let trashed = try await K.addPaper(env, title: "Trashed")
            _ = try await env.engine.softDelete(paperID: trashed.id)

            #expect(try await env.engine.papersMissingFullTextCount() == 2)              // cached + real
            #expect(await env.engine.reindexMissingFullText() == 2)
            #expect(try await env.engine.papersMissingFullTextCount() == 0)
            // A newly imported paper without text yet counts again.
            _ = try await K.addPaper(env, title: "New arrival")
            #expect(try await env.engine.papersMissingFullTextCount() == 1)
        }
    }
}
