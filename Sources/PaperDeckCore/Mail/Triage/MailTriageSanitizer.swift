import Foundation

/// Turns the model's triage output into a `MailTriage` we are willing to store and render
/// (defence in depth after the prompt, in the `CardSanitizer` style — OWASP LLM01): the email
/// was untrusted input, so the output is too.
///
/// - Text: hidden characters (controls, bidi overrides, zero-width, Unicode tags) stripped,
///   whitespace collapsed, URLs → `[link]`, email addresses → `[email]`, phone numbers →
///   `[phone]`, block tags neutralized; `summary` ≤ 300, `why` ≤ 140 characters.
/// - Papers: `ref` survives only when it names a known candidate (`cN`); a DOI / arXiv id only
///   counts (`PaperHint.ids`) when it appears in the email text or a candidate — anything else
///   goes to `unverifiedIDs` for the integration to verify (Crossref / arXiv) before any use.
///   Model-only titles are hints too (`needsVerification`). Nothing here ever downloads.
/// - `due_date` survives only inside [received − 1 d, received + 180 d] with an evidence phrase
///   that fuzzy-matches the subject or body; `priority` high only for advisor / person senders;
///   an alert sender can never produce a personal request.
/// - The result is data: it never carries actions and never changes message state by itself.
package enum MailTriageSanitizer {
    package enum SanitizeError: Error, Equatable {
        case notAnObject
        /// `has_reading_request` is missing or not a boolean.
        case missingDecision
    }

    /// One paper the model mentioned, after grounding.
    package struct PaperHint: Sendable, Equatable {
        /// A known candidate id ("c3") — either the model's ref or a candidate it matched by id / title.
        package var ref: String?
        package var title: String?
        /// DOI / arXiv id that also appear in the email text or a candidate.
        package var ids: PaperIDs
        /// Syntactically valid ids only the model produced: verify before use, never download from them.
        package var unverifiedIDs: PaperIDs
        package var relevance: MailItemRelevance
        package var why: String
        package var confidence: Double

        package init(ref: String? = nil, title: String? = nil, ids: PaperIDs = PaperIDs(),
                     unverifiedIDs: PaperIDs = PaperIDs(), relevance: MailItemRelevance = .listed, why: String = "",
                     confidence: Double = 0.5) {
            self.ref = ref; self.title = title; self.ids = ids; self.unverifiedIDs = unverifiedIDs
            self.relevance = relevance; self.why = why; self.confidence = confidence
        }

        /// Backed by something PaperDeck found locally (a candidate or an id present in the email).
        package var isGrounded: Bool { ref != nil || !ids.isEmpty }
        /// Model-only entry (title and/or unverified ids): the integration must verify it first
        /// (Crossref `query.bibliographic` + `TitleSimilarity` ≥ 0.92) or show it as a plain citation.
        package var needsVerification: Bool { !isGrounded }
    }

    package static let summaryLimit = 300
    package static let whyLimit = 140
    package static let titleLimit = 300
    package static let requesterLimit = 80
    package static let evidenceLimit = 80
    package static let maxPapers = 30
    package static let dueDaysBefore = 1
    package static let dueDaysAfter = 180

    /// - Parameters:
    ///   - items: the message's candidates (`mail_item` rows) — the only refs that survive.
    ///   - bodyText: the stored body (with `[cN]` markers) used to ground ids and due evidence.
    ///   - maxAlertPapers: alert digests keep at most this many requested / highlighted papers
    ///     (the rest become `listed`), `ReadingCriteria.maxAlertPapers`.
    ///   - calendar: the user's calendar (received day for the due-date window).
    package static func sanitize(_ raw: JSONValue, message: MailMessage, items: [MailItem], bodyText: String,
                                 maxAlertPapers: Int = 8,
                                 calendar: Calendar = .current) throws -> (MailTriage, [PaperHint]) {
        guard let o = rootObject(raw) else { throw SanitizeError.notAnObject }
        guard let decision = bool(o["has_reading_request"]) else { throw SanitizeError.missingDecision }

        var kind = MailRequestKind(rawValue: enumString(o["request_kind"])) ?? .other
        // Public alert content can never be a personal request.
        if message.senderKind == .alert, kind != .notPaper { kind = .alertDigest }
        let hasRequest = kind == .notPaper ? false : decision

        let summary = outputText(o["summary"], limit: summaryLimit)
        let requester = optional(outputText(o["requester"], limit: requesterLimit))

        var priority: Priority
        switch enumString(o["priority"]) {
        case "high": priority = .high
        case "low": priority = .low
        default: priority = .normal
        }
        if priority == .high, message.senderKind != .advisor, message.senderKind != .person { priority = .normal }

        let haystack = message.subject + "\n" + bodyText
        let due = dueDate(o, message: message, haystack: haystack, calendar: calendar)

        let hints = papers(o["papers"], message: message, items: items, bodyText: haystack, kind: kind,
                           maxAlertPapers: maxAlertPapers)
        let focus = hints.filter { $0.relevance != .listed }.map(\.confidence)
        let best = (focus.isEmpty ? hints.map(\.confidence) : focus).max()
        let confidence = hasRequest ? (best ?? 0.75) : 0.2

        let triage = MailTriage(hasReadingRequest: hasRequest, requestKind: kind, summary: summary,
                                requester: requester, dueDate: due?.date, dueEvidence: due?.evidence,
                                dueConfidence: due?.confidence, priority: priority, confidence: confidence)
        return (triage, hints)
    }

    // MARK: - Due date

    private struct Due {
        var date: LocalDate
        var evidence: String
        var confidence: Double
    }

    private static func dueDate(_ o: [String: JSONValue], message: MailMessage, haystack: String,
                                calendar: Calendar) -> Due? {
        let raw = outputText(o["due_date"], limit: 40)
        guard raw.count >= 10, let date = LocalDate(iso: String(raw.prefix(10))) else { return nil }
        let received = LocalDate(message.receivedAt, calendar: calendar)
        guard date >= received.adding(days: -dueDaysBefore, calendar: calendar),
              date <= received.adding(days: dueDaysAfter, calendar: calendar) else { return nil }
        let evidence = outputText(o["due_evidence"], limit: 400)
        guard !evidence.isEmpty, evidenceMatches(evidence, in: haystack) else { return nil }
        return Due(date: date, evidence: CardSanitizer.truncate(evidence, to: evidenceLimit),
                   confidence: dueConfidence(evidence))
    }

    private static let explicitDate = try! NSRegularExpression(
        pattern: #"\d|\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|月|日|号"#,
        options: [.caseInsensitive])
    private static let relativeDate = try! NSRegularExpression(
        pattern: #"\b(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?\b|\b(?:tomorrow|tonight|next week|end of (?:the )?week|this week)\b|周|星期|明天|下周|本周"#,
        options: [.caseInsensitive])

    /// Explicit dates are high confidence, weekday / relative phrases medium, anything else low.
    private static func dueConfidence(_ evidence: String) -> Double {
        let range = NSRange(location: 0, length: (evidence as NSString).length)
        if explicitDate.firstMatch(in: evidence, range: range) != nil { return 0.9 }
        if relativeDate.firstMatch(in: evidence, range: range) != nil { return 0.75 }
        return 0.6
    }

    /// The evidence must be (nearly) verbatim: equal after folding case / width / diacritics and
    /// dropping punctuation and spacing, or — for longer Latin phrases — ≥ 80 % of its words present.
    static func evidenceMatches(_ evidence: String, in haystack: String) -> Bool {
        let e = folded(evidence), h = folded(haystack)
        let ec = e.replacingOccurrences(of: " ", with: "")
        guard ec.count >= 3 else { return false }
        if h.replacingOccurrences(of: " ", with: "").contains(ec) { return true }
        let tokens = e.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard tokens.count >= 4 else { return false }
        let words = Set(h.split(separator: " ").map(String.init))
        let hits = tokens.filter { words.contains($0) }.count
        return Double(hits) / Double(tokens.count) >= 0.8
    }

    /// Lowercased, diacritic/width-folded alphanumeric words separated by single spaces.
    private static func folded(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
        var out = String.UnicodeScalarView()
        var pending = false
        for u in f.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                if pending, !out.isEmpty { out.append(" ") }
                pending = false
                out.append(u)
            } else {
                pending = true
            }
        }
        return String(out)
    }

    // MARK: - Papers

    private static func papers(_ v: JSONValue?, message: MailMessage, items: [MailItem], bodyText: String,
                               kind: MailRequestKind, maxAlertPapers: Int) -> [PaperHint] {
        var byCand: [String: MailItem] = [:]
        for item in items { byCand[item.cand.lowercased()] = byCand[item.cand.lowercased()] ?? item }
        let text = bodyText.lowercased()
        let itemURLs = items.flatMap { [$0.url, $0.urlOriginal].compactMap { $0?.lowercased() } }
            .map { $0.removingPercentEncoding ?? $0 }

        func doiPresent(_ doi: String) -> Bool {
            text.contains(doi) || items.contains { $0.ids.doi?.lowercased() == doi || $0.ids.publishedDOI?.lowercased() == doi }
                || itemURLs.contains { $0.contains(doi) }
        }
        func arxivPresent(_ id: String) -> Bool {
            let l = id.lowercased()
            return text.contains(l) || items.contains { $0.ids.arxivID?.lowercased() == l } || itemURLs.contains { $0.contains(l) }
        }

        var out: [PaperHint] = []
        var usedRefs = Set<String>()
        var usedIDs = Set<String>()
        for entry in list(v).prefix(maxPapers * 2) {
            guard let p = entry.objectValue else { continue }
            var ref = normalizeRef(p["ref"]).flatMap { byCand[$0] != nil ? $0 : nil }
            let title = optional(outputText(p["title"], limit: titleLimit))
            var ids = PaperIDs(), unverified = PaperIDs()
            if let doi = doi(p["doi"]) {
                if doiPresent(doi) { ids.doi = doi } else { unverified.doi = doi }
            }
            if let arxiv = arxivID(p["arxiv_id"]) {
                if arxivPresent(arxiv.id) {
                    ids.arxivID = arxiv.id; ids.arxivVersion = arxiv.version
                } else {
                    unverified.arxivID = arxiv.id; unverified.arxivVersion = arxiv.version
                }
            }
            if ref == nil {
                ref = items.first { item in
                    if let d = ids.doi, item.ids.doi?.lowercased() == d { return true }
                    if let a = ids.arxivID, item.ids.arxivID?.lowercased() == a.lowercased() { return true }
                    if let t = title, let it = item.title, TitleSimilarity.matches(t, it) { return true }
                    return false
                }?.cand.lowercased()
            }
            guard ref != nil || title != nil || !ids.isEmpty || !unverified.isEmpty else { continue }
            if let r = ref {
                guard usedRefs.insert(r).inserted else { continue }
            }
            let key = ids.doi ?? ids.arxivID ?? unverified.doi ?? unverified.arxivID
            if ref == nil, let key {
                guard usedIDs.insert(key).inserted else { continue }
            } else if let key {
                usedIDs.insert(key)
            }

            var relevance = MailItemRelevance(rawValue: enumString(p["relevance"])) ?? .listed
            if message.senderKind == .alert, relevance == .requested { relevance = .highlighted }
            out.append(PaperHint(ref: ref, title: title, ids: ids, unverifiedIDs: unverified, relevance: relevance,
                                 why: outputText(p["why"], limit: whyLimit),
                                 confidence: clamp01(number(p["confidence"]) ?? 0.5)))
            if out.count == maxPapers { break }
        }

        // Alert digests: at most `maxAlertPapers` requested / highlighted entries, the most confident ones.
        if kind == .alertDigest {
            let cap = max(0, maxAlertPapers)
            let focus = out.indices.filter { out[$0].relevance != .listed }
            if focus.count > cap {
                let keep = Set(focus.sorted { (out[$0].confidence, -$0) > (out[$1].confidence, -$1) }.prefix(cap))
                for i in focus where !keep.contains(i) { out[i].relevance = .listed }
            }
        }
        return out
    }

    private static let refRegex = try! NSRegularExpression(pattern: #"^\[?\s*(c\d{1,4})(?![0-9])"#, options: [.caseInsensitive])

    /// "c3", "C3", "[c3]", "[c3 biorxiv.org]" → "c3".
    private static func normalizeRef(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let ns = s as NSString
        guard let m = refRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1)).lowercased()
    }

    private static func doi(_ v: JSONValue?) -> String? {
        guard var s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty,
              s.count <= 250 else { return nil }
        s = String(s.unicodeScalars.filter { !MailTriageText.isHidden($0) }.map(Character.init))
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"]
        where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return Identifiers.cleanDOI(s)
    }

    private static let arxivRegex = try! NSRegularExpression(
        pattern: #"^(?:arxiv:\s*|https?://(?:www\.)?arxiv\.org/(?:abs|pdf|html)/)?(\d{4}\.\d{4,5}|[a-z][a-z\-]+(?:\.[a-z]{2})?/\d{7})(?:v(\d{1,3}))?(?:\.pdf)?$"#,
        options: [.caseInsensitive])

    private static func arxivID(_ v: JSONValue?) -> (id: String, version: Int?)? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= 80 else {
            return nil
        }
        let ns = s as NSString
        guard let m = arxivRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let id = ns.substring(with: m.range(at: 1))
        guard Identifiers.isValidArxivID(id) else { return nil }
        let vr = m.range(at: 2)
        return (id, vr.location == NSNotFound ? nil : Int(ns.substring(with: vr)))
    }

    // MARK: - Output text hygiene

    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]\n]{0,200})\]\([^)\n]{0,2000}\)"#)
    /// Plain single-line text with no links, addresses or phone numbers, capped at `limit`.
    static func outputText(_ v: JSONValue?, limit: Int) -> String {
        let raw: String
        switch v {
        case .string(let s)?: raw = s
        case .number(let n)? where n.isFinite:
            raw = n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: return ""
        }
        var s = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(20_000).filter { !MailTriageText.isHidden($0) }))
        s = CardSanitizer.clean(s)
        s = MailTriageText.replace(markdownLink, in: s) { m, ns in ns.substring(with: m.range(at: 1)) }
        s = MailTriageText.replace(MailTriageText.emailRegex, in: s) { _, _ in "[email]" }
        s = MailTriageText.replace(MailTriageText.urlRegex, in: s) { m, ns in
            let url = ns.substring(with: m.range).lowercased()
            if url.hasPrefix("mailto:") { return "[email]" }
            if url.hasPrefix("tel:") || url.hasPrefix("sms:") { return "[phone]" }
            return "[link]"
        }
        s = MailTriageText.replace(MailTriageText.phoneRegex, in: s) { _, _ in "[phone]" }
        s = MailTriageText.neutralizeBlockTags(s)
        return CardSanitizer.truncate(CardSanitizer.clean(s), to: limit)
    }

    // MARK: - Lenient JSON access

    /// Accepts the object itself or a JSON string that encodes it.
    private static func rootObject(_ raw: JSONValue) -> [String: JSONValue]? {
        if let o = raw.objectValue { return o }
        if let s = raw.stringValue, let data = s.data(using: .utf8),
           let v = try? JSONDecoder().decode(JSONValue.self, from: data) { return v.objectValue }
        return nil
    }

    private static func list(_ v: JSONValue?) -> [JSONValue] {
        switch v {
        case .array(let a)?: return a
        case nil, .null?: return []
        case let other?: return [other]
        }
    }

    private static func bool(_ v: JSONValue?) -> Bool? {
        switch v {
        case .bool(let b)?: return b
        case .string(let s)?:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    private static func enumString(_ v: JSONValue?) -> String {
        v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func optional(_ s: String) -> String? { s.isEmpty ? nil : s }

    private static func clamp01(_ d: Double) -> Double { min(max(d, 0), 1) }
}
