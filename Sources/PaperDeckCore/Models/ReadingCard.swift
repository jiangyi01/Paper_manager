import Foundation

/// The AI reading card (English). Field names/JSON keys match the agent JSON
/// schema in `CardSchema` exactly (snake_case on the wire). Values stored here
/// have already been through `CardSanitizer`.
package struct ReadingCard: Codable, Sendable, Equatable {
    package struct ExtractedMetadata: Codable, Sendable, Equatable {
        package var title: String
        package var authors: [String]
        package var year: Int?
        package var venue: String?
        package var doi: String?
        package init(title: String, authors: [String], year: Int?, venue: String?, doi: String?) {
            self.title = title; self.authors = authors; self.year = year; self.venue = venue; self.doi = doi
        }
    }

    package struct Limitation: Codable, Sendable, Equatable {
        package enum Source: String, Codable, Sendable { case authors, inferred }
        package var text: String
        package var source: Source
        package init(text: String, source: Source) { self.text = text; self.source = source }
    }

    package struct KeyTerm: Codable, Sendable, Equatable {
        package var term: String
        package var definition: String
        package init(term: String, definition: String) { self.term = term; self.definition = definition }
    }

    package struct Resource: Codable, Sendable, Equatable {
        package enum Kind: String, Codable, Sendable { case dataset, code, model, protocol_ = "protocol", other }
        package var kind: Kind
        package var name: String
        package var identifier: String?
        package var url: String?
        package init(kind: Kind, name: String, identifier: String?, url: String?) {
            self.kind = kind; self.name = name; self.identifier = identifier; self.url = url
        }
    }

    package struct NewCategory: Codable, Sendable, Equatable {
        package var name: String
        package var description: String
        package init(name: String, description: String) { self.name = name; self.description = description }
    }

    package struct Step: Codable, Sendable, Equatable {
        package var task: String
        package var section: String?
        package var page: Int?
        package var minutes: Int
        package var kind: ChecklistKind
        package init(task: String, section: String?, page: Int?, minutes: Int, kind: ChecklistKind) {
            self.task = task; self.section = section; self.page = page; self.minutes = minutes; self.kind = kind
        }
    }

    package var extractedMetadata: ExtractedMetadata?
    package var tldr: String
    package var summary: String
    package var contributions: [String]
    package var method: String
    package var results: [String]
    package var limitations: [Limitation]
    package var keyTerms: [KeyTerm]
    package var resources: [Resource]
    package var paperType: PaperType
    package var category: String                 // an existing category name or "__new__"
    package var newCategory: NewCategory?
    package var tags: [String]
    package var difficulty: Difficulty
    package var estimatedMinutes: Int
    package var checklist: [Step]
    package var textQuality: TextQuality

    package static let newCategoryToken = "__new__"

    enum CodingKeys: String, CodingKey {
        case extractedMetadata = "extracted_metadata"
        case tldr, summary, contributions, method, results, limitations
        case keyTerms = "key_terms"
        case resources
        case paperType = "paper_type"
        case category
        case newCategory = "new_category"
        case tags, difficulty
        case estimatedMinutes = "estimated_minutes"
        case checklist
        case textQuality = "text_quality"
    }

    package init(extractedMetadata: ExtractedMetadata? = nil, tldr: String, summary: String,
                 contributions: [String], method: String, results: [String], limitations: [Limitation],
                 keyTerms: [KeyTerm], resources: [Resource], paperType: PaperType, category: String,
                 newCategory: NewCategory? = nil, tags: [String], difficulty: Difficulty,
                 estimatedMinutes: Int, checklist: [Step], textQuality: TextQuality) {
        self.extractedMetadata = extractedMetadata; self.tldr = tldr; self.summary = summary
        self.contributions = contributions; self.method = method; self.results = results
        self.limitations = limitations; self.keyTerms = keyTerms; self.resources = resources
        self.paperType = paperType; self.category = category; self.newCategory = newCategory
        self.tags = tags; self.difficulty = difficulty; self.estimatedMinutes = estimatedMinutes
        self.checklist = checklist; self.textQuality = textQuality
    }
}
