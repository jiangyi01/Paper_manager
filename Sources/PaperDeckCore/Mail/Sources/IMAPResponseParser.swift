import Foundation

// IMAP4rev1 (RFC 3501) server responses — pure framing and parsing, no I/O.
//
// Two stages:
//  1. `IMAPFramer` cuts the byte stream into complete responses. A response is one
//     line, except that a line ending in a literal marker `{n}` (or `~{n}`) is followed
//     by exactly n raw bytes and then continues on the next line (multi-line FETCH).
//  2. `IMAPResponseParser.parse` turns one framed response into an `IMAPResponse`.
//
// Error details never contain message bytes (headers/bodies are private).

/// A syntactic value inside a data response.
package indirect enum IMAPValue: Sendable, Equatable {
    case atom(String)          // atoms, numbers, NIL, flags, section names ("BODY[HEADER.FIELDS (FROM)]<0>")
    case quoted(String)
    case literal(Data)
    case list([IMAPValue])

    package var isNil: Bool {
        if case .atom(let a) = self { return a.uppercased() == "NIL" }
        return false
    }

    /// Atom (non-NIL), quoted string or literal (UTF-8, lossy).
    package var string: String? {
        switch self {
        case .atom(let a): return a.uppercased() == "NIL" ? nil : a
        case .quoted(let q): return q
        case .literal(let d): return String(decoding: d, as: UTF8.self)
        case .list: return nil
        }
    }

    /// Raw bytes of a literal or quoted string.
    package var data: Data? {
        switch self {
        case .literal(let d): return d
        case .quoted(let q): return Data(q.utf8)
        default: return nil
        }
    }

    package var number: Int? {
        if case .atom(let a) = self { return Int(a) }
        return nil
    }

    package var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

package enum IMAPStatus: String, Sendable, Equatable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

/// `[NAME args]` of a status response, e.g. UIDVALIDITY 3857529045, READ-ONLY, AUTHENTICATIONFAILED.
package struct IMAPResponseCode: Sendable, Equatable {
    package var name: String            // uppercased
    package var arguments: String       // raw text after the name ("" when none)
    package init(name: String, arguments: String = "") { self.name = name; self.arguments = arguments }
    package var number: UInt32? { UInt32(arguments.trimmingCharacters(in: .whitespaces)) }
}

/// Parsed attributes of one `* n FETCH (…)` response.
package struct IMAPFetchData: Sendable, Equatable {
    package var sequence: Int
    package var uid: UInt32?
    package var size: Int?
    package var internalDate: Date?
    package var flags: [String]?
    /// Body sections by normalized spec ("" = BODY[], "HEADER.FIELDS (FROM …)", "HEADER", "TEXT").
    /// NIL sections are absent.
    package var sections: [String: Data]

    package init(sequence: Int, uid: UInt32? = nil, size: Int? = nil, internalDate: Date? = nil,
                 flags: [String]? = nil, sections: [String: Data] = [:]) {
        self.sequence = sequence; self.uid = uid; self.size = size; self.internalDate = internalDate
        self.flags = flags; self.sections = sections
    }

    /// The whole message (BODY[] / RFC822).
    package var body: Data? { sections[""] }
    /// The HEADER / HEADER.FIELDS section.
    package var headerFields: Data? {
        sections.first { $0.key.hasPrefix("HEADER") }?.value
    }
    /// Bytes of all section literals (for redacted traces).
    package var sectionBytes: Int { sections.values.reduce(0) { $0 + $1.count } }
}

package enum IMAPResponse: Sendable, Equatable {
    case tagged(tag: String, status: IMAPStatus, code: IMAPResponseCode?, text: String)
    case status(IMAPStatus, code: IMAPResponseCode?, text: String)     // untagged OK/NO/BAD/BYE/PREAUTH
    case continuation(String)
    case capability([String])
    case exists(Int)
    case recent(Int)
    case expunge(Int)
    case flags([String])
    case search([UInt32])
    case fetch(IMAPFetchData)
    case other(name: String, values: [IMAPValue])
}

package enum IMAPParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)             // what was expected — never the offending bytes
    case literalTooLarge(Int)
    case lineTooLong

    package var description: String {
        switch self {
        case .malformed(let s): "malformed IMAP response (\(s))"
        case .literalTooLarge(let n): "IMAP literal too large (\(n) bytes)"
        case .lineTooLong: "IMAP response line too long"
        }
    }
}

/// One framed response: text segments separated by literals. Every segment but the
/// last ends with its literal marker (`{n}`); line terminators are stripped.
package struct IMAPRawResponse: Sendable, Equatable {
    package var segments: [[UInt8]]
    package var literals: [Data]
    package init(segments: [[UInt8]], literals: [Data]) { self.segments = segments; self.literals = literals }

    package var firstLine: String { String(decoding: segments.first ?? [], as: UTF8.self) }
}

// MARK: - Framing

/// Accumulates server bytes and yields complete responses (literal-aware).
package struct IMAPFramer: Sendable {
    /// Largest literal accepted (memory guard against a hostile server).
    package var maxLiteral: Int
    /// Largest text line accepted.
    package var maxLine: Int
    /// Oversized literals are dropped (delivered as empty) instead of failing the stream,
    /// so one pathological message can't wedge a sync on the same page forever.
    package var discardOversizedLiterals = false
    /// Literals dropped so far (see `discardOversizedLiterals`).
    package private(set) var discardedLiterals = 0

    private var buffer: [UInt8] = []
    private var segmentStart = 0
    private var scanFrom = 0
    private var segments: [Range<Int>] = []
    private var literals: [Range<Int>] = []
    private var pendingLiteral: (start: Int, count: Int, discard: Bool)?

    package init(maxLiteral: Int = 1 << 20, maxLine: Int = 1 << 20) {
        self.maxLiteral = maxLiteral; self.maxLine = maxLine
    }

    package var bufferedBytes: Int { buffer.count }

    package mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    package mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete response, or nil when more bytes are needed.
    package mutating func next() throws -> IMAPRawResponse? {
        while true {
            if var lit = pendingLiteral {
                if lit.discard {
                    let take = min(buffer.count - lit.start, lit.count)
                    buffer.removeSubrange(lit.start..<(lit.start + take))
                    lit.count -= take
                    guard lit.count == 0 else { pendingLiteral = lit; return nil }
                    literals.append(lit.start..<lit.start)
                    discardedLiterals += 1
                    segmentStart = lit.start
                } else {
                    guard buffer.count - lit.start >= lit.count else { return nil }
                    literals.append(lit.start..<(lit.start + lit.count))
                    segmentStart = lit.start + lit.count
                }
                scanFrom = segmentStart
                pendingLiteral = nil
            }
            guard let lf = buffer[scanFrom...].firstIndex(of: 0x0A) else {
                scanFrom = buffer.count
                if buffer.count - segmentStart > maxLine { throw IMAPParseError.lineTooLong }
                return nil
            }
            var end = lf
            if end > segmentStart, buffer[end - 1] == 0x0D { end -= 1 }
            if end - segmentStart > maxLine { throw IMAPParseError.lineTooLong }
            let segment = segmentStart..<end
            if let n = Self.trailingLiteralCount(buffer, segment) {
                guard n <= maxLiteral || discardOversizedLiterals else { throw IMAPParseError.literalTooLarge(n) }
                segments.append(segment)
                pendingLiteral = (lf + 1, n, n > maxLiteral)
                continue
            }
            segments.append(segment)
            let raw = IMAPRawResponse(segments: segments.map { Array(buffer[$0]) },
                                      literals: literals.map { Data(buffer[$0]) })
            buffer.removeSubrange(0...lf)
            segmentStart = 0; scanFrom = 0
            segments.removeAll(keepingCapacity: true)
            literals.removeAll(keepingCapacity: true)
            return raw
        }
    }

    /// n when the segment ends with `{n}` or `~{n}` (1…10 digits).
    static func trailingLiteralCount(_ bytes: [UInt8], _ r: Range<Int>) -> Int? {
        literalMarker(bytes, r)?.count
    }

    /// Byte count and index of the `{` of a literal marker ending the range.
    static func literalMarker(_ bytes: [UInt8], _ r: Range<Int>) -> (count: Int, brace: Int)? {
        guard r.count >= 3, bytes[r.upperBound - 1] == UInt8(ascii: "}") else { return nil }
        var i = r.upperBound - 2
        var digits = 0
        while i >= r.lowerBound, bytes[i] >= 0x30, bytes[i] <= 0x39 { i -= 1; digits += 1 }
        guard digits >= 1, digits <= 10, i >= r.lowerBound, bytes[i] == UInt8(ascii: "{") else { return nil }
        var n = 0
        for j in (i + 1)..<(r.upperBound - 1) { n = n * 10 + Int(bytes[j] - 0x30) }
        return (n, i)
    }
}

// MARK: - Parsing

package enum IMAPResponseParser {

    /// Parses one framed response.
    package static func parse(_ raw: IMAPRawResponse) throws -> IMAPResponse {
        var s = Scanner(raw)
        guard let first = s.peek() else { throw IMAPParseError.malformed("empty response") }
        if first == UInt8(ascii: "+") {
            s.advance()
            s.skipSpaces()
            return .continuation(s.restOfSegment())
        }
        if first == UInt8(ascii: "*") {
            s.advance()
            guard s.consume(UInt8(ascii: " ")) else { throw IMAPParseError.malformed("untagged without space") }
            return try parseUntagged(&s)
        }
        let tag = s.readWord()
        guard !tag.isEmpty, s.consume(UInt8(ascii: " ")) else { throw IMAPParseError.malformed("tag") }
        let word = s.readWord().uppercased()
        guard let status = IMAPStatus(rawValue: word), status != .preauth else {
            throw IMAPParseError.malformed("tagged status")
        }
        let (code, text) = try parseRespText(&s)
        return .tagged(tag: tag, status: status, code: code, text: text)
    }

    private static func parseUntagged(_ s: inout Scanner) throws -> IMAPResponse {
        let word = s.readWord()
        if let n = Int(word) {
            guard s.consume(UInt8(ascii: " ")) else { throw IMAPParseError.malformed("message data") }
            let keyword = s.readWord().uppercased()
            switch keyword {
            case "EXISTS": return .exists(n)
            case "RECENT": return .recent(n)
            case "EXPUNGE": return .expunge(n)
            case "FETCH":
                s.skipSpaces()
                let value = try s.readValue()
                guard case .list(let items) = value else { throw IMAPParseError.malformed("FETCH list") }
                return .fetch(try fetchData(sequence: n, items))
            default:
                return .other(name: keyword, values: [.atom(word)] + s.readValuesTolerantly())
            }
        }
        let keyword = word.uppercased()
        if let status = IMAPStatus(rawValue: keyword) {
            let (code, text) = try parseRespText(&s)
            return .status(status, code: code, text: text)
        }
        switch keyword {
        case "CAPABILITY":
            return .capability(s.restOfSegment().split(separator: " ").map(String.init))
        case "FLAGS":
            s.skipSpaces()
            let v = try s.readValue()
            return .flags((v.list ?? []).compactMap(\.string))
        case "SEARCH":
            var uids: [UInt32] = []
            for v in s.readValuesTolerantly() {
                if case .atom(let a) = v, let n = UInt32(a) { uids.append(n) }   // skips "(MODSEQ n)"
            }
            return .search(uids)
        default:
            return .other(name: keyword, values: s.readValuesTolerantly())
        }
    }

    /// `SP ["[" code "]" SP] text` after a status word.
    private static func parseRespText(_ s: inout Scanner) throws -> (IMAPResponseCode?, String) {
        s.skipSpaces()
        var code: IMAPResponseCode?
        if s.peek() == UInt8(ascii: "[") {
            guard let inner = s.readBracketed() else { throw IMAPParseError.malformed("response code") }
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            if let sp = trimmed.firstIndex(of: " ") {
                code = IMAPResponseCode(name: trimmed[..<sp].uppercased(),
                                        arguments: String(trimmed[trimmed.index(after: sp)...]))
            } else {
                code = IMAPResponseCode(name: trimmed.uppercased())
            }
            s.skipSpaces()
        }
        return (code, s.restOfSegment())
    }

    private static func fetchData(sequence: Int, _ items: [IMAPValue]) throws -> IMAPFetchData {
        guard items.count % 2 == 0 else { throw IMAPParseError.malformed("FETCH attribute pairs") }
        var out = IMAPFetchData(sequence: sequence)
        var i = 0
        while i < items.count {
            guard case .atom(let rawName) = items[i] else { throw IMAPParseError.malformed("FETCH attribute name") }
            let value = items[i + 1]
            i += 2
            let name = rawName.uppercased()
            switch name {
            case "UID":
                guard let n = value.number, let u = UInt32(exactly: n) else { throw IMAPParseError.malformed("UID") }
                out.uid = u
            case "RFC822.SIZE":
                out.size = value.number
            case "INTERNALDATE":
                out.internalDate = value.string.flatMap(parseInternalDate)
            case "FLAGS":
                out.flags = (value.list ?? []).compactMap(\.string)
            case "RFC822":
                if let d = value.data { out.sections[""] = d }
            case "RFC822.HEADER":
                if let d = value.data { out.sections["HEADER"] = d }
            case "RFC822.TEXT":
                if let d = value.data { out.sections["TEXT"] = d }
            default:
                if (name.hasPrefix("BODY[") || name.hasPrefix("BINARY[")),
                   let open = name.firstIndex(of: "["), let close = name.lastIndex(of: "]"), open < close {
                    let spec = normalizeSection(String(name[name.index(after: open)..<close]))
                    if let d = value.data { out.sections[spec] = d }
                }
                // ENVELOPE, BODYSTRUCTURE, MODSEQ, X-GM-*… are ignored.
            }
        }
        return out
    }

    /// Uppercased with runs of whitespace collapsed ("HEADER.FIELDS (FROM SUBJECT)").
    package static func normalizeSection(_ s: String) -> String {
        s.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    // MARK: Dates

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// INTERNALDATE `"17-Jul-1996 02:44:25 -0700"` (day may be space-padded).
    package static func parseInternalDate(_ s: String) -> Date? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 3 else { return nil }
        let d = parts[0].split(separator: "-")
        let t = parts[1].split(separator: ":")
        let z = parts[2]
        guard d.count == 3, t.count == 3, let day = Int(d[0]), let year = Int(d[2]),
              let month = months.firstIndex(where: { $0.caseInsensitiveCompare(d[1]) == .orderedSame }),
              let hh = Int(t[0]), let mm = Int(t[1]), let ss = Int(t[2]),
              z.count == 5, let sign = z.first, sign == "+" || sign == "-",
              let zh = Int(z.dropFirst().prefix(2)), let zm = Int(z.suffix(2)) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month + 1; comps.day = day
        comps.hour = hh; comps.minute = mm; comps.second = ss
        guard let local = utc.date(from: comps) else { return nil }
        let offset = TimeInterval((zh * 60 + zm) * 60) * (sign == "-" ? -1 : 1)
        return local.addingTimeInterval(-offset)
    }

    /// SEARCH date `16-Sep-2026` (UTC calendar day of `date`).
    package static func searchDate(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return "\(c.day ?? 1)-\(months[(c.month ?? 1) - 1])-\(c.year ?? 1970)"
    }

    // MARK: Command-side helpers

    /// A quoted string (`"` and `\` escaped), or nil when `s` needs a literal
    /// (CR, LF, NUL or non-ASCII bytes).
    package static func quoted(_ s: String) -> String? {
        var out = "\""
        for b in s.utf8 {
            if b == 0 || b == 0x0D || b == 0x0A || b >= 0x80 { return nil }
            if b == UInt8(ascii: "\"") || b == UInt8(ascii: "\\") { out.append("\\") }
            out.unicodeScalars.append(Unicode.Scalar(b))
        }
        return out + "\""
    }

    /// Compact UID set: [1,2,3,5,7,8] → "1:3,5,7:8".
    package static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        guard var start = sorted.first else { return "" }
        var parts: [String] = []
        var prev = start
        for u in sorted.dropFirst() {
            if u == prev + 1 { prev = u; continue }
            parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
            start = u; prev = u
        }
        parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
        return parts.joined(separator: ",")
    }

    /// Modified UTF-7 mailbox name (RFC 3501 §5.1.3): "台北" → "&U,BTFw-", "&" → "&-".
    package static func encodeMailboxName(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for u in pending { bytes.append(UInt8(u >> 8)); bytes.append(UInt8(u & 0xFF)) }
            let b64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            out += "&" + b64 + "-"
            pending.removeAll()
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(Character(scalar))
            } else {
                pending.append(contentsOf: String(Character(scalar)).utf16)
            }
        }
        flush()
        return out
    }

    /// Inverse of `encodeMailboxName`; nil when malformed.
    package static func decodeMailboxName(_ s: String) -> String? {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&" else { out.append(c); i = s.index(after: i); continue }
            guard let dash = s[i...].firstIndex(of: "-") else { return nil }
            let chunk = s[s.index(after: i)..<dash]
            if chunk.isEmpty {
                out += "&"
            } else {
                var b64 = chunk.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                guard let data = Data(base64Encoded: b64), data.count % 2 == 0 else { return nil }
                var units: [UInt16] = []
                var j = data.startIndex
                while j < data.endIndex {
                    units.append(UInt16(data[j]) << 8 | UInt16(data[data.index(after: j)]))
                    j = data.index(j, offsetBy: 2)
                }
                out += String(decoding: units, as: UTF16.self)
            }
            i = s.index(after: dash)
        }
        return out
    }
}

// MARK: - Scanner

/// Cursor over a framed response; literals are consumed where a segment ends in `{n}`.
private struct Scanner {
    let raw: IMAPRawResponse
    var seg = 0
    var pos = 0

    init(_ raw: IMAPRawResponse) { self.raw = raw }

    private var bytes: [UInt8] { raw.segments[seg] }

    func peek() -> UInt8? {
        guard seg < raw.segments.count, pos < raw.segments[seg].count else { return nil }
        return raw.segments[seg][pos]
    }

    mutating func advance() { pos += 1 }

    mutating func consume(_ b: UInt8) -> Bool {
        guard peek() == b else { return false }
        pos += 1
        return true
    }

    mutating func skipSpaces() {
        while peek() == UInt8(ascii: " ") { pos += 1 }
    }

    /// Bytes up to the next space (or end of segment).
    mutating func readWord() -> String {
        let start = pos
        while let b = peek(), b != UInt8(ascii: " ") { pos += 1 }
        return String(decoding: raw.segments[seg][start..<pos], as: UTF8.self)
    }

    /// Rest of the current segment as text (resp-text is never tokenized).
    mutating func restOfSegment() -> String {
        guard seg < raw.segments.count else { return "" }
        let s = String(decoding: raw.segments[seg][min(pos, raw.segments[seg].count)...], as: UTF8.self)
        pos = raw.segments[seg].count
        return s
    }

    /// Content between a `[` at the cursor and its matching `]`.
    mutating func readBracketed() -> String? {
        guard peek() == UInt8(ascii: "[") else { return nil }
        var depth = 0
        let start = pos + 1
        while let b = peek() {
            if b == UInt8(ascii: "[") { depth += 1 }
            if b == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 {
                    let inner = String(decoding: bytes[start..<pos], as: UTF8.self)
                    pos += 1
                    return inner
                }
            }
            pos += 1
        }
        return nil
    }

    /// True when the rest of the current segment is exactly a literal marker.
    private func atLiteralMarker() -> Bool {
        guard seg < raw.segments.count - 1 else { return false }
        var i = pos
        if i < bytes.count, bytes[i] == UInt8(ascii: "~") { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return false }
        return IMAPFramer.literalMarker(bytes, i..<bytes.count)?.brace == i
    }

    mutating func readValue() throws -> IMAPValue {
        skipSpaces()
        guard let b = peek() else { throw IMAPParseError.malformed("value expected") }
        if atLiteralMarker() {
            let lit = raw.literals[seg]
            seg += 1
            pos = 0
            return .literal(lit)
        }
        switch b {
        case UInt8(ascii: "("):
            pos += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let c = peek() else { throw IMAPParseError.malformed("unterminated list") }
                if c == UInt8(ascii: ")") { pos += 1; return .list(items) }
                items.append(try readValue())
            }
        case UInt8(ascii: "\""):
            pos += 1
            var out: [UInt8] = []
            while let c = peek() {
                pos += 1
                if c == UInt8(ascii: "\\") {
                    guard let e = peek() else { break }
                    out.append(e); pos += 1
                    continue
                }
                if c == UInt8(ascii: "\"") { return .quoted(String(decoding: out, as: UTF8.self)) }
                out.append(c)
            }
            throw IMAPParseError.malformed("unterminated quoted string")
        case UInt8(ascii: ")"):
            throw IMAPParseError.malformed("unexpected )")
        default:
            return .atom(readAtom())
        }
    }

    /// Atom characters; `[…]` (section specs, response codes) is taken whole, so
    /// `BODY[HEADER.FIELDS (FROM SUBJECT)]<0>` is one atom.
    private mutating func readAtom() -> String {
        let start = pos
        var depth = 0
        while let c = peek() {
            if depth == 0, c == UInt8(ascii: " ") || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")
                || c == UInt8(ascii: "\"") { break }
            if c == UInt8(ascii: "[") { depth += 1 }
            if c == UInt8(ascii: "]") { depth = max(0, depth - 1) }
            pos += 1
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    /// Values until the end of the response; stops quietly at anything unparseable.
    mutating func readValuesTolerantly() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            guard peek() != nil else { return out }
            guard let v = try? readValue() else { return out }
            out.append(v)
        }
    }
}
