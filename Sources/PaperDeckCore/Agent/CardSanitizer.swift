import Foundation

/// Turns the agent's `structured_output` into a `ReadingCard` we are willing to
/// store and render. The schema has no length/count constraints (to avoid
/// quota-burning CLI retries), so every limit is enforced here, and anything
/// the model got structurally wrong degrades to a safe default instead of
/// failing the whole (already paid-for) run.
package enum CardSanitizer {
    package enum SanitizeError: Error, Equatable {
        case notAnObject
        case emptyCard           // neither a tldr nor a summary survived cleaning
    }

    package static let tldrLimit = 180
    package static let summaryLimit = 1050
    package static let methodLimit = 750
    package static let itemLimit = 270
    package static let maxListItems = 5
    package static let maxTermsOrResources = 8
    package static let maxTags = 6
    package static let minutesRange = 10...480
    package static let stepCountRange = 3...10
    package static let stepMinutesRange = 2...90
    package static let maxInferredLimitations = 2
    /// A model-written category description is replayed into <library> for every later paper.
    package static let categoryDescriptionLimit = 120

    /// Resource URLs are only kept (and later made clickable) for these hosts
    /// and their subdomains, over https.
    package static let allowedResourceHosts = [
        "github.com", "gitlab.com", "zenodo.org", "doi.org", "ncbi.nlm.nih.gov", "ebi.ac.uk",
        "huggingface.co", "figshare.com", "cellxgene.cziscience.com",
    ]

    package static func sanitize(_ raw: JSONValue, pageCount: Int?) throws -> ReadingCard {
        guard let o = rootObject(raw) else { throw SanitizeError.notAnObject }

        let summary = text(o["summary"], limit: summaryLimit)
        var tldr = text(o["tldr"], limit: tldrLimit)
        if tldr.isEmpty { tldr = truncate(firstSentence(of: summary), to: tldrLimit) }
        guard !tldr.isEmpty || !summary.isEmpty else { throw SanitizeError.emptyCard }

        var category = text(o["category"], limit: 100)
        if category.isEmpty || category.lowercased() == ReadingCard.newCategoryToken {
            category = ReadingCard.newCategoryToken
        }
        let newCategory = category == ReadingCard.newCategoryToken ? newCategoryValue(o["new_category"]) : nil

        let categoryTag = normalizeTag(newCategory?.name ?? category)
        let estimated = int(o["estimated_minutes"]).map { clamp($0, minutesRange) }
        let steps = checklist(o["checklist"], pageCount: pageCount, estimated: estimated)

        return ReadingCard(
            extractedMetadata: extractedMetadata(o["extracted_metadata"]),
            tldr: tldr,
            summary: summary,
            contributions: strings(o["contributions"], limit: itemLimit, max: maxListItems),
            method: text(o["method"], limit: methodLimit),
            results: strings(o["results"], limit: itemLimit, max: maxListItems),
            limitations: limitations(o["limitations"]),
            keyTerms: keyTerms(o["key_terms"]),
            resources: resources(o["resources"]),
            paperType: enumValue(o["paper_type"], default: .other),
            category: category,
            newCategory: newCategory,
            tags: tags(o["tags"], excluding: categoryTag),
            difficulty: enumValue(o["difficulty"], default: .medium),
            estimatedMinutes: estimated
                ?? clamp(steps.reduce(0) { $0 + $1.minutes }, minutesRange),
            checklist: steps,
            textQuality: enumValue(o["text_quality"], default: .partial)
        )
    }

    // MARK: - Fields

    private static func extractedMetadata(_ v: JSONValue?) -> ReadingCard.ExtractedMetadata? {
        guard let o = v?.objectValue else { return nil }
        let title = text(o["title"], limit: 300)
        guard !title.isEmpty else { return nil }
        let year = int(o["year"]).flatMap { (1500...2100).contains($0) ? $0 : nil }
        return ReadingCard.ExtractedMetadata(
            title: title,
            authors: strings(o["authors"], limit: 120, max: 50),
            year: year,
            venue: optionalText(o["venue"], limit: 200),
            doi: doi(o["doi"])
        )
    }

    private static func doi(_ v: JSONValue?) -> String? {
        guard var s = optionalText(v, limit: 250)?.lowercased() else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil ? s : nil
    }

    private static func newCategoryValue(_ v: JSONValue?) -> ReadingCard.NewCategory? {
        guard let o = v?.objectValue else { return nil }
        let name = text(o["name"], limit: 60)
        guard !name.isEmpty else { return nil }
        return ReadingCard.NewCategory(name: name, description: categoryDescription(text(o["description"], limit: 2000)))
    }

    /// A new category's description comes from untrusted model output and is sent back to the
    /// model in <library> with every later paper, so it must stay a short topical phrase: first
    /// sentence only, ≤ `categoryDescriptionLimit` characters, and dropped entirely ("") when it
    /// reads like an instruction, addresses the model, or carries a URL / markup.
    package static func categoryDescription(_ raw: String) -> String {
        let t = clean(raw)
        guard !t.isEmpty else { return "" }
        let range = NSRange(t.startIndex..., in: t)
        if instructionLike.contains(where: { $0.firstMatch(in: t, range: range) != nil }) { return "" }
        return truncate(firstSentence(of: t), to: categoryDescriptionLimit)
    }

    private static let instructionLike: [NSRegularExpression] = [
        #"\b(ignore|disregard|forget|override|obey|jailbreak|instructions?|prompts?)\b"#,
        #"\b(system|assistant|developer|admin)\b\s*(note|prompt|message|:)"#,
        #"\b(you|your|you're|yourself)\b"#,
        #"\b(must|always|never|do not|don't|should)\b"#,
        #"\bset\s+(the\s+)?(category|tldr|tags?|fields?|summary|title)\b"#,
        #"\b(every|all|each|future|later|next)\s+(papers?|cards?|requests?|inputs?)\b"#,
        #"\b(category|tldr|tags?|fields?|json|schema|output)\s*(to|=|:)"#,
        #"https?:|www\."#,
        #"\b[a-z0-9-]+\.(com|net|org|io|ai|example|xyz|info|biz|ru|cn)\b"#,
        #"[<>{}`\[\]]"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Keeps every author-stated limitation but at most two inferred ones.
    private static func limitations(_ v: JSONValue?) -> [ReadingCard.Limitation] {
        var out: [ReadingCard.Limitation] = []
        var inferred = 0
        for item in list(v) {
            let body: String
            let source: ReadingCard.Limitation.Source
            if let o = item.objectValue {
                body = text(o["text"], limit: itemLimit)
                source = enumValue(o["source"], default: .inferred)
            } else {
                body = text(item, limit: itemLimit)
                source = .inferred
            }
            guard !body.isEmpty else { continue }
            if source == .inferred {
                guard inferred < maxInferredLimitations else { continue }
                inferred += 1
            }
            out.append(.init(text: body, source: source))
            if out.count == maxListItems { break }
        }
        return out
    }

    private static func keyTerms(_ v: JSONValue?) -> [ReadingCard.KeyTerm] {
        var out: [ReadingCard.KeyTerm] = []
        for item in list(v) {
            guard let o = item.objectValue else { continue }
            let term = text(o["term"], limit: 80)
            guard !term.isEmpty else { continue }
            out.append(.init(term: term, definition: text(o["definition"], limit: itemLimit)))
            if out.count == maxTermsOrResources { break }
        }
        return out
    }

    private static func resources(_ v: JSONValue?) -> [ReadingCard.Resource] {
        var out: [ReadingCard.Resource] = []
        for item in list(v) {
            guard let o = item.objectValue else { continue }
            let identifier = optionalText(o["identifier"], limit: 200)
            var name = text(o["name"], limit: 200)
            if name.isEmpty, let identifier { name = identifier }
            guard !name.isEmpty else { continue }
            out.append(.init(kind: enumValue(o["kind"], default: .other), name: name,
                             identifier: identifier, url: allowedURL(o["url"])))
            if out.count == maxTermsOrResources { break }
        }
        return out
    }

    /// https + allowlisted host (or subdomain) only; everything else loses its URL.
    package static func allowedURL(_ v: JSONValue?) -> String? {
        guard let s = optionalText(v, limit: 2048), !s.contains(" "),
              let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil,
              var host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard allowedResourceHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return s
    }

    private static func tags(_ v: JSONValue?, excluding categoryTag: String?) -> [String] {
        var out: [String] = []
        for item in list(v) {
            guard let tag = normalizeTag(text(item, limit: 200)), tag != categoryTag,
                  !out.contains(tag) else { continue }
            out.append(tag)
            if out.count == maxTags { break }
        }
        return out
    }

    /// Lowercase kebab-case matching `^[a-z0-9][a-z0-9-]{1,39}$`, or nil.
    package static func normalizeTag(_ raw: String) -> String? {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var lastWasHyphen = true            // also drops leading separators
        for ch in folded.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                out.unicodeScalars.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        if out.count > 40 { out = String(out.prefix(40)) }
        while out.hasSuffix("-") { out.removeLast() }
        guard out.count >= 2 else { return nil }
        return out
    }

    /// 3–10 steps of 2–90 minutes; pages beyond the document dropped.
    /// Too few steps are padded with generic ones rather than failing the run.
    private static func checklist(_ v: JSONValue?, pageCount: Int?, estimated: Int?) -> [ReadingCard.Step] {
        var steps: [(task: String, section: String?, page: Int?, minutes: Int?, kind: ChecklistKind)] = []
        var seen = Set<String>()
        for item in list(v) {
            guard let o = item.objectValue else { continue }
            let task = text(o["task"] ?? o["text"], limit: itemLimit)
            guard !task.isEmpty, seen.insert(task.lowercased()).inserted else { continue }
            var page = int(o["page"])
            if let p = page, p < 1 || (pageCount.map { p > $0 } ?? false) { page = nil }
            steps.append((task, optionalText(o["section"], limit: 80), page,
                          int(o["minutes"]).map { clamp($0, stepMinutesRange) },
                          enumValue(o["kind"], default: .other)))
            if steps.count == stepCountRange.upperBound { break }
        }
        for generic in genericSteps where steps.count < stepCountRange.lowerBound {
            guard seen.insert(generic.task.lowercased()).inserted else { continue }
            steps.append((generic.task, generic.section, nil, nil, generic.kind))
        }

        let known = steps.compactMap(\.minutes)
        let missing = steps.count - known.count
        let fill: Int
        if missing > 0, let estimated {
            fill = clamp((estimated - known.reduce(0, +)) / missing, stepMinutesRange)
        } else {
            fill = 10
        }
        return steps.map {
            ReadingCard.Step(task: $0.task, section: $0.section, page: $0.page,
                             minutes: max($0.minutes ?? fill, stepMinutesRange.lowerBound), kind: $0.kind)
        }
    }

    private static let genericSteps: [(task: String, section: String?, kind: ChecklistKind)] = [
        ("Read abstract; skim all figure titles", "Abstract", .overview),
        ("Read the main text end-to-end; note the main claim and key evidence", nil, .other),
        ("Discussion: note stated limitations and future work", "Discussion", .discussion),
    ]

    // MARK: - Lenient JSON access

    /// Accepts the object itself or a JSON string that encodes it.
    private static func rootObject(_ raw: JSONValue) -> [String: JSONValue]? {
        if let o = raw.objectValue { return o }
        if let s = raw.stringValue, let data = s.data(using: .utf8),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v.objectValue }
        return nil
    }

    /// A lone value where an array was expected counts as a one-item array.
    private static func list(_ v: JSONValue?) -> [JSONValue] {
        switch v {
        case .array(let a)?: return a
        case nil, .null?: return []
        case let other?: return [other]
        }
    }

    /// Crash-safe integer read: NaN/∞/huge doubles and numeric strings are handled.
    private static func int(_ v: JSONValue?) -> Int? {
        let d: Double?
        switch v {
        case .number(let n)?: d = n
        case .string(let s)?: d = Double(s.trimmingCharacters(in: .whitespaces))
        default: d = nil
        }
        guard let d, d.isFinite, abs(d) < 1_000_000_000 else { return nil }
        return Int(d.rounded())
    }

    private static func enumValue<E: RawRepresentable>(_ v: JSONValue?, default fallback: E) -> E
        where E.RawValue == String {
        guard let s = v?.stringValue else { return fallback }
        return E(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? fallback
    }

    private static func strings(_ v: JSONValue?, limit: Int, max: Int) -> [String] {
        var out: [String] = []
        for item in list(v) {
            let s = text(item, limit: limit)
            guard !s.isEmpty else { continue }
            out.append(s)
            if out.count == max { break }
        }
        return out
    }

    private static func optionalText(_ v: JSONValue?, limit: Int) -> String? {
        let s = text(v, limit: limit)
        return s.isEmpty ? nil : s
    }

    private static func text(_ v: JSONValue?, limit: Int) -> String {
        let raw: String
        switch v {
        case .string(let s)?: raw = s
        case .number(let n)? where n.isFinite:
            raw = n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: return ""
        }
        return truncate(clean(raw), to: limit)
    }

    // MARK: - Text hygiene

    /// Invisible direction overrides/isolates and zero-width marks: they can
    /// disguise text (e.g. reverse a URL) and have no place in a plain-text card.
    private static let invisible: Set<UInt32> = [
        0x061C, 0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]

    /// Strips control and bidi characters; newlines/tabs become spaces; whitespace collapses.
    package static func clean(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for u in s.unicodeScalars {
            let isSpace = u.properties.isWhitespace
            if isSpace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if u.properties.generalCategory == .control || invisible.contains(u.value) { continue }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(u)
        }
        return String(scalars)
    }

    /// Cuts at a grapheme boundary, preferably a word boundary, marking the cut with "…".
    package static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        guard limit > 1 else { return String(s.prefix(limit)) }
        var cut = s.prefix(limit - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 30 {
            cut = cut[..<space]
        }
        let trimmed = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—"))
        return trimmed + "…"
    }

    private static func firstSentence(of s: String) -> String {
        guard let r = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return s }
        return String(s[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
}
