import Foundation

/// Page numbers in the built-in reader (READING_ASSIST_PLAN §6.4 C4, LN §8). PaperDeck counts pages
/// PHYSICALLY, 1-based: a checklist item's `page`, a `[[p. N]]` citation, an explanation's page and
/// the reader's page memory all mean "the N-th page of the file". A PDF may also carry printed labels
/// (/PageLabels: "iii", "1203", "S4"); the reader shows a label beside the physical number when it says
/// something else, and its page field accepts either. Owned by Slice C (reader).
package enum ReaderPages {
    /// `page` clamped into 1...pageCount (nil when the document has no pages).
    package static func clamp(_ page: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(page, 1), pageCount)
    }

    /// The printed label worth showing for physical page `physical`: nil when the PDF has none (or an
    /// empty one) or the label just repeats the physical number ("7" on the 7th page).
    package static func printedLabel(physical: Int, label: String?) -> String? {
        guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let n = Int(raw), n == physical { return nil }
        return raw
    }

    /// Whether any page carries a printed label other than its physical number (`labels[i]` is the
    /// label of physical page i + 1).
    package static func hasPrintedLabels(_ labels: [String?]) -> Bool {
        labels.enumerated().contains { printedLabel(physical: $0.offset + 1, label: $0.element) != nil }
    }

    /// The physical page the reader's page field means, or nil (the field then shows the current page
    /// again). The field shows physical numbers, so a number within 1...pageCount is physical; anything
    /// else is looked up among the printed labels (case-insensitive: "iii", "S4", or "1205" in a
    /// 14-page reprint of pp. 1201–1214). A "p." / "p" / "page" prefix is allowed before a number.
    package static func resolve(_ input: String, labels: [String?], pageCount: Int) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageCount > 0, !text.isEmpty else { return nil }
        if let n = number(text), (1...pageCount).contains(n) { return n }
        let wanted = text.lowercased()
        if let i = labels.prefix(pageCount).firstIndex(where: {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }) {
            return i + 1
        }
        return nil
    }

    /// "12", "p. 12", "p12", "page 12" → 12 (digits only after the prefix).
    static func number(_ text: String) -> Int? {
        var s = Substring(text.lowercased())
        for prefix in ["page", "p.", "p"] where s.hasPrefix(prefix) { s = s.dropFirst(prefix.count); break }
        s = s.drop { $0 == " " }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), s.count <= 9 else { return nil }
        return Int(s)
    }
}

/// The reader's remembered page per paper (kv `reader.page.<paper id>`): the physical page last shown.
/// Not library state (no change notification, not in sidecars or exports). Owned by Slice C (reader).
package enum ReaderPageMemory {
    package static let prefix = "reader.page."

    package static func key(paperID: String) -> String { prefix + paperID.lowercased() }

    package static func encode(page: Int) -> String { String(max(page, 1)) }

    /// A stored value: a positive number, else nil (a damaged row is ignored).
    package static func decode(_ raw: String?) -> Int? {
        guard let raw, let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 1 else { return nil }
        return n
    }

    /// The page the reader opens at: an explicit page (a checklist chip, a citation) wins, then the
    /// remembered page, else the first; clamped to the document (a replaced PDF may be shorter).
    package static func startPage(requested: Int?, remembered: Int?, pageCount: Int) -> Int {
        ReaderPages.clamp(requested ?? remembered ?? 1, pageCount: pageCount) ?? 1
    }
}
