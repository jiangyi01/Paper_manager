import Foundation

/// "Which one is newer" (DQ §3.4, dive-dedupe §6.1), pure: a version of record (a final DOI
/// that is not a preprint server's) > a preprint, and among preprints a higher version wins
/// (arXiv vN, bioRxiv vN, eLife `.N`, F1000 `.N`). Unknown when nothing says.
package struct VersionRank: Sendable, Equatable, Codable {
    package enum Tier: Int, Sendable, Codable, Comparable {
        case unknown = 0, preprint = 1, published = 3
        package static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    package var tier: Tier
    /// The version number when one is known (0: none).
    package var version: Int

    package init(tier: Tier, version: Int = 0) { self.tier = tier; self.version = max(0, version) }

    /// Stored in `paper_fingerprint.version_rank`.
    package var code: Int { tier.rawValue * 1_000 + min(version, 999) }
    package init(code: Int) {
        self.init(tier: Tier(rawValue: code / 1_000) ?? .unknown, version: code % 1_000)
    }

    /// DOI registrants of preprint servers (DQ §3.4). 10.1101 is shared with Cold Spring Harbor's
    /// journals, so it counts only through `MetadataClients.biorxivDOI` (date-stamped / numeric ids).
    package static let preprintPrefixes = ["10.64898/", "10.48550/", "10.21203/", "10.2139/", "10.20944/",
                                           "10.31219/", "10.31234/", "10.31235/", "10.26434/", "10.22541/", "10.7287/peerj.preprints"]
    /// Venue names of preprint servers.
    package static let preprintVenues: Set<String> = ["biorxiv", "medrxiv", "arxiv", "research square", "ssrn",
                                                      "preprints.org", "chemrxiv", "osf preprints", "authorea",
                                                      "psyarxiv", "socarxiv", "peerj preprints"]

    /// The rank of a paper (or a parked file) from its ids, venue and Crossref type.
    package static func of(ids: PaperIDs, venue: String?, workType: String? = nil) -> VersionRank {
        let venueIsPreprint = venue.map { preprintVenues.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? false
        if let doi = MetadataClients.normalizeDOI(ids.doi) {
            let doiVersion = DOIFamily.version(doi) ?? 0
            let preprintDOI = preprintPrefixes.contains { doi.hasPrefix($0) }
                || (MetadataClients.biorxivDOI(doi) != nil)
            if preprintDOI || workType?.lowercased().hasPrefix("posted-content") == true {
                let v = MetadataClients.arxivID(fromDOI: doi) != nil ? (ids.arxivVersion ?? doiVersion) : doiVersion
                return VersionRank(tier: .preprint, version: v)
            }
            // A DOI on a record that says it is a preprint (venue) stays a preprint.
            if venueIsPreprint && ids.publishedDOI != nil { return VersionRank(tier: .preprint, version: doiVersion) }
            return VersionRank(tier: .published, version: doiVersion)
        }
        if ids.publishedDOI != nil { return VersionRank(tier: .preprint, version: ids.arxivVersion ?? 0) }
        if ids.arxivID != nil { return VersionRank(tier: .preprint, version: ids.arxivVersion ?? 0) }
        if venueIsPreprint { return VersionRank(tier: .preprint) }
        return VersionRank(tier: .unknown)
    }

    /// Which of two versions is newer: `.new` / `.existing`, nil when the same or unknown.
    package static func newer(new n: VersionRank, existing e: VersionRank) -> DupSide? {
        guard n.tier != .unknown, e.tier != .unknown else { return nil }
        if n.tier != e.tier { return n.tier > e.tier ? .new : .existing }
        guard n.version > 0, e.version > 0, n.version != e.version else { return nil }
        return n.version > e.version ? .new : .existing
    }

    /// Same tier and the same known version (an unknown version — 0 — says nothing: two bioRxiv
    /// files of one DOI may be v1 and v2).
    package static func sameVersion(_ a: VersionRank, _ b: VersionRank) -> Bool {
        a.tier != .unknown && a.tier == b.tier && a.version > 0 && a.version == b.version
    }

    /// A bioRxiv / medRxiv file names its version where its printed DOI doesn't:
    /// `2024.01.01.000777v2.full.pdf` of `10.1101/2024.01.01.000777` is v2. nil unless the file
    /// name starts with that DOI's own id.
    package static func biorxivFileVersion(fileName: String?, doi: String?) -> Int? {
        guard let name = fileName?.lowercased(), let d = MetadataClients.normalizeDOI(doi),
              let b = MetadataClients.biorxivDOI(d), let slash = b.firstIndex(of: "/") else { return nil }
        var id = String(b[b.index(after: slash)...])
        if let v = id.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { id.removeSubrange(v) }
        guard !id.isEmpty, name.hasPrefix(id) else { return nil }
        let rest = name.dropFirst(id.count)
        guard let m = rest.firstMatch(of: /^v(\d{1,3})(?:[._\- ]|$)/) else { return nil }
        return Int(m.1)
    }

    /// The rank of a file: `of(ids:venue:)`, with a bioRxiv / medRxiv version from its file name
    /// when its DOI names none.
    package static func of(ids: PaperIDs, venue: String?, workType: String? = nil, fileName: String?) -> VersionRank {
        var r = of(ids: ids, venue: venue, workType: workType)
        if r.tier == .preprint, r.version == 0, let v = biorxivFileVersion(fileName: fileName, doi: ids.doi) {
            r.version = v
        }
        return r
    }
}
