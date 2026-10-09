import Foundation

/// Text fingerprints that survive a relaunch (dive-dedupe §4.2): word shingles hashed with
/// FNV-1a 64 and k fixed multiply–xor seeds. Swift's `Hasher` is seeded per process, so it
/// can never be used for a signature that is stored and compared later.
package enum MinHash {
    /// Signature length of the page-1 text (4-word shingles of the first pages).
    package static let pageSize = 128
    /// Signature length of the abstract (3-word shingles).
    package static let abstractSize = 64
    /// Characters of normalized body text that go into the page-1 signature.
    package static let bodyChars = 8_000

    /// Seeds from a fixed SplitMix64 stream: the same on every launch and machine.
    package static let seeds: [UInt64] = {
        var state: UInt64 = 0x5EED_D0C5_1A7E_2026
        var out: [UInt64] = []
        out.reserveCapacity(pageSize)
        for _ in 0..<pageSize {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            out.append(z ^ (z >> 31))
        }
        return out
    }()

    /// FNV-1a 64 of the UTF-8 bytes.
    package static func fnv1a(_ s: Substring) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// k minimum hashes over the shingles; nil when there are none.
    package static func signature(_ shingles: [Substring], k: Int) -> [UInt32]? {
        guard !shingles.isEmpty, k > 0 else { return nil }
        let k = min(k, seeds.count)
        var mins = [UInt64](repeating: .max, count: k)
        for s in shingles {
            let h = fnv1a(s)
            for i in 0..<k {
                let x = (h ^ seeds[i]) &* 0x9E37_79B9_7F4A_7C15
                if x < mins[i] { mins[i] = x }
            }
        }
        return mins.map { UInt32(truncatingIfNeeded: $0 >> 32) }
    }

    /// Estimated Jaccard similarity of two signatures (positions that agree); nil when either is
    /// missing or they have different lengths.
    package static func jaccard(_ a: [UInt32]?, _ b: [UInt32]?) -> Double? {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return nil }
        var same = 0
        for i in a.indices where a[i] == b[i] { same += 1 }
        return Double(same) / Double(a.count)
    }

    /// `size`-word shingles ("w1 w2 w3"), as substrings of one space-joined string.
    package static func shingles(_ words: [String], size: Int) -> [Substring] {
        guard !words.isEmpty else { return [] }
        if words.count <= size { return [Substring(words.joined(separator: " "))] }
        var out: [Substring] = []
        out.reserveCapacity(words.count - size + 1)
        for i in 0...(words.count - size) {
            out.append(Substring(words[i..<(i + size)].joined(separator: " ")))
        }
        return out
    }

    /// Lowercased, diacritic-folded letter/digit words.
    package static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var out: [String] = []
        var word = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) { word.append(u) } else if !word.isEmpty {
                out.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { out.append(String(word)) }
        return out
    }

    /// The body words of the first pages: running header / footer lines (a line on two or more
    /// of the first three pages, a page number) removed, at most `bodyChars` characters.
    package static func bodyWords(pages: [String]) -> [String] {
        let first = Array(pages.prefix(3))
        func key(_ line: Substring) -> String {
            line.lowercased().filter { $0.isLetter }
        }
        var seen: [String: Int] = [:]
        for page in first {
            var onPage = Set<String>()
            for line in page.split(whereSeparator: \.isNewline) {
                let k = key(line)
                if k.count >= 4, onPage.insert(k).inserted { seen[k, default: 0] += 1 }
            }
        }
        let running = Set(seen.filter { $0.value >= 2 }.map(\.key))
        var out: [String] = []
        var chars = 0
        outer: for page in first {
            for line in page.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "/" }) { continue }
                if first.count > 1, running.contains(key(line)) { continue }
                for w in words(String(line)) {
                    out.append(w)
                    chars += w.count + 1
                    if chars >= bodyChars { break outer }
                }
            }
        }
        return out
    }

    /// The page-1 signature (4-word shingles of `bodyWords`); nil without text.
    package static func pageSignature(pages: [String]) -> [UInt32]? {
        let w = bodyWords(pages: pages)
        guard w.count >= 8 else { return nil }
        return signature(shingles(w, size: 4), k: pageSize)
    }

    /// The abstract signature (3-word shingles); nil for a short or missing abstract.
    package static func abstractSignature(_ abstract: String?) -> [UInt32]? {
        guard let abstract else { return nil }
        let w = words(abstract)
        guard w.count >= 12 else { return nil }
        return signature(shingles(w, size: 3), k: abstractSize)
    }

    // MARK: Storage (`paper_fingerprint.minhash`, `paper_history.minhash`)

    /// Layout v1: "PDM1", the first 16 hex digits of the file's SHA-256 as 8 bytes (zeros when
    /// unknown: the page signature is recomputed when the file changed), the page count (UInt32
    /// LE) and values, the abstract count and values.
    package static func encode(page: [UInt32]?, abstract: [UInt32]?, sha256: String? = nil) -> Data? {
        guard page != nil || abstract != nil else { return nil }
        var data = Data("PDM1".utf8)
        var sha = [UInt8](repeating: 0, count: 8)
        if let hex = sha256?.lowercased(), hex.count >= 16 {
            let chars = Array(hex.utf8.prefix(16))
            for i in 0..<8 {
                let pair = String(decoding: chars[(2 * i)...(2 * i + 1)], as: UTF8.self)
                sha[i] = UInt8(pair, radix: 16) ?? 0
            }
        }
        data.append(contentsOf: sha)
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt32(page?.count ?? 0)); page?.forEach(put)
        put(UInt32(abstract?.count ?? 0)); abstract?.forEach(put)
        return data
    }

    /// The signatures and the SHA-256 prefix they were computed from (nil when unknown or unreadable).
    package static func decode(_ data: Data?) -> (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?) {
        guard let data, data.count >= 20 else { return (nil, nil, nil) }
        let bytes = [UInt8](data)
        guard bytes[0..<4].elementsEqual(Array("PDM1".utf8)) else { return (nil, nil, nil) }
        let shaBytes = bytes[4..<12]
        let sha = shaBytes.allSatisfy { $0 == 0 } ? nil : shaBytes.map { String(format: "%02x", $0) }.joined()
        var i = 12
        func next() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            i += 4
            return v
        }
        func list() -> [UInt32]? {
            guard let n = next(), n > 0, n <= 4_096 else { return nil }
            var out: [UInt32] = []
            out.reserveCapacity(Int(n))
            for _ in 0..<n { guard let v = next() else { return nil }; out.append(v) }
            return out
        }
        let page = list()
        let abstract = list()
        return (page, abstract, sha)
    }
}
