import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct CardSanitizerTests {
    /// A minimal valid card; tests override single fields.
    private func card(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "extracted_metadata": .null,
            "tldr": .string("Agents beat baselines on 7 of 24 tasks."),
            "summary": .string("A benchmark. It has tasks."),
            "contributions": .array([.string("Builds a benchmark")]),
            "method": .string("Containers."),
            "results": .array([.string("7 of 24")]),
            "limitations": .array([]),
            "key_terms": .array([]),
            "resources": .array([]),
            "paper_type": .string("benchmark"),
            "category": .string("AI Agents for Science"),
            "new_category": .null,
            "tags": .array([.string("llm-agents"), .string("benchmark"), .string("bio-ml")]),
            "difficulty": .string("hard"),
            "estimated_minutes": .number(60),
            "checklist": .array((1...5).map { (i: Int) in step("Step \(i)", page: i, minutes: 12) }),
            "text_quality": .string("good"),
        ]
        for (k, v) in overrides { o[k] = v }
        return .object(o)
    }

    private func step(_ task: String, section: JSONValue = .string("Fig. 1"), page: Int? = nil, minutes: Int? = 10,
                      kind: String = "figure") -> JSONValue {
        .object(["task": .string(task), "section": section, "page": page.map { .number(Double($0)) } ?? .null,
                 "minutes": minutes.map { .number(Double($0)) } ?? .null, "kind": .string(kind)])
    }

    private func strings(_ items: [String]) -> JSONValue { .array(items.map { .string($0) }) }

    @Test func fixtureCardSurvivesIntact() throws {
        let url = try #require(Bundle.module.url(forResource: "envelope-success", withExtension: "json",
                                                 subdirectory: "Fixtures/agent"))
        let env = try #require(ClaudeEnvelope.parse(try Data(contentsOf: url)))
        let raw = try #require(env.structuredOutput)
        let c = try CardSanitizer.sanitize(raw, pageCount: 14)
        #expect(c.tldr == raw["tldr"]?.stringValue)
        #expect(c.paperType == .benchmark)
        #expect(c.difficulty == .medium)
        #expect(c.estimatedMinutes == 55)
        #expect(c.tags == ["llm-agents", "benchmark", "biomedical-ml"])
        #expect(c.resources.first?.url == "https://github.com/science-machine/biomlbench")
        #expect(c.checklist.map(\.page) == [1, 4, 6, 9, 8, 11])
        #expect(c.limitations.map(\.source) == [.authors, .inferred])
        #expect(c.extractedMetadata == nil)
        // Round-trips through the stored Codable form.
        let again = try JSONValue.from(c).decode(ReadingCard.self)
        #expect(again == c)
    }

    @Test func controlAndBidiCharactersAreStripped() throws {
        let c = try CardSanitizer.sanitize(card([
            "tldr": .string("  Hello\u{202E}dlrow\u{0007}\u{200B} world\n\nnext\tline\u{2066}  "),
            "method": .string("a\u{0000}b\u{001B}[31mc\u{FEFF}"),
        ]), pageCount: nil)
        #expect(c.tldr == "Hellodlrow world next line")
        #expect(c.method == "ab[31mc")
    }

    @Test func lengthLimits() throws {
        let long = String(repeating: "word ", count: 400)
        let c = try CardSanitizer.sanitize(card([
            "tldr": .string(long), "summary": .string(long), "method": .string(long),
            "contributions": strings(Array(repeating: long, count: 9)),
            "results": strings((0..<9).map { "result \($0)" }),
            "key_terms": .array((0..<12).map { .object(["term": .string("T\($0)"), "definition": .string(long)]) }),
            "resources": .array((0..<12).map {
                .object(["kind": .string("dataset"), "name": .string("GSE\($0)"), "identifier": .null, "url": .null])
            }),
        ]), pageCount: nil)
        #expect(c.tldr.count <= 180 && c.tldr.hasSuffix("…"))
        #expect(c.summary.count <= 1050)
        #expect(c.method.count <= CardSanitizer.methodLimit)
        #expect(c.contributions.count == 5)
        #expect(c.contributions.allSatisfy { $0.count <= 270 })
        #expect(c.results == (0..<5).map { "result \($0)" })
        #expect(c.keyTerms.count == 8)
        #expect(c.keyTerms.allSatisfy { $0.definition.count <= 270 })
        #expect(c.resources.count == 8)
    }

    @Test func truncationKeepsGraphemesWhole() {
        let s = String(repeating: "👩‍🔬", count: 300)
        let t = CardSanitizer.truncate(s, to: 180)
        #expect(t.count <= 180)
        #expect(t.dropLast().allSatisfy { $0 == "👩‍🔬" })
    }

    @Test func tagsAreNormalized() throws {
        let c = try CardSanitizer.sanitize(card(["tags": strings([
            "Single Cell", "single-cell", "#CRISPR_screens", "a", "Ünïcödé Tag", String(repeating: "x", count: 60),
            "--lead--", "spatial transcriptomics", "extra-one", "extra-two",
        ])]), pageCount: nil)
        #expect(c.tags == ["single-cell", "crispr-screens", "unicode-tag", String(repeating: "x", count: 40), "lead",
                           "spatial-transcriptomics"])
        for tag in c.tags {
            #expect(tag.range(of: #"^[a-z0-9][a-z0-9-]{1,39}$"#, options: .regularExpression) != nil, "\(tag)")
        }
        #expect(CardSanitizer.normalizeTag("单细胞") == nil)
        #expect(CardSanitizer.normalizeTag("scRNA-seq") == "scrna-seq")
        #expect(CardSanitizer.normalizeTag(String(repeating: "ab-", count: 20)) == "ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-a")
    }

    @Test func tagRepeatingTheCategoryIsDropped() throws {
        let c = try CardSanitizer.sanitize(card([
            "category": .string("Single-cell & Spatial Omics"),
            "tags": strings(["single-cell-spatial-omics", "atlas"]),
        ]), pageCount: nil)
        #expect(c.tags == ["atlas"])
    }

    @Test func estimatedMinutesClamp() throws {
        #expect(try CardSanitizer.sanitize(card(["estimated_minutes": .number(2)]), pageCount: nil).estimatedMinutes == 10)
        #expect(try CardSanitizer.sanitize(card(["estimated_minutes": .number(10_000)]), pageCount: nil).estimatedMinutes == 480)
        #expect(try CardSanitizer.sanitize(card(["estimated_minutes": .string("45")]), pageCount: nil).estimatedMinutes == 45)
        #expect(try CardSanitizer.sanitize(card(["estimated_minutes": .number(1e300)]), pageCount: nil).estimatedMinutes == 60)
        // Missing → sum of the steps (5 × 12).
        #expect(try CardSanitizer.sanitize(card(["estimated_minutes": .null]), pageCount: nil).estimatedMinutes == 60)
    }

    @Test func checklistBoundsAndPages() throws {
        let many = (1...15).map { step("Task \($0)", page: $0 * 2, minutes: $0 == 1 ? 0 : 500) }
        let c = try CardSanitizer.sanitize(card(["checklist": .array(many)]), pageCount: 12)
        #expect(c.checklist.count == 10)
        #expect(c.checklist[0].minutes == 2)
        #expect(c.checklist[1].minutes == 90)
        #expect(c.checklist.map(\.page) == [2, 4, 6, 8, 10, 12, nil, nil, nil, nil])

        let zero = try CardSanitizer.sanitize(card(["checklist": .array([step("A", page: 0), step("B", page: 99)])]),
                                              pageCount: nil)
        #expect(zero.checklist.first?.page == nil)
        try #require(zero.checklist.count > 1)          // no index past a failed expectation (QA-15)
        #expect(zero.checklist[1].page == 99)     // unknown page count: kept
    }

    @Test func tooFewStepsArePadded() throws {
        let c = try CardSanitizer.sanitize(card([
            "estimated_minutes": .number(60),
            "checklist": .array([step("Fig. 2: compare proportions", minutes: 20), .string("not an object"),
                                 step("", minutes: 5)]),
        ]), pageCount: 10)
        #expect(c.checklist.count == 3)
        #expect(c.checklist[0].task == "Fig. 2: compare proportions")
        #expect(c.checklist[1].task == "Read abstract; skim all figure titles")
        #expect(c.checklist[1].minutes == 20)      // (60 − 20) / 2
        #expect(c.checklist.allSatisfy { (2...90).contains($0.minutes) })

        let none = try CardSanitizer.sanitize(card(["checklist": .null]), pageCount: nil)
        #expect(none.checklist.count == 3)
    }

    @Test func unknownEnumsFallBackToSafeDefaults() throws {
        let c = try CardSanitizer.sanitize(card([
            "paper_type": .string("opinion"), "difficulty": .string("brutal"), "text_quality": .string("meh"),
            "checklist": .array((1...3).map { step("S\($0)", kind: "skim") }),
            "limitations": .array([.object(["text": .string("n=3"), "source": .string("reviewer")])]),
            "resources": .array([.object(["kind": .string("software"), "name": .string("tool"),
                                          "identifier": .null, "url": .null])]),
        ]), pageCount: nil)
        #expect(c.paperType == .other)
        #expect(c.difficulty == .medium)
        #expect(c.textQuality == .partial)
        #expect(c.checklist.allSatisfy { $0.kind == .other })
        #expect(c.limitations.first?.source == .inferred)
        #expect(c.resources.first?.kind == .other)
        let cased = try CardSanitizer.sanitize(card(["paper_type": .string(" Methods "),
                                                     "resources": .array([.object(["kind": .string("protocol"), "name": .string("p")])])]),
                                               pageCount: nil)
        #expect(cased.paperType == .methods)
        #expect(cased.resources.first?.kind == .protocol_)
    }

    @Test func atMostTwoInferredLimitations() throws {
        let items: [JSONValue] = [("a", "inferred"), ("b", "authors"), ("c", "inferred"), ("d", "inferred"), ("e", "authors")]
            .map { .object(["text": .string($0.0), "source": .string($0.1)]) }
        let c = try CardSanitizer.sanitize(card(["limitations": .array(items)]), pageCount: nil)
        #expect(c.limitations.map(\.text) == ["a", "b", "c", "e"])
    }

    @Test(arguments: [
        ("https://github.com/org/repo", true),
        ("https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE1", true),
        ("https://sub.cellxgene.cziscience.com/collections/x", true),
        ("https://doi.org/10.5281/zenodo.123", true),
        ("https://huggingface.co/org/model", true),
        ("https://www.ebi.ac.uk/ena", true),
        ("https://GitHub.com/Org/Repo", true),
        ("http://github.com/org/repo", false),
        ("https://evil.example/github.com", false),
        ("https://github.com.evil.example/x", false),
        ("https://notgithub.com/x", false),
        ("https://user:pw@github.com/x", false),
        ("javascript:alert(1)", false),
        ("paperdeck://paper/123", false),
        ("https://git hub.com", false),
        ("", false),
    ])
    func resourceURLAllowlist(url: String, kept: Bool) {
        #expect((CardSanitizer.allowedURL(.string(url)) != nil) == kept)
    }

    @Test func newCategoryOnlyWithTheToken() throws {
        let nc: JSONValue = .object(["name": .string("Plant Biology"), "description": .string("Plants")])
        let a = try CardSanitizer.sanitize(card(["category": .string("__NEW__"), "new_category": nc]), pageCount: nil)
        #expect(a.category == ReadingCard.newCategoryToken)
        #expect(a.newCategory == .init(name: "Plant Biology", description: "Plants"))
        let b = try CardSanitizer.sanitize(card(["new_category": nc]), pageCount: nil)
        #expect(b.category == "AI Agents for Science")
        #expect(b.newCategory == nil)
        let c = try CardSanitizer.sanitize(card(["category": .string("  ")]), pageCount: nil)
        #expect(c.category == ReadingCard.newCategoryToken)
    }

    @Test func extractedMetadataCleanup() throws {
        let c = try CardSanitizer.sanitize(card(["extracted_metadata": .object([
            "title": .string("Eubiota"), "authors": strings(["A B", "", "C D"]), "year": .number(20245),
            "venue": .string("  "), "doi": .string("https://doi.org/10.1101/2026.02.27.708412"),
        ])]), pageCount: nil)
        let m = try #require(c.extractedMetadata)
        #expect(m.title == "Eubiota")
        #expect(m.authors == ["A B", "C D"])
        #expect(m.year == nil)
        #expect(m.venue == nil)
        #expect(m.doi == "10.1101/2026.02.27.708412")
        let bad = try CardSanitizer.sanitize(card(["extracted_metadata": .object(["title": .string(""), "doi": .string("nope")])]),
                                             pageCount: nil)
        #expect(bad.extractedMetadata == nil)
    }

    @Test func lenientShapes() throws {
        // Root delivered as a JSON string; single values where arrays are expected.
        let encoded = card(["contributions": .string("Only one"), "tags": .string("solo-tag")]).compactString()
        let c = try CardSanitizer.sanitize(.string(encoded), pageCount: nil)
        #expect(c.contributions == ["Only one"])
        #expect(c.tags == ["solo-tag"])
    }

    @Test func missingTldrFallsBackToFirstSentence() throws {
        let c = try CardSanitizer.sanitize(card(["tldr": .null, "summary": .string("First claim here. Second one.")]),
                                           pageCount: nil)
        #expect(c.tldr == "First claim here.")
    }

    @Test func rejectsUnusableInput() {
        #expect(throws: CardSanitizer.SanitizeError.notAnObject) { try CardSanitizer.sanitize(.array([]), pageCount: nil) }
        #expect(throws: CardSanitizer.SanitizeError.notAnObject) { try CardSanitizer.sanitize(.string("hi"), pageCount: nil) }
        #expect(throws: CardSanitizer.SanitizeError.emptyCard) {
            try CardSanitizer.sanitize(card(["tldr": .string("\u{202E}  "), "summary": .null]), pageCount: nil)
        }
    }
}
