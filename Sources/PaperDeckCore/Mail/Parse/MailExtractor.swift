import Foundation

/// Local extraction for one allowlisted (or user-dropped) message — MAIL_DESIGN Part A §2
/// "Local extraction". Pure and deterministic; callers run it on `BlockingIO`.
///
/// 1. Body: text/plain when it is meaningful, else the HTML rendered by `HTMLText`.
/// 2. Quoted reply history is cut (en/zh markers); a forwarded message is kept as a capped
///    `[forwarded]` section ("FYI, see #3" depends on it). Signatures and "Sent from my…" go.
/// 3. Candidates, numbered `c1…cN` in this order: attachments (PDFs, and — from a person, an
///    advisor or a dropped email — Word / RTF / ODT / slides documents), classified links (deduped
///    by identifiers / URL; from those senders, links to shared files too), bare DOIs / arXiv ids
///    in the text, alert entries.
/// 4. Every URL in the text becomes `[cN host]` (or `[link host]` for non-paper links) — wrapped
///    or tracking URLs never reach the stored body or the AI. Phone numbers become `[phone]`,
///    email addresses other than the sender's `[email]`. The text is capped at `bodyCap`.
///
/// Mail text is untrusted: literal `[c1 …]` markers and `[forwarded]` labels in the source are
/// defused so they cannot impersonate ours, and nothing in the text is acted upon.
package enum MailExtractor {

    package static let forwardedLabel = "[forwarded]"
    package static let maxCandidates = 80
    package static let snippetLimit = 255
    package static let forwardedCap = 8_000
    package static let defaultBodyCap = 20_000
    /// Lines of cut history kept for the confidentiality guard (it reads the first 25 non-empty ones).
    static let historyLines = 400

    package static func extract(_ content: MailContent, senderKind: SenderKind, bodyCap: Int) -> MailExtraction {
        let cap = bodyCap > 0 ? bodyCap : defaultBodyCap
        let subject = content.header.subject
        let sender = SenderMatcher.normalize(content.header.fromAddress)

        // 1. Text sources
        let htmlOut = content.html.map { HTMLText.convert($0, markAnchors: true) }
        let htmlText = htmlOut.map { dropSafetyTip(neutralize($0.text)) }
        let plain = content.plainText.map { dropSafetyTip(neutralize(cleanPlain($0))) }
        let usePlain = plain.map { isMeaningful($0, comparedTo: htmlText) } ?? false
        let source = usePlain ? (plain ?? "") : (htmlText ?? plain ?? "")

        // 2. Reply history / forwarded section
        let split = splitHistory(source, subject: subject)
        let anchorSplit: HistorySplit? = htmlText.map { usePlain ? splitHistory($0, subject: subject) : split }
        let isForwarded = split.forwarded != nil || isForwardSubject(subject)

        // 3. Candidates
        var b = Builder()
        // Documents and shared-file links come from people (a lab manuscript as a .docx, a draft on
        // SharePoint), never from alert services.
        let personal = senderKind != .alert
        for (i, a) in content.attachments.enumerated() where !a.isInline {
            if a.looksLikePDF {
                let ids = a.filename.map {
                    Identifiers.detect(fileName: $0, firstPagesText: "", attributeTitle: nil, xmpHead: nil)
                } ?? PaperIDs()
                b.add(.attachments, MailCandidate(cand: "", origin: .attachment, ids: ids, attachmentIndex: i,
                                                  pdfState: a.data != nil ? .hasPDF : .needsPDF, snippet: a.filename))
            } else if personal, let kind = DocumentKind.detect(fileName: a.filename, contentType: a.contentType) {
                b.add(.attachments, MailCandidate(cand: "", origin: .document, title: documentTitle(a.filename),
                                                  attachmentIndex: i, pdfState: a.data != nil ? kind.pdfState : .needsPDF,
                                                  snippet: a.filename, documentKind: kind.rawValue,
                                                  documentFileName: a.filename))
            }
        }
        let entries = AlertParsers.parse(html: content.html, plainText: content.plainText,
                                         generic: senderKind == .alert || isForwarded)
        for e in entries { b.add(.entries, e) }

        if let out = htmlOut, let s = anchorSplit {
            for idx in markerIndices(in: s.unique + "\n" + (s.forwarded ?? "")) where idx < out.anchors.count {
                let a = out.anchors[idx]
                guard let url = LinkUnwrapper.url(from: a.href) else { continue }
                if let ref = b.entryByHref[url.absoluteString] { b.anchorRef[idx] = ref; continue }
                guard let c = PaperLinkClassifier.classify(url, anchorText: a.text, shareLinks: personal) else { continue }
                b.anchorRef[idx] = b.add(.links, c)
            }
        }
        let keptSource = split.unique + "\n" + (split.forwarded ?? "")
        for found in urls(in: keptSource) {
            guard let url = LinkUnwrapper.url(from: found.raw) else { continue }
            if b.urlRef[found.raw] != nil { continue }
            if let ref = b.entryByHref[url.absoluteString] { b.urlRef[found.raw] = ref; continue }
            guard let c = PaperLinkClassifier.classify(url, anchorText: found.context, shareLinks: personal) else { continue }
            b.urlRef[found.raw] = b.add(.links, c)
        }
        for c in identifierCandidates(in: stripURLsAndMarkers(keptSource)) { b.add(.identifiers, c) }

        let (candidates, names) = b.finish(limit: maxCandidates)

        // 4. Render: markers, redaction, caps
        func render(_ text: String) -> String {
            var s = replaceAnchorMarkers(text) { idx in
                b.anchorRef[idx].flatMap { names[$0] }.map { "[\($0.cand) \($0.host)]" } ?? ""
            }
            s = replaceURLs(s) { raw, url in
                if let ref = b.urlRef[raw], let n = names[ref] { return "[\(n.cand) \(n.host)]" }
                let host = url.flatMap { LinkUnwrapper.unwrap($0).host }.map(PaperLinkClassifier.displayHost)
                return host.map { "[link \($0)]" } ?? "[link]"
            }
            s = redact(s, sender: sender)
            return HTMLText.tidy(s.replacingOccurrences(of: "  ", with: " "))
        }
        let unique = render(split.unique)
        let forwarded = split.forwarded.map(render).flatMap { $0.isEmpty ? nil : $0 }

        var body = truncate(unique, to: cap)
        if let f = forwarded {
            let budget = min(forwardedCap, cap - body.count - forwardedLabel.count - 4)
            if budget >= 200 {
                body += (body.isEmpty ? "" : "\n\n") + forwardedLabel + "\n" + truncate(f, to: budget)
            }
        }
        let snippetSource = unique.isEmpty ? (forwarded ?? "") : unique
        // The first lines of what was cut (a reply's quoted history is dropped from the body; a
        // forwarded section may not fit it): the confidentiality guard reads them too, so an
        // Outlook forward whose subject lost its "FW:" still counts as the invitation it quotes.
        let historyHead = split.history.map(MailHeuristics.leadingLines)
            .flatMap { $0.isEmpty ? nil : $0 }
        return MailExtraction(bodyText: body, snippet: snippet(snippetSource), candidates: candidates,
                              isForwarded: isForwarded, historyHead: historyHead)
    }

    // MARK: - Candidate bookkeeping

    enum Bucket: Int, CaseIterable { case attachments, links, identifiers, entries }

    struct Ref: Hashable {
        var bucket: Bucket
        var index: Int
    }

    private struct Builder {
        var lists: [[MailCandidate]] = Array(repeating: [], count: Bucket.allCases.count)
        var keyIndex: [String: Ref] = [:]
        var entryByHref: [String: Ref] = [:]
        var anchorRef: [Int: Ref] = [:]
        var urlRef: [String: Ref] = [:]

        @discardableResult
        mutating func add(_ bucket: Bucket, _ c: MailCandidate) -> Ref {
            let keys = MailExtractor.identityKeys(c)
            let href = c.urlOriginal.flatMap(LinkUnwrapper.url(from:))?.absoluteString
            var match: Ref?
            if bucket != .attachments { for k in keys { if let r = keyIndex[k] { match = r; break } } }
            if let existing = match {
                MailExtractor.merge(c, into: &lists[existing.bucket.rawValue][existing.index])
                for k in keys where keyIndex[k] == nil { keyIndex[k] = existing }
                if bucket == .entries, let href { entryByHref[href] = existing }
                return existing
            }
            let ref = Ref(bucket: bucket, index: lists[bucket.rawValue].count)
            lists[bucket.rawValue].append(c)
            for k in keys where keyIndex[k] == nil { keyIndex[k] = ref }
            if bucket == .entries, let href { entryByHref[href] = ref }
            return ref
        }

        /// Final order + `cN` numbering; refs beyond the cap get no name.
        func finish(limit: Int) -> ([MailCandidate], [Ref: (cand: String, host: String)]) {
            var out: [MailCandidate] = []
            var names: [Ref: (cand: String, host: String)] = [:]
            for bucket in Bucket.allCases {
                for (i, original) in lists[bucket.rawValue].enumerated() where out.count < limit {
                    var c = original
                    c.cand = "c\(out.count + 1)"
                    let fallback = c.origin == .attachment || c.origin == .document ? "attachment" : "link"
                    names[Ref(bucket: bucket, index: i)] = (c.cand, c.host ?? fallback)
                    out.append(c)
                }
            }
            return (out, names)
        }
    }

    /// Identity of a candidate for de-duplication: DOI (both bioRxiv prefixes), arXiv id, PII, URL.
    package static func identityKeys(_ c: MailCandidate) -> [String] {
        var k: [String] = []
        if let d = c.ids.doi {
            k.append("doi:" + d.lowercased())
            if let alt = MetadataClients.alternateBiorxivDOI(d) { k.append("doi:" + alt) }
        }
        if let a = c.ids.arxivID { k.append("arxiv:" + a.lowercased()) }
        if let p = c.ids.pii { k.append("pii:" + p.uppercased()) }
        if let u = c.url.flatMap(normalizedURLKey) { k.append("url:" + u) }
        return k
    }

    static func normalizedURLKey(_ s: String) -> String? {
        guard var comps = URLComponents(string: s), let host = comps.host?.lowercased() else { return nil }
        comps.fragment = nil
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        let q = comps.query.map { "?" + $0 } ?? ""
        return PaperLinkClassifier.displayHost(host) + path + q
    }

    static func merge(_ n: MailCandidate, into e: inout MailCandidate) {
        if e.title == nil { e.title = n.title }
        if e.authors.isEmpty { e.authors = n.authors }
        if e.venue == nil { e.venue = n.venue }
        if e.year == nil { e.year = n.year }
        e.ids = e.ids.merged(with: n.ids)
        if e.urlOriginal == nil { e.urlOriginal = n.urlOriginal }
        if e.snippet == nil, e.origin != .attachment, e.origin != .document { e.snippet = n.snippet }
        if e.url == nil { e.url = n.url; e.host = e.host ?? n.host }
        if e.pdfState == .needsPDF || e.pdfState == .unknown, n.pdfState == .downloadable {
            e.pdfState = .downloadable
            if let u = n.url, PaperLinkClassifier.pdfURL(for: e) == nil { e.url = u; e.host = n.host ?? e.host }
        }
    }

    /// "Lab_manuscript_v3.docx" → "Lab manuscript v3" — a document row's title until something
    /// better is known (a PDF / document extension is dropped, underscores become spaces).
    package static func documentTitle(_ filename: String?) -> String? {
        guard var name = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" || DocumentKind(rawValue: ext) != nil { name = (name as NSString).deletingPathExtension }
        name = name.replacingOccurrences(of: "_", with: " ")
        name = CardSanitizer.clean(name)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    // MARK: - Body selection

    static func cleanPlain(_ s: String) -> String {
        let scalars = s.unicodeScalars.compactMap { c -> Unicode.Scalar? in
            if c == "\r" || c == HTMLText.markerOpen || c == HTMLText.markerClose { return nil }
            if c == "\u{A0}" { return " " }
            if HTMLText.isInvisible(c) { return nil }
            return c
        }
        return HTMLText.tidy(String(String.UnicodeScalarView(scalars)))
    }

    private static let spoofedMarker = try! NSRegularExpression(pattern: #"\[(c\d+|link\b)"#, options: [.caseInsensitive])

    /// Defuses look-alikes of our own markers in untrusted text.
    static func neutralize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: forwardedLabel, with: "(forwarded)", options: .caseInsensitive)
        let ns = t as NSString
        t = spoofedMarker.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length), withTemplate: "($1")
        return t
    }

    private static let placeholders = [
        "html-capable", "html capable", "this is an html", "does not support html", "view this email in your browser",
        "enable html", "view the html version", "请使用支持html", "此邮件为html格式", "html 格式",
    ]

    /// text/plain is used unless it is a placeholder or has far less text than the HTML part.
    static func isMeaningful(_ plain: String, comparedTo html: String?) -> Bool {
        let p = plain.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        guard p >= 10 else { return false }
        let lower = plain.lowercased()
        if p < 400, placeholders.contains(where: { lower.contains($0) }) { return false }
        guard let html else { return true }
        let h = html.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        return p * 4 >= h
    }

    // MARK: - Outlook safety tip

    /// Outlook's first-contact safety tip at the top of a message ("You don't often get email from
    /// x@y. Learn why this is important" + an aka.ms link; Power Automate's Export email keeps it) is
    /// Microsoft's text, not the sender's: dropped before the summary, the card and the AI see the body.
    private static let safetyTip = rx(#"(?m)^[ \t]*(?:some people who received this message don['’]t often get e-?mail from|you don['’]t often get e-?mail from|你通常不会收到来自)[^\n]*?(?:\n[^\n]*?)?(?:learn why this is important|了解这一点为什么很重要)[^\n]*(?:\n|$)"#)

    /// Removes the safety tip when it is within the first 2,000 characters (that's where Outlook puts it).
    static func dropSafetyTip(_ s: String) -> String {
        let ns = s as NSString
        guard let m = safetyTip.firstMatch(in: s, range: NSRange(location: 0, length: min(ns.length, 2_000))) else { return s }
        return ns.replacingCharacters(in: m.range, with: "")
    }

    // MARK: - Reply history

    package struct HistorySplit: Sendable, Equatable {
        package var unique: String
        package var forwarded: String?
        /// The lines from the cut on (a reply's quoted history, or the forwarded section before its
        /// cleanup; at most `historyLines`), nil when nothing was cut. Local only: the
        /// confidentiality guard reads its first lines (`MailExtraction.historyHead`); it is never
        /// stored or sent.
        package var history: String?

        package init(unique: String, forwarded: String?, history: String? = nil) {
            self.unique = unique; self.forwarded = forwarded; self.history = history
        }
    }

    private static func rx(_ p: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        catch { preconditionFailure("MailExtractor: bad pattern \(p)") }
    }
    private static let forwardMarker = rx(#"^(?:-{2,}\s*(?:forwarded message|forwarded e-?mail|forwarded|转发的邮件|转发邮件信息|轉寄郵件|转发邮件)\s*-{2,}|begin forwarded message:?|开始转发的邮件[:：]?)$"#)
    private static let originalMarker = rx(#"^-{2,}\s*(?:original message|原始邮件|原始郵件|原邮件)\s*-{2,}$"#)
    private static let wroteLine = rx(#"^(?:on|am|le|el|il|op)\b.{0,300}\b(?:wrote|schrieb|a écrit|escribió|scrisse|schreef)\s*:$"#)
    private static let zhWroteLine = rx(#"^.{0,300}写道[:：]$"#)
    private static let headerStart = rx(#"^\*?(?:from|发件人|寄件者|寄件人|von|de)\s*\*?\s*[:：]"#)
    private static let headerField = rx(#"^\*?(?:sent|date|to|cc|subject|发送时间|日期|时间|收件人|抄送|主题|主旨|傳送時間|收件者|gesendet|an|betreff|envoyé|objet)\s*\*?\s*[:：]"#)
    private static let underscores = rx(#"^_{8,}$"#)
    private static let forwardSubject = rx(#"^\s*(?:\[[^\]]{0,40}\]\s*)?(?:fwd?|fw|wg|转发|轉寄|转)\s*[:：]"#)
    private static let sentFrom = rx(#"^(?:sent from my .{1,40}|get outlook for .{1,20}|发自我的.{1,20}|从我的.{1,20}发送)$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func isForwardSubject(_ subject: String) -> Bool { matches(forwardSubject, subject) }

    /// Splits off quoted history. Forwarded content (explicit forward markers, or an Outlook header
    /// block / "Original Message" in a "Fwd:" mail) is returned separately; replies are dropped.
    package static func splitHistory(_ text: String, subject: String) -> HistorySplit {
        let lines = text.components(separatedBy: "\n")
        let fwdSubject = isForwardSubject(subject)
        var cut: Int?
        var forward = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.count <= 80, matches(forwardMarker, t) { cut = i; forward = true; break }
            if t.count <= 80, matches(originalMarker, t) { cut = i; forward = fwdSubject; break }
            if isWrote(lines, i) { cut = i; forward = false; break }
            if matches(underscores, t), let n = nextNonEmpty(lines, after: i), isHeaderBlock(lines, n) {
                cut = i; forward = fwdSubject; break
            }
            if isHeaderBlock(lines, i) { cut = i; forward = fwdSubject; break }
        }
        let uniqueLines = cut.map { Array(lines[..<$0]) } ?? lines
        let unique = cleanUnique(uniqueLines)
        let history = cut.map { lines[$0...].prefix(historyLines).joined(separator: "\n") }
        guard let c = cut, forward else { return HistorySplit(unique: unique, forwarded: nil, history: history) }
        let f = cleanForwarded(Array(lines[c...]))
        return HistorySplit(unique: unique, forwarded: f.isEmpty ? nil : f, history: history)
    }

    private static func nextNonEmpty(_ lines: [String], after i: Int) -> Int? {
        var j = i + 1
        while j < lines.count {
            if !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { return j }
            j += 1
        }
        return nil
    }

    private static func isWrote(_ lines: [String], _ i: Int) -> Bool {
        var joined = ""
        for k in 0..<3 where i + k < lines.count {
            joined += (k == 0 ? "" : " ") + lines[i + k].trimmingCharacters(in: .whitespaces)
            guard joined.count <= 400 else { return false }
            if matches(wroteLine, joined) { return true }
            if k == 0, matches(zhWroteLine, joined), joined.hasPrefix("在") || joined.contains("于") || joined.contains("於") {
                return true
            }
        }
        return false
    }

    private static func isHeaderBlock(_ lines: [String], _ i: Int) -> Bool {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        guard matches(headerStart, t) else { return false }
        var fields = 0
        var j = i + 1
        while j < lines.count, j <= i + 8 {
            let l = lines[j].trimmingCharacters(in: .whitespaces)
            if matches(headerField, l) { fields += 1 }
            j += 1
        }
        return fields >= 2
    }

    private static func cleanUnique(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if line == "-- " || t == "--" { break }                      // signature delimiter
            if t.hasPrefix(">") { continue }
            if t.count <= 60, matches(sentFrom, t) { continue }
            out.append(line)
        }
        return HTMLText.tidy(out.joined(separator: "\n"))
    }

    private static let keptForwardFields = rx(#"^\*?(?:from|date|sent|subject|发件人|发送时间|日期|时间|主题|主旨)\s*\*?\s*[:：]"#)

    private static func cleanForwarded(_ lines: [String]) -> String {
        var out: [String] = []
        var i = 0
        // Marker line(s) and the forwarded header block.
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || matches(forwardMarker, t) || matches(originalMarker, t) || matches(underscores, t) { i += 1; continue }
            break
        }
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; break }
            guard matches(headerStart, t) || matches(headerField, t) else { break }
            if matches(keptForwardFields, t) { out.append(t) }
            i += 1
        }
        if !out.isEmpty { out.append("") }
        for line in lines[min(i, lines.count)...] {
            var l = line
            while l.hasPrefix(">") { l.removeFirst(); if l.hasPrefix(" ") { l.removeFirst() } }
            out.append(l)
        }
        return HTMLText.tidy(out.joined(separator: "\n"))
    }

    // MARK: - URLs and markers in text

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"<?\b(?:https?://|www\.)[^\s<>"'　，。、）》」【】]+>?"#, options: [.caseInsensitive])

    struct FoundURL {
        var raw: String
        var range: NSRange          // including angle brackets when present
        var context: String?        // Outlook "Title<https://…>" anchor text
    }

    static func urls(in text: String) -> [FoundURL] {
        let ns = text as NSString
        var out: [FoundURL] = []
        for m in urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            let angled = s.hasPrefix("<")
            if angled { s.removeFirst() }
            if s.hasSuffix(">") { s.removeLast() }
            let raw = trimURL(s)
            guard !raw.isEmpty else { continue }
            var context: String?
            if angled {
                let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: m.range.location))
                let from = lineStart.location == NSNotFound ? 0 : lineStart.location + 1
                let prefix = ns.substring(with: NSRange(location: from, length: m.range.location - from))
                    .trimmingCharacters(in: .whitespaces)
                if PaperLinkClassifier.isTitleLike(prefix), !prefix.hasSuffix(":"), !prefix.hasSuffix(","),
                   !prefix.contains("<") { context = prefix }
            }
            out.append(FoundURL(raw: raw, range: m.range, context: context))
        }
        return out
    }

    /// Trailing punctuation that belongs to the sentence, not the URL (balanced ")" kept).
    static func trimURL(_ s: String) -> String {
        var t = s
        while let last = t.last {
            if ".,;:!?'\"*".contains(last) { t.removeLast(); continue }
            if last == ")", t.filter({ $0 == "(" }).count < t.filter({ $0 == ")" }).count { t.removeLast(); continue }
            if last == "]", t.filter({ $0 == "[" }).count < t.filter({ $0 == "]" }).count { t.removeLast(); continue }
            break
        }
        return t
    }

    static func replaceURLs(_ text: String, _ replacement: (String, URL?) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for found in urls(in: text) {
            let r = found.range
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let matched = ns.substring(with: r)
            let inner = matched.hasPrefix("<") ? String(matched.dropFirst()) : matched
            let trailing = String((inner.hasSuffix(">") ? String(inner.dropLast()) : inner).dropFirst(found.raw.count))
            if let last = out.last, !last.isWhitespace, last != "(" { out += " " }
            out += replacement(found.raw, LinkUnwrapper.url(from: found.raw))
            out += trailing
            cursor = r.location + r.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static let markerRegex = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")

    static func markerIndices(in text: String) -> [Int] {
        let ns = text as NSString
        var seen = Set<Int>()
        return markerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let i = Int(ns.substring(with: m.range(at: 1))), seen.insert(i).inserted else { return nil }
            return i
        }
    }

    static func replaceAnchorMarkers(_ text: String, _ name: (Int) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in markerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let replacement = Int(ns.substring(with: m.range(at: 1))).map(name) ?? ""
            if replacement.isEmpty { while out.last == " " { out.removeLast() } } else { out += replacement }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func stripURLsAndMarkers(_ text: String) -> String {
        let ns = text as NSString
        var s = urlRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let ns2 = s as NSString
        s = markerRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns2.length), withTemplate: " ")
        return s
    }

    // MARK: - Bare identifiers

    private static let arxivText = try! NSRegularExpression(
        pattern: #"\barxiv\s*[:：]?\s*(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[a-z]{2})?/\d{7})(?:v(\d+))?\b|\b10\.48550/arxiv\.(\d{4}\.\d{4,5})(?:v(\d+))?"#,
        options: [.caseInsensitive])

    static func identifierCandidates(in text: String) -> [MailCandidate] {
        var out: [MailCandidate] = []
        let ns = text as NSString
        for m in arxivText.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let idRange = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 3)
            let vRange = m.range(at: 1).location != NSNotFound ? m.range(at: 2) : m.range(at: 4)
            guard idRange.location != NSNotFound else { continue }
            let id = ns.substring(with: idRange)
            guard id.contains("/") || Identifiers.isValidArxivID(id) else { continue }
            let v = vRange.location == NSNotFound ? nil : Int(ns.substring(with: vRange))
            out.append(MailCandidate(cand: "", origin: .identifier, ids: PaperIDs(arxivID: id, arxivVersion: v),
                                     url: "https://arxiv.org/abs/\(id)", host: "arxiv.org", pdfState: .downloadable))
        }
        for (doi, _) in Identifiers.doiCandidates(in: text) where !Identifiers.isDataRepositoryDOI(doi) {
            var c = MailCandidate(cand: "", origin: .identifier, ids: PaperIDs(doi: doi), url: "https://doi.org/\(doi)",
                                  host: "doi.org")
            if let pre = PaperLinkClassifier.preprintDOI(doi) {
                c.host = pre.range(of: #"\.\d{8}$"#, options: .regularExpression) != nil ? "medrxiv.org" : "biorxiv.org"
            }
            c.pdfState = PaperLinkClassifier.pdfURL(for: c) != nil ? .downloadable : .needsPDF
            out.append(c)
        }
        return out
    }

    // MARK: - Redaction and caps

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-+])(?:\+\d{1,3}[\s.\-]?)?(?:\(\d{1,4}\)[\s.\-]?)?\d{2,4}(?:[\s.\-]\d{2,5}){1,4}(?![\w/\-])|(?<![\w+])1[3-9]\d{9}(?!\d)|(?<![\w/.\-])\+\d{9,14}(?!\d)"#)

    /// Phone numbers → `[phone]`; email addresses other than the sender's → `[email]`.
    package static func redact(_ text: String, sender: String) -> String {
        var s = text
        var ns = s as NSString
        for m in emailRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: m.range)
            if !sender.isEmpty, SenderMatcher.normalize(found) == sender { continue }
            s = (s as NSString).replacingCharacters(in: m.range, with: "[email]")
        }
        ns = s as NSString
        for m in phoneRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: m.range)
            guard isPhone(found) else { continue }
            s = (s as NSString).replacingCharacters(in: m.range, with: "[phone]")
        }
        return s
    }

    private static func isPhone(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        guard (10...15).contains(digits) else { return false }
        if s.range(of: #"^\d{4}[\-./]\d{1,2}[\-./]\d{1,2}"#, options: .regularExpression) != nil { return false }
        // "2609.12345"-style ids or dotted numbers with a 4-digit head are not phones.
        if !s.contains(" "), !s.contains("-"), !s.contains("("), !s.contains("+"), s.contains("."),
           s.split(separator: ".").first?.count == 4 { return false }
        return true
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.count > limit else { return s }
        let marker = "\n[…truncated]"
        var cut = String(s.prefix(max(0, limit - marker.count)))
        if let space = cut.lastIndex(where: { $0 == " " || $0 == "\n" }), cut.distance(from: space, to: cut.endIndex) < 40 {
            cut = String(cut[..<space])
        }
        // Never leave half a marker behind.
        if let open = cut.lastIndex(of: "["), !cut[open...].contains("]") { cut = String(cut[..<open]) }
        return cut + marker
    }

    private static let snippetMarker = try! NSRegularExpression(pattern: #"\s?\[(?:c\d+|link)(?: [^\]\s]+)?\]"#)

    static func snippet(_ text: String) -> String {
        let ns = text as NSString
        let stripped = snippetMarker.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let s = HTMLText.collapse(stripped)
        guard s.count > snippetLimit else { return s }
        return String(s.prefix(snippetLimit - 1)) + "…"
    }
}
