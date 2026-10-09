import Foundation

/// PaperCategory and tag decisions for `applyAgentCard` (§6.2, §8 设置 ▸ AI). Pure: the
/// caller supplies the library's categories and per-category tag profile, then
/// applies the returned decision inside its transaction.
package enum Taxonomy {
    /// Claude may only add categories while the library has fewer than this many.
    package static let autoCreateLimit = 20
    /// Number of slots in the category chip palette (`PaperCategory.hue` ∈ 0..<paletteSize).
    package static let paletteSize = 10
    package static let maxAgentTags = 6

    package enum Decision: Sendable, Equatable {
        /// Leave `category_pk` as it is (user-set, or nothing sensible to pick).
        case keep
        case useExisting(pk: Int64)
        case createNew(name: String, description: String, hue: Int)
        /// Closest existing category when a new one isn't allowed; flag the paper for review.
        case fallback(pk: Int64, needsReview: Bool)
    }

    /// What the library already files under one category.
    package struct CategoryProfile: Sendable, Equatable {
        package var pk: Int64
        package var paperCount: Int
        package var tags: Set<String>          // tag names on live papers of this category (non-suppressed)
        package init(pk: Int64, paperCount: Int = 0, tags: Set<String> = []) {
            self.pk = pk; self.paperCount = paperCount; self.tags = tags
        }
    }

    package static func decide(card: ReadingCard, existing: [PaperCategory], profiles: [CategoryProfile],
                               allowNew: Bool, categoryUserSet: Bool, currentPK: Int64?) -> Decision {
        decide(category: card.category, newCategory: card.newCategory, tags: card.tags, existing: existing,
               profiles: profiles, allowNew: allowNew, categoryUserSet: categoryUserSet, currentPK: currentPK)
    }

    /// Rules, in order: user-set → keep; exact existing name (case-insensitive) → use it;
    /// otherwise the proposed new name — reuse an existing category it collides with, else
    /// create it when allowed and under the limit; else fall back to the category with the
    /// highest tag overlap (needs review); with no categories at all → keep.
    package static func decide(category: String, newCategory: ReadingCard.NewCategory?, tags: [String],
                               existing: [PaperCategory], profiles: [CategoryProfile], allowNew: Bool,
                               categoryUserSet: Bool, currentPK: Int64?) -> Decision {
        if categoryUserSet { return .keep }
        let picked = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if picked != ReadingCard.newCategoryToken, let hit = find(picked, in: existing) {
            return .useExisting(pk: hit.pk)
        }

        // "__new__" names its category in new_category; an off-enum pick names itself.
        let proposed = ((picked == ReadingCard.newCategoryToken || picked.isEmpty) ? newCategory?.name : picked)
            .flatMap { key($0) == ReadingCard.newCategoryToken ? nil : $0 }
        let name = proposed.flatMap(normalizeCategoryName)
        if let hit = proposed.flatMap({ find($0, in: existing) }) ?? name.flatMap({ find($0, in: existing) }) {
            return .useExisting(pk: hit.pk)
        }
        if allowNew, existing.count < autoCreateLimit, let name {
            return .createNew(name: name, description: oneLine(newCategory?.description ?? "", limit: 200),
                              hue: nextHue(existing: existing))
        }

        guard let best = closest(to: tags, proposedName: proposed, existing: existing,
                                 profiles: profiles, currentPK: currentPK) else { return .keep }
        return .fallback(pk: best, needsReview: true)
    }

    /// The least-used palette slot (ties → lowest index), so chips stay distinguishable.
    package static func nextHue(existing: [PaperCategory]) -> Int {
        var usage = Array(repeating: 0, count: paletteSize)
        for c in existing { usage[((c.hue % paletteSize) + paletteSize) % paletteSize] += 1 }
        let least = usage.min() ?? 0
        return usage.firstIndex(of: least) ?? 0
    }

    /// Lowercase kebab-case matching `^[a-z0-9][a-z0-9-]{1,39}$`, or nil if nothing usable is left.
    package static func normalizeTag(_ raw: String) -> String? {
        let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39:          // a-z, 0-9
                slug.unicodeScalars.append(scalar)
            default:
                if !slug.isEmpty && !slug.hasSuffix("-") { slug.append("-") }
            }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.count >= 2 ? slug : nil
    }

    /// Tags after a (re-)read: the user's tags ∪ the new agent tags − suppressed, at most
    /// `maxAgentTags` agent tags. Old agent tags are replaced, not accumulated. Suppressed
    /// names only block agent tags (a user tag can't also be suppressed in `paper_tag`);
    /// the caller keeps its suppressed rows as they are.
    package static func mergeTags(user: [Tag], agent: [String], suppressed: [String]) -> [Tag] {
        var seen = Set<String>()
        var result: [Tag] = []
        for tag in user {
            let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(normalizeTag(name) ?? name.lowercased()).inserted else { continue }
            result.append(Tag(name: name, origin: .user))
        }
        let blocked = Set(suppressed.flatMap { [normalizeTag($0), $0.lowercased()].compactMap { $0 } })
        var added = 0
        for raw in agent where added < maxAgentTags {
            guard let name = normalizeTag(raw), !blocked.contains(name), seen.insert(name).inserted else { continue }
            result.append(Tag(name: name, origin: .agent))
            added += 1
        }
        return result
    }

    /// Title Case, at most 3 significant words (minor words and "&" don't count), ≤60
    /// characters; nil when no word is left. Acronyms and mixed case ("scRNA-seq") are kept.
    package static func normalizeCategoryName(_ raw: String) -> String? {
        let tokens = oneLine(raw, limit: 500).split(separator: " ").map { token in
            String(token).trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "&+/")).inverted)
        }.filter { !$0.isEmpty }

        var kept: [String] = []
        var significant = 0
        for token in tokens where significant < 3 {
            kept.append(token)
            if isSignificant(token) { significant += 1 }
        }
        while let last = kept.last, !isSignificant(last) { kept.removeLast() }
        guard !kept.isEmpty else { return nil }

        var words = kept.enumerated().map { index, word in
            if index > 0 && minorWords.contains(word.lowercased()) { return word.lowercased() }
            // Only an all-lowercase head is capitalized: "cryo-EM" → "Cryo-EM", but "scRNA-seq"/"mRNA" stay.
            let head = word.split(separator: "-", maxSplits: 1).first.map(String.init) ?? word
            guard head == head.lowercased(), let first = word.first, first.isLowercase else { return word }
            return first.uppercased() + word.dropFirst()
        }
        while words.count > 1 && words.joined(separator: " ").count > 60 { words.removeLast() }
        while let last = words.last, words.count > 1, !isSignificant(last) { words.removeLast() }
        return String(words.joined(separator: " ").prefix(60))
    }

    // MARK: - Private

    private static let minorWords: Set<String> = [
        "a", "an", "the", "and", "or", "nor", "but", "of", "for", "in", "on", "at", "to", "by", "with",
        "via", "vs", "from", "as", "into", "per",
    ]

    private static func isSignificant(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber } && !minorWords.contains(token.lowercased())
    }

    /// Line breaks/tabs become spaces, other control/format characters (incl. bidi
    /// overrides) are dropped, whitespace is collapsed.
    private static func oneLine(_ raw: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format {
                scalars.append(scalar)
            }
        }
        return String(String(scalars).split(separator: " ").joined(separator: " ").prefix(limit))
    }

    private static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func find(_ name: String, in existing: [PaperCategory]) -> PaperCategory? {
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        return existing.first { key($0.name) == wanted }
    }

    /// Content words for the keyword tiebreak ("single-cell" → single, cell; plural s dropped).
    private static func keywords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return Set(words.compactMap { word in
            guard word.count >= 3, !minorWords.contains(word) else { return nil }
            return word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
        })
    }

    /// Ranking: tag overlap with the category's papers, then staying in the current
    /// category, then keyword overlap between the card's tags/proposed name and the
    /// category's name+description (lets a fresh library with untagged starters still
    /// pick sensibly), then most papers, then name.
    private static func closest(to tags: [String], proposedName: String?, existing: [PaperCategory],
                                profiles: [CategoryProfile], currentPK: Int64?) -> Int64? {
        let cardTags = Set(tags.compactMap(normalizeTag))
        let cardWords = keywords(cardTags.joined(separator: " ") + " " + (proposedName ?? ""))
        let byPK = Dictionary(profiles.map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a })

        struct Score { var category: PaperCategory; var tagOverlap: Int; var current: Bool; var wordOverlap: Int; var papers: Int }
        let scored = existing.map { c -> Score in
            let profile = byPK[c.pk]
            let profileTags = Set((profile?.tags ?? []).map { normalizeTag($0) ?? $0.lowercased() })
            return Score(category: c, tagOverlap: cardTags.intersection(profileTags).count, current: c.pk == currentPK,
                         wordOverlap: cardWords.intersection(keywords(c.name + " " + (c.description ?? ""))).count,
                         papers: profile?.paperCount ?? 0)
        }
        let best = scored.min { a, b in
            if a.tagOverlap != b.tagOverlap { return a.tagOverlap > b.tagOverlap }
            if a.current != b.current { return a.current }
            if a.wordOverlap != b.wordOverlap { return a.wordOverlap > b.wordOverlap }
            if a.papers != b.papers { return a.papers > b.papers }
            let order = a.category.name.localizedCaseInsensitiveCompare(b.category.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.category.pk < b.category.pk
        }
        return best?.category.pk
    }
}
