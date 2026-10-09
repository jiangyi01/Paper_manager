import Foundation
import Testing
@testable import PaperDeckCore

private typealias PaperTag = PaperDeckCore.Tag

@Suite struct CardSidecarTests {
    static func sampleCard() -> ReadingCard {
        ReadingCard(
            extractedMetadata: .init(title: "Molecular and cellular dynamics", authors: ["Li Wang"], year: 2024,
                                     venue: "Nature", doi: "10.1038/s41586-024-08351-7"),
            tldr: "A spatial atlas of the developing human neocortex.",
            summary: "The authors profile 38 samples.\nThey find new progenitor states.",
            contributions: ["Atlas of 4 million cells", "New progenitor states"],
            method: "Single-nucleus RNA-seq plus MERFISH.",
            results: ["Result one", "Result two"],
            limitations: [.init(text: "Few late-gestation samples", source: .authors),
                          .init(text: "Batch effects possible", source: .inferred)],
            keyTerms: [.init(term: "oRG", definition: "outer radial glia")],
            resources: [.init(kind: .dataset, name: "CELLxGENE", identifier: "GSE123", url: "https://example.org/d")],
            paperType: .resource, category: "Neuroscience & Development", tags: ["single-cell", "spatial"],
            difficulty: .hard, estimatedMinutes: 110,
            checklist: [.init(task: "Read Fig. 2", section: "Fig. 2", page: 5, minutes: 15, kind: .figure)],
            textQuality: .good)
    }

    static func samplePaper() -> Paper {
        Paper(
            pk: 42, id: "0f8fad5b-d9cb-469f-a165-70867728950e",
            sha256: "5f31a23cf3eb7b5137f0b49850cc7433b6b5966a0519ad42b96d33c83891c504", fileSize: 35_339_756,
            ids: PaperIDs(doi: "10.1038/s41586-024-08351-7", arxivID: "2606.24530", arxivVersion: 2,
                          pii: "S0092867424013321", publishedDOI: "10.1016/j.cell.2024.01.001"),
            title: "Molecular and cellular dynamics of the developing human neocortex", titleRank: .api,
            authors: ["Li Wang", "Arnold R. Kriegstein"], year: 2024, venue: "Nature", abstract: "Abstract…",
            metaSource: .crossref, metaUserEdited: true, pageCount: 49, charCount: 312_000,
            flags: [.scanned, .locked], folder: "Papers/2024_Wang_Molecular", pdfName: "2024_Wang_Molecular.pdf",
            originalName: "s41586-024-08351-7.pdf", nameFinal: true, stage: .ready, status: .reading,
            priority: .high, deadline: LocalDate(year: 2026, month: 10, day: 2), scheduleMode: .pinned,
            deadlineOrigin: .user, queueRank: 17, placementFloor: LocalDate(year: 2026, month: 9, day: 30),
            provisional: false, estMinutes: 110, estSource: .agent, categoryPK: 7, categoryUserSet: true,
            needsReview: true, tldr: "A spatial atlas.", card: sampleCard(), cardVersion: 1, textQuality: .partial,
            aiState: .done, aiNote: "retry used effort=low", aiSeen: false, notes: "My own thoughts\n- one",
            addedAt: Date(timeIntervalSince1970: 1_790_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_123.456),
            openedAt: Date(timeIntervalSince1970: 1_790_000_500), doneAt: nil,
            deletedAt: Date(timeIntervalSince1970: 1_790_009_999))
    }

    static func sampleChecklist() -> [ChecklistItem] {
        [ChecklistItem(id: "k3f9a2qd", ord: 2.5, text: "Fig. 2: compare proportions", section: "Fig. 2", page: 5,
                       minutes: 15, kind: .figure, origin: .agent, userEdited: true,
                       doneAt: Date(timeIntervalSince1970: 1_790_001_000)),
         ChecklistItem(id: "a1b2c3d4", ord: 1, text: "Overview", minutes: 10, kind: .overview, origin: .heuristic)]
    }

    fileprivate static func sampleTags() -> [PaperTag] {
        [PaperTag(name: "spatial", origin: .user), PaperTag(name: "single-cell", origin: .agent), PaperTag(name: "mouse", origin: .suppressed)]
    }

    static func sampleSidecar() -> CardSidecar {
        CardSidecar(paper: samplePaper(), checklist: sampleChecklist(), categoryName: "Neuroscience & Development",
                    tags: sampleTags(), aiProvider: "claude", aiModel: "claude-sonnet-4-5",
                    aiGeneratedAt: Date(timeIntervalSince1970: 1_790_000_100))
    }

    @Test func roundTripIsLossless() throws {
        let sidecar = Self.sampleSidecar()
        let data = try sidecar.encoded()
        let decoded = try CardSidecar.decoded(from: data)
        #expect(decoded == sidecar)
        #expect(try decoded.encoded() == data)

        let models = decoded.toModels(folder: "Papers/2024_Wang_Molecular")
        var expected = Self.samplePaper()
        expected.pk = 0
        expected.categoryPK = nil
        #expect(models.paper == expected)
        #expect(models.checklist == Self.sampleChecklist().sorted { $0.ord < $1.ord })
        #expect(models.categoryName == "Neuroscience & Development")
        #expect(Set(models.tags) == Set(Self.sampleTags()))
        #expect(models.aiProvider == "claude")
        #expect(models.aiModel == "claude-sonnet-4-5")
        #expect(models.aiGeneratedAt == Date(timeIntervalSince1970: 1_790_000_100))
    }

    @Test func encodedShapeMatchesSchema() throws {
        var paper = Self.samplePaper()
        paper.card = nil
        paper.doneAt = nil
        let sidecar = CardSidecar(paper: paper, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil)
        let data = try sidecar.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"addedAt\" : \"2026-09-21T"))        // sorted keys, pretty printed
        #expect(text.contains("\"schema\" : \"paperdeck.card/1\""))
        #expect(text.contains("\"updatedAt\" : \"2026-09-21T") && text.contains(".456Z\""))
        #expect(text.contains("\"deadline\" : \"2026-10-02\""))

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schema", "id", "sha256", "fileSize", "addedAt", "updatedAt", "pdf", "originalName",
                                   "ids", "meta", "reading", "state", "checklist", "category", "tags", "notes", "ai"])
        let reading = try #require(json["reading"] as? [String: Any])
        #expect(reading["doneAt"] is NSNull)                                 // explicit nulls, stable shape
        #expect(reading["priority"] as? Int == 1)
        let ids = try #require(json["ids"] as? [String: Any])
        #expect(Set(ids.keys) == ["doi", "arxiv", "arxivVersion", "pii", "publishedDoi"])
        let state = try #require(json["state"] as? [String: Any])
        #expect(state["flags"] as? Int == 3)
        let category = try #require(json["category"] as? [String: Any])
        #expect(category["name"] is NSNull)
        #expect(category["userSet"] as? Bool == true)
        let ai = try #require(json["ai"] as? [String: Any])
        #expect(ai["card"] is NSNull)
    }

    @Test func readingCardKeepsSnakeCaseKeys() throws {
        let data = try Self.sampleSidecar().encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let card = try #require((json["ai"] as? [String: Any])?["card"] as? [String: Any])
        #expect(card["estimated_minutes"] as? Int == 110)
        #expect(card["key_terms"] != nil)
    }

    @Test func decodesDesignExampleLiterally() throws {
        let url = try #require(Bundle.module.url(forResource: "card-example", withExtension: "json",
                                                  subdirectory: "Fixtures/library"))
        let s = try CardSidecar.decoded(from: Data(contentsOf: url))
        #expect(s.schema == "paperdeck.card/1")
        #expect(s.id == "…")
        #expect(s.addedAt == nil)                                             // "…" is not a timestamp
        #expect(s.pdf == "2024_Wang_….pdf")
        #expect(s.originalName == "s41586-024-08351-7.pdf")
        #expect(s.ids == .init(doi: "10.1038/s41586-024-08351-7"))
        #expect(s.meta.titleRank == .api)
        #expect(s.meta.authors == ["Li Wang", "…"])
        #expect(s.meta.year == 2024 && s.meta.venue == "Nature" && s.meta.source == .crossref)
        #expect(s.meta.pageCount == 49)
        #expect(s.reading.status == .toRead)
        #expect(s.reading.deadline == LocalDate(year: 2026, month: 10, day: 2))
        #expect(s.reading.placementFloor == LocalDate(year: 2026, month: 9, day: 30))
        #expect(s.reading.queueRank == 17 && !s.reading.provisional && s.reading.estMinutes == 110)
        #expect(s.reading.estSource == .agent && s.reading.scheduleMode == .auto && s.reading.deadlineOrigin == .place)
        #expect(s.state.stage == .ready && s.state.flags == [] && s.state.nameFinal && !s.state.needsReview)
        #expect(s.state.textQuality == .good && s.state.aiState == .done && s.state.aiSeen)
        #expect(s.checklist.count == 1)
        #expect(s.checklist.first?.id == "k3f9a2qd" && s.checklist.first?.section == "Fig. 2")
        #expect(s.checklist.first?.page == 5 && s.checklist.first?.minutes == 15 && s.checklist.first?.kind == .figure)
        #expect(s.category == .init(name: "Neuroscience & Development", userSet: false))
        #expect(s.tags == [PaperTag(name: "single-cell", origin: .agent)])
        #expect(s.notes == "…")
        #expect(s.ai.provider == "claude" && s.ai.model == "claude-sonnet-…" && s.ai.cardVersion == 1)
        #expect(s.ai.generatedAt == nil && s.ai.card == nil)                // "card":{} is not a full card

        let models = s.toModels(folder: "Papers/2024_Wang_X", fallbackDate: Date(timeIntervalSince1970: 5))
        #expect(models.paper.addedAt == Date(timeIntervalSince1970: 5))
        #expect(models.checklist.first?.ord == 1)
        #expect(models.paper.folder == "Papers/2024_Wang_X")
    }

    @Test func lenientFieldsButRequiredIdentity() throws {
        let messy = #"""
        {"schema":"paperdeck.card/1","id":"abc","sha256":"def","addedAt":"2026-09-30T10:42:00+02:00",
         "updatedAt":"2026-09-30T08:42:00.5Z","meta":{"title":"","titleRank":"four","authors":["A",3]},
         "reading":{"status":"skimming","deadline":"2026-02-30","priority":1},
         "checklist":[{"id":"x1","text":"ok","minutes":5},{"text":"no id"},{"id":"x3","text":"bad kind","kind":"poem"}],
         "tags":[{"name":"a","origin":"agent"},{"name":"b","origin":"alien"}],"ai":null,"extra":{"future":true}}
        """#
        let s = try CardSidecar.decoded(from: Data(messy.utf8))
        #expect(s.addedAt == Date(timeIntervalSince1970: 1_790_757_720))
        #expect(s.updatedAt == Date(timeIntervalSince1970: 1_790_757_720.5))
        #expect(s.meta.titleRank == .filename)
        #expect(s.meta.authors == ["A"])                                   // bad element dropped, not the list
        #expect(s.reading.status == .toRead && s.reading.deadline == nil && s.reading.priority == .high)
        #expect(s.checklist.map(\.id) == ["x1", "x3"])
        #expect(s.checklist.last?.kind == .other)
        #expect(s.tags == [PaperTag(name: "a", origin: .agent)])
        #expect(s.ai == .init())
        #expect(s.toModels(folder: "Papers/f").paper.title == "Untitled")
        #expect(s.toModels(folder: "Papers/f").paper.pdfName == "f.pdf")

        for bad in [#"{"schema":"paperdeck.card/2","id":"a","sha256":"b"}"#,
                    #"{"schema":"something/1","id":"a","sha256":"b"}"#,
                    #"{"schema":"paperdeck.card/1","sha256":"b"}"#,
                    #"{"schema":"paperdeck.card/1","id":"","sha256":"b"}"#,
                    "not json"] {
            #expect(throws: (any Error).self) { try CardSidecar.decoded(from: Data(bad.utf8)) }
        }
    }

    @Test func manifestRoundTripAndExample() throws {
        let cats = [PaperCategory(pk: 3, name: "Neuroscience & Development", description: "Brain", hue: 4, origin: .starter,
                             acknowledged: true, createdAt: Date(timeIntervalSince1970: 1_780_000_000)),
                    PaperCategory(pk: 9, name: "Spatial Models", description: nil, hue: 7, origin: .agent, acknowledged: false,
                             createdAt: Date(timeIntervalSince1970: 1_780_000_001))]
        let skip: Set<LocalDate> = [LocalDate(year: 2026, month: 10, day: 3), LocalDate(year: 2026, month: 10, day: 1)]
        let manifest = LibraryManifest(libraryID: "lib-1", categories: cats, skipDays: skip,
                                       updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try manifest.encoded()
        let back = try LibraryManifest.decoded(from: data)
        #expect(back == manifest)
        #expect(back.skipDays == skip.sorted())
        #expect(back.categoryModels().map(\.name) == cats.map(\.name))
        #expect(back.categoryModels().map(\.createdAt) == cats.map(\.createdAt))
        #expect(back.categoryModels()[1].description == nil)
        #expect(String(decoding: data, as: UTF8.self).contains("\"format\" : 1"))

        let url = try #require(Bundle.module.url(forResource: "library-example", withExtension: "json",
                                                  subdirectory: "Fixtures/library"))
        let example = try LibraryManifest.decoded(from: Data(contentsOf: url))
        #expect(example.format == 1)
        #expect(example.categories.map(\.name) == ["Neuroscience & Development", "Spatial Models"])
        try #require(example.categories.count > 1)          // no index past a failed expectation (QA-15)
        #expect(example.categories[1].acknowledged == false && example.categories[1].origin == .agent)
        #expect(example.skipDays == [LocalDate(year: 2026, month: 10, day: 1), LocalDate(year: 2026, month: 10, day: 3)])
        #expect(example.updatedAt == Date(timeIntervalSince1970: 1_790_764_920))

        #expect(throws: (any Error).self) {
            try LibraryManifest.decoded(from: Data(#"{"libraryID":"x","format":2}"#.utf8))
        }
    }
}
