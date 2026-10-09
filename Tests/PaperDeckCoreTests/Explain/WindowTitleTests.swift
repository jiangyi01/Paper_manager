import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// `WindowTitle.normalize` / `parse` over the viewers' title shapes (LN §10 "PaperLocator"), the
/// window list picker, and `FTSQuery.anyOf`'s injection safety.
@Suite struct WindowTitleTests {
    static let table: [(raw: String, cleaned: String)] = [
        ("2406.12345v2.pdf", "2406.12345v2"),
        ("Attention Is All You Need.pdf — Edited", "Attention Is All You Need"),
        ("paper.pdf (page 3 of 12)", "paper"),
        ("2024_Wang_Attention-Guided-Regularization.pdf - Adobe Acrobat Reader (64-bit)", "2024_Wang_Attention-Guided-Regularization"),
        ("Adobe Acrobat Reader - smith2025.pdf", "smith2025"),
        ("A Synthetic Benchmark for Coding Agents - Google Chrome - Person 1", "A Synthetic Benchmark for Coding Agents"),
        ("A Synthetic Benchmark for Coding Agents – Mozilla Firefox", "A Synthetic Benchmark for Coding Agents"),
        ("[2406.12345] Attention-guided regularization of transformers", "Attention-guided regularization of transformers"),
        ("Single-cell atlas of the developing heart | bioRxiv", "Single-cell atlas of the developing heart"),
        ("Single-cell atlas of the developing heart | Nature Communications", "Single-cell atlas of the developing heart"),
        ("• draft-notes.pdf", "draft-notes"),
        ("https://arxiv.org/pdf/2406.12345v2.pdf", "2406.12345v2"),
        ("My%20Paper.pdf", "My Paper"),
        ("BERT: Pre-training of Deep Bidirectional Transformers", "BERT: Pre-training of Deep Bidirectional Transformers"),
        ("Arc: a new method for arcs", "Arc: a new method for arcs"),
        ("Global outlook for the tropics - Preview", "Global outlook for the tropics"),
        ("论文 第 3 页，共 10 页", "论文"),
        ("Deep learning and 3 more pages - Microsoft\u{200B} Edge", "Deep learning"),
        ("  ", ""),
    ]

    @Test func normalizeTable() {
        for (raw, cleaned) in Self.table {
            #expect(WindowTitle.normalize(raw) == cleaned, "\(raw)")
        }
    }

    @Test func parseKeepsTheFileNameIdentifiersAndPage() {
        let a = WindowTitle.parse("2406.12345v2.pdf - Google Chrome")
        #expect(a.fileName == "2406.12345v2.pdf" && a.arxivID == "2406.12345" && a.doi == nil)
        let b = WindowTitle.parse("10.1038_s41586-024-08351-7.pdf (page 4 of 20) — Preview")
        #expect(b.doi == "10.1038/s41586-024-08351-7" && b.page == 4 && b.arxivID == nil)
        let c = WindowTitle.parse("https://doi.org/10.1101/2024.01.02.573456 - Safari")
        #expect(c.doi == "10.1101/2024.01.02.573456" && c.arxivID == nil)      // no arXiv id inside a DOI
        let d = WindowTitle.parse("Report 2024.13579 draft")                     // month 13: not an arXiv id
        #expect(d.arxivID == nil)
        let e = WindowTitle.parse("math.GT/0309136v1 notes")
        #expect(e.arxivID == "math.GT/0309136")
        let f = WindowTitle.parse("论文 第 3 页，共 10 页")
        #expect(f.page == 3)
        #expect(WindowTitle.parse("Untitled").fileName == nil)
    }

    @Test func genericNamesSayNothing() {
        for g in ["main", "Untitled", "download", "paper", "1234", "pdf", "a b", ""] { #expect(WindowTitle.isGeneric(g), "\(g)") }
        for ok in ["smith2025", "Attention Is All You Need", "2024_Wang_Title"] { #expect(!WindowTitle.isGeneric(ok), "\(ok)") }
    }

    @Test func anyOfQuotesEveryWordAndJoinsWithOr() {
        #expect(FTSQuery.anyOf(["attention", "Regularize", "attention"]) == "\"attention\" OR \"Regularize\"")
        // FTS5 syntax is inert: quotes, stars, carets, column filters, parentheses, NEAR, AND/OR/NOT.
        let hostile = ["\"x\" OR title:*", "NEAR(a b)", "AND", "or", "^start", "col:value", "a\"b", "-minus", "(paren)"]
        let expr = try! #require(FTSQuery.anyOf(hostile))
        #expect(!expr.contains("*") && !expr.contains(":") && !expr.contains("(") && !expr.contains("^"))
        // Only quoted phrases joined by " OR " remain outside the quotes.
        let outside = expr.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        #expect(outside.range(of: #"^( OR )*$"#, options: .regularExpression) != nil, "\(expr)")
        #expect(expr.filter { $0 == "\"" }.count == 2 * (outside.components(separatedBy: " OR ").count))
        #expect(!expr.contains("\"AND\"") && !expr.contains("\"or\""))
        #expect(FTSQuery.anyOf(["!!!", "", "  "]) == nil)
        #expect(FTSQuery.anyOf(["a1", "b2", "c3"], limit: 2)?.components(separatedBy: " OR ").count == 2)
        #expect(FTSQuery.anyOf(["single-cell"]) == "\"single cell\"")
    }

    @Test func theWindowListPicksTheFrontmostForeignWindowUnderThePoint() {
        func dict(_ n: UInt32, pid: Int32, name: String?, _ b: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
            var d: [String: Any] = [kCGWindowNumber as String: NSNumber(value: n), kCGWindowOwnerPID as String: NSNumber(value: pid),
                                    kCGWindowBounds as String: b.dictionaryRepresentation as NSDictionary,
                                    kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
                                    kCGWindowOwnerName as String: "App\(pid)"]
            if let name { d[kCGWindowName as String] = name }
            return d
        }
        let info: [[String: Any]] = [
            dict(1, pid: 50, name: "Menubar", CGRect(x: 0, y: 0, width: 1440, height: 24), layer: 25),
            dict(2, pid: 99, name: "Overlay", CGRect(x: 0, y: 0, width: 1440, height: 900)),          // ours
            dict(3, pid: 70, name: nil, CGRect(x: 100, y: 100, width: 10, height: 10)),                 // too small
            dict(4, pid: 71, name: "", CGRect(x: 0, y: 0, width: 800, height: 800), alpha: 0),           // invisible
            dict(5, pid: 72, name: "paper.pdf — Preview", CGRect(x: 0, y: 30, width: 800, height: 800)),
            dict(6, pid: 73, name: "Mail", CGRect(x: 0, y: 0, width: 1440, height: 900)),
            [kCGWindowNumber as String: NSNumber(value: 7)],                                              // malformed
        ]
        let entries = WindowList.entries(from: info)
        #expect(entries.map(\.windowID) == [1, 2, 3, 4, 5, 6])
        #expect(entries[3].title == nil)                                       // an empty name is no title
        let hit = WindowList.window(at: CGPoint(x: 105, y: 105), in: entries, excludingPID: 99)
        #expect(hit?.windowID == 5 && hit?.title == "paper.pdf — Preview" && hit?.ownerName == "App72")
        #expect(WindowList.window(at: CGPoint(x: 1000, y: 500), in: entries, excludingPID: 99)?.windowID == 6)
        #expect(WindowList.window(at: CGPoint(x: 5000, y: 5000), in: entries, excludingPID: 99) == nil)
        #expect(WindowList.frontmostWindow(ofPID: 73, in: entries)?.windowID == 6)
        #expect(WindowList.frontmostWindow(ofPID: 70, in: entries) == nil)
    }
}
