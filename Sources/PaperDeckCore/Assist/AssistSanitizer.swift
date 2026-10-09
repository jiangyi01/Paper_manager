import Foundation

/// What the model wrote, made safe to show (READING_ASSIST_PLAN §3.2, §10 "prompt injection"):
/// control characters and invisible direction / zero-width marks are removed (the card
/// sanitizer's set, `CardSanitizer.clean`, which a test cross-checks), and in the final answer
/// Markdown links and images become plain text, so nothing in an answer is clickable or loads
/// anything. Newlines and Markdown emphasis stay (the panel renders inline Markdown).
package enum AssistSanitizer {
    /// Invisible direction overrides / isolates and zero-width marks (the same code points as
    /// `CardSanitizer`'s private list).
    package static let invisible: Set<UInt32> = [
        0x061C, 0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]

    /// A streamed delta or replace: scalar by scalar, so fragments can be cleaned independently.
    /// Keeps `\n` and `\t`; drops `\r`, other controls and the invisible marks; U+2028 / U+2029 → `\n`.
    package static func fragment(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: needsWork) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x0A, 0x09: out.append(u)
            case 0x2028, 0x2029: out.append("\n")
            default:
                if u.properties.generalCategory == .control || invisible.contains(u.value) { continue }
                out.append(u)
            }
        }
        return String(out)
    }

    /// The final answer: `fragment`'s rules, CRLF → LF, runs of blank lines → one, Markdown links
    /// and images inert, trimmed, at most `limit` characters ("…" marks a cut).
    package static func answer(_ s: String, limit: Int) -> String {
        var text = fragment(s.replacingOccurrences(of: "\r\n", with: "\n"))
        text = inertLinks(text)
        text = text.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// `![alt](url)` → `alt`; `[label](url)` → `label (url)` (`url` alone when the label is the
    /// url); `<https://…>` autolinks → the bare address. The text stays, nothing is a link.
    package static func inertLinks(_ s: String) -> String {
        guard s.contains("](") || s.contains("<") else { return s }
        var t = s
        t = t.replacingOccurrences(of: #"!\[([^\]\n]{0,300})\]\([^)\n]{0,2000}\)"#, with: "$1", options: .regularExpression)
        t = replaceLinks(t)
        t = t.replacingOccurrences(of: #"<((?:https?|ftp|mailto|file):[^>\s]{1,2000})>"#, with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        return t
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]{1,300})\]\(\s*<?([^)\s>]{1,2000})>?(?:\s+"[^"\n]{0,300}")?\s*\)"#)

    private static func replaceLinks(_ s: String) -> String {
        let ns = s as NSString
        let matches = linkPattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let label = ns.substring(with: m.range(at: 1))
            let url = ns.substring(with: m.range(at: 2))
            out += label == url ? url : "\(label) (\(url))"
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func needsWork(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0x0A || u.value == 0x09 { return false }
        return u.properties.generalCategory == .control || invisible.contains(u.value) || u.value == 0x2028 || u.value == 0x2029
    }
}

/// How a turn's text is framed when a process has to be (re)started for an ongoing conversation
/// (dive-cli §3.4 C — the stateless fallback after a crash, cancel, idle close or the 12-turn cap;
/// every Codex follow-up): the earlier turns in one `<history>` block, newest last, at most
/// `historyLimit` characters (the oldest are dropped first), then the turn's own blocks.
package enum AssistFraming {
    package static let historyLimit = 6_000

    package static func statelessText(turnText: String, history: [AssistTurnText], limit: Int = historyLimit) -> String {
        guard !history.isEmpty, limit > 0 else { return turnText }
        var kept: [String] = []
        var used = 0
        for turn in history.reversed() {
            // A user turn is our own blocks (their values were neutralized when it was built): only
            // `<history>` is defused. An answer is model text: every block tag is.
            let body = turn.role == .user ? BlockTags.neutralize(turn.text, tags: ["history"]) : BlockTags.neutralize(turn.text)
            let entry = "[\(turn.role.rawValue)] " + body
            let cost = entry.count + (kept.isEmpty ? 0 : 1)
            if used + cost > limit {
                // The newest part of the first entry that doesn't fit, when there is real room left.
                let room = limit - used - (kept.isEmpty ? 0 : 1) - 1
                if room >= 200 { kept.append("…" + String(entry.suffix(room))) }
                break
            }
            kept.append(entry)
            used += cost
        }
        guard !kept.isEmpty else { return turnText }
        return "<history>\n" + kept.reversed().joined(separator: "\n") + "\n</history>\n" + turnText
    }
}
