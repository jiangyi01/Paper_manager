import Foundation

/// Untrusted text (a paper, the screen, an earlier answer, the user's question) can never open or
/// close a prompt block: `</context>` becomes `[/context]`, `<question foo>` `[question foo]`. The
/// same rule as the card prompt's private neutralizer (CardSchema, which stays untouched), for the
/// assist surfaces' block names. Apply it to every value placed inside a block.
///
/// Every spelling a model could still read as the tag is caught (Phase 2 fixes QA-1, QA-9): any case;
/// whitespace of any kind — spaces, tabs, newlines, no-break and ideographic spaces — before or after
/// the slash (`< /paper>`, `<\n/question>`, `< / question >`); invisible marks between `<` and the
/// name or inside the name (zero-width space U+200B, word joiner U+2060, soft hyphen U+00AD, BOM
/// U+FEFF, the bidi controls — every Unicode `Cf` — plus the combining grapheme joiner and variation
/// selectors); and the full-width / small forms of the angle brackets (`＜/paper＞`). Text that only
/// resembles a tag (`<papers>`, `<b>`, `a < b`) stays as it is.
package enum BlockTags {
    /// Every block name an assist prompt uses (plan §4).
    package static let all: Set<String> = [
        "paper", "paper_meta", "paper_context", "context", "selection", "excerpt", "ocr_hint", "history",
        "question", "task", "metadata", "card", "conversation", "new", "candidate", "stdin",
    ]

    /// The angle brackets a model may read as one: ASCII, full-width, small form.
    static let openers: Set<Unicode.Scalar> = ["<", "\u{FF1C}", "\u{FE64}"]
    static let closers: Set<Unicode.Scalar> = [">", "\u{FF1E}", "\u{FE65}"]
    /// Marks a reader (or a tokenizer) may not see: format characters (zero-width marks, bidi
    /// controls, the soft hyphen, the BOM), the combining grapheme joiner, variation selectors.
    static let invisible = #"[\p{Cf}\x{034F}\x{FE00}-\x{FE0F}]"#
    /// Whitespace of any kind (ICU `\s` is `[\t\n\f\r\p{Z}]`; plus VT and NEL) or an invisible mark.
    static let gap = #"[\s\x{0B}\x{85}\p{Cf}\x{034F}\x{FE00}-\x{FE0F}]"#

    private static let cache = RegexCache()

    /// `s` with every `<tag…>` / `</tag…>` of `tags` (case-insensitive, up to 200 chars of
    /// attributes, an unterminated one included) turned into `[tag…]` / `[/tag…]`.
    package static func neutralize(_ s: String, tags: Set<String> = BlockTags.all) -> String {
        guard !tags.isEmpty, s.unicodeScalars.contains(where: { openers.contains($0) }) else { return s }
        let regex = cache.regex(for: tags)
        let ns = s as NSString
        return regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "[$1]")
    }

    /// The pattern for `tags` (exposed for tests). Possessive quantifiers keep it linear: a long run
    /// of spaces after a `<` is scanned once.
    static func pattern(for tags: Set<String>) -> String {
        // Longest first, so `paper_meta` is not read as `paper` + `_meta`.
        let names = tags.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.map(namePattern).joined(separator: "|")
        let open = "[" + openers.map { NSRegularExpression.escapedPattern(for: String($0)) }.sorted().joined() + "]"
        let close = "[" + closers.map { NSRegularExpression.escapedPattern(for: String($0)) }.sorted().joined() + "]"
        let notBracket = "[^\\n" + (openers.union(closers)).map { NSRegularExpression.escapedPattern(for: String($0)) }.sorted().joined() + "]"
        return open + "(" + gap + "*+/?" + gap + "*+(?:" + names + ")(?![\\p{L}\\p{N}_])" + notBracket + "{0,200})" + close + "?"
    }

    /// `paper` → `p(?:inv)*+a(?:inv)*+p…`: a name with invisible marks between its letters still matches.
    private static func namePattern(_ name: String) -> String {
        name.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: invisible + "*+")
    }

    /// One compiled pattern per tag set.
    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var compiled: [Set<String>: NSRegularExpression] = [:]

        func regex(for tags: Set<String>) -> NSRegularExpression {
            lock.withLock {
                if let r = compiled[tags] { return r }
                let r = try! NSRegularExpression(pattern: BlockTags.pattern(for: tags), options: [.caseInsensitive])
                compiled[tags] = r
                return r
            }
        }
    }
}
