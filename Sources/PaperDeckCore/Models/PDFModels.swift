import Foundation

/// Kinds of sections the checklist heuristics care about.
package enum SectionKind: String, Codable, Sendable, CaseIterable {
    case abstract, introduction, background, results, discussion, conclusion
    case methods, experiments, evaluation, relatedWork = "related_work"
    case dataAvailability = "data_availability", codeAvailability = "code_availability"
    case extendedData = "extended_data", supplementary
    case references, acknowledgements, other
}

/// A detected section heading and the page (1-based) where it first appears.
package struct SectionHit: Codable, Sendable, Equatable {
    package var kind: SectionKind
    package var title: String
    package var page: Int
    package init(kind: SectionKind, title: String, page: Int) {
        self.kind = kind; self.title = title; self.page = page
    }
}

/// Structural facts used by `ChecklistHeuristics` and `TextPreparer`.
package struct DocumentStructure: Codable, Sendable, Equatable {
    package var sections: [SectionHit]          // in document order, first occurrence per kind
    package var sectionsFromOutline: Bool       // true when taken from the PDF outline
    package var mainFigureNumbers: [Int]        // distinct "Fig. N" (not Extended/Supplementary), ≤ 12
    package var hasExtendedData: Bool
    package var hasSupplementary: Bool
    package var mainWordCount: Int              // words before References/Supplementary
    package var benchmarkMentions: Int          // occurrences of "benchmark"

    package init(sections: [SectionHit] = [], sectionsFromOutline: Bool = false, mainFigureNumbers: [Int] = [],
                 hasExtendedData: Bool = false, hasSupplementary: Bool = false, mainWordCount: Int = 0,
                 benchmarkMentions: Int = 0) {
        self.sections = sections; self.sectionsFromOutline = sectionsFromOutline
        self.mainFigureNumbers = mainFigureNumbers; self.hasExtendedData = hasExtendedData
        self.hasSupplementary = hasSupplementary; self.mainWordCount = mainWordCount
        self.benchmarkMentions = benchmarkMentions
    }

    package func page(of kind: SectionKind) -> Int? { sections.first { $0.kind == kind }?.page }
    package func has(_ kind: SectionKind) -> Bool { sections.contains { $0.kind == kind } }
}

/// Everything PDFKit extraction yields for one file (no UI, no DB).
package struct ExtractedPDF: Sendable {
    package var pageCount: Int
    package var pageTexts: [String]             // one string per page, in order
    package var charCount: Int
    package var isEncrypted: Bool
    package var isLocked: Bool                  // still locked after trying the empty password
    package var isScanned: Bool                 // < ~200 chars/page on average
    package var attributeTitle: String?         // PDF Title attribute (junk already filtered out)
    package var attributeAuthor: String?
    package var fontTitle: String?              // largest-font heuristic from page 1
    package var ids: PaperIDs                   // from file name + first pages + XMP
    package var structure: DocumentStructure
    package var cardThumbnailJPEG: Data?        // 560×240 top crop of page 1, q0.75

    package init(pageCount: Int, pageTexts: [String], charCount: Int, isEncrypted: Bool, isLocked: Bool,
                 isScanned: Bool, attributeTitle: String?, attributeAuthor: String?, fontTitle: String?,
                 ids: PaperIDs, structure: DocumentStructure, cardThumbnailJPEG: Data?) {
        self.pageCount = pageCount; self.pageTexts = pageTexts; self.charCount = charCount
        self.isEncrypted = isEncrypted; self.isLocked = isLocked; self.isScanned = isScanned
        self.attributeTitle = attributeTitle; self.attributeAuthor = attributeAuthor
        self.fontTitle = fontTitle; self.ids = ids; self.structure = structure
        self.cardThumbnailJPEG = cardThumbnailJPEG
    }

    /// Best local title guess and its rank (font > attribute), nil if neither.
    package var bestLocalTitle: (String, TitleRank)? {
        if let t = fontTitle { return (t, .font) }
        if let t = attributeTitle { return (t, .pdfAttribute) }
        return nil
    }

    /// Full text with form feeds between pages (for FTS and the text cache).
    package var fullText: String { pageTexts.joined(separator: "\u{0C}") }
}
