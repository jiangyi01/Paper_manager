import Foundation

/// One key per work for DOIs that encode a version (dive-dedupe §2.2); every other DOI is its own
/// key. Inline regex literals (no non-Sendable static storage), as `MetadataClients.arxivURL` does.
package enum DOIFamily {
    package static func key(_ raw: String?) -> String? {
        guard let d = MetadataClients.normalizeDOI(raw) else { return nil }
        if let b = MetadataClients.biorxivDOI(d), let slash = b.firstIndex(of: "/") {
            var suffix = String(b[b.index(after: slash)...])                        // 10.1101 ≡ 10.64898
            if let v = suffix.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { suffix.removeSubrange(v) }
            return "biorxiv:" + suffix
        }
        if let m = d.firstMatch(of: /^10\.7554\/elife\.(\d+)(?:\.\d+)?$/) { return "elife:\(m.1)" }        // reviewed preprint .N, VOR
        if let m = d.firstMatch(of: /^(10\.12688\/[a-z0-9]+\.\d+)\.\d+$/) { return String(m.1) }              // F1000Research & co.
        if let m = d.firstMatch(of: /^(10\.21203\/rs\.3\.rs-\d+)\/v\d+$/) { return String(m.1) }           // Research Square
        if let m = d.firstMatch(of: /^(10\.20944\/preprints\d{6}\.\d{4})\.v\d+$/) { return String(m.1) }   // Preprints.org
        if let m = d.firstMatch(of: /^(10\.26434\/chemrxiv-\d{4}-[a-z0-9]+)-v\d+$/) { return String(m.1) } // ChemRxiv
        if let m = d.firstMatch(of: /^(10\.7287\/peerj\.preprints\.\d+)v\d+$/) { return String(m.1) }      // PeerJ Preprints
        if let id = MetadataClients.arxivID(fromDOI: d) { return DupKeys.arxivToken(id) }
        return d
    }

    /// The version a version-encoding DOI names (eLife `.3`, F1000 `.2`, Research Square `/v2`, …).
    package static func version(_ raw: String?) -> Int? {
        guard let d = MetadataClients.normalizeDOI(raw) else { return nil }
        let patterns: [Regex<(Substring, Substring)>] = [
            /^10\.7554\/elife\.\d+\.(\d+)$/, /^10\.12688\/[a-z0-9]+\.\d+\.(\d+)$/, /^10\.21203\/rs\.3\.rs-\d+\/v(\d+)$/,
            /^10\.20944\/preprints\d{6}\.\d{4}\.v(\d+)$/, /^10\.26434\/chemrxiv-\d{4}-[a-z0-9]+-v(\d+)$/,
            /^10\.7287\/peerj\.preprints\.\d+v(\d+)$/, /^10\.(?:1101|64898)\/.*\d+v(\d+)$/,
        ]
        for p in patterns { if let m = d.firstMatch(of: p) { return Int(m.1) } }
        return nil
    }
}

/// One identity token of a paper (`paper_key` row): the kind says why we have it, `value` is the
/// canonical token every comparison uses (a DOI family key, `arxiv:<base id>`, `openalex:W…`).
package struct DupKey: Sendable, Hashable, Codable {
    /// The frozen `paper_key.kind` CHECK list (SchemaAssist).
    package enum Kind: String, Sendable, Codable, CaseIterable {
        case doi, arxiv
        case preprintDOI = "preprint_doi", publishedDOI = "published_doi", versionDOI = "version_doi"
        case openalex, pmid, pmcid
    }

    /// Where it came from (`paper_key.source`): the paper row's own ids are `local` (re-derived
    /// and re-checked every time — a user's corrected DOI never keeps matching), the rest are
    /// what a metadata record or a merge said.
    package enum Source: String, Sendable, Codable, CaseIterable { case local, crossref, arxiv, biorxiv, openalex, merge, user }

    package var kind: Kind
    package var value: String
    package var source: Source

    package init(kind: Kind, value: String, source: Source) { self.kind = kind; self.value = value; self.source = source }
}

/// Identity tokens (dive-dedupe §2). Two papers sharing one token are the same work.
package enum DupKeys {
    /// `arxiv:<base id>`, lowercased, version dropped; an old-style id loses its subject class
    /// ("math.GT/0309136" → "arxiv:math/0309136", as the DataCite DOI writes it).
    package static func arxivToken(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if s.hasPrefix("arxiv:") { s = String(s.dropFirst(6)) }
        if let r = s.range(of: #"v\d+$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let m = s.firstMatch(of: /^([a-z\-]+)\.[a-z]{2}\/(\d{7})$/) { s = "\(m.1)/\(m.2)" }
        guard s.range(of: #"^(\d{4}\.\d{4,5}|[a-z\-]+/\d{7})$"#, options: .regularExpression) != nil else { return nil }
        return "arxiv:" + s
    }

    package static func doiToken(_ raw: String?) -> String? { DOIFamily.key(raw) }

    package static func openAlexToken(_ raw: String?) -> String? {
        MetadataClients.openAlexWorkID(raw).map { "openalex:" + $0.lowercased() }
    }

    /// The tokens of a paper's own ids (source `local`).
    package static func local(_ ids: PaperIDs) -> [DupKey] {
        var out: [DupKey] = []
        func add(_ kind: DupKey.Kind, _ value: String?) {
            guard let value, !out.contains(where: { $0.kind == kind && $0.value == value }) else { return }
            out.append(DupKey(kind: kind, value: value, source: .local))
        }
        add(.doi, doiToken(ids.doi))
        add(.publishedDOI, doiToken(ids.publishedDOI))
        add(.arxiv, arxivToken(ids.arxivID))
        return out
    }

    /// The tokens a metadata record adds: same-work relations and the OpenAlex id.
    package static func fromRecord(_ meta: BiblioMetadata) -> [DupKey] {
        let source: DupKey.Source
        switch meta.source {
        case .crossref: source = .crossref
        case .arxiv: source = .arxiv
        case .biorxiv: source = .biorxiv
        case .openalex: source = .openalex
        default: source = .crossref
        }
        var out: [DupKey] = []
        func add(_ kind: DupKey.Kind, _ value: String?, _ src: DupKey.Source) {
            guard let value, !out.contains(where: { $0.kind == kind && $0.value == value }) else { return }
            out.append(DupKey(kind: kind, value: value, source: src))
        }
        for r in meta.relations where r.kind.sameWork {
            switch r.kind {
            case .hasPreprint: add(.preprintDOI, doiToken(r.doi), source)
            case .isPreprintOf: add(.publishedDOI, doiToken(r.doi), source)
            default: add(.versionDOI, doiToken(r.doi), source)
            }
        }
        add(.openalex, openAlexToken(meta.openAlexID), .openalex)
        return out
    }

    /// Every token of a key list.
    package static func tokens(_ keys: [DupKey]) -> Set<String> { Set(keys.map(\.value)) }
}
