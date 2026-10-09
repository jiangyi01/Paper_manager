import Foundation

/// Persistent identifiers found in the file name, PDF text/XMP, or metadata APIs.
package struct PaperIDs: Codable, Sendable, Equatable, Hashable {
    package var doi: String?             // lowercased, e.g. "10.1038/s41586-024-08351-7"
    package var arxivID: String?         // base id without version, e.g. "2606.24530" or "math.GT/0309136"
    package var arxivVersion: Int?
    package var pii: String?             // Elsevier PII, e.g. "S0092867424013321"
    package var publishedDOI: String?    // journal DOI of a preprint (bioRxiv `published`)

    package init(doi: String? = nil, arxivID: String? = nil, arxivVersion: Int? = nil,
                 pii: String? = nil, publishedDOI: String? = nil) {
        self.doi = doi; self.arxivID = arxivID; self.arxivVersion = arxivVersion
        self.pii = pii; self.publishedDOI = publishedDOI
    }

    package var isEmpty: Bool { doi == nil && arxivID == nil && pii == nil }

    /// Fill nil fields from `other` (self wins on conflicts).
    package func merged(with other: PaperIDs) -> PaperIDs {
        PaperIDs(doi: doi ?? other.doi, arxivID: arxivID ?? other.arxivID,
                 arxivVersion: arxivVersion ?? other.arxivVersion, pii: pii ?? other.pii,
                 publishedDOI: publishedDOI ?? other.publishedDOI)
    }
}

/// Canonical bibliographic record from arXiv / bioRxiv / Crossref / OpenAlex.
package struct BiblioMetadata: Codable, Sendable, Equatable {
    package var title: String?
    package var authors: [String]        // display order, "Given Family"
    package var year: Int?
    package var venue: String?           // journal / "bioRxiv" / "arXiv"
    package var abstract: String?
    package var ids: PaperIDs
    package var source: MetaSource
    /// Links the record states to other works (Crossref `relation` / `update-to`; OpenAlex
    /// locations). Only the duplicate check reads them; nothing here is ever adopted as an id.
    package var relations: [WorkRelation]
    /// Crossref `type` / `subtype` ("journal-article", "posted-content/preprint", "component", …).
    package var workType: String?
    /// OpenAlex work id ("W2741809807"), when OpenAlex was asked anyway.
    package var openAlexID: String?

    package init(title: String? = nil, authors: [String] = [], year: Int? = nil, venue: String? = nil,
                 abstract: String? = nil, ids: PaperIDs = PaperIDs(), source: MetaSource,
                 relations: [WorkRelation] = [], workType: String? = nil, openAlexID: String? = nil) {
        self.title = title; self.authors = authors; self.year = year; self.venue = venue
        self.abstract = abstract; self.ids = ids; self.source = source
        self.relations = relations; self.workType = workType; self.openAlexID = openAlexID
    }

    private enum CodingKeys: String, CodingKey {
        case title, authors, year, venue, abstract, ids, source, relations, workType, openAlexID
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(abstract, forKey: .abstract)
        try c.encode(ids, forKey: .ids)
        try c.encode(source, forKey: .source)
        if !relations.isEmpty { try c.encode(relations, forKey: .relations) }
        try c.encodeIfPresent(workType, forKey: .workType)
        try c.encodeIfPresent(openAlexID, forKey: .openAlexID)
    }

    /// The duplicate-check fields are optional on decode (records encoded before they existed).
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        venue = try c.decodeIfPresent(String.self, forKey: .venue)
        abstract = try c.decodeIfPresent(String.self, forKey: .abstract)
        ids = try c.decodeIfPresent(PaperIDs.self, forKey: .ids) ?? PaperIDs()
        source = try c.decode(MetaSource.self, forKey: .source)
        relations = try c.decodeIfPresent([WorkRelation].self, forKey: .relations) ?? []
        workType = try c.decodeIfPresent(String.self, forKey: .workType)
        openAlexID = try c.decodeIfPresent(String.self, forKey: .openAlexID)
    }
}

/// One link a metadata record states from its work to another (`doi`, lowercased). `sameWork`
/// kinds name another version of the same work (preprint ↔ journal, versions, identical copies);
/// the others name a different work tied to it (a comment, a supplement, a correction notice).
package struct WorkRelation: Codable, Sendable, Equatable, Hashable {
    package enum Kind: String, Codable, Sendable, CaseIterable {
        case hasPreprint, isPreprintOf, hasVersion, isVersionOf, isIdenticalTo, isSameAs, replaces, isReplacedBy
        case isCommentOn, isReplyTo, isSupplementTo
        /// Crossmark `update-to`: this record is a notice (correction, retraction…) of `doi`.
        case correctionOf

        package var sameWork: Bool {
            switch self {
            case .hasPreprint, .isPreprintOf, .hasVersion, .isVersionOf, .isIdenticalTo, .isSameAs, .replaces,
                 .isReplacedBy: return true
            case .isCommentOn, .isReplyTo, .isSupplementTo, .correctionOf: return false
            }
        }
    }

    package var kind: Kind
    package var doi: String

    package init(kind: Kind, doi: String) { self.kind = kind; self.doi = doi }
}
