import Foundation

/// A viewer's window title, cleaned for matching (LN §5): app and site suffixes, status words,
/// page counters, bullets and the `.pdf` extension go; a DOI, an arXiv id, the file name and a
/// "page N of M" are kept aside. Local only — a raw title is never sent to a model (it may name
/// someone's mail or another document).
package enum WindowTitle {
    package struct Parsed: Sendable, Equatable {
        /// `normalize(raw)`: what's left to compare with paper titles.
        package var cleaned: String
        /// "name.pdf" when the title names a PDF file (a path's or URL's last component).
        package var fileName: String?
        package var doi: String?
        /// Base id, version dropped.
        package var arxivID: String?
        /// The viewer's "page N of M" (physical page).
        package var page: Int?

        package init(cleaned: String, fileName: String? = nil, doi: String? = nil, arxivID: String? = nil, page: Int? = nil) {
            self.cleaned = cleaned; self.fileName = fileName; self.doi = doi; self.arxivID = arxivID; self.page = page
        }
    }

    /// Viewers and browsers whose name ends (or starts) a window title.
    package static let appNames = [
        "Google Chrome", "Chromium", "Mozilla Firefox", "Firefox", "Safari", "Microsoft Edge", "Microsoft\u{200B} Edge",
        "Brave", "Arc", "Opera", "Vivaldi", "Orion", "DuckDuckGo", "Adobe Acrobat Reader( \\(64-bit\\))?",
        "Adobe Acrobat( Pro( DC)?)?( \\(64-bit\\))?", "Acrobat Reader", "Preview", "Skim", "PDF Expert", "Zotero",
        "Highlights", "PDFgear", "UPDF", "PDF Viewer", "Papers", "ReadCube Papers", "Mendeley Reference Manager",
        "Mendeley", "Bookends", "Sioyek", "PaperDeck", "预览", "Microsoft Word",
    ]

    /// Journal and site names a browser tab appends to an article's title.
    package static let siteNames = [
        "bioRxiv", "medRxiv", "arXiv(\\.org)?", "Nature( [A-Z][a-z]+)*", "Science( Advances)?", "Cell( Reports)?",
        "PNAS", "ScienceDirect", "PubMed", "PMC", "Europe PMC", "Semantic Scholar", "Google Scholar", "SpringerLink",
        "Springer", "Wiley Online Library", "IEEE Xplore", "ACM Digital Library", "OpenReview", "PLOS ONE", "PLOS",
        "eLife", "Oxford Academic", "Taylor & Francis Online", "Frontiers", "MDPI", "ResearchGate", "Cell Press",
        "The Lancet", "NEJM", "JAMA", "BMJ", "Annual Reviews", "Royal Society", "Proceedings of the National Academy of Sciences",
    ]

    /// Names that say nothing about the paper ("main.pdf", "download").
    package static let genericNames: Set<String> = [
        "untitled", "document", "download", "downloads", "main", "paper", "manuscript", "preprint", "article",
        "fulltext", "full text", "pdf", "file", "view", "viewer", "preview", "reader", "new tab", "home", "index",
        "supplement", "supplementary", "si", "draft", "submission", "pdfjs", "pdf viewer",
    ]

    package static func normalize(_ raw: String) -> String { parse(raw).cleaned }

    package static func parse(_ raw: String) -> Parsed {
        var s = OCRPostProcess.cleanLine(raw)
        var out = Parsed(cleaned: "")
        out.doi = findDOI(s)
        out.arxivID = findArxiv(s)
        // Bullets of an unsaved document, then the arXiv abstract page's "[2406.12345] Title".
        s = replace(s, #"^[•●◦∙·*]\s*"#, "")
        s = replace(s, #"^\[(\d{4}\.\d{4,5}(v\d+)?|[a-z-]+(\.[A-Z]{2})?/\d{7}(v\d+)?)\]\s*"#, "")
        out.page = firstInt(s, [#"(?i)\bpage\s+(\d{1,5})\s+(?:of|/)\s+\d{1,5}\b"#, #"第\s*(\d{1,5})\s*页"#])
        let apps = "(?:" + appNames.joined(separator: "|") + ")"
        let sites = "(?:" + siteNames.joined(separator: "|") + ")"
        // No ":" — titles have colons ("BERT: Pre-training …"). Names match case-sensitively.
        let sep = #"\s+[-–—|·]\s+"#
        for _ in 0..<4 {
            let before = s
            s = replace(s, sep + apps + #"(?![\p{L}\p{N}]).*$"#, "")              // "… - Google Chrome - Person 1"
            s = replace(s, "^" + apps + #"\s*[-–—|·]\s+"#, "")                    // "Adobe Acrobat Reader - x.pdf"
            s = replace(s, sep + sites + #"\s*$"#, "")                              // "Title | bioRxiv"
            s = replace(s, #"(?i)\s*[-–—]\s*(edited|locked|已编辑|已锁定)\s*$"#, "")
            s = replace(s, #"(?i)\s*\((edited|locked)\)\s*$"#, "")
            s = replace(s, #"(?i)\s*\(?\s*page\s+\d{1,5}\s+(?:of|/)\s+\d{1,5}\s*\)?"#, " ")
            // "第 2 页，共 9 页" in ASCII or full-width parentheses (CUX-12), and a lone "（第 2 页）".
            s = replace(s, #"\s*[\(（]?\s*第\s*\d{1,5}\s*页\s*[，,、]?\s*共\s*\d{1,5}\s*页\s*[\)）]?"#, " ")
            s = replace(s, #"\s*[\(（]\s*第\s*\d{1,5}\s*页\s*[\)）]"#, " ")
            s = replace(s, #"(?i)\s*\(\d{1,5}\s+pages?\)\s*$"#, "")
            // Edge tab groups, also before the profile name the app suffix left ("… and 3 more pages - Work"),
            // in English and Chinese (CUX-12).
            s = replace(s, #"(?i)\s+and\s+\d+\s+more\s+(?:pages?|tabs?)(?:\s+[-–—]\s+[^-–—|]{1,40}?)?\s*$"#, "")
            s = replace(s, #"\s*和另外\s*\d+\s*个(?:页面|标签页)(?:\s+[-–—]\s+[^-–—|]{1,40}?)?\s*$"#, "")
            s = s.trimmingCharacters(in: .whitespaces)
            s = replace(s, #"\s*[-–—|·]\s*$"#, "")
            if s == before { break }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"(?i)\.pdf$"#, options: .regularExpression) {
            let stem = String(s[..<r.lowerBound])
            let last = stem.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? stem
            let name = (last.removingPercentEncoding ?? last).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.fileName = name + ".pdf" }
            s = name
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespaces))
        out.cleaned = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return out
    }

    /// The cleaned title says nothing (empty, very short, "untitled", "main").
    package static func isGeneric(_ cleaned: String) -> Bool {
        let c = cleaned.lowercased().trimmingCharacters(in: .whitespaces)
        return c.count < 4 || genericNames.contains(c) || c.range(of: #"^[\d\s._-]+$"#, options: .regularExpression) != nil
    }

    /// What a DOI looks like in a title (also a file name's `10.1038_s41586-…`, slash written as `_`).
    static let doiPattern = #"10\.\d{4,9}[/_][^\s\[\]"<>]+"#

    /// A DOI anywhere in the title.
    package static func findDOI(_ s: String) -> String? {
        guard let r = s.range(of: doiPattern, options: .regularExpression) else { return nil }
        var doi = String(s[r])
        if let u = doi.range(of: #"^10\.\d{4,9}_"#, options: .regularExpression) {
            doi.replaceSubrange(doi.index(before: u.upperBound)..<u.upperBound, with: "/")
        }
        if let ext = doi.range(of: #"(?i)\.pdf$"#, options: .regularExpression) { doi.removeSubrange(ext) }
        return FTSQuery.parseDOI(doi)
    }

    /// A modern (YYMM.NNNNN, month 01–12) or legacy (`math.GT/0309136`) arXiv id outside any DOI
    /// (a bioRxiv DOI holds date-like numbers).
    package static func findArxiv(_ s: String) -> String? {
        let text = s.replacingOccurrences(of: doiPattern, with: " ", options: .regularExpression)
        let ns = text as NSString
        let modern = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{2})(\d{2})\.(\d{4,5})(v\d+)?(?![\d])"#)
        for m in modern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let month = Int(ns.substring(with: m.range(at: 2))), (1...12).contains(month),
                  let year = Int(ns.substring(with: m.range(at: 1))), year >= 7 else { continue }
            if let id = FTSQuery.parseArxivID(ns.substring(with: m.range)) { return id }
        }
        if let r = text.range(of: #"\b[a-z-]+(\.[A-Z]{2})?/\d{7}(v\d+)?\b"#, options: .regularExpression) {
            return FTSQuery.parseArxivID(String(text[r]))
        }
        return nil
    }

    private static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    private static func firstInt(_ s: String, _ patterns: [String]) -> Int? {
        for p in patterns {
            guard let rx = try? NSRegularExpression(pattern: p) else { continue }
            let ns = s as NSString
            if let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
               let n = Int(ns.substring(with: m.range(at: 1))), n > 0 {
                return n
            }
        }
        return nil
    }
}

/// Which library paper a capture shows (LN §5), locally, with no AI and no network:
/// 1. the window title — a DOI / arXiv id, the PDF's file name (canonical or original), the title;
/// 2. the OCR / selected text — its rare words (`FTSQuery.anyOf`) find candidates in the full-text
///    index, then each candidate's cached text is searched page by page: character n-gram
///    containment of the normalized excerpt in sliding windows (`TextMatch`). Accepted at
///    `textAccept`; it also gives the page.
/// Papers matched or opened from PaperDeck recently are verified first. Nothing matched → nil
/// (the panel offers a picker). The title wins over a weak text hit; a strong text hit on another
/// paper wins over a title whose own text clearly isn't on screen.
package enum PaperLocator {
    package struct Tuning: Sendable, Equatable {
        /// A window title at least this similar to a paper's title matches it.
        package var titleAccept = 0.88
        /// Text containment needed to accept a paper from the text alone.
        package var textAccept = 0.5
        /// Containment that confirms (and pages) a title match.
        package var textConfirm = 0.35
        /// A text hit this strong on another paper overrides a title whose own text scores below
        /// `titleRefuted`.
        package var textOverride = 0.8
        package var titleRefuted = 0.2
        /// Fewer normalized characters than this: too short to match by text.
        package var minExcerpt = 40
        /// Full-text candidates verified per capture.
        package var textCandidates = 3
        /// A text-only match of a short excerpt (fewer normalized characters than `shortExcerpt`,
        /// boilerplate removed) needs this containment (CUX-6).
        package var shortTextAccept = 0.65
        package var shortExcerpt = 80
        /// A text-only match needs this many distinctive words (`TextMatch.rareTokens`) — or, for
        /// Chinese / Japanese, `minCJK` characters — so shared generic sentences never decide.
        package var minRareTokens = 3
        package var minCJK = 20
        package init() {}
    }

    package static let tuning = Tuning()
    /// Papers matched within this many seconds are verified first.
    package static let recentMatchWindow: TimeInterval = 15 * 60
    /// Papers opened from PaperDeck within this many seconds are verified too.
    package static let recentOpenWindow: TimeInterval = 30 * 60

    package static func locate(windowTitle: String?, ocrText: String?, engine: Engine) async -> PaperMatch? {
        await locate(windowTitle: windowTitle, ocrText: ocrText, engine: engine, tuning: tuning)
    }

    package static func locate(windowTitle: String?, ocrText: String?, engine: Engine, tuning t: Tuning) async -> PaperMatch? {
        let now = engine.ctx.now()
        let parsed = windowTitle.map(WindowTitle.parse)
        // Licence footers, journal headers, "Downloaded from …", URLs and DOIs are shared by many
        // papers: they never count as evidence (CUX-6).
        let excerpt = Boilerplate.strip(ocrText ?? "")
        let scope = ObjectIdentifier(engine)
        // The user's own word for this window / excerpt comes first ("Not this paper", a picked paper).
        let said = PaperMatchCorrections.shared.decisions(windowTitle: windowTitle, excerpt: ocrText, scope: scope, now: now)
        if let chosen = said.chosen, let p = try? await engine.db.paper(id: chosen), p.isLive {
            let pages = await ExplainTextCache.shared.pages(of: p, texts: engine.ctx.texts, now: now)
            let hit = TextMatch.normalizedCount(excerpt) >= t.minExcerpt ? TextMatch.find(excerpt, in: pages) : nil
            let page = hit.flatMap { $0.score >= t.textConfirm ? $0.page : nil } ?? parsed?.page
            return remember(PaperMatch(paperID: p.id, page: page, confidence: 1, via: .user), engine: engine, now: now)
        }
        let rejected = said.rejected
        // Ambiguous file names ("main.pdf" held by several papers) only nominate text candidates.
        var weak: [Int64] = []
        var titleHit: TitleHit?
        // The arXiv stamp printed in the page's margin names the document on screen.
        if let id = Boilerplate.arxivStamp(ocrText ?? ""),
           let p = try? await engine.db.paperMatchingWork(doi: nil, arxivID: id, publishedDOI: nil), p.isLive {
            titleHit = TitleHit(paper: p, confidence: 0.97, via: .identifier)
        } else {
            switch await titleCandidate(parsed, engine: engine, tuning: t) {
            case .hit(let h)?: titleHit = h
            case .ambiguous(let pks)?: weak = pks
            case nil: break
            }
        }
        if let h = titleHit, rejected.contains(h.paper.id) { titleHit = nil }
        // The window names a specific document the library doesn't hold: a text-only match must be strong.
        let foreignWindow = titleHit == nil && weak.isEmpty && parsed.map(namesSpecificDocument) == true

        guard TextMatch.normalizedCount(excerpt) >= t.minExcerpt else {
            guard let titleHit else { return nil }
            return remember(PaperMatch(paperID: titleHit.paper.id, page: parsed?.page, confidence: titleHit.confidence,
                                       via: titleHit.via), engine: engine, now: now)
        }
        // Candidates to verify, in order: the title's paper, recent matches, ambiguous file-name
        // holders, recently opened papers, the full-text index's best.
        var pks: [Int64] = []
        func add(_ pk: Int64) { if !pks.contains(pk) { pks.append(pk) } }
        if let titleHit { add(titleHit.paper.pk) }
        for id in ExplainTextCache.shared.recentMatches(scope: ObjectIdentifier(engine), now: now, within: recentMatchWindow) {
            if let p = try? await engine.db.paper(id: id), p.isLive { add(p.pk) }
        }
        weak.forEach(add)
        for e in engine.recentOpens.recent(now: now, within: recentOpenWindow).prefix(3) {
            if let p = try? await engine.db.paper(id: e.paperID), p.isLive { add(p.pk) }
        }
        if let expr = FTSQuery.anyOf(TextMatch.rareTokens(excerpt)) {
            for pk in (try? await engine.db.fullTextCandidates(expr, limit: t.textCandidates)) ?? [] { add(pk) }
        }
        var scored: [(paper: Paper, hit: TextMatch.Hit)] = []
        var titleText: TextMatch.Hit?
        for pk in pks.prefix(8) {
            guard let paper = try? await engine.db.paper(pk: pk), paper.isLive, !rejected.contains(paper.id) else { continue }
            let pages = await ExplainTextCache.shared.pages(of: paper, texts: engine.ctx.texts, now: now)
            guard let hit = TextMatch.find(excerpt, in: pages) else { continue }
            if paper.pk == titleHit?.paper.pk { titleText = hit }
            scored.append((paper, hit))
        }
        let best = scored.max { $0.hit.score < $1.hit.score }
        if let titleHit {
            // The title's paper has text and it clearly isn't what's on screen, while another
            // paper's is: the window shows something else (an inserted page, an attachment).
            if let best, best.paper.pk != titleHit.paper.pk, best.hit.score >= t.textOverride,
               let own = titleText, own.score < t.titleRefuted {
                return remember(PaperMatch(paperID: best.paper.id, page: best.hit.page, confidence: best.hit.score, via: .text),
                                engine: engine, now: now)
            }
            if let own = titleText, own.score >= t.textConfirm {
                return remember(PaperMatch(paperID: titleHit.paper.id, page: own.page,
                                           confidence: max(titleHit.confidence, own.score), via: titleHit.via),
                                engine: engine, now: now)
            }
            return remember(PaperMatch(paperID: titleHit.paper.id, page: parsed?.page, confidence: titleHit.confidence,
                                       via: titleHit.via), engine: engine, now: now)
        }
        guard let best, best.hit.score >= textOnlyAccept(excerpt, foreignWindow: foreignWindow, tuning: t),
              TextMatch.isDistinctive(excerpt, minRareTokens: t.minRareTokens, minCJK: t.minCJK) else { return nil }
        return remember(PaperMatch(paperID: best.paper.id, page: best.hit.page, confidence: best.hit.score, via: .text),
                        engine: engine, now: now)
    }

    /// The containment a match from the text alone needs (CUX-6): `textAccept`; a short excerpt
    /// `shortTextAccept`; a window naming another, specific document `textOverride`.
    package static func textOnlyAccept(_ excerpt: String, foreignWindow: Bool, tuning t: Tuning = tuning) -> Double {
        var need = t.textAccept
        if TextMatch.normalizedCount(excerpt) < t.shortExcerpt { need = max(need, t.shortTextAccept) }
        if foreignWindow { need = max(need, t.textOverride) }
        return need
    }

    /// The window's title names one specific document (a non-generic file name or title), so a
    /// capture from it that matched no paper by name is probably of something outside the library.
    package static func namesSpecificDocument(_ p: WindowTitle.Parsed) -> Bool {
        if let f = p.fileName, !WindowTitle.isGeneric((f as NSString).deletingPathExtension) { return true }
        let words = p.cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }
        return !WindowTitle.isGeneric(p.cleaned) && words.count >= 3
    }

    // MARK: - Title

    struct TitleHit: Sendable {
        var paper: Paper
        var confidence: Double
        var via: MatchSource
    }

    enum TitleOutcome: Sendable {
        case hit(TitleHit)
        case ambiguous([Int64])
    }

    static func titleCandidate(_ parsed: WindowTitle.Parsed?, engine: Engine, tuning t: Tuning) async -> TitleOutcome? {
        guard let parsed else { return nil }
        if parsed.doi != nil || parsed.arxivID != nil,
           let p = try? await engine.db.paperMatchingWork(doi: parsed.doi, arxivID: parsed.arxivID, publishedDOI: nil) {
            return .hit(TitleHit(paper: p, confidence: 0.97, via: .identifier))
        }
        var names: [String] = []
        if let f = parsed.fileName { names.append(f) }
        if !WindowTitle.isGeneric(parsed.cleaned) { names += [parsed.cleaned + ".pdf", parsed.cleaned] }
        let byName = (try? await engine.db.livePaperPKs(fileNames: names)) ?? []
        if byName.count == 1, let p = try? await engine.db.paper(pk: byName[0]) {
            let generic = WindowTitle.isGeneric(parsed.cleaned)
            if !generic { return .hit(TitleHit(paper: p, confidence: 0.95, via: .fileName)) }
            return .ambiguous(byName)
        }
        if byName.count > 1 { return .ambiguous(byName) }
        guard !WindowTitle.isGeneric(parsed.cleaned) else { return nil }
        let words = parsed.cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        guard words.count >= 2, let expr = FTSQuery.anyOf(words, limit: 12) else { return nil }
        var best: (Paper, Double)?
        for pk in (try? await engine.db.titleCandidates(expr, limit: 8)) ?? [] {
            guard let p = try? await engine.db.paper(pk: pk) else { continue }
            let s = titleScore(parsed.cleaned, p.title)
            if s >= t.titleAccept, s > (best?.1 ?? 0) { best = (p, s) }
        }
        return best.map { .hit(TitleHit(paper: $0.0, confidence: min($0.1, 0.95) * 0.95, via: .windowTitle)) }
    }

    /// How well a cleaned window title names `paperTitle` (0…1): equal, containing it whole (a
    /// tab adding the site), contained in it, else `TitleSimilarity.score`.
    package static func titleScore(_ windowTitle: String, _ paperTitle: String) -> Double {
        let a = TitleSimilarity.normalize(windowTitle), b = TitleSimilarity.normalize(paperTitle)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let aw = a.split(separator: " "), bw = b.split(separator: " ")
        if bw.count >= 4, (" " + a + " ").contains(" " + b + " ") { return 0.95 }
        if aw.count >= 4, Double(aw.count) >= 0.6 * Double(bw.count), (" " + b + " ").contains(" " + a + " ") { return 0.9 }
        return TitleSimilarity.score(a, b)
    }

    private static func remember(_ m: PaperMatch, engine: Engine, now: Date) -> PaperMatch {
        ExplainTextCache.shared.noteMatch(m.paperID, scope: ObjectIdentifier(engine), at: now)
        return m
    }
}

/// Finding an excerpt (noisy OCR or exact copied text) in a paper's pages. Both sides are
/// normalized to letters and digits only (lowercased, ligatures folded): spacing, punctuation and
/// line-end hyphenation can't break a match. The score is the share of the excerpt's distinct
/// character `gram`-grams found in the best window of the page (≈ 1.5 × the excerpt's length,
/// sliding by a quarter of it): OCR noise costs a few grams, unrelated text shares few.
package enum TextMatch {
    package static let gram = 4

    package struct Hit: Sendable, Equatable {
        /// 1-based physical page.
        package var page: Int
        package var score: Double
        /// The match's centre and extent in the page's characters (`Array(page)` offsets).
        package var center: Int
        package var range: Range<Int>
    }

    /// A page normalized for matching: lowercased letters / digits, each with its character offset.
    package struct Normalized: Sendable {
        package var scalars: [UInt32]
        package var offsets: [Int32]
    }

    package static func normalize(_ s: String) -> Normalized {
        var scalars: [UInt32] = []
        var offsets: [Int32] = []
        scalars.reserveCapacity(s.utf8.count / 2)
        offsets.reserveCapacity(s.utf8.count / 2)
        for (i, ch) in s.enumerated() {
            guard ch.isLetter || ch.isNumber else { continue }
            let offset = Int32(clamping: i)
            for u in ch.unicodeScalars {
                if u.value < 0x80 {
                    // ASCII fast path: letters lowercased, digits kept.
                    if (0x41...0x5A).contains(u.value) { scalars.append(u.value + 0x20); offsets.append(offset) }
                    else if (0x61...0x7A).contains(u.value) || (0x30...0x39).contains(u.value) { scalars.append(u.value); offsets.append(offset) }
                    continue
                }
                guard u.properties.isAlphabetic || u.properties.numericType != nil else { continue }   // combining marks
                let folded = (0xFB00...0xFB06).contains(u.value) || (0xFF10...0xFF5A).contains(u.value)
                    ? OCRPostProcess.foldLigatures(String(u)) : u.properties.lowercaseMapping
                for f in folded.unicodeScalars where f.properties.isAlphabetic || f.properties.numericType != nil {
                    scalars.append(f.value)
                    offsets.append(offset)
                }
            }
        }
        return Normalized(scalars: scalars, offsets: offsets)
    }

    /// How much matchable text `s` holds: letters and digits, CJK characters counting double (one
    /// carries about as much as a short word).
    package static func normalizedCount(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? (OCRPostProcess.isCJK($1) ? 2 : 1) : 0) }
    }

    /// The best page for `excerpt` among `pages` (nil when the excerpt is empty or no page has
    /// text). Pages are 1-based in order.
    package static func find(_ excerpt: String, in pages: [ExplainTextCache.Page]) -> Hit? {
        let ex = normalize(excerpt)
        let grams = gramSet(ex.scalars)
        guard !grams.isEmpty else { return nil }
        var best: Hit?
        for (i, page) in pages.enumerated() {
            guard let (score, start, end) = bestWindow(grams, length: ex.scalars.count, in: page.normalized.scalars) else { continue }
            if score > (best?.score ?? -1) {
                let offs = page.normalized.offsets
                let lo = Int(offs[min(start, offs.count - 1)]), hi = Int(offs[min(max(end - 1, start), offs.count - 1)]) + 1
                best = Hit(page: i + 1, score: score, center: (lo + hi) / 2, range: lo..<max(hi, lo))
            }
        }
        return best
    }

    /// The containment of `excerpt` in `text` (one page), 0…1.
    package static func containment(_ excerpt: String, in text: String) -> Double {
        let ex = normalize(excerpt)
        let grams = gramSet(ex.scalars)
        guard !grams.isEmpty else { return 0 }
        return bestWindow(grams, length: ex.scalars.count, in: normalize(text).scalars)?.0 ?? 0
    }

    /// Distinct grams of `s`, each with an index (for the window counter).
    static func gramSet(_ s: [UInt32]) -> [UInt64: Int] {
        guard s.count >= gram else { return [:] }
        var out: [UInt64: Int] = [:]
        out.reserveCapacity(s.count)
        for i in 0...(s.count - gram) {
            let g = key(s, i)
            if out[g] == nil { out[g] = out.count }
        }
        return out
    }

    @inline(__always)
    static func key(_ s: [UInt32], _ i: Int) -> UInt64 {
        var k: UInt64 = 0
        for j in 0..<gram { k = k &* 0x100000001B3 ^ UInt64(s[i + j]) }
        return k
    }

    /// The window of `text` holding the most of `grams`: (share, start, end) in normalized
    /// positions; nil when the text is shorter than one gram.
    static func bestWindow(_ grams: [UInt64: Int], length: Int, in text: [UInt32]) -> (Double, Int, Int)? {
        guard text.count >= gram else { return nil }
        let total = text.count - gram + 1
        let window = max(gram, length + length / 2)
        let stride = max(1, length / 4)
        var stamp = [Int32](repeating: -1, count: grams.count)
        var keys = [Int](repeating: -1, count: total)
        for i in 0..<total { keys[i] = grams[key(text, i)] ?? -1 }
        var best: (Double, Int, Int) = (0, 0, min(window, text.count))
        var start = 0, id: Int32 = 0
        while true {
            let end = min(start + window, total)
            var found = 0
            for i in start..<end {
                let k = keys[i]
                if k >= 0, stamp[k] != id { stamp[k] = id; found += 1 }
            }
            let share = Double(found) / Double(grams.count)
            if share > best.0 {
                // The span from the first to the last matched gram: the excerpt itself, without
                // the window's slack.
                var lo = start, hi = end - 1
                while lo < hi, keys[lo] < 0 { lo += 1 }
                while hi > lo, keys[hi] < 0 { hi -= 1 }
                best = (share, lo, min(hi + gram, text.count))
            }
            if end >= total { break }
            start += stride
            id += 1
        }
        return best
    }

    /// Enough distinctive content to decide a paper by text alone (CUX-6): `minRareTokens` rare
    /// words, or `minCJK` Chinese / Japanese characters.
    package static func isDistinctive(_ text: String, minRareTokens: Int = 3, minCJK: Int = 20) -> Bool {
        rareTokens(text, limit: minRareTokens).count >= minRareTokens
            || text.filter({ OCRPostProcess.isCJK($0) && ($0.isLetter || $0.isNumber) }).count >= minCJK
    }

    /// ≤ `limit` distinctive words of `text` for the full-text index: ≥ 5 letters, not a stopword,
    /// longest first (rarer in practice), each once.
    package static func rareTokens(_ text: String, limit: Int = 10) -> [String] {
        var seen = Set<String>()
        var words: [(String, Int)] = []
        let folded = OCRPostProcess.foldLigatures(text)
        for (i, raw) in folded.split(whereSeparator: { !$0.isLetter }).enumerated() {
            let w = raw.lowercased()
            guard w.count >= 5, w.count <= 30, !stopwords.contains(w), !w.contains(where: OCRPostProcess.isCJK),
                  seen.insert(w).inserted else { continue }
            words.append((w, i))
        }
        return words.sorted { $0.0.count != $1.0.count ? $0.0.count > $1.0.count : $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// Common long words of scientific English that find every paper.
    package static let stopwords: Set<String> = [
        "about", "above", "after", "again", "against", "along", "although", "among", "analysis", "another", "approach",
        "based", "because", "before", "being", "below", "between", "cannot", "could", "data", "different", "during",
        "each", "every", "example", "figure", "first", "found", "further", "given", "however", "important", "include",
        "including", "increase", "large", "later", "level", "levels", "method", "methods", "might", "model", "models",
        "number", "often", "other", "order", "paper", "particular", "performance", "possible", "present", "previous",
        "process", "proposed", "provide", "range", "recent", "related", "result", "results", "same", "second", "section",
        "several", "should", "shown", "shows", "similar", "since", "small", "specific", "study", "studies", "suggest",
        "supplementary", "table", "their", "there", "therefore", "these", "thing", "third", "those", "three", "through",
        "together", "toward", "towards", "under", "until", "using", "value", "values", "various", "where", "whether",
        "which", "while", "within", "without", "would", "years", "total", "following", "observed", "significant",
        "compared", "consistent", "available", "according", "across", "addition", "additional", "already", "always",
        "around", "become", "both", "common", "change", "changes", "changed", "clear", "complete", "consider", "known",
        "less", "little", "means", "more", "most", "much", "must", "never", "other", "overall", "perhaps", "rather",
        "really", "report", "reported", "required", "shall", "still", "such", "taken", "thus", "upon", "whole", "whose",
        "work", "works", "world", "written",
    ]
}

/// Cached page text of the papers Explain looked at recently (raw pages from the text cache,
/// normalized once), and the papers it matched: the next capture of the same paper is verified
/// first and doesn't reload. In memory only; a few papers for ten minutes.
package final class ExplainTextCache: @unchecked Sendable {
    package struct Page: Sendable {
        package var text: String
        package var normalized: TextMatch.Normalized

        package init(text: String) {
            self.text = text
            self.normalized = TextMatch.normalize(text)
        }
    }

    package static let shared = ExplainTextCache()
    package static let capacity = 4
    package static let lifetime: TimeInterval = 10 * 60

    private struct Entry { var key: String; var pages: [Page]; var loadedAt: Date }
    private struct Match { var id: String; var scope: ObjectIdentifier; var at: Date }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var matches: [Match] = []

    package init() {}

    /// The paper's pages (the text cache split at form feeds; empty without cached text).
    package func pages(of paper: Paper, texts: TextStore, now: Date) async -> [Page] {
        let key = paper.id + "#" + paper.sha256
        if let hit = lock.withLock({ () -> [Page]? in
            entries.removeAll { now.timeIntervalSince($0.loadedAt) > Self.lifetime || $0.loadedAt > now.addingTimeInterval(60) }
            return entries.first { $0.key == key }?.pages
        }) { return hit }
        let id = paper.id
        let pages = await BlockingIO.run { () -> [Page] in
            guard let raw = (try? texts.load(id: id)) ?? nil, !raw.isEmpty else { return [] }
            return raw.split(separator: "\u{0C}", omittingEmptySubsequences: false).map { Page(text: String($0)) }
        }
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.insert(Entry(key: key, pages: pages, loadedAt: now), at: 0)
            if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        }
        return pages
    }

    /// Remembers a match for `scope` (the engine: one library's papers never nominate another's).
    package func noteMatch(_ paperID: String, scope: ObjectIdentifier, at date: Date) {
        lock.withLock {
            matches.removeAll { $0.id == paperID && $0.scope == scope }
            matches.insert(Match(id: paperID, scope: scope, at: date), at: 0)
            if matches.count > 16 { matches.removeLast(matches.count - 16) }
        }
    }

    /// `scope`'s matches within `within` seconds of `now`, newest first.
    package func recentMatches(scope: ObjectIdentifier, now: Date, within: TimeInterval) -> [String] {
        lock.withLock { matches.filter { $0.scope == scope && abs(now.timeIntervalSince($0.at)) <= within }.map(\.id) }
    }

    /// Forgets everything (tests).
    package func removeAll() {
        lock.withLock { entries.removeAll(); matches.removeAll() }
    }
}
