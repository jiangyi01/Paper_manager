import Foundation

/// An answer's Markdown as blocks the Ask views can draw (SwiftUI `Text` renders inline Markdown
/// only): paragraphs, bullet and numbered items, quotes. Tolerant of partial text — it runs on
/// every streamed redraw (≤ 30 a second). Headings become bold paragraphs; fenced code becomes a
/// plain paragraph. Pure.
package enum QAAnswerFormat {
    package enum Block: Sendable, Equatable {
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case quote(String)
    }

    private static let bulletRx = try! NSRegularExpression(pattern: #"^\s{0,3}[-*•+]\s+(.*)$"#)
    private static let numberedRx = try! NSRegularExpression(pattern: #"^\s{0,3}(\d{1,3})[.)]\s+(.*)$"#)
    private static let headingRx = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$"#)
    private static let quoteRx = try! NSRegularExpression(pattern: #"^\s{0,3}>\s?(.*)$"#)

    package static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                continue
            }
            if let g = match(headingRx, line) {
                flush()
                if !g[0].isEmpty { out.append(.paragraph("**" + g[0] + "**")) }
            } else if let g = match(bulletRx, line) {
                flush()
                out.append(.bullet(g[0]))
            } else if let g = match(numberedRx, line), let n = Int(g[0]) {
                flush()
                out.append(.numbered(n, g[1]))
            } else if let g = match(quoteRx, line) {
                flush()
                if case .quote(let prev)? = out.last {
                    out[out.count - 1] = .quote(prev + "\n" + g[0])
                } else {
                    out.append(.quote(g[0]))
                }
            } else if paragraph.isEmpty, raw.hasPrefix("  ") || raw.hasPrefix("\t"), let last = out.last {
                // An indented continuation of the item above.
                let more = line.trimmingCharacters(in: .whitespaces)
                switch last {
                case .bullet(let s): out[out.count - 1] = .bullet(s + " " + more)
                case .numbered(let n, let s): out[out.count - 1] = .numbered(n, s + " " + more)
                default: paragraph.append(more)
                }
            } else {
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return out
    }

    private static func match(_ rx: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }
}
