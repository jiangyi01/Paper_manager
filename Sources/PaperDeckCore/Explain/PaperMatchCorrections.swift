import Foundation

/// Text that many papers share and that says nothing about which one is on screen (CUX-6):
/// licence and copyright sentences, "Downloaded from …", preprint-server stamps, journal running
/// heads, URLs, DOIs, e-mail addresses, received / accepted dates, competing-interest and publisher
/// notes. Removed before the locator matches OCR or copied text against the library. Pure.
package enum Boilerplate {
    /// A sentence holding one of these (case-insensitive) is dropped whole.
    package static let sentenceTriggers: [String] = [
        #"\blicen[cs]ed under\b"#, #"\bcreative\s+commons\b"#, #"\bopen access\b"#, #"©"#, #"\(c\)\s*(?:19|20)\d{2}"#,
        #"\bcopyright\b"#, #"\ball rights reserved\b"#, #"\bdownloaded from\b"#, #"\b(?:bio|med|chem)rxiv preprint\b"#,
        #"\bthis version posted\b"#, #"\bpublished by (?:elsevier|springer|wiley|oxford|cambridge|the royal society|nature|ieee|acm|cell press|frontiers|mdpi|taylor)"#,
        #"\bunder review\b"#, #"\bcorrespondence (?:and requests|to|should be addressed)\b"#, #"\bcorresponding authors?\b"#,
        #"\bcompeting (?:financial )?interests\b"#, #"\bjurisdictional claims\b"#, #"\breprints and permissions\b"#,
        #"\bpermits (?:unrestricted )?(?:use|reuse)\b"#, #"\bpeer review information\b"#,
        #"\ball (?:other )?data (?:are|is|needed to evaluate)\b[^.]{0,60}\bavailable\b"#,
        #"版权所有"#, #"许可协议"#, #"知识共享"#,
    ]
    /// Removed wherever they appear: links, identifiers, addresses, running heads, the arXiv stamp, dates.
    package static let inlinePatterns: [String] = [
        #"https?://\S+"#, #"\bwww\.\S+"#, #"\bdoi:?\s*10\.\d{4,9}/\S+"#, #"\b10\.\d{4,9}/\S+"#, #"\S+@\S+\.[a-z]{2,}"#,
        #"[^\n|.]{0,40}\|\s*vol(?:ume)?\.?\s*\d+\s*(?:\|\s*\d{1,2}\s+[a-z]{3,9}\s+(?:19|20)\d{2}\s*)?(?:\|\s*\d{1,5}\b)?"#,
        #"\barxiv:\d{4}\.\d{4,5}(?:v\d+)?\s*\[[a-z.\- ]+\](?:\s*\d{1,2}\s+[a-z]{3,9}\s+(?:19|20)\d{2})?"#,
        #"\b(?:received|revised|accepted|published(?: online)?)\s*:?\s*\d{1,2}\s+[a-z]{3,9}\.?\s+(?:19|20)\d{2}[;,.]?"#,
    ]

    private static func compile(_ ps: [String]) -> [NSRegularExpression] {
        ps.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }
    private static let triggers = compile(sentenceTriggers)
    private static let inline = compile(inlinePatterns)
    /// After a sentence's end: whitespace (Latin), or straight after 。！？ (CJK). "4.0" never splits.
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?;])\s+|(?<=[。！？；])"#)

    /// `text` without its boilerplate (spacing collapsed, line breaks kept).
    package static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        for re in inline {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s.components(separatedBy: "\n").map { line -> String in
            sentences(line).filter { sentence in
                let r = NSRange(location: 0, length: (sentence as NSString).length)
                return !triggers.contains { $0.firstMatch(in: sentence, range: r) != nil }
            }
            .joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// One line's sentences, in order.
    static func sentences(_ line: String) -> [String] {
        let ns = line as NSString
        var out: [String] = []
        var start = 0
        for m in sentenceEnd.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The id of an arXiv stamp ("arXiv:2406.12345v2 [cs.CL] 3 Jun 2024", printed in the margin of
    /// an arXiv PDF's first page): it names the document on screen. A plain "arXiv:…" citation in a
    /// reference list has no "[category]" and doesn't count.
    package static func arxivStamp(_ text: String) -> String? {
        guard let r = text.range(of: #"(?i)\barxiv:(\d{4}\.\d{4,5})(v\d+)?\s*\[[a-z]+(?:[.\-][a-z]+)*\]"#, options: .regularExpression)
        else { return nil }
        let raw = String(text[r]).dropFirst("arxiv:".count)
        return FTSQuery.parseArxivID(String(raw.prefix { !$0.isWhitespace && $0 != "[" }))
    }
}

/// The user's corrections of the locator (CUX-6): "Not this paper" and a picked paper, remembered for
/// the window they came from (its cleaned title) and for the excerpt, so explaining again — and
/// the next capture of that window — follows them. In memory only (titles never leave this Mac),
/// per library, the newest `capacity`, for `lifetime`.
package final class PaperMatchCorrections: @unchecked Sendable {
    package static let shared = PaperMatchCorrections()
    package static let capacity = 32
    package static let lifetime: TimeInterval = 2 * 60 * 60

    package enum Decision: Sendable, Equatable {
        case notThis(String)
        case paper(String)
    }

    private struct Entry { var key: String; var scope: ObjectIdentifier; var decision: Decision; var at: Date }
    private let lock = NSLock()
    private var entries: [Entry] = []

    package init() {}

    /// The keys a capture is remembered under: its window (a specific cleaned title) and its excerpt.
    package static func keys(windowTitle: String?, excerpt: String?) -> [String] {
        var out: [String] = []
        if let raw = windowTitle {
            let cleaned = WindowTitle.parse(raw).cleaned
            if !WindowTitle.isGeneric(cleaned) { out.append("t:" + cleaned.lowercased()) }
        }
        if let excerpt {
            let n = TextMatch.normalize(Boilerplate.strip(excerpt)).scalars.prefix(160)
            if n.count >= 12 { out.append("x:" + String(String.UnicodeScalarView(n.compactMap(Unicode.Scalar.init)))) }
        }
        return out
    }

    package func reject(_ paperID: String, windowTitle: String?, excerpt: String?, scope: ObjectIdentifier, now: Date) {
        record(.notThis(paperID), windowTitle: windowTitle, excerpt: excerpt, scope: scope, now: now)
    }

    package func choose(_ paperID: String, windowTitle: String?, excerpt: String?, scope: ObjectIdentifier, now: Date) {
        record(.paper(paperID), windowTitle: windowTitle, excerpt: excerpt, scope: scope, now: now)
    }

    /// What the user said for this capture: the paper picked last (nil: none), and every paper said
    /// not to be it (a later pick of that paper lifts its rejection).
    package func decisions(windowTitle: String?, excerpt: String?, scope: ObjectIdentifier,
                           now: Date) -> (chosen: String?, rejected: Set<String>) {
        let keys = Set(Self.keys(windowTitle: windowTitle, excerpt: excerpt))
        guard !keys.isEmpty else { return (nil, []) }
        return lock.withLock {
            prune(now)
            var chosen: String?
            var rejected = Set<String>()
            // Oldest first, so the newest word wins.
            for e in entries.reversed() where e.scope == scope && keys.contains(e.key) {
                switch e.decision {
                case .notThis(let id):
                    rejected.insert(id)
                    if chosen == id { chosen = nil }
                case .paper(let id):
                    chosen = id
                    rejected.remove(id)
                }
            }
            return (chosen, rejected)
        }
    }

    /// Forgets everything (tests).
    package func removeAll() { lock.withLock { entries.removeAll() } }

    /// The panel's paper picker: titles holding every word of `query` (case- and accent-blind), the
    /// current match left out, at most `limit`, in library order; an empty query lists the first ones.
    package static func candidates(_ papers: [(id: String, title: String)], query: String, excluding: String?,
                                   limit: Int = 8) -> [(id: String, title: String)] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var out: [(id: String, title: String)] = []
        for p in papers where p.id != excluding {
            let t = p.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard words.allSatisfy({ t.contains($0) }) else { continue }
            out.append(p)
            if out.count == limit { break }
        }
        return out
    }

    private func record(_ d: Decision, windowTitle: String?, excerpt: String?, scope: ObjectIdentifier, now: Date) {
        let keys = Self.keys(windowTitle: windowTitle, excerpt: excerpt)
        lock.withLock {
            prune(now)
            for k in keys { entries.insert(Entry(key: k, scope: scope, decision: d, at: now), at: 0) }
            if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        }
    }

    private func prune(_ now: Date) {
        entries.removeAll { now.timeIntervalSince($0.at) > Self.lifetime || $0.at > now.addingTimeInterval(60) }
    }
}
