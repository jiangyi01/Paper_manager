import Foundation

/// Pure presentation rules of the Mail inbox (App ▸ Views/Mail, MAIL_DESIGN Part A §3): the state
/// chip and actions of a paper row, which rows an alert digest shows before 「其余 N 篇」, the
/// 「全部合并 (N)」 count, the email due-date hint, snooze presets, matching a PDF dropped on a
/// card to one of its rows, drop-target hit testing, and link / text safety for untrusted mail.
/// No I/O, no clock of its own — everything is a function of its arguments (unit-tested).
package enum MailInboxRules {

    // MARK: - Row state

    /// What a row's chip says (colour is always paired with this text in the UI).
    package enum ItemChip: String, Sendable, CaseIterable {
        case attachment         // 附件 PDF · PDF attached
        case downloaded         // 已下载 · Downloaded (fetched from a link, waiting to be merged)
        case downloadable       // 可下载 · Downloadable
        case downloading        // 下载中 · Downloading
        case needsPDF           // 需要 PDF · Needs PDF
        case inLibrary          // 已在库中 · In library (pending: the paper exists; linked rows)
        case merged             // 已合并 · Merged
        case skipped            // 已跳过 · Skipped
    }

    /// The chip of one row. Merged / linked / skipped rows show their outcome; pending rows
    /// their PDF state (`unknown` resolved by the local PDF-link rules, no network).
    package static func chip(_ item: MailItem) -> ItemChip {
        switch item.status {
        case .merged: return .merged
        case .linked: return .inLibrary
        case .skipped: return .skipped
        case .pending: break
        }
        return pdfChip(item)
    }

    /// The chip for the row's PDF state alone (also what a skipped row would offer again).
    static func pdfChip(_ item: MailItem) -> ItemChip {
        switch item.pdfState {
        case .hasPDF: return item.origin == .attachment ? .attachment : .downloaded
        case .downloading: return .downloading
        case .needsPDF: return .needsPDF
        case .inLibrary: return .inLibrary
        case .downloadable, .unknown: return hasDownloadSource(item) ? .downloadable : .needsPDF
        }
    }

    /// The merge would find a locally extracted PDF link (arXiv, bioRxiv / medRxiv, direct `.pdf`)
    /// — the same rule as `Engine.mergeMailItem`; never a URL the AI returned.
    package static func hasDownloadSource(_ item: MailItem) -> Bool {
        Engine.mailDownloadURL(item) != nil
    }

    /// Buttons a row offers.
    package struct ItemActions: OptionSet, Sendable, Hashable {
        package let rawValue: Int
        package init(rawValue: Int) { self.rawValue = rawValue }

        package static let merge = ItemActions(rawValue: 1 << 0)            // 合并到论文库 (PDF here, or link an existing paper)
        package static let downloadAndMerge = ItemActions(rawValue: 1 << 1) // 自动下载并合并
        package static let download = ItemActions(rawValue: 1 << 2)         // 仅下载 (context menu)
        package static let openLink = ItemActions(rawValue: 1 << 3)         // 打开链接 (url_original)
        package static let openCard = ItemActions(rawValue: 1 << 4)         // 打开卡片 (the library paper)
        package static let skip = ItemActions(rawValue: 1 << 5)             // 跳过
        package static let acceptsDrop = ItemActions(rawValue: 1 << 6)      // a dropped PDF becomes this row's paper
        package static let dropBox = ItemActions(rawValue: 1 << 7)          // show 「把下载好的 PDF 拖到这里」
    }

    package static func actions(_ item: MailItem) -> ItemActions {
        var a: ItemActions = []
        if linkURL(item) != nil { a.insert(.openLink) }
        switch item.status {
        case .merged, .linked:
            if item.paperID != nil { a.insert(.openCard) }
            return a
        case .pending, .skipped:
            break
        }
        let chip = pdfChip(item)
        switch chip {
        case .attachment, .downloaded:
            a.insert(.merge)
        case .downloadable:
            a.insert(.downloadAndMerge)
            a.insert(.download)
        case .inLibrary:
            a.insert(.merge)
            if item.paperID != nil { a.insert(.openCard) }
        case .downloading, .needsPDF, .merged, .skipped:
            break
        }
        if item.status == .pending { a.insert(.skip) }
        if chip != .inLibrary && chip != .downloading { a.insert(.acceptsDrop) }
        if item.status == .pending && chip == .needsPDF { a.insert(.dropBox) }
        return a
    }

    /// 「打开链接」: the link as it appeared in the email (`url_original`, so the university's
    /// time-of-click scan still runs), else the unwrapped URL, else a DOI / arXiv landing page.
    /// Only http(s) — mail text is untrusted (`javascript:`, `file:`, `data:` never open).
    package static func linkURL(_ item: MailItem) -> URL? {
        for raw in [item.urlOriginal, item.url] {
            if let url = safeWebURL(raw) { return url }
        }
        if let doi = item.ids.doi, let url = safeWebURL("https://doi.org/" + doi) { return url }
        if let arxiv = item.ids.arxivID, let url = safeWebURL("https://arxiv.org/abs/" + arxiv) { return url }
        return nil
    }

    /// An http(s) URL with a host, nil for anything else (or for control / whitespace characters).
    package static func safeWebURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || MailInertText.isInvisible($0) }),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Card

    /// 「全部合并 (N)」: the rows `Engine.mergeAllMailItems` would take right now — the card's
    /// pending target rows (`MailMergeState.targetItems`) with a PDF source (stored PDF, a local
    /// download link, or an existing library paper), in row order.
    package static func mergeAllItems(_ items: [MailItem]) -> [MailItem] {
        MailMergeState.targetItems(items).filter { item in
            guard item.status == .pending else { return false }
            if item.pdfState == .downloading { return hasDownloadSource(item) }
            switch pdfChip(item) {
            case .attachment, .downloaded, .downloadable: return true
            case .inLibrary: return item.paperID != nil
            case .downloading, .needsPDF, .merged, .skipped: return false
            }
        }.sorted { ($0.ord, $0.pk) < ($1.ord, $1.pk) }
    }

    package static func mergeAllCount(_ items: [MailItem]) -> Int { mergeAllItems(items).count }

    /// Alert / TOC digests collapse the rows nobody picked.
    package static func isDigest(_ message: MailMessage) -> Bool {
        message.triage?.requestKind == .alertDigest || message.senderKind == .alert
    }

    /// Rows shown first and rows behind 「其余 N 篇」. Non-digests show everything (ord order).
    /// Digests: requested / highlighted rows (and rows already merged or linked) first, the rest
    /// collapsed; with nothing rated, the first `head` rows when there are more than `threshold`.
    package static func partition(_ items: [MailItem], digest: Bool, threshold: Int = 6,
                                  head: Int = 4) -> (shown: [MailItem], rest: [MailItem]) {
        let ordered = items.sorted { ($0.ord, $0.pk) < ($1.ord, $1.pk) }
        guard digest else { return (ordered, []) }
        func focus(_ i: MailItem) -> Bool {
            i.relevance == .requested || i.relevance == .highlighted || i.status == .merged || i.status == .linked
        }
        let picked = ordered.filter(focus)
        if !picked.isEmpty {
            func rank(_ i: MailItem) -> Int {
                switch i.relevance {
                case .requested: return 0
                case .highlighted: return 1
                default: return 2
                }
            }
            let shown = picked.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            return (shown, ordered.filter { !focus($0) })
        }
        guard ordered.count > max(threshold, head) else { return (ordered, []) }
        return (Array(ordered.prefix(head)), Array(ordered.dropFirst(head)))
    }

    // MARK: - Request badge / due date

    /// The card's request badge: 导师请求 / Request · 组会 / Journal club · 论文提醒 / Alert · 分享 / FYI.
    package enum RequestBadge: String, Sendable, CaseIterable {
        case request, journalClub, alert, fyi, other
    }

    package static func requestBadge(_ m: MailMessage) -> RequestBadge? {
        switch m.triage?.requestKind {
        case .advisorRequest: return .request
        case .journalClub: return .journalClub
        case .alertDigest: return .alert
        case .fyi: return .fyi
        case .other: return .other
        case .notPaper: return nil
        case nil: return m.senderKind == .alert ? .alert : nil
        }
    }

    /// The email's due date as the card shows it (「邮件 DDL ≈10/3」). `confident` = the merge
    /// popover pre-checks 「固定 DDL」 (`MailMergeOptions.confidentDue`); `isPast` = 「邮件中的日期已过」.
    package struct DueHint: Sendable, Equatable {
        package var date: LocalDate
        package var confident: Bool
        package var isPast: Bool
        package var evidence: String?
    }

    package static func dueHint(_ m: MailMessage, today: LocalDate) -> DueHint? {
        guard let t = m.triage, let date = t.dueDate else { return nil }
        let evidence = t.dueEvidence.map { MailInertText.clip($0, 80) }.flatMap { $0.isEmpty ? nil : $0 }
        return DueHint(date: date, confident: (t.dueConfidence ?? 0) >= MailMergeOptions.confidentDue,
                       isPast: date < today, evidence: evidence)
    }

    // MARK: - Snooze (「稍后 ▾ 明天 / 下周一 / 自定义」)

    /// Hour of the day a snoozed card comes back.
    package static let snoozeHour = 9

    /// Tomorrow at `snoozeHour` (local).
    package static func snoozeTomorrow(now: Date, calendar: Calendar) -> Date {
        LocalDate.today(now: now, calendar: calendar).adding(days: 1, calendar: calendar)
            .date(hour: snoozeHour, minute: 0, calendar: calendar)
    }

    /// The next Monday strictly after today (a Monday gives the one a week later), at `snoozeHour`.
    package static func snoozeNextMonday(now: Date, calendar: Calendar) -> Date {
        let today = LocalDate.today(now: now, calendar: calendar)
        let weekday = today.weekday(calendar: calendar)          // 1 = Sunday … 2 = Monday
        let ahead = (2 - weekday + 7) % 7
        return today.adding(days: ahead == 0 ? 7 : ahead, calendar: calendar)
            .date(hour: snoozeHour, minute: 0, calendar: calendar)
    }

    /// A custom snooze time is only accepted in the future (at least a minute ahead).
    package static func validSnooze(_ date: Date, now: Date) -> Bool { date.timeIntervalSince(now) >= 60 }

    // MARK: - A PDF dropped on a card (not on a row)

    /// The row a PDF dropped on the card belongs to: an exact DOI (also the preprint's published
    /// DOI) or arXiv id; else a title match (≥ `MailMatcher.titleThreshold`) without conflicting
    /// ids; else — only when `soleFallback` (one PDF dropped) — the card's single row still
    /// waiting for a PDF, unless the PDF's ids say it is another work. Nil → a normal import.
    package static func matchDroppedPDF(ids: PaperIDs, title: String?, items: [MailItem],
                                        soleFallback: Bool) -> MailItem? {
        let open = items.filter { actions($0).contains(.acceptsDrop) && $0.status == .pending }
            .sorted { ($0.ord, $0.pk) < ($1.ord, $1.pk) }
        let pdfDOIs = Set([ids.doi, ids.publishedDOI].compactMap { $0?.lowercased() })
        let pdfArxiv = ids.arxivID.map(baseArxiv)
        for item in open {
            if let doi = item.ids.doi?.lowercased(), pdfDOIs.contains(doi) { return item }
            if let a = item.ids.arxivID.map(baseArxiv), a == pdfArxiv { return item }
        }
        func conflicts(_ item: MailItem) -> Bool {
            if let doi = item.ids.doi?.lowercased(), !pdfDOIs.isEmpty, !pdfDOIs.contains(doi) { return true }
            if let a = item.ids.arxivID.map(baseArxiv), let p = pdfArxiv, a != p { return true }
            return false
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let scored = open.compactMap { item -> (MailItem, Double)? in
                guard !conflicts(item), let t = item.title else { return nil }
                let s = TitleSimilarity.score(title, t)
                return s >= MailMatcher.titleThreshold ? (item, s) : nil
            }
            if let best = scored.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        guard soleFallback else { return nil }
        let waiting = open.filter { pdfChip($0) == .needsPDF }
        guard waiting.count == 1, let only = waiting.first, !conflicts(only) else { return nil }
        return only
    }

    private static func baseArxiv(_ id: String) -> String {
        let lower = id.lowercased()
        if let r = lower.range(of: #"v\d+$"#, options: .regularExpression) { return String(lower[..<r.lowerBound]) }
        return lower
    }

    // MARK: - Drop targets (DropTargetRegistry / DropHostingView)

    /// One registered drop zone in window coordinates. Higher `priority` wins (rows over cards);
    /// equal priority → the smaller zone.
    package struct DropZone: Sendable, Equatable {
        package var id: String
        package var rect: CGRect
        package var priority: Int
        package init(id: String, rect: CGRect, priority: Int) { self.id = id; self.rect = rect; self.priority = priority }
    }

    /// The zone under `point`, only inside `clip` (the visible list) when given.
    package static func pick(_ point: CGPoint, zones: [DropZone], clip: CGRect?) -> String? {
        if let clip, !clip.contains(point) { return nil }
        let hits = zones.filter { !$0.rect.isNull && !$0.rect.isEmpty && $0.rect.contains(point) }
        return hits.min { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let aa = a.rect.width * a.rect.height, ba = b.rect.width * b.rect.height
            if aa != ba { return aa < ba }
            return a.id < b.id
        }?.id
    }

    // MARK: - Untrusted text

    /// One inert line for the UI (subject, sender name, paper title): no control / bidi /
    /// zero-width characters, whitespace collapsed, at most `limit` characters.
    package static func line(_ s: String?, limit: Int = 300) -> String {
        MailInertText.clip(s ?? "", limit)
    }

    /// Multi-line inert text (summary, body): invisible and control characters removed except
    /// newlines and tabs; runs of more than two blank lines collapsed; at most `limit` characters.
    package static func text(_ s: String?, limit: Int = 25_000) -> String {
        let cleaned = String(String.UnicodeScalarView((s ?? "").unicodeScalars.filter { u in
            u == "\n" || u == "\t" || !MailInertText.isInvisible(u)
        }))
        let collapsed = cleaned.replacingOccurrences(of: #"\n{4,}"#, with: "\n\n\n", options: .regularExpression)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
