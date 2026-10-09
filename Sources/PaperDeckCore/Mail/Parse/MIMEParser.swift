import CryptoKit
import Foundation

/// RFC 5322 / 2045–2047 / 2231 message parser shared by the folder, IMAP and manual `.eml`
/// sources (MAIL_DESIGN Part B §4 "MIME parser scope").
///
/// Pure and synchronous — callers run it on `BlockingIO`. Mail is untrusted input: structure is
/// bounded (`maxDepth`, `maxParts`), attachments over the cap keep only their size, and nothing
/// is logged. `MailHeader.ref` is left empty; the transport sets it.
package enum MIMEParser {

    package enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case notAMessage

        package var description: String {
            switch self {
            case .empty: return "empty message"
            case .notAMessage: return "no RFC 5322 header fields"
            }
        }
    }

    /// Nesting limit for multipart / message/rfc822 (hostile mail can nest thousands deep).
    package static let maxDepth = 16
    /// Leaf parts beyond this are ignored.
    package static let maxParts = 500

    /// Raw header field with its value unfolded (not decoded).
    package struct HeaderField: Sendable, Equatable {
        package var name: String             // lowercased
        package var value: String
    }

    /// Header names copied into `MailContent.headers` (address/subject values RFC 2047-decoded).
    package static let keptHeaders: [String] = [
        "message-id", "date", "from", "sender", "reply-to", "to", "cc", "subject", "in-reply-to", "references",
        "list-id", "list-unsubscribe", "list-post", "authentication-results", "arc-authentication-results",
        "received-spf", "return-path", "auto-submitted", "precedence", "content-type", "x-mailer", "user-agent",
        "thread-topic", "x-ms-has-attach", "x-forwarded-to", "x-original-from",
    ]
    private static let decodedHeaders: Set<String> = ["from", "sender", "reply-to", "to", "cc", "subject", "thread-topic", "x-original-from"]

    // MARK: - Entry points

    /// Full parse: headers, decoded text/plain + text/html, attachments (bytes kept up to
    /// `maxAttachmentBytes`; larger ones keep `sizeBytes` with `data == nil`).
    /// Forwarded `message/rfc822` parts are flattened into the text under a
    /// "---------- Forwarded message ---------" block; their attachments are kept.
    package static func parse(_ data: Data, maxAttachmentBytes: Int) throws -> MailContent {
        guard !data.isEmpty else { throw ParseError.empty }
        let bytes = [UInt8](data)
        let (fields, bodyStart) = headerFields(bytes, 0..<bytes.count)
        guard !fields.isEmpty else { throw ParseError.notAMessage }

        var ctx = Context(maxAttachmentBytes: max(0, maxAttachmentBytes))
        let flat = parseEntity(bytes, fields: fields, body: bodyStart..<bytes.count, depth: 0,
                               defaultType: "text/plain", inRelated: false, ctx: &ctx)

        var header = makeHeader(fields, size: data.count)
        header.hasAttachments = ctx.attachments.contains { !$0.isInline }
        return MailContent(header: header, plainText: flat.plain, html: flat.html,
                           attachments: ctx.attachments, headers: keptHeaderValues(fields))
    }

    /// Phase-1 parse: reads only up to the first blank line.
    package static func parseHeaders(_ data: Data) throws -> MailHeader {
        guard !data.isEmpty else { throw ParseError.empty }
        let bytes = [UInt8](data)
        let end = headerEnd(bytes, 0..<bytes.count)
        let (fields, _) = headerFields(bytes, 0..<end.bodyStart)
        guard !fields.isEmpty else { throw ParseError.notAMessage }
        var header = makeHeader(fields, size: data.count)
        if let flag = field("x-ms-has-attach", in: fields)?.lowercased() {
            header.hasAttachments = flag == "yes"
        } else {
            let type = parseParameters(field("content-type", in: fields) ?? "text/plain").value.lowercased()
            if type == "multipart/mixed" { header.hasAttachments = true }
            else if type.hasPrefix("text/") || type == "multipart/alternative" { header.hasAttachments = false }
        }
        return header
    }

    /// DMARC/DKIM verdict from an `Authentication-Results` header (the top one is added by the
    /// receiving server). DMARC decides when present, then Microsoft `compauth`, then DKIM/SPF.
    package static func authState(_ authResults: String?) -> MailAuthState {
        guard let a = authResults?.lowercased(), !a.isEmpty else { return .unknown }
        if a.range(of: #"\bdmarc=pass\b"#, options: .regularExpression) != nil { return .pass }
        if a.range(of: #"\bdmarc=fail\b"#, options: .regularExpression) != nil { return .fail }
        if a.range(of: #"\bcompauth=pass\b"#, options: .regularExpression) != nil { return .pass }
        if a.range(of: #"\bcompauth=fail\b"#, options: .regularExpression) != nil { return .fail }
        if a.range(of: #"\bdkim=pass\b"#, options: .regularExpression) != nil { return .pass }
        if a.range(of: #"\b(dkim|spf)=fail\b"#, options: .regularExpression) != nil { return .fail }
        return .unknown
    }

    // MARK: - Header construction

    private static func makeHeader(_ fields: [HeaderField], size: Int) -> MailHeader {
        let from = field("from", in: fields).flatMap { parseAddressList($0).first }
        let sender = field("sender", in: fields).flatMap { parseAddressList($0).first }
        let subject = decodeEncodedWords(field("subject", in: fields) ?? "")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let dateRaw = field("date", in: fields) ?? ""
        let fromAddress = from?.address ?? sender?.address ?? ""
        let messageID = normalizeMessageID(field("message-id", in: fields))
            ?? fallbackMessageID(from: fromAddress, date: dateRaw, subject: subject)

        return MailHeader(
            ref: "",
            internetMessageID: messageID,
            fromAddress: fromAddress,
            fromName: from?.name,
            senderAddress: sender.flatMap { $0.address != fromAddress ? $0.address : nil },
            subject: String(subject.prefix(998)),
            receivedAt: receivedDate(fields: fields, dateRaw: dateRaw),
            sizeBytes: size,
            hasAttachments: nil,
            authResults: field("authentication-results", in: fields)
        )
    }

    /// The Date header, unless it disagrees by more than a day with the topmost Received
    /// timestamp (added by the receiving server); then the Received time wins. Falls back to now.
    private static func receivedDate(fields: [HeaderField], dateRaw: String) -> Date {
        let date = parseDate(dateRaw)
        let received = fields.first(where: { $0.name == "received" }).flatMap { f -> Date? in
            guard let semi = f.value.lastIndex(of: ";") else { return nil }
            return parseDate(String(f.value[f.value.index(after: semi)...]))
        }
        switch (date, received) {
        case let (d?, r?): return abs(d.timeIntervalSince(r)) > 86_400 ? r : d
        case let (d?, nil): return d
        case let (nil, r?): return r
        default: return Date()
        }
    }

    private static func keptHeaderValues(_ fields: [HeaderField]) -> [String: String] {
        var out: [String: String] = [:]
        for name in keptHeaders {
            guard let v = field(name, in: fields) else { continue }
            out[name] = decodedHeaders.contains(name) ? decodeEncodedWords(v) : v
        }
        return out
    }

    static func field(_ name: String, in fields: [HeaderField]) -> String? {
        fields.first(where: { $0.name == name })?.value
    }

    // MARK: - Message-ID

    /// `<ABC@x.com>` → `<abc@x.com>`; bare ids are wrapped; nil when absent or unusable.
    package static func normalizeMessageID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw.filter { !$0.isWhitespace }
        if let open = compact.firstIndex(of: "<"), let close = compact[open...].firstIndex(of: ">") {
            let inner = compact[compact.index(after: open)..<close]
            guard !inner.isEmpty, inner.count <= 900 else { return nil }
            return "<" + inner.lowercased() + ">"
        }
        let bare = compact.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        guard !bare.isEmpty, bare.count <= 900 else { return nil }
        return "<" + bare.lowercased() + ">"
    }

    /// Stable id for mail without a Message-ID: sha256(from + date + subject).
    package static func fallbackMessageID(from: String, date: String, subject: String) -> String {
        let key = from.lowercased() + "\n" + date.trimmingCharacters(in: .whitespaces) + "\n" + subject
        let hex = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "<\(hex)@paperdeck.invalid>"
    }

    // MARK: - Header section

    /// End of the header block: `bodyStart` is the first byte after the blank line (or the end).
    private static func headerEnd(_ b: [UInt8], _ r: Range<Int>) -> (headerEnd: Int, bodyStart: Int) {
        var i = r.lowerBound
        // A part may start directly with its blank line (no headers).
        if i < r.upperBound, b[i] == 0x0A { return (i, i + 1) }
        if i + 1 < r.upperBound, b[i] == 0x0D, b[i + 1] == 0x0A { return (i, i + 2) }
        while i < r.upperBound {
            if b[i] == 0x0A {
                var j = i + 1
                if j < r.upperBound, b[j] == 0x0D { j += 1 }
                if j < r.upperBound, b[j] == 0x0A { return (i, j + 1) }
                if j >= r.upperBound { return (r.upperBound, r.upperBound) }
            }
            i += 1
        }
        return (r.upperBound, r.upperBound)
    }

    /// Unfolded header fields of the entity in `r`, plus where its body starts.
    package static func headerFields(_ b: [UInt8], _ r: Range<Int>) -> (fields: [HeaderField], bodyStart: Int) {
        let (end, bodyStart) = headerEnd(b, r)
        guard end > r.lowerBound else { return ([], bodyStart) }
        let raw = Array(b[r.lowerBound..<end])
        // "\r\n" is a single Character in Swift, so normalize before splitting into lines.
        let text = headerText(raw).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        var fields: [HeaderField] = []
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line
            defer { first = false }
            if let c = l.first, c == " " || c == "\t" {
                if !fields.isEmpty { fields[fields.count - 1].value += String(l) }
                continue
            }
            if first, l.hasPrefix("From "), !l.hasPrefix("From:") { continue }          // mbox separator
            guard let colon = l.firstIndex(of: ":") else { continue }
            let name = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, name.count <= 76,
                  name.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { continue }
            fields.append(HeaderField(name: name, value: String(l[l.index(after: colon)...])))
            if fields.count > 2_000 { break }
        }
        for i in fields.indices {
            fields[i].value = fields[i].value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (fields, bodyStart)
    }

    /// Header bytes as text: UTF-8 (RFC 6532), else the charset of an 8-bit legacy mailer
    /// (taken from the Content-Type line), else Windows-1252.
    private static func headerText(_ raw: [UInt8]) -> String {
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        let ascii = String(decoding: raw.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        if let m = ascii.range(of: #"(?i)charset\s*=\s*"?([A-Za-z0-9_\-:.]+)"#, options: .regularExpression) {
            let cs = ascii[m].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            if let cs, let enc = encoding(forCharset: cs), let s = String(bytes: raw, encoding: enc) { return s }
        }
        if let s = String(bytes: raw, encoding: .windowsCP1252) { return s }
        return String(bytes: raw, encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }

    // MARK: - Body tree

    private struct Context {
        let maxAttachmentBytes: Int
        var attachments: [MailAttachment] = []
        var leafCount = 0
    }

    private struct Flat {
        var ownPlain: [String] = []
        var ownHTML: [String] = []
        var forwarded: [(header: ForwardHeader, plain: String?, html: String?)] = []

        var plain: String? {
            guard !ownPlain.isEmpty || ownHTML.isEmpty else { return nil }
            var parts = ownPlain
            for f in forwarded {
                let body = f.plain ?? f.html.map(HTMLText.text) ?? ""
                parts.append(f.header.plainBlock + body)
            }
            let joined = parts.joined(separator: "\n\n")
            return joined.isEmpty && forwarded.isEmpty ? nil : joined
        }

        var html: String? {
            guard !ownHTML.isEmpty else { return nil }
            var parts = ownHTML
            for f in forwarded {
                let body = f.html ?? f.plain.map { "<pre>" + MIMEParser.escapeHTML($0) + "</pre>" } ?? ""
                parts.append(f.header.htmlBlock + body)
            }
            return parts.joined(separator: "\n")
        }
    }

    private struct ForwardHeader {
        var from: String
        var date: String
        var subject: String

        var lines: [String] {
            var l = ["---------- Forwarded message ---------"]
            if !from.isEmpty { l.append("From: " + from) }
            if !date.isEmpty { l.append("Date: " + date) }
            if !subject.isEmpty { l.append("Subject: " + subject) }
            return l
        }
        var plainBlock: String { lines.joined(separator: "\n") + "\n\n" }
        var htmlBlock: String { "<div>" + lines.map(MIMEParser.escapeHTML).joined(separator: "<br>") + "</div><br>" }
    }

    private static func parseEntity(_ b: [UInt8], fields: [HeaderField], body: Range<Int>, depth: Int,
                                    defaultType: String, inRelated: Bool, ctx: inout Context) -> Flat {
        var flat = Flat()
        let ct = field("content-type", in: fields).map(parseParameters)
        var type = (ct?.value ?? defaultType).lowercased().trimmingCharacters(in: .whitespaces)
        if !type.contains("/") { type = type == "text" ? "text/plain" : defaultType }
        let params = ct?.params ?? [:]
        let cte = (field("content-transfer-encoding", in: fields) ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let disp = field("content-disposition", in: fields).map(parseParameters)
        let dispType = disp?.value.lowercased().trimmingCharacters(in: .whitespaces)
        let filename = sanitizeFilename(disp?.params["filename"] ?? params["name"])

        if type.hasPrefix("multipart/") {
            guard depth < maxDepth else { return flat }
            let boundary = params["boundary"] ?? sniffBoundary(b, body)
            guard let boundary, !boundary.isEmpty else {
                // Broken multipart without a boundary: salvage as text.
                appendText(b, body, cte: cte, type: "text/plain", params: params, into: &flat)
                return flat
            }
            let childDefault = type == "multipart/digest" ? "message/rfc822" : "text/plain"
            let related = type == "multipart/related"
            let alternative = type == "multipart/alternative"
            var alternatives: [Flat] = []
            for part in splitMultipart(b, body, boundary: boundary) {
                guard ctx.leafCount < maxParts else { break }
                let (pf, pbody) = headerFields(b, part)
                let child = parseEntity(b, fields: pf, body: pbody..<part.upperBound, depth: depth + 1,
                                        defaultType: childDefault, inRelated: related || inRelated, ctx: &ctx)
                if alternative { alternatives.append(child) } else { merge(child, into: &flat) }
            }
            if alternative {
                // Each alternative renders the same content: keep the last plain and the last html
                // rendering (RFC 2046 orders them by increasing faithfulness).
                let p = alternatives.last(where: { !$0.ownPlain.isEmpty })
                let h = alternatives.last(where: { !$0.ownHTML.isEmpty })
                flat.ownPlain = p?.ownPlain ?? []
                flat.ownHTML = h?.ownHTML ?? []
                flat.forwarded = h?.forwarded ?? p?.forwarded ?? alternatives.last?.forwarded ?? []
            }
            return flat
        }

        ctx.leafCount += 1
        guard ctx.leafCount <= maxParts else { return flat }

        if (type == "message/rfc822" || type == "message/global"), depth < maxDepth {
            let raw = decodeTransfer(b, body, cte: cte, limit: nil).data ?? Data()
            let inner = [UInt8](raw)
            let (innerFields, innerBody) = headerFields(inner, 0..<inner.count)
            guard !innerFields.isEmpty else { return flat }
            let innerFlat = parseEntity(inner, fields: innerFields, body: innerBody..<inner.count, depth: depth + 1,
                                        defaultType: "text/plain", inRelated: false, ctx: &ctx)
            let from = field("from", in: innerFields).map(decodeEncodedWords) ?? ""
            let fh = ForwardHeader(from: from.trimmingCharacters(in: .whitespaces),
                                   date: field("date", in: innerFields) ?? "",
                                   subject: decodeEncodedWords(field("subject", in: innerFields) ?? ""))
            flat.forwarded.append((fh, innerFlat.plain, innerFlat.html))
            return flat
        }
        if ["message/delivery-status", "message/disposition-notification", "text/rfc822-headers",
            "message/feedback-report", "message/global-delivery-status", "message/global-headers"].contains(type) {
            return flat
        }
        if (type == "text/plain" || type == "text/html"), dispType != "attachment", filename == nil {
            appendText(b, body, cte: cte, type: type, params: params, into: &flat)
            return flat
        }

        // Attachment (or inline resource).
        let decoded = decodeTransfer(b, body, cte: cte, limit: ctx.maxAttachmentBytes)
        let hasCID = field("content-id", in: fields) != nil
        let isImage = type.hasPrefix("image/")
        let isInline: Bool
        switch dispType {
        case "attachment": isInline = false
        case "inline": isInline = isImage || (inRelated && hasCID)
        default: isInline = (isImage && (inRelated || hasCID)) || (inRelated && hasCID)
        }
        ctx.attachments.append(MailAttachment(filename: filename, contentType: type, isInline: isInline,
                                              data: decoded.data, sizeBytes: decoded.size))
        return flat
    }

    private static func merge(_ child: Flat, into flat: inout Flat) {
        flat.ownPlain += child.ownPlain
        flat.ownHTML += child.ownHTML
        flat.forwarded += child.forwarded
    }

    private static func appendText(_ b: [UInt8], _ body: Range<Int>, cte: String, type: String,
                                   params: [String: String], into flat: inout Flat) {
        let raw = decodeTransfer(b, body, cte: cte, limit: nil).data ?? Data()
        var charset = params["charset"]
        if charset == nil, type == "text/html" { charset = sniffMetaCharset(raw) }
        var text = decode(raw, charset: charset)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if type == "text/plain", params["format"]?.lowercased() == "flowed" {
            text = unflow(text, delsp: params["delsp"]?.lowercased() == "yes")
        }
        if type == "text/html" { flat.ownHTML.append(text) } else { flat.ownPlain.append(text) }
    }

    // MARK: - Multipart splitting

    /// Body ranges between `--boundary` delimiter lines (preamble and epilogue dropped). The line
    /// break before a delimiter belongs to the delimiter. A missing close delimiter ends at EOF.
    static func splitMultipart(_ b: [UInt8], _ r: Range<Int>, boundary: String) -> [Range<Int>] {
        let delim = Array(("--" + boundary).utf8)
        var parts: [Range<Int>] = []
        var current: Int?
        var lineStart = r.lowerBound
        while lineStart < r.upperBound {
            let lineEnd = nextLF(b, from: lineStart, end: r.upperBound)
            if lineEnd - lineStart >= delim.count, b[lineStart] == 0x2D, matches(b, at: lineStart, delim) {
                var k = lineStart + delim.count
                var closing = false
                if k + 1 < r.upperBound, b[k] == 0x2D, b[k + 1] == 0x2D { closing = true; k += 2 }
                // Only transport padding may follow the boundary.
                var tailOK = true
                while k < lineEnd {
                    let c = b[k]
                    if c != 0x20, c != 0x09, c != 0x0D { tailOK = false; break }
                    k += 1
                }
                if tailOK {
                    if let start = current {
                        var end = lineStart
                        if end > start, b[end - 1] == 0x0A { end -= 1 }
                        if end > start, b[end - 1] == 0x0D { end -= 1 }
                        parts.append(start..<max(start, end))
                    }
                    if closing { return parts }
                    current = min(lineEnd + 1, r.upperBound)
                }
            }
            lineStart = lineEnd + 1
        }
        if let start = current, start < r.upperBound { parts.append(start..<r.upperBound) }
        return parts
    }

    /// Index of the next "\n" at or after `from` (or `end`), via memchr.
    private static func nextLF(_ b: [UInt8], from: Int, end: Int) -> Int {
        guard from < end else { return end }
        return b.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress,
                  let hit = memchr(base + from, 0x0A, end - from) else { return end }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func matches(_ b: [UInt8], at i: Int, _ p: [UInt8]) -> Bool {
        guard i + p.count <= b.count else { return false }
        for k in 0..<p.count where b[i + k] != p[k] { return false }
        return true
    }

    /// A multipart without a boundary parameter: use the first "--xyz" line.
    private static func sniffBoundary(_ b: [UInt8], _ r: Range<Int>) -> String? {
        var lineStart = r.lowerBound
        var lines = 0
        while lineStart < r.upperBound, lines < 200 {
            var lineEnd = lineStart
            while lineEnd < r.upperBound, b[lineEnd] != 0x0A { lineEnd += 1 }
            if lineEnd - lineStart > 3, b[lineStart] == 0x2D, b[lineStart + 1] == 0x2D {
                var e = lineEnd
                if e > lineStart, b[e - 1] == 0x0D { e -= 1 }
                let s = String(decoding: b[(lineStart + 2)..<e], as: UTF8.self)
                if !s.isEmpty, !s.contains(" ") { return s }
            }
            lineStart = lineEnd + 1
            lines += 1
        }
        return nil
    }

    // MARK: - Transfer encodings

    /// Decoded bytes (nil when over `limit`) and the decoded size.
    private static func decodeTransfer(_ b: [UInt8], _ r: Range<Int>, cte: String, limit: Int?) -> (data: Data?, size: Int) {
        switch cte {
        case "base64":
            // r.count * 3 / 4 bounds the decoded size; count exactly only when it may exceed the cap.
            if let limit, r.count / 4 * 3 > limit {
                let size = base64DecodedLength(b, r)
                if size > limit { return (nil, size) }
            }
            let d = decodeBase64(b, r)
            return (d, d.count)
        case "quoted-printable":
            let d = decodeQuotedPrintable(b, r)
            if let limit, d.count > limit { return (nil, d.count) }
            return (d, d.count)
        default:
            let size = r.count
            if let limit, size > limit { return (nil, size) }
            return (Data(b[r]), size)
        }
    }

    private static let base64Table: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() { t[Int(c)] = Int8(i) }
        return t
    }()

    private static func base64DecodedLength(_ b: [UInt8], _ r: Range<Int>) -> Int {
        var n = 0
        for i in r where base64Table[Int(b[i])] >= 0 { n += 1 }
        return n * 6 / 8
    }

    /// Lenient base64: whitespace, padding and stray bytes are skipped.
    package static func decodeBase64(_ data: Data) -> Data {
        let b = [UInt8](data)
        return decodeBase64(b, 0..<b.count)
    }

    private static func decodeBase64(_ b: [UInt8], _ r: Range<Int>) -> Data {
        // Fast path: Foundation's decoder (whitespace skipped); the lenient loop handles bad padding.
        if let d = Data(base64Encoded: Data(b[r]), options: .ignoreUnknownCharacters) { return d }
        var out = [UInt8]()
        out.reserveCapacity(r.count * 3 / 4)
        var acc: UInt32 = 0
        var bits = 0
        for i in r {
            let v = base64Table[Int(b[i])]
            guard v >= 0 else { continue }
            acc = (acc << 6) | UInt32(v)
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
            }
        }
        return Data(out)
    }

    /// Quoted-printable body decoding (soft line breaks removed, `=XX` decoded, bad escapes kept).
    package static func decodeQuotedPrintable(_ data: Data) -> Data {
        let b = [UInt8](data)
        return decodeQuotedPrintable(b, 0..<b.count)
    }

    private static func decodeQuotedPrintable(_ b: [UInt8], _ r: Range<Int>, header: Bool = false) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(r.count)
        var i = r.lowerBound
        let end = r.upperBound
        while i < end {
            let c = b[i]
            if header, c == 0x5F { out.append(0x20); i += 1; continue }
            guard c == 0x3D else { out.append(c); i += 1; continue }
            // Soft line break: "=" [spaces] CRLF / LF
            var j = i + 1
            while j < end, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            if j < end, b[j] == 0x0A { i = j + 1; continue }
            if j + 1 < end, b[j] == 0x0D, b[j + 1] == 0x0A { i = j + 2; continue }
            if j == end, !header { i = end; continue }
            if i + 2 < end, let h = hexValue(b[i + 1]), let l = hexValue(b[i + 2]) {
                out.append(h << 4 | l); i += 3; continue
            }
            out.append(c)
            i += 1
        }
        return Data(out)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    // MARK: - Charsets

    /// Text in `charset` (IANA name, via CFStringConvertIANACharSetNameToEncoding). Legacy Chinese
    /// labels decode as GB18030 (their superset), Latin-1 as Windows-1252; unknown or wrong labels
    /// fall back to UTF-8, then Windows-1252 / Latin-1 — never fails.
    package static func decode(_ data: Data, charset: String?) -> String {
        let cs = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() ?? ""
        let utf8ish: Set<String> = ["", "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8", "x-unknown", "unknown-8bit", "unknown", "default", "x-user-defined", "ansi_x3.4-1968"]
        if utf8ish.contains(cs) {
            if let s = String(data: data, encoding: .utf8) { return s }
            if cs.hasPrefix("utf") { return String(decoding: data, as: UTF8.self) }
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        let enc = encoding(forCharset: cs)
        if let enc, let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let enc, enc != .windowsCP1252 { return lossyDecode(data, enc) }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Line-by-line decoding for text with a few corrupt multi-byte sequences: lines that fail
    /// keep their ASCII characters only.
    private static func lossyDecode(_ data: Data, _ enc: String.Encoding) -> String {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map { line -> String in
            String(data: Data(line), encoding: enc) ?? String(decoding: line.filter { $0 < 0x80 }, as: UTF8.self)
        }.joined(separator: "\n")
    }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    private static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))

    package static func encoding(forCharset raw: String) -> String.Encoding? {
        var cs = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if let star = cs.firstIndex(of: "*") { cs = String(cs[..<star]) }      // RFC 2231 language suffix
        switch cs {
        case "utf-8", "utf8": return .utf8
        case "gb2312", "gbk", "cp936", "x-gbk", "gb_2312-80", "gb_2312", "euc-cn", "x-euc-cn", "chinese", "csgb2312",
             "gb18030", "windows-936", "ms936", "x-mac-chinesesimp": return gb18030
        case "big5", "big-5", "cn-big5", "x-x-big5", "csbig5", "big5-hkscs", "x-mac-chinesetrad", "cp950", "windows-950": return big5
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "iso_8859-1", "cp819", "iso-ir-100", "csisolatin1", "us",
             "windows-1252", "cp1252", "x-cp1252": return .windowsCP1252
        case "ks_c_5601-1987", "ks_c_5601", "korean", "csksc56011987", "cp949", "uhc", "windows-949":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "csshiftjis", "windows-31j", "cp932":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        default: break
        }
        var name = cs
        if name.hasPrefix("cp"), let n = Int(name.dropFirst(2)), (1250...1258).contains(n) { name = "windows-\(n)" }
        if name.hasPrefix("iso8859-") { name = "iso-8859-" + name.dropFirst("iso8859-".count) }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// `<meta charset="…">` / `<meta http-equiv content="…charset=…">` in the first 4 KB.
    private static func sniffMetaCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(4096).map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        guard let r = head.range(of: #"(?i)<meta[^>]*charset\s*=\s*["']?([A-Za-z0-9_\-:.]+)"#, options: .regularExpression) else {
            return nil
        }
        let m = head[r]
        guard let eq = m.range(of: "charset", options: .caseInsensitive) else { return nil }
        return m[eq.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "= \"'"))
    }

    // MARK: - format=flowed (RFC 3676)

    static func unflow(_ text: String, delsp: Bool) -> String {
        var out: [String] = []
        var current = ""
        var continuing = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            let quoteDepth = line.prefix(while: { $0 == ">" }).count
            if quoteDepth == 0, line.hasPrefix(" ") { line.removeFirst() }                 // space-stuffing
            let isSig = line == "-- "
            let flowed = !isSig && line.hasSuffix(" ")
            if flowed, delsp { line.removeLast() }
            current += line
            continuing = flowed
            if !continuing { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out.joined(separator: "\n")
    }

    // MARK: - RFC 2047 encoded words

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#)

    /// Decodes `=?charset?B|Q?…?=` words; whitespace between adjacent words is dropped and
    /// adjacent words in one charset are joined before decoding (multi-byte characters split
    /// across words survive).
    package static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        let matches = encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        var pendingBytes = [UInt8]()
        var pendingCharset: String?

        func flush() {
            guard let cs = pendingCharset else { return }
            out += decode(Data(pendingBytes), charset: cs)
            pendingBytes = []
            pendingCharset = nil
        }

        for m in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let adjacent = pendingCharset != nil && gap.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
            if !adjacent { flush(); out += gap }
            var charset = ns.substring(with: m.range(at: 1)).lowercased()
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = Array(ns.substring(with: m.range(at: 3)).utf8)
            let bytes: [UInt8] = enc == "B"
                ? [UInt8](decodeBase64(text, 0..<text.count))
                : [UInt8](decodeQuotedPrintable(text, 0..<text.count, header: true))
            if pendingCharset != nil, pendingCharset != charset { flush() }
            pendingCharset = charset
            pendingBytes += bytes
            cursor = m.range.location + m.range.length
        }
        flush()
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    // MARK: - Parameters (RFC 2045 + RFC 2231)

    /// `type/subtype; a=b; name*=UTF-8''%E4…` → ("type/subtype", [lowercased name: decoded value]).
    /// RFC 2231 continuations (`name*0*=`, `name*1=`) are joined and percent-decoded in the
    /// first segment's charset; an extended value beats a plain one of the same name.
    package static func parseParameters(_ header: String) -> (value: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for ch in header {
            if escape { current.append(ch); escape = false; continue }
            if inQuote, ch == "\\" { current.append(ch); escape = true; continue }
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch == ";", !inQuote { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        pieces.append(current)
        let value = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        struct Segment { var index: Int; var extended: Bool; var value: String }
        var simple: [String: String] = [:]
        var extendedSingle: [String: String] = [:]
        var segments: [String: [Segment]] = [:]

        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let rawName = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("\""), v.count >= 2 {
                v = String(v.dropFirst())
                if v.hasSuffix("\"") { v.removeLast() }
                v = unescapeQuoted(v)
            }
            guard !rawName.isEmpty else { continue }
            let parts = rawName.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            let base = parts[0]
            if parts.count == 1 {
                if simple[base] == nil { simple[base] = v }
            } else if parts.count == 2, parts[1].isEmpty {
                extendedSingle[base] = v                                         // name*=
            } else if let idx = Int(parts[1]) {
                let ext = parts.count == 3 && parts[2].isEmpty                    // name*N* / name*N
                segments[base, default: []].append(Segment(index: idx, extended: ext, value: v))
            }
        }

        var params: [String: String] = [:]
        for (k, v) in simple { params[k] = v.contains("=?") ? decodeEncodedWords(v) : v }
        for (k, v) in extendedSingle { params[k] = decode2231(v, charsetPrefix: true).text }
        for (k, segs) in segments {
            let sorted = segs.sorted { $0.index < $1.index }
            var bytes = [UInt8]()
            var charset: String?
            for (i, seg) in sorted.enumerated() {
                if seg.extended {
                    let r = decode2231(seg.value, charsetPrefix: i == 0)
                    if i == 0 { charset = r.charset }
                    bytes += r.bytes
                } else {
                    bytes += Array(seg.value.utf8)
                }
            }
            params[k] = decode(Data(bytes), charset: charset ?? "utf-8")
        }
        return (value, params)
    }

    private static func unescapeQuoted(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escape = false
        for ch in s {
            if escape { out.append(ch); escape = false } else if ch == "\\" { escape = true } else { out.append(ch) }
        }
        return out
    }

    /// `charset'lang'%XX…` → bytes (and text decoded in that charset).
    private static func decode2231(_ v: String, charsetPrefix: Bool) -> (text: String, bytes: [UInt8], charset: String?) {
        var rest = Substring(v)
        var charset: String?
        if charsetPrefix {
            let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                charset = parts[0].isEmpty ? nil : String(parts[0])
                rest = parts[2]
            }
        }
        var bytes = [UInt8]()
        let u = Array(rest.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let h = hexValue(u[i + 1]), let l = hexValue(u[i + 2]) {
                bytes.append(h << 4 | l); i += 3
            } else {
                bytes.append(u[i]); i += 1
            }
        }
        return (decode(Data(bytes), charset: charset ?? "utf-8"), bytes, charset)
    }

    /// Last path component only, no control characters, ≤ 255 characters.
    static func sanitizeFilename(_ raw: String?) -> String? {
        guard var s = raw.map(decodeEncodedWords) else { return nil }
        s = s.replacingOccurrences(of: "\\", with: "/")
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        s = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !HTMLText.isInvisible($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        return String(s.prefix(255))
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Addresses

    /// First mailbox of an address header.
    package static func parseAddress(_ value: String) -> (address: String, name: String?)? {
        parseAddressList(value).first
    }

    /// Mailboxes of an address list: `"Name" <a@b>`, `a@b (Name)`, encoded-word names, groups.
    /// Addresses are lowercased; display names are decoded but never used for identity.
    package static func parseAddressList(_ value: String) -> [(address: String, name: String?)] {
        var pieces: [String] = []
        var current = ""
        var inQuote = false, escape = false
        var comment = 0, angle = false
        for ch in value {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\", inQuote || comment > 0 { current.append(ch); escape = true; continue }
            if inQuote { if ch == "\"" { inQuote = false }; current.append(ch); continue }
            switch ch {
            case "\"" where comment == 0: inQuote = true
            case "(": comment += 1
            case ")": comment = max(0, comment - 1)
            case "<" where comment == 0: angle = true
            case ">" where comment == 0: angle = false
            case ":" where comment == 0 && !angle:
                // Group syntax "Name: a@b, c@d;" — drop the display part.
                if !current.contains("@") { current = ""; continue }
            case ";" where comment == 0 && !angle:
                pieces.append(current); current = ""; continue
            case "," where comment == 0 && !angle:
                pieces.append(current); current = ""; continue
            default: break
            }
            current.append(ch)
        }
        pieces.append(current)
        return pieces.compactMap(parseMailbox)
    }

    private static func parseMailbox(_ piece: String) -> (address: String, name: String?)? {
        enum Word { case atom(String), quoted(String) }
        var words: [(word: Word, spaceBefore: Bool)] = []
        var comments: [String] = []
        var angleAddr: String?
        var i = piece.startIndex
        var sawSpace = false
        while i < piece.endIndex {
            let ch = piece[i]
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" { sawSpace = true; i = piece.index(after: i); continue }
            if ch == "\"" {
                var j = piece.index(after: i)
                var v = ""
                var esc = false
                while j < piece.endIndex {
                    let c = piece[j]
                    if esc { v.append(c); esc = false } else if c == "\\" { esc = true } else if c == "\"" { break } else { v.append(c) }
                    j = piece.index(after: j)
                }
                words.append((.quoted(v), sawSpace)); sawSpace = false
                i = j < piece.endIndex ? piece.index(after: j) : j
                continue
            }
            if ch == "(" {
                var depth = 1
                var j = piece.index(after: i)
                var v = ""
                var esc = false
                while j < piece.endIndex, depth > 0 {
                    let c = piece[j]
                    if esc { v.append(c); esc = false }
                    else if c == "\\" { esc = true }
                    else if c == "(" { depth += 1; v.append(c) }
                    else if c == ")" { depth -= 1; if depth > 0 { v.append(c) } }
                    else { v.append(c) }
                    j = piece.index(after: j)
                }
                comments.append(v)
                i = j
                sawSpace = true
                continue
            }
            if ch == "<" {
                var j = piece.index(after: i)
                var v = ""
                while j < piece.endIndex, piece[j] != ">" { v.append(piece[j]); j = piece.index(after: j) }
                if angleAddr == nil { angleAddr = v }
                i = j < piece.endIndex ? piece.index(after: j) : j
                sawSpace = true
                continue
            }
            var j = i
            var v = ""
            while j < piece.endIndex, !" \t\r\n\"(<".contains(piece[j]) { v.append(piece[j]); j = piece.index(after: j) }
            words.append((.atom(v), sawSpace)); sawSpace = false
            i = j
        }

        // Join adjacent words (no whitespace between) into tokens: `"john doe"@x.org` stays one token.
        var tokens: [String] = []
        for (w, space) in words {
            let s: String
            switch w { case .atom(let a): s = a; case .quoted(let q): s = q }
            if !space, !tokens.isEmpty { tokens[tokens.count - 1] += s } else { tokens.append(s) }
        }

        var address: String
        var nameParts: [String]
        if let a = angleAddr {
            address = a
            if let colon = address.lastIndex(of: ":") { address = String(address[address.index(after: colon)...]) }  // route
            nameParts = tokens
        } else if let at = tokens.lastIndex(where: { $0.contains("@") }) {
            address = tokens[at]
            nameParts = tokens
            nameParts.remove(at: at)
        } else {
            address = tokens.joined()
            nameParts = []
        }
        address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        guard !address.isEmpty else { return nil }

        var name = decodeEncodedWords(nameParts.joined(separator: " "))
        if name.isEmpty, let c = comments.first { name = decodeEncodedWords(c) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        name = String(name.unicodeScalars.filter { !HTMLText.isInvisible($0) }.map(Character.init))
        return (address, name.isEmpty ? nil : String(name.prefix(200)))
    }

    // MARK: - Dates

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zones: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0, "wet": 0, "bst": 60, "cet": 60, "cest": 120, "met": 60, "mest": 120,
        "eet": 120, "eest": 180, "est": -300, "edt": -240, "cst": -360, "cdt": -300, "mst": -420, "mdt": -360,
        "pst": -480, "pdt": -420, "akst": -540, "akdt": -480, "hst": -600, "jst": 540, "kst": 540, "ist": 330,
        "sgt": 480, "hkt": 480, "aest": 600, "aedt": 660, "nzst": 720, "nzdt": 780,
    ]

    /// RFC 5322 dates plus common variants: missing weekday/seconds, 2-digit years, zone names,
    /// comments, "29-Sep-2026" (IMAP), asctime ("Tue Sep 29 14:05:00 2026"), ISO 8601.
    package static func parseDate(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}([T ]|$)"#, options: .regularExpression) != nil {
            let iso = s.replacingOccurrences(of: " ", with: "T", options: [], range: s.range(of: " "))
            if let d = try? Date(iso, strategy: .iso8601) { return d }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: iso) { return d }
        }
        // Drop comments like "(CDT)".
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        let tokens: [Substring] = s.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .flatMap { tok -> [Substring] in
                // "29-Sep-2026" → three tokens; keep "+0500"/"-0500" and times intact.
                if tok.contains("-"), !tok.hasPrefix("-"), !tok.hasPrefix("+"), !tok.contains(":") {
                    return tok.split(separator: "-")
                }
                return [tok]
            }

        var day: Int?, month: Int?, year: Int?
        if let m = s.range(of: #"\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b"#, options: .regularExpression) {
            let p = s[m].split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
            if p.count == 3 { year = p[0]; month = p[1]; day = p[2] }
            s.removeSubrange(m)
        }
        var hour = 0, minute = 0, second = 0
        var offsetMinutes: Int?
        var pm: Bool?
        for tok in tokens {
            let t = tok.lowercased()
            if t.contains(":") {
                var timePart = Substring(t)
                if let z = timePart.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "z" }) {
                    let zone = String(timePart[z...])
                    timePart = timePart[..<z]
                    if zone == "z" { offsetMinutes = 0 } else if let o = parseOffset(zone) { offsetMinutes = o }
                }
                let comps = timePart.split(separator: ":").map { Int($0.prefix(while: \.isNumber)) }
                guard comps.count >= 2, let h = comps[0], let m = comps[1] else { continue }
                hour = h; minute = m; second = comps.count > 2 ? (comps[2] ?? 0) : 0
                continue
            }
            if (t.hasPrefix("+") || t.hasPrefix("-")), let o = parseOffset(t) { offsetMinutes = o; continue }
            if t == "am" || t == "a.m." { pm = false; continue }
            if t == "pm" || t == "p.m." { pm = true; continue }
            if let first = t.first, first.isLetter {
                let p3 = String(t.prefix(3))
                if let m = months.firstIndex(of: p3), month == nil, t.count <= 9 { month = m + 1; continue }
                if let z = zones[t] { offsetMinutes = offsetMinutes ?? z; continue }
                if t.count == 1 { offsetMinutes = offsetMinutes ?? 0; continue }        // military zones
                continue                                                               // weekday / noise
            }
            let digits = t.prefix(while: \.isNumber)
            guard !digits.isEmpty, let v = Int(digits) else { continue }
            if digits.count == 4 { if year == nil { year = v }; continue }
            if day == nil, digits.count <= 2, v >= 1, v <= 31 { day = v; continue }
            if year == nil { year = digits.count == 3 ? v + 1900 : (v < 50 ? 2000 + v : 1900 + v) }
        }
        guard let d = day, let m = month, let y = year, (1...31).contains(d), (1...12).contains(m),
              (1970...2200).contains(y) else { return nil }
        if let pm { if pm, hour < 12 { hour += 12 } else if !pm, hour == 12 { hour = 0 } }
        guard hour < 24, minute < 60, second <= 60 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = hour; comps.minute = minute; comps.second = min(second, 59)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: (offsetMinutes ?? 0) * 60) ?? TimeZone(identifier: "UTC")!
        guard comps.isValidDate(in: cal) else { return nil }
        return cal.date(from: comps)
    }

    private static func parseOffset(_ t: String) -> Int? {
        let sign = t.hasPrefix("-") ? -1 : 1
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count == 4 || digits.count == 2, let v = Int(digits) else { return nil }
        let h = digits.count == 4 ? v / 100 : v
        let m = digits.count == 4 ? v % 100 : 0
        guard h <= 14, m < 60 else { return nil }
        return sign * (h * 60 + m)
    }
}
