import Foundation

/// Local (no-AI) triage — the instant first pass for every card and the whole result for
/// senders whose AI policy is ask/never (MAIL_DESIGN Part A §2 "Heuristic triage").
///
/// - Kind from the sender rule (alert → `alertDigest`) plus en/zh request verbs.
/// - Due date only for person/advisor requests: explicit dates, weekdays and relative words in
///   sentences with a deadline trigger ("by / before / due / until…", 「截止 / 之前 / 前」),
///   resolved relative to the email's received date (not "now"), kept only inside
///   [received − 1 day, received + 180 days], with the verbatim evidence (≤ 80 chars).
/// - `ReadingCriteria`: exclude keywords → not relevant / 「无阅读需求」; include keywords and
///   research-interest overlap → highlighted; alert digests highlight at most `maxAlertPapers`.
/// - Documents and shared files: a person's or an advisor's email carrying a Word / slides
///   attachment or a link to a shared file (`MailItemOrigin.document` / `.shareLink`) is a reading
///   candidate — kind by the same phrase rules (request / journal club, else FYI), kept in 待处理
///   (`keepsDocumentPending`), with a slightly higher confidence for an FYI.
/// Mail text is untrusted: an alert that says "urgent, deadline tomorrow" gets neither.
package enum MailHeuristics {

    package static func triage(content: MailContent, extraction: MailExtraction, senderKind: SenderKind,
                               criteria: ReadingCriteria, now: Date, calendar: Calendar,
                               lang: UILang = .en,
                               dateOrder: SlashDateOrder = .mdy) -> (MailTriage, relevance: [String: MailItemRelevance]) {
        let (unique, _) = splitBody(extraction.bodyText)
        let subject = content.header.subject
        let requestText = subject + "\n" + unique
        let cands = extraction.candidates
        let isPerson = senderKind == .advisor || senderKind == .person || senderKind == .manual
        let hit = isPerson && matches(requestRegex, requestText)
        let journalClub = hit && matches(journalClubRegex, requestText)
        let entries = cands.filter { $0.origin == .alertEntry }

        // Kind
        var kind: MailRequestKind
        if senderKind == .alert {
            kind = cands.isEmpty ? .notPaper : .alertDigest
        } else if hit {
            kind = journalClub ? .journalClub : .advisorRequest
        } else if senderKind == .manual, entries.count >= 2, !extraction.isForwarded {
            kind = .alertDigest                                   // a dropped alert/TOC email
        } else {
            kind = cands.isEmpty ? .notPaper : .fyi
        }

        // Criteria
        let profile = InterestProfile(criteria)
        let excluded = Set(cands.filter { profile.isExcluded(candidateText($0)) }.map(\.cand))
        // The subject decides for the whole message; the body only when it lists no papers (a digest's
        // body contains every entry, and one excluded entry must not hide the others).
        let messageExcluded = profile.isExcluded(subject) || (cands.isEmpty && profile.isExcluded(String(unique.prefix(4000))))
        if !(isPerson && hit) {
            if messageExcluded || (!cands.isEmpty && excluded.count == cands.count) { kind = .notPaper }
        }
        let hasRequest = kind == .advisorRequest || kind == .journalClub

        // Relevance
        let relevance = relevanceMap(cands, kind: kind, extraction: extraction, unique: unique,
                                     profile: profile, excluded: excluded, maxAlert: criteria.maxAlertPapers)

        // Due date (people only; alerts never set deadlines)
        let due = hasRequest && isPerson
            ? findDue(in: unique, received: content.header.receivedAt, now: now, calendar: calendar, dateOrder: dateOrder)
            : nil

        let priority: Priority
        if hasRequest, senderKind == .advisor || senderKind == .person { priority = .high }
        else if kind == .notPaper { priority = .low }
        else { priority = .normal }

        let highlighted = relevance.values.filter { $0 == .highlighted }.count
        let summary: String
        switch kind {
        case .alertDigest:
            summary = alertSummary(total: cands.count, highlighted: highlighted, lang: lang)
        default:
            let s = summarize(unique)
            summary = s.isEmpty ? (kind == .notPaper ? noRequestSummary(lang) : containsPapersSummary(cands.count, lang)) : s
        }

        var confidence: Double
        switch kind {
        case .advisorRequest, .journalClub:
            confidence = 0.7 + (cands.isEmpty ? 0 : 0.15) + (due != nil ? 0.05 : 0) + (senderKind == .advisor ? 0.05 : 0)
        case .alertDigest: confidence = highlighted > 0 ? 0.8 : 0.65
        case .fyi: confidence = highlighted > 0 || (isPerson && hasDocuments(cands)) ? 0.6 : 0.5
        case .other: confidence = 0.4
        case .notPaper: confidence = 0.15
        }
        confidence = min(0.95, confidence)

        let triage = MailTriage(
            hasReadingRequest: hasRequest,
            requestKind: kind,
            summary: summary,
            requester: hasRequest ? (content.header.fromName ?? content.header.fromAddress) : nil,
            dueDate: due?.date,
            dueEvidence: due?.evidence,
            dueConfidence: due?.confidence,
            priority: priority,
            confidence: confidence
        )
        return (triage, relevance)
    }

    /// The candidates include an attached document or a link to a shared file.
    package static func hasDocuments(_ cands: [MailCandidate]) -> Bool {
        cands.contains { $0.origin == .document || $0.origin == .shareLink }
    }

    /// A person's or an advisor's email with an attached document or a shared-file link stays in
    /// 待处理 whatever the 「作为阅读需求保留」 kinds say — the manuscript must not vanish into
    /// 「无阅读需求」 — unless the user's exclude keywords made it `notPaper`.
    package static func keepsDocumentPending(_ triage: MailTriage, candidates: [MailCandidate],
                                             senderKind: SenderKind) -> Bool {
        guard senderKind == .advisor || senderKind == .person, triage.requestKind != .notPaper else { return false }
        return hasDocuments(candidates)
    }

    // MARK: - Body parts

    /// (text before the `[forwarded]` label, forwarded section).
    static func splitBody(_ body: String) -> (unique: String, forwarded: String?) {
        let label = MailExtractor.forwardedLabel
        if body.hasPrefix(label + "\n") { return ("", String(body.dropFirst(label.count + 1))) }
        guard let r = body.range(of: "\n" + label + "\n") else { return (body, nil) }
        return (String(body[..<r.lowerBound]), String(body[r.upperBound...]))
    }

    private static func candidateText(_ c: MailCandidate) -> String {
        [c.title ?? "", c.snippet ?? "", c.authors.joined(separator: ", ")].joined(separator: "\n")
    }

    // MARK: - Request detection

    private static func rx(_ p: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        catch { preconditionFailure("MailHeuristics: bad pattern \(p)") }
    }

    static let requestRegex = rx(
        #"\b(?:please|pls|plz|kindly)\s+(?:do\s+)?(?:read|skim|review|check(?:\s+out)?|go\s+(?:through|over)|look\s+(?:at|into|over)|take\s+a\s+(?:look|read)|have\s+a\s+(?:look|read)|present|prepare)\b"#
        + #"|\b(?:could|can|would|will)\s+you\s+(?:please\s+)?(?:read|present|review|take\s+a\s+look|have\s+a\s+look|look\s+(?:at|over|into)|go\s+(?:through|over)|skim|lead|discuss)\b"#
        + #"|\btake\s+a\s+look\b|\bjournal\s+club\b|\blab\s+meeting\b|\bgroup\s+meeting\b|\bdiscuss(?:ion)?\b"#
        + #"|\b(?:read|present)\s+(?:this|these|it|the\s+(?:attached|paper|papers|article|preprint))\b|\bmust[-\s]read\b|\bshould\s+read\b"#
        + #"|\bI'?d\s+like\s+you\s+to\s+(?:read|present|look)\b"#
        + #"|看一下|看一看|读一下|读一读|看看|读读|过一下|组会|汇报|讨论|阅读|研读|精读|读书会|文献分享|报告一下|讲一下|准备一下"#)
    static let journalClubRegex = rx(
        #"\bjournal\s+club\b|\blab\s+meeting\b|\bgroup\s+meeting\b|\bpresent(?:ation)?\b|组会|汇报|读书会|文献分享|报告|讲一下"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // MARK: - Relevance

    private static let ordinalWords = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
                                       "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10]
    private static let zhNumerals: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6,
                                                        "七": 7, "八": 8, "九": 9, "十": 10]
    private static let referenceRegex = rx(
        #"#\s?(\d{1,2})\b|\bno\.\s?(\d{1,2})\b|\bnumber\s+(\d{1,2})\b|\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+(?:one|paper|article|link|entry|preprint)\b|第\s*([一二两三四五六七八九十\d]{1,3})\s*[篇个條条项]"#)

    /// "see #3", "the second paper", 「第三篇」 → 1-based positions.
    static func references(in text: String) -> Set<Int> {
        let ns = text as NSString
        var out = Set<Int>()
        for m in referenceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for g in 1...5 where m.range(at: g).location != NSNotFound {
                let s = ns.substring(with: m.range(at: g)).lowercased()
                if let n = Int(s) { out.insert(n) }
                else if let n = ordinalWords[s] { out.insert(n) }
                else if s.count == 1, let n = zhNumerals[s.first!] { out.insert(n) }
                else if s.hasPrefix("十"), s.count == 2, let n = zhNumerals[s.last!] { out.insert(10 + n) }
            }
        }
        return out.filter { $0 >= 1 && $0 <= 99 }
    }

    private static func relevanceMap(_ cands: [MailCandidate], kind: MailRequestKind, extraction: MailExtraction,
                                     unique: String, profile: InterestProfile, excluded: Set<String>,
                                     maxAlert: Int) -> [String: MailItemRelevance] {
        var out: [String: MailItemRelevance] = [:]
        guard !cands.isEmpty else { return out }
        let body = extraction.bodyText
        let forwardStart = body.hasPrefix(MailExtractor.forwardedLabel + "\n") ? body.startIndex
            : body.range(of: "\n" + MailExtractor.forwardedLabel + "\n")?.lowerBound

        func inUnique(_ c: MailCandidate) -> Bool {
            if c.origin == .attachment || c.origin == .document { return true }
            var pos = body.range(of: "[\(c.cand) ")?.lowerBound
            if pos == nil, c.origin == .identifier, let key = c.ids.doi ?? c.ids.arxivID {
                pos = body.range(of: key, options: .caseInsensitive)?.lowerBound
            }
            if let pos { return forwardStart.map { pos < $0 } ?? true }
            if c.origin == .alertEntry { return false }
            return !extraction.isForwarded
        }

        let scores = Dictionary(uniqueKeysWithValues: cands.map { ($0.cand, profile.score(candidateText($0))) })
        let listed = cands.filter { !inUnique($0) }
        let refs = references(in: unique)
        // "#N" counts entries of the forwarded list, else the listed links (attachments are not numbered).
        let linked = cands.filter { $0.origin != .attachment && $0.origin != .document }
        let pool = !listed.isEmpty ? listed : (linked.isEmpty ? cands : linked)
        let referenced = Set(refs.compactMap { $0 <= pool.count ? pool[$0 - 1].cand : nil })

        // Interest ranking (alerts and forwarded lists): best `maxAlert` scoring ≥ 2 are highlighted.
        func rankedHighlights(_ list: [MailCandidate]) -> Set<String> {
            guard maxAlert > 0 else { return [] }
            let scored = list.filter { !excluded.contains($0.cand) && (scores[$0.cand] ?? 0) >= 2 }
            let sorted = scored.enumerated().sorted { a, b in
                let sa = scores[a.element.cand] ?? 0, sb = scores[b.element.cand] ?? 0
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            return Set(sorted.prefix(maxAlert).map(\.element.cand))
        }

        // "see #3" narrows the choice to the referenced entries (attachments always count as chosen).
        let attachments = Set(cands.filter { $0.origin == .attachment || $0.origin == .document }.map(\.cand))
        let uniqueCands = Set(cands.filter(inUnique).map(\.cand))
        let chosen = referenced.isEmpty ? uniqueCands : referenced.union(attachments)

        switch kind {
        case .advisorRequest, .journalClub:
            var requested = chosen
            if requested.isEmpty, cands.count <= 3 { requested = Set(cands.map(\.cand)) }
            let highlights = rankedHighlights(cands.filter { !requested.contains($0.cand) })
            for c in cands {
                out[c.cand] = requested.contains(c.cand) ? .requested : (highlights.contains(c.cand) ? .highlighted : .listed)
            }
        case .fyi:
            let shared = chosen
            let highlights = rankedHighlights(cands.filter { !shared.contains($0.cand) })
            for c in cands {
                let chosen = (shared.contains(c.cand) && !excluded.contains(c.cand)) || highlights.contains(c.cand)
                out[c.cand] = chosen ? .highlighted : .listed
            }
        case .alertDigest:
            let highlights = rankedHighlights(cands).union(referenced.subtracting(excluded))
            for c in cands { out[c.cand] = highlights.contains(c.cand) ? .highlighted : .listed }
        case .other, .notPaper:
            for c in cands { out[c.cand] = .listed }
        }
        return out
    }

    // MARK: - Interest profile

    struct InterestProfile {
        var include: [String]
        var exclude: [String]
        var phrases: [String]
        var words: Set<String>
        var cjk: [String]

        private static let stopwords: Set<String> = [
            "and", "for", "the", "with", "from", "into", "onto", "using", "based", "via", "that", "this", "these",
            "their", "our", "your", "new", "study", "studies", "analysis", "approach", "method", "methods", "data",
            "toward", "towards", "about", "between", "within", "across", "of", "in", "on", "to", "a", "an", "or",
            "its", "are", "is", "by", "at", "as", "interest", "interests", "research", "paper", "papers", "work",
        ]

        init(_ c: ReadingCriteria) {
            include = c.includeKeywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            exclude = c.excludeKeywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let rawPhrases = c.researchInterests
                .components(separatedBy: CharacterSet(charactersIn: ",;/|\n、，；&"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            phrases = rawPhrases.filter { InterestProfile.tokens($0).count >= 2 }.map { $0.lowercased() }
            words = Set(InterestProfile.tokens(c.researchInterests))
            cjk = InterestProfile.cjkRuns(c.researchInterests)
        }

        /// Lowercased, diacritic-folded ASCII-ish words (≥ 3 letters, crude plural stemming).
        static func tokens(_ s: String) -> [String] {
            let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return folded.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) && $0 != "-" })
                .map { w -> String in
                    var t = String(w).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    if t.count > 4, t.hasSuffix("s"), !t.hasSuffix("ss") { t.removeLast() }
                    return t
                }
                .filter { $0.count >= 3 && !stopwords.contains($0) }
        }

        static func cjkRuns(_ s: String) -> [String] {
            var out: [String] = []
            var cur = ""
            for ch in s {
                if ch.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) {
                    cur.append(ch)
                } else {
                    if cur.count >= 2 { out.append(cur) }
                    cur = ""
                }
            }
            if cur.count >= 2 { out.append(cur) }
            return out
        }

        static func contains(_ keyword: String, in text: String) -> Bool {
            let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return false }
            if k.count <= 4, k.allSatisfy({ $0.isASCII }) {
                let escaped = NSRegularExpression.escapedPattern(for: k)
                return text.range(of: "(?i)(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])", options: .regularExpression) != nil
            }
            return text.range(of: k, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        func isExcluded(_ text: String) -> Bool {
            exclude.contains { InterestProfile.contains($0, in: text) }
        }

        func score(_ text: String) -> Int {
            var s = 0
            for k in include where InterestProfile.contains(k, in: text) { s += 3 }
            let lower = text.lowercased()
            for p in phrases where lower.contains(p) { s += 2 }
            for r in cjk where text.contains(r) { s += 2 }
            if !words.isEmpty { s += Set(InterestProfile.tokens(text)).intersection(words).count }
            return s
        }
    }

    // MARK: - Summary

    private static let greeting = rx(#"^(?:hi|hello|hey|dear|good\s+(?:morning|afternoon|evening)|greetings)\b[^.!?\n]{0,40}[,!:：，]?$"#)
    private static let zhGreeting = rx(#"^(?:.{0,10}(?:老师|同学|大家|各位)[^，,。]{0,4}好|你好|您好|大家好)[，,!！:：。]?.{0,3}$"#)
    /// "小易：", "Yi," — a short salutation line.
    private static let addressLine = rx(#"^[^\s，。！？.!?]{1,12}\s?[：:,，]$"#)
    private static let signOff = rx(#"^(?:thanks|thank you|many thanks|best|cheers|regards|best regards|kind regards|warm regards|sincerely|谢谢|多谢|祝好|此致|敬礼)\b.{0,30}$"#)
    private static let markerRegex = try! NSRegularExpression(pattern: #"\s?\[(?:c\d+|link)(?: [^\]\s]+)?\]"#)

    /// First two sentences of the unique body (greetings skipped, nothing after a sign-off), ≤ 240 chars.
    static func summarize(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if matches(signOff, line) { break }
            if matches(greeting, line) || matches(zhGreeting, line) || matches(addressLine, line) { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n")
        let ns = joined as NSString
        let clean = markerRegex.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let sentences = sentenceRanges(clean).map { HTMLText.collapse(String(clean[$0])) }
            .filter { $0.contains(where: \.isLetter) }
        var out = sentences.prefix(2).joined(separator: " ")
        if out.count > 240 {
            out = String(out.prefix(239))
            if let space = out.lastIndex(of: " "), out.distance(from: space, to: out.endIndex) < 30 { out = String(out[..<space]) }
            out += "…"
        }
        return out
    }

    static func alertSummary(total: Int, highlighted: Int, lang: UILang) -> String {
        switch lang {
        case .zh:
            return highlighted > 0 ? "论文提醒：共 \(total) 篇，其中 \(highlighted) 篇符合你的兴趣。" : "论文提醒：共 \(total) 篇。"
        case .en:
            let papers = total == 1 ? "1 paper" : "\(total) papers"
            return highlighted > 0 ? "Alert digest with \(papers); \(highlighted) match your interests." : "Alert digest with \(papers)."
        }
    }

    static func noRequestSummary(_ lang: UILang) -> String {
        lang == .zh ? "未发现论文阅读需求。" : "No paper-reading request found."
    }

    static func containsPapersSummary(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "邮件中包含 \(n) 篇论文。" : "The email contains \(n) paper(s)."
    }

    private static let abbreviations: Set<String> = [
        "fig", "figs", "e.g", "i.e", "al", "dr", "prof", "vs", "no", "ref", "refs", "eq", "mr", "ms", "mrs", "st",
        "approx", "sec", "ch", "vol", "pp", "cf", "ca", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "inc", "ltd", "co", "jr", "sr",
    ]

    /// Sentence ranges: split after . ! ? 。！？ and newlines, but not after abbreviations
    /// ("Fig. 2", "et al."), initials or inside numbers ("2.5").
    static func sentenceRanges(_ s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            let next = s.index(after: i)
            var boundary = false
            if "!?。！？\n".contains(ch) {
                boundary = true
            } else if ch == "." {
                let nextCh = next < s.endIndex ? s[next] : " "
                if nextCh == " " || nextCh == "\n" {
                    let word = s[start..<i].split(whereSeparator: { $0 == " " || $0 == "(" }).last.map { $0.lowercased() } ?? ""
                    let isInitial = word.count == 1 && word.first!.isLetter
                    boundary = !abbreviations.contains(word) && !isInitial
                }
            }
            if boundary {
                let r = start..<next
                if !s[r].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(r) }
                start = next
            }
            i = next
        }
        if start < s.endIndex, !s[start...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(start..<s.endIndex) }
        return out
    }

    // MARK: - Due dates

    package struct DueHit: Sendable, Equatable {
        package var date: LocalDate
        package var evidence: String
        package var confidence: Double
    }

    private static let triggerRegex = rx(
        #"\b(?:by|before|due|deadline|until|till|no\s+later\s+than|ahead\s+of|prior\s+to)\b|截止|截至|之前|以前|最晚|之内|以内|前"#)

    private static let monthNames = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    private static let monthDayRegex = rx(#"\b("# + monthNames + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?!\d)"#)
    private static let dayMonthRegex = rx(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + monthNames + #")\.?(?:,?\s+(\d{4}))?\b"#)
    private static let isoRegex = rx(#"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    private static let slashRegex = rx(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"#)
    private static let zhDateRegex = rx(#"(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*[日号號]"#)
    private static let weekdayRegex = rx(#"\b(?:(this|next|coming)\s+)?(mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?\b"#)
    private static let zhWeekdayRegex = rx(#"(下下|下个|下|本|这个|这|今)?(?:周|星期|礼拜|禮拜)([一二三四五六日天1-7])"#)
    private static let relativeRegex = rx(
        #"\b(today|tonight|tomorrow|eod|eow|end\s+of\s+(?:the\s+|this\s+)?(?:day|week|month)|next\s+week|this\s+weekend|the\s+weekend)\b|(大后天|后天|明天|明日|今天|今晚|本周末|这周末|周末|下周|月底)"#)

    private struct DateMatch {
        var date: LocalDate
        var range: NSRange
        var confidence: Double
    }

    /// The first deadline-like date in `text`, resolved relative to `received`. A slash date
    /// ("3/10") reads month first (`.mdy`, every install before `mail.dateOrder` existed) or day
    /// first (`.dmy`); `.auto` follows the Mac's region.
    package static func findDue(in text: String, received: Date, now: Date, calendar: Calendar,
                                dateOrder: SlashDateOrder = .mdy) -> DueHit? {
        let order = dateOrder.resolved()
        let base = LocalDate(received, calendar: calendar)
        let lower = base.adding(days: -1, calendar: gmt), upper = base.adding(days: 180, calendar: gmt)
        for r in sentenceRanges(text) {
            let sentence = String(text[r])
            let ns = sentence as NSString
            let full = NSRange(location: 0, length: ns.length)
            let triggers = triggerRegex.matches(in: sentence, range: full).map(\.range)
            guard !triggers.isEmpty else { continue }
            var found = dateMatches(sentence, base: base, calendar: calendar, slashOrder: order)
            if found.isEmpty { found = detectorMatches(sentence, base: base, received: received, now: now, calendar: calendar) }
            let inWindow = found.filter { $0.date >= lower && $0.date <= upper }
            guard !inWindow.isEmpty else { continue }
            // Prefer the date closest to a trigger word.
            func distance(_ m: DateMatch) -> Int {
                triggers.map { t in
                    if NSMaxRange(t) <= m.range.location { return m.range.location - NSMaxRange(t) }
                    if NSMaxRange(m.range) <= t.location { return t.location - NSMaxRange(m.range) }
                    return 0
                }.min() ?? Int.max
            }
            guard let best = inWindow.min(by: { distance($0) < distance($1) }) else { continue }
            let d = distance(best)
            var confidence = best.confidence + (d <= 12 ? 0.1 : (d > 40 ? -0.15 : 0))
            if best.date < base { confidence = min(confidence, 0.3) }
            let trigger = triggers.min(by: { abs($0.location - best.range.location) < abs($1.location - best.range.location) })!
            let evidence = evidenceText(sentence, date: best.range, trigger: trigger)
            return DueHit(date: best.date, evidence: evidence, confidence: max(0.1, min(0.95, confidence)))
        }
        return nil
    }

    /// Verbatim phrase (≤ 80 chars) around the trigger and the date, grown by whole words.
    private static func evidenceText(_ sentence: String, date: NSRange, trigger: NSRange) -> String {
        let ns = sentence as NSString
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        var start = min(date.location, trigger.location)
        var end = max(NSMaxRange(date), NSMaxRange(trigger))
        if end - start > 80 { start = date.location; end = NSMaxRange(date) }
        let limit = 80
        func isSpace(_ i: Int) -> Bool { let c = ns.character(at: i); return c == 0x20 || c == 0x0A || c == 0x09 }
        // Finish the words the phrase starts/ends in.
        while start > 0, !isSpace(start - 1), end - start < limit { start -= 1 }
        while end < ns.length, !isSpace(end), end - start < limit { end += 1 }
        var grew = true
        while grew {
            grew = false
            if end < ns.length {
                var e = end + 1
                while e < ns.length, !isSpace(e) { e += 1 }
                if e - start <= limit { end = e; grew = true }
            }
            if start > 0 {
                var b = start - 1
                while b > 0, isSpace(b) { b -= 1 }
                while b > 0, !isSpace(b - 1) { b -= 1 }
                if end - b <= limit { start = b; grew = true }
            }
        }
        let piece = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(piece.prefix(limit))
    }

    private static func dateMatches(_ s: String, base: LocalDate, calendar: Calendar,
                                    slashOrder: SlashDateOrder) -> [DateMatch] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [DateMatch] = []
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        func monthIndex(_ name: String) -> Int? {
            let p = String(name.lowercased().prefix(3))
            return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: p).map { $0 + 1 }
        }
        func add(_ y: Int?, _ mo: Int, _ d: Int, _ range: NSRange, _ conf: Double) {
            if let date = resolve(year: y, month: mo, day: d, base: base) { out.append(DateMatch(date: date, range: range, confidence: conf)) }
        }
        for m in monthDayRegex.matches(in: s, range: full) {
            if let mo = group(m, 1).flatMap(monthIndex), let d = group(m, 2).flatMap({ Int($0) }) {
                add(group(m, 3).flatMap { Int($0) }, mo, d, m.range, 0.85)
            }
        }
        for m in dayMonthRegex.matches(in: s, range: full) {
            if let d = group(m, 1).flatMap({ Int($0) }), let mo = group(m, 2).flatMap(monthIndex) {
                add(group(m, 3).flatMap { Int($0) }, mo, d, m.range, 0.85)
            }
        }
        for m in isoRegex.matches(in: s, range: full) {
            if let y = group(m, 1).flatMap({ Int($0) }), let mo = group(m, 2).flatMap({ Int($0) }), let d = group(m, 3).flatMap({ Int($0) }) {
                add(y, mo, d, m.range, 0.85)
            }
        }
        for m in slashRegex.matches(in: s, range: full) {
            if let first = group(m, 1).flatMap({ Int($0) }), let second = group(m, 2).flatMap({ Int($0) }) {
                let (mo, d) = slashOrder == .dmy ? (second, first) : (first, second)
                var y = group(m, 3).flatMap { Int($0) }
                if let yy = y, yy < 100 { y = 2000 + yy }
                add(y, mo, d, m.range, 0.7)
            }
        }
        for m in zhDateRegex.matches(in: s, range: full) {
            if let mo = group(m, 2).flatMap({ Int($0) }), let d = group(m, 3).flatMap({ Int($0) }) {
                add(group(m, 1).flatMap { Int($0) }, mo, d, m.range, 0.85)
            }
        }
        for m in weekdayRegex.matches(in: s, range: full) {
            guard let name = group(m, 2)?.lowercased(), let w = enWeekday(name) else { continue }
            // "sat"/"sun"/"wed" as bare words are fine; "mon" in "month" is excluded by \b.
            let modifier = group(m, 1)?.lowercased()
            if let date = weekdayDate(w, modifier: modifier == "next" ? .nextWeek : (modifier == "this" ? .thisWeek : .upcoming),
                                      base: base, calendar: calendar) {
                out.append(DateMatch(date: date, range: m.range, confidence: modifier == "next" ? 0.55 : 0.75))
            }
        }
        for m in zhWeekdayRegex.matches(in: s, range: full) {
            guard let ch = group(m, 2), let w = zhWeekday(ch) else { continue }
            let mod = group(m, 1)
            let kind: WeekModifier
            switch mod {
            case "下下": kind = .weekAfterNext
            case "下", "下个": kind = .nextWeek
            case "本", "这", "这个", "今": kind = .thisWeek
            default: kind = .upcoming
            }
            if let date = weekdayDate(w, modifier: kind, base: base, calendar: calendar) {
                out.append(DateMatch(date: date, range: m.range, confidence: 0.75))
            }
        }
        for m in relativeRegex.matches(in: s, range: full) {
            let word = (group(m, 1) ?? group(m, 2) ?? "").lowercased().replacingOccurrences(of: "  ", with: " ")
            if let (date, conf) = relativeDate(word, base: base, calendar: calendar) {
                out.append(DateMatch(date: date, range: m.range, confidence: conf))
            }
        }
        return out
    }

    /// Month/day with an optional year; a missing year is the next occurrence on/after received − 1 day.
    private static func resolve(year: Int?, month: Int, day: Int, base: LocalDate) -> LocalDate? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        if let y = year { return LocalDate(iso: String(format: "%04d-%02d-%02d", y, month, day)) }
        guard let d = LocalDate(iso: String(format: "%04d-%02d-%02d", base.year, month, day)) else { return nil }
        if d < base.adding(days: -1, calendar: gmt) {
            return LocalDate(iso: String(format: "%04d-%02d-%02d", base.year + 1, month, day))
        }
        return d
    }

    private static let gmt: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private enum WeekModifier { case upcoming, thisWeek, nextWeek, weekAfterNext }

    private static func enWeekday(_ name: String) -> Int? {
        switch String(name.prefix(2)) {
        case "su": return 1
        case "mo": return 2
        case "tu": return 3
        case "we": return 4
        case "th": return 5
        case "fr": return 6
        case "sa": return 7
        default: return nil
        }
    }

    private static func zhWeekday(_ ch: String) -> Int? {
        switch ch {
        case "一", "1": return 2
        case "二", "2": return 3
        case "三", "3": return 4
        case "四", "4": return 5
        case "五", "5": return 6
        case "六", "6": return 7
        case "日", "天", "7": return 1
        default: return nil
        }
    }

    /// Weekday (1 = Sunday … 7 = Saturday) relative to `base`. Weeks start on Monday.
    /// upcoming: the next such day after base (a week later when it is today); thisWeek: in
    /// base's Monday-week; nextWeek / weekAfterNext: in the following week(s).
    private static func weekdayDate(_ w: Int, modifier: WeekModifier, base: LocalDate, calendar: Calendar) -> LocalDate? {
        let bw = base.weekday(calendar: gmt)
        switch modifier {
        case .upcoming:
            var delta = (w - bw + 7) % 7
            if delta == 0 { delta = 7 }
            return base.adding(days: delta, calendar: gmt) as LocalDate?
        case .thisWeek, .nextWeek, .weekAfterNext:
            let mondayOffset = (bw + 5) % 7                     // days since Monday
            let targetOffset = (w + 5) % 7
            let weeks = modifier == .thisWeek ? 0 : (modifier == .nextWeek ? 1 : 2)
            return base.adding(days: targetOffset - mondayOffset + 7 * weeks, calendar: gmt) as LocalDate?
        }
    }

    private static func relativeDate(_ word: String, base: LocalDate, calendar: Calendar) -> (LocalDate, Double)? {
        let bw = base.weekday(calendar: gmt)
        let mondayOffset = (bw + 5) % 7
        func add(_ n: Int) -> LocalDate? { base.adding(days: n, calendar: gmt) as LocalDate? }
        let w = word.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch w {
        case "today", "tonight", "eod", "end of the day", "end of day", "end of this day", "今天", "今晚": return add(0).map { ($0, 0.7) }
        case "tomorrow", "明天", "明日": return add(1).map { ($0, 0.75) }
        case "后天": return add(2).map { ($0, 0.75) }
        case "大后天": return add(3).map { ($0, 0.7) }
        case "eow", "end of the week", "end of week", "end of this week": return add(4 - mondayOffset).flatMap { d in d >= base ? (d, 0.5) : nil }
        case "this weekend", "the weekend", "周末", "本周末", "这周末": return add(5 - mondayOffset).map { ($0, 0.4) }
        case "next week", "下周": return add(7 - mondayOffset).map { ($0, 0.4) }
        case "end of the month", "end of month", "end of this month", "月底":
            var c = DateComponents(); c.year = base.year; c.month = base.month + 1; c.day = 0
            guard let date = gmt.date(from: c) else { return nil }
            return (LocalDate(date, calendar: gmt), 0.5)
        default: return nil
        }
    }

    /// NSDataDetector for phrasings the patterns above miss ("Oct. 3rd", "the 3rd of October").
    /// Absolute dates are year-corrected into the window; relative ones are shifted from "now"
    /// back to the received day (the detector resolves them against the current date).
    private static func detectorMatches(_ s: String, base: LocalDate, received: Date, now: Date,
                                        calendar: Calendar) -> [DateMatch] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let ns = s as NSString
        let today = LocalDate(now, calendar: calendar)
        let shift = base.days(from: today)
        var out: [DateMatch] = []
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let date = m.date else { continue }
            let text = ns.substring(with: m.range)
            let hasDigit = text.contains(where: \.isNumber)
            let hasWord = text.contains(where: \.isLetter)
            guard hasWord else { continue }                            // bare "3/10" is handled above
            var d = LocalDate(date, calendar: calendar)
            if hasDigit {
                for delta in [0, 1, -1] {
                    if let c = LocalDate(iso: String(format: "%04d-%02d-%02d", base.year + delta, d.month, d.day)),
                       c >= base.adding(days: -1, calendar: gmt), c <= base.adding(days: 180, calendar: gmt) {
                        d = c; break
                    }
                }
            } else {
                d = d.adding(days: shift, calendar: gmt)
            }
            out.append(DateMatch(date: d, range: m.range, confidence: hasDigit ? 0.5 : 0.45))
        }
        return out
    }
}
