import Foundation

/// Human-readable, filesystem-safe names for library folders and files (§5 命名).
/// Pure functions: the same metadata always yields the same name, so refiling is idempotent.
package enum FileNamer {
    package static let maxTitleCharacters = 80
    /// Whole folder name budget in UTF-8 bytes (APFS allows 255; PDF name adds ".pdf").
    package static let maxNameBytes = 120
    /// Budget for sanitized original file names in the inbox (keeps long preprint names intact).
    package static let maxFileNameBytes = 200
    package static let fallbackName = "Untitled"

    /// `YYYY_Lastname_Title-Words`; missing parts are omitted, all missing → "Untitled".
    package static func folderName(year: Int?, firstAuthor: String?, title: String?) -> String {
        var parts: [String] = []
        if let year, (1000...9999).contains(year) { parts.append(String(year)) }
        if let author = firstAuthor.map({ namePart(lastName(from: $0)) }), !author.isEmpty { parts.append(author) }
        if let words = title.map(titlePart), !words.isEmpty { parts.append(words) }
        let name = trimEdges(truncate(parts.joined(separator: "_"), maxBytes: maxNameBytes))
        return name.isEmpty ? fallbackName : name
    }

    /// PDF file name inside a paper folder (§5: folder name + ".pdf").
    package static func pdfName(forFolder folder: String) -> String { folder + ".pdf" }

    /// Family name of one author string. Handles "Given Family", "Family, Given",
    /// PubMed-style "Family AB", particles ("Jan van der Berg" → "van der Berg"),
    /// suffixes ("Jr.") and trailing affiliation markers ("Li Wang1,2*").
    package static func lastName(from author: String) -> String {
        var s = author.precomposedStringWithCanonicalMapping
        s = s.replacingOccurrences(of: #"[\d*†‡§¶#]+(\s*,\s*[\d*†‡§¶#]+)*\s*$"#, with: "", options: .regularExpression)
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !s.isEmpty else { return "" }

        let commaParts = s.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if commaParts.count == 2 {
            if isSuffix(commaParts[1]) || commaParts[1].isEmpty {
                s = commaParts[0]                                  // "John Smith, Jr." → "John Smith"
            } else if !commaParts[0].isEmpty {
                return commaParts[0]                               // "van der Berg, Jan"
            } else {
                s = commaParts[1]
            }
        }

        var tokens = s.split(separator: " ").map(String.init)
        while tokens.count > 1, let last = tokens.last, isSuffix(last) { tokens.removeLast() }
        guard tokens.count > 1, let last = tokens.last else { return tokens.first ?? "" }

        // "Kriegstein AR" / "Wang L": family first, trailing initials (skipped for ALL-CAPS names).
        if isInitials(last), !isInitials(tokens[0]), tokens[0] != tokens[0].uppercased() {
            var end = tokens.count
            while end > 1, isInitials(tokens[end - 1]) { end -= 1 }
            return tokens[..<end].joined(separator: " ")
        }

        var start = tokens.count - 1
        while start > 1, isParticle(tokens[start - 1]) { start -= 1 }   // never consume the given name
        return tokens[start...].joined(separator: " ")
    }

    /// `base`, or `base_2`, `base_3`… — the first not in `existing` (case-insensitive, like APFS).
    /// Stays within `maxNameBytes` by shortening the base.
    package static func uniqueName(_ base: String, existing: Set<String>) -> String {
        let taken = Set(existing.map(collisionKey))
        if !taken.contains(collisionKey(base)) { return base }
        var n = 2
        while true {
            let suffix = "_\(n)"
            let stem = base.utf8.count + suffix.utf8.count <= maxNameBytes
                ? base : trimEdges(truncate(base, maxBytes: maxNameBytes - suffix.utf8.count))
            let candidate = stem + suffix
            if !taken.contains(collisionKey(candidate)) { return candidate }
            n += 1
        }
    }

    /// `_Inbox/<sha8>` folder for a committed but not yet filed paper.
    /// `originalName` is only used if `sha` carries no usable hex digits.
    package static func inboxFolderName(sha: String, originalName: String) -> String {
        let hex = sha.lowercased().filter { $0.isASCII && $0.isHexDigit }
        if hex.count >= 8 { return String(hex.prefix(8)) }
        let stem = (originalName as NSString).deletingPathExtension
        return trimEdges(truncate(sanitizedFileName(stem), maxBytes: maxNameBytes))
    }

    /// `<sanitized original name>.pdf` for the inbox copy.
    package static func inboxPDFName(originalName: String) -> String {
        let name = sanitizedFileName(originalName)
        return name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf"
    }

    /// A safe single path component: forbidden, control and bidi characters → "-",
    /// NFC, no leading dots, whitespace collapsed, ≤ 200 UTF-8 bytes keeping the extension.
    package static func sanitizedFileName(_ name: String) -> String {
        var s = replacingForbidden(name.precomposedStringWithCanonicalMapping)
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = collapsing(s, "-")
        s = trimEdges(s)
        guard !s.isEmpty else { return fallbackName }
        guard s.utf8.count > maxFileNameBytes else { return s }
        let ext = (s as NSString).pathExtension
        if !ext.isEmpty, ext.utf8.count <= 10 {
            let stem = trimEdges(truncate((s as NSString).deletingPathExtension,
                                          maxBytes: maxFileNameBytes - ext.utf8.count - 1))
            return (stem.isEmpty ? fallbackName : stem) + "." + ext
        }
        let cut = trimEdges(truncate(s, maxBytes: maxFileNameBytes))
        return cut.isEmpty ? fallbackName : cut
    }

    // MARK: - Parts

    /// Author part: sanitized, spaces → "-" ("van der Berg" → "van-der-Berg").
    private static func namePart(_ s: String) -> String {
        let cleaned = replacingForbidden(s.precomposedStringWithCanonicalMapping)
        let joined = cleaned.split(whereSeparator: isWordBreak).joined(separator: "-")
        return trimEdges(collapsing(collapsing(joined, "-"), "_"))
    }

    /// Title words joined by "-", cut at a word boundary to ≤ 80 characters.
    private static func titlePart(_ title: String) -> String {
        let cleaned = replacingForbidden(title.precomposedStringWithCanonicalMapping)
        let words = cleaned.split(whereSeparator: isWordBreak)
            .map { word -> String in
                var w = Substring(word)
                while let last = w.last, last == "," || last == ";" { w = w.dropLast() }
                return trimEdges(collapsing(collapsing(String(w), "-"), "_"))
            }
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "" }

        var out = first.count > maxTitleCharacters ? String(first.prefix(maxTitleCharacters)) : first
        for word in words.dropFirst() {
            guard out.count + 1 + word.count <= maxTitleCharacters else { break }
            out += "-" + word
        }
        return trimEdges(out)
    }

    // MARK: - Character rules

    private static let forbiddenASCII: Set<Unicode.Scalar> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]

    private static func isForbidden(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F: return true                        // C0/C1 controls incl. NUL
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true   // bidi controls
        case 0x2028, 0x2029, 0xFEFF: return true                          // line/paragraph separators, BOM
        default: return forbiddenASCII.contains(s)
        }
    }

    private static func replacingForbidden(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            out.append(isForbidden(scalar) ? "-" : scalar)
        }
        return String(out)
    }

    private static func isWordBreak(_ c: Character) -> Bool {
        c.isWhitespace || c == "\u{200B}"
    }

    /// Collapses runs of `ch` into one.
    private static func collapsing(_ s: String, _ ch: Character) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var previous: Character?
        for c in s {
            if c == ch, previous == ch { continue }
            out.append(c)
            previous = c
        }
        return out
    }

    /// No leading dots (hidden files, ".."), no dangling separators at either end.
    private static func trimEdges(_ s: String) -> String {
        let edge: Set<Character> = [".", "-", "_", " "]
        var sub = Substring(s)
        while let c = sub.first, edge.contains(c) { sub = sub.dropFirst() }
        while let c = sub.last, edge.contains(c) { sub = sub.dropLast() }
        return String(sub)
    }

    /// Longest prefix within `maxBytes` UTF-8 bytes, cut between grapheme clusters
    /// (so never inside a scalar); falls back to scalar boundaries for a single huge cluster.
    private static func truncate(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        guard maxBytes > 0 else { return "" }
        var out = ""
        var bytes = 0
        for ch in s {
            let n = ch.utf8.count
            if bytes + n > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        if out.isEmpty {
            var scalars = String.UnicodeScalarView()
            for scalar in s.unicodeScalars {
                let n = UTF8.width(scalar)
                if bytes + n > maxBytes { break }
                scalars.append(scalar)
                bytes += n
            }
            out = String(scalars)
        }
        return out
    }

    private static func collisionKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Author name rules

    private static let lowercaseParticles: Set<String> = [
        "van", "von", "der", "den", "de", "del", "della", "dei", "degli", "di", "da", "das", "dos", "du",
        "la", "le", "ter", "ten", "zu", "zur", "af", "av", "bin", "ibn", "al", "el", "van't", "d'", "y",
    ]
    /// Capitalized forms accepted too ("Robert De Niro"); "Le"/"La" excluded — common given names.
    private static let capitalizedParticles: Set<String> = [
        "Van", "Von", "Der", "Den", "De", "Del", "Della", "Di", "Da", "Das", "Dos", "Du", "Ter", "Ten",
    ]

    private static func isParticle(_ token: String) -> Bool {
        lowercaseParticles.contains(token) || capitalizedParticles.contains(token)
    }

    private static func isSuffix(_ token: String) -> Bool {
        let t = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",. "))
        return ["jr", "sr", "ii", "iii", "iv", "phd", "ph.d", "md", "m.d"].contains(t)
    }

    private static func isInitials(_ token: String) -> Bool {
        token.range(of: #"^(\p{Lu}\.?){1,3}$"#, options: .regularExpression) != nil
    }
}
