import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct MetadataTaxonomyOperationsTests {
    private typealias Kit = OpsTestKit
    private typealias PDTag = PaperDeckCore.Tag

    private static func card(_ env: OpsTestKit.Env, _ p: Paper) throws -> CardSidecar {
        try CardSidecar.decoded(from: Data(contentsOf: env.engine.ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName)))
    }

    @Test func editMetadataSetsUserRankAndFlags() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Filename guess")
            let edited = try await env.engine.editMetadata(
                paperID: p.id, title: "  Molecular and cellular dynamics\nof the developing human neocortex ",
                authors: ["Li Wang", " ", "Arnold R. Kriegstein"], year: 2024, venue: "Nature",
                doi: "https://doi.org/10.1038/S41586-024-08351-7", arxivID: "arXiv:2606.24530v2")
            #expect(edited.title == "Molecular and cellular dynamics of the developing human neocortex")
            #expect(edited.titleRank == .user && edited.metaUserEdited)
            #expect(edited.metaSource == .crossref)                       // canonical source is kept
            #expect(edited.authors == ["Li Wang", "Arnold R. Kriegstein"])
            #expect(edited.ids.doi == "10.1038/s41586-024-08351-7")
            #expect(edited.ids.arxivID == "2606.24530" && edited.ids.arxivVersion == 2)
            #expect(try await env.engine.search("neocortex") == [p.id])

            var bare = try await Kit.addPaper(env, title: "No metadata")
            bare = try await env.db.modifyPaper(pk: bare.pk) { $0.metaSource = .none }
            let user = try await env.engine.editMetadata(paperID: bare.id, title: "Typed by hand", authors: [], year: nil,
                                                         venue: nil, doi: nil, arxivID: nil)
            #expect(user.metaSource == .user && user.ids.doi == nil)

            await #expect(throws: PaperOperationError.duplicateIdentifier(paperID: p.id, title: edited.title)) {
                try await env.engine.editMetadata(paperID: bare.id, title: "x", authors: [], year: nil, venue: nil,
                                                  doi: "10.1038/s41586-024-08351-7", arxivID: nil)
            }
            await #expect(throws: PaperOperationError.invalidIdentifier("not a doi")) {
                try await env.engine.editMetadata(paperID: bare.id, title: "x", authors: [], year: nil, venue: nil,
                                                  doi: "not a doi", arxivID: nil)
            }
            await #expect(throws: PaperOperationError.emptyTitle) {
                try await env.engine.editMetadata(paperID: bare.id, title: " \n", authors: [], year: nil, venue: nil,
                                                  doi: nil, arxivID: nil)
            }
        }
    }

    @Test func notesAreSearchableAndMirroredToNotesMarkdown() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Some paper")
            let saved = try await env.engine.setNotes(paperID: p.id, "Compare with the zebrafish organoid dataset")
            #expect(saved.notes.hasPrefix("Compare"))
            #expect(try await env.engine.search("zebrafish") == [p.id])
            await env.engine.ctx.sidecars.flush()
            let notes = try String(contentsOf: env.engine.ctx.folderURL(saved).appendingPathComponent(CardSidecar.notesFileName),
                                   encoding: .utf8)
            #expect(notes.contains("## My notes") && notes.contains("zebrafish organoid"))
        }
    }

    @Test func tagSuppressSemantics() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            try await env.db.setTags(paperPK: p.pk, [PDTag(name: "atlas", origin: .agent), PDTag(name: "cortex", origin: .agent)])

            let added = try await env.engine.addTag(paperID: p.id, "Single Cell")
            #expect(added.contains(PDTag(name: "single-cell", origin: .user)))

            let afterAgent = try await env.engine.removeTag(paperID: p.id, "atlas")
            #expect(!afterAgent.map(\.name).contains("atlas"))
            #expect(try await env.db.tags(paperPK: p.pk).contains(PDTag(name: "atlas", origin: .suppressed)))

            _ = try await env.engine.removeTag(paperID: p.id, "single-cell")
            #expect(!(try await env.db.tags(paperPK: p.pk)).map(\.name).contains("single-cell"))   // user tag: gone

            let back = try await env.engine.addTag(paperID: p.id, "ATLAS")
            #expect(back.contains(PDTag(name: "atlas", origin: .user)))                            // un-suppressed
            #expect(try await env.db.tags(paperPK: p.pk).count == 2)

            await #expect(throws: PaperOperationError.invalidTag("!")) { try await env.engine.addTag(paperID: p.id, "!") }

            await env.engine.ctx.sidecars.flush()
            #expect(try Self.card(env, p).tags.sorted { $0.name < $1.name }
                    == [PDTag(name: "atlas", origin: .user), PDTag(name: "cortex", origin: .agent)])
        }
    }

    @Test func categoryCRUDKeepsManifestAndCardsInSync() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let created = try await env.engine.createCategory(name: "spatial transcriptomics methods for tissue",
                                                              description: " Spatial methods \n in tissue ")
            #expect(created.name == "Spatial Transcriptomics Methods")
            #expect(created.description == "Spatial methods in tissue")
            #expect(created.origin == .user && created.acknowledged)
            #expect(created.hue == 7)                                    // starters use hues 0…6
            await #expect(throws: PaperOperationError.duplicateCategory("Spatial Transcriptomics Methods")) {
                try await env.engine.createCategory(name: "SPATIAL transcriptomics methods")
            }

            let categorized = try await env.engine.setCategory(paperID: p.id, categoryPK: created.pk)
            #expect(categorized.categoryPK == created.pk && categorized.categoryUserSet)
            await env.engine.ctx.sidecars.flush()
            #expect(try Self.card(env, p).category == CardSidecar.CategoryRef(name: "Spatial Transcriptomics Methods", userSet: true))

            _ = try await env.engine.renameCategory(pk: created.pk, name: "Spatial Omics Methods")
            _ = try await env.engine.setCategoryDescription(pk: created.pk, "Methods for spatial omics")
            await env.engine.ctx.sidecars.flush()
            #expect(try Self.card(env, p).category.name == "Spatial Omics Methods")
            let manifest = try #require(try SidecarWriter.readManifest(at: env.paths.libraryManifest))
            let entry = try #require(manifest.categories.first { $0.name == "Spatial Omics Methods" })
            #expect(entry.description == "Methods for spatial omics" && entry.hue == 7 && entry.origin == .user)

            // NEW badge off
            let agentCat = try await env.db.insertCategory(PaperCategory(name: "Agent Made", hue: 8, origin: .agent,
                                                                         acknowledged: false))
            try await env.engine.acknowledgeCategory(pk: agentCat.pk)
            #expect(try await env.db.category(pk: agentCat.pk)?.acknowledged == true)

            try await env.engine.deleteCategory(pk: created.pk)
            let uncategorized = try await Kit.paper(env, p.id)
            #expect(uncategorized.categoryPK == nil)
            await env.engine.ctx.sidecars.flush()
            #expect(try Self.card(env, p).category.name == nil)
            #expect(try SidecarWriter.readManifest(at: env.paths.libraryManifest)?.categories
                .contains { $0.name == "Spatial Omics Methods" } == false)
            await #expect(throws: PaperOperationError.categoryNotFound(created.pk)) {
                try await env.engine.setCategory(paperID: p.id, categoryPK: created.pk)
            }
        }
    }

    @Test func aiSeenRereadAndRefresh() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.aiSeen = false; $0.aiState = .done }
            #expect(try await env.engine.markAISeen(paperID: p.id).aiSeen)
            try await env.engine.requestReread(paperID: p.id)
            _ = try await env.engine.refreshMetadata(paperID: p.id)
            await #expect(throws: PaperOperationError.paperNotFound("missing-id")) {
                try await env.engine.requestReread(paperID: "missing-id")
            }
        }
    }
}
