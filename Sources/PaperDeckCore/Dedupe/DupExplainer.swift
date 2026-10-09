import Foundation

/// The words of a review (DQ §3.5) in English or Chinese: a headline, the two versions, the
/// earlier paper's history and one line per reason. Percentages are rounded and the raw score
/// is never shown. Engine-side text (toasts) uses the same strings.
package enum DupExplainer {
    package static func explain(_ review: DupReview, new n: DupSideSummary, existing e: DupSideSummary,
                                lang: UILang, calendar: Calendar = .autoupdatingCurrent) -> DupExplanation {
        DupExplanation(headline: headline(review, existing: e, lang: lang),
                       versionLine: versionLine(new: n, existing: e, lang: lang),
                       historyLine: historyLine(e, lang: lang, calendar: calendar),
                       evidence: review.evidence.map { line($0, lang: lang) })
    }

    // MARK: Headline

    package static func headline(_ r: DupReview, existing e: DupSideSummary, lang: UILang) -> String {
        let zh = lang == .zh
        if r.matchesHistory, r.relation.isSameWork {
            return zh ? "你以前读过这篇论文（已从资料库删除）" : "You had this paper before (removed from the library)"
        }
        switch r.relation {
        case .sameFile: return zh ? "这个文件你以前收过" : "You've had this exact file before"
        case .newerVersion: return zh ? "同一篇论文的新版本" : "Same paper, newer version"
        case .olderVersion: return zh ? "库中已有更新的版本" : "You already have a newer version"
        case .sameVersion: return zh ? "同一篇论文的另一份拷贝" : "Same paper, same version (another copy)"
        case .supplement: return zh ? "看起来是库中某篇论文的补充材料" : "Looks like supplementary material of a paper you have"
        case .correction: return zh ? "库中某篇论文的更正 / 撤稿声明" : "A correction or retraction notice of a paper you have"
        case .comment: return zh ? "针对库中某篇论文的评论或回复" : "A comment on or reply to a paper you have"
        case .sameWork:
            switch r.band {
            case .certain: return zh ? "库中已有同一篇论文" : "Same paper already in your library"
            case .likely: return zh ? "很可能是同一篇论文" : "Probably the same paper"
            case .possible: return zh ? "可能是同一篇论文" : "Possibly the same paper"
            }
        }
    }

    // MARK: Lines

    /// "bioRxiv v2", "Nature", "arXiv v3" — nil when nothing is known. Without a venue, `ids`
    /// name the preprint server (an arXiv id, a bioRxiv DOI); without either, "Preprint" / "预印本".
    package static func versionLabel(venue: String?, rank: VersionRank, ids: PaperIDs? = nil, lang: UILang = .en) -> String? {
        var v = venue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if v == nil, rank.tier == .preprint, let ids {
            if ids.arxivID != nil || MetadataClients.arxivID(fromDOI: ids.doi ?? "") != nil { v = "arXiv" }
            else if MetadataClients.biorxivDOI(ids.doi ?? "") != nil { v = "bioRxiv" }
        }
        switch rank.tier {
        case .preprint:
            let base = v ?? (lang == .zh ? "预印本" : "Preprint")
            return rank.version > 0 ? "\(base) v\(rank.version)" : base
        case .published:
            return v.map { rank.version > 0 && $0.lowercased().contains("elife") ? "\($0) v\(rank.version)" : $0 }
        case .unknown:
            return v
        }
    }

    /// "bioRxiv v2 (2024)", "Nature (2025)", "2024"; nil when neither a version nor a year is known.
    private static func label(_ s: DupSideSummary) -> String? {
        switch (s.versionLabel, s.year) {
        case let (l?, y?): return "\(l) (\(y))"
        case let (l?, nil): return l
        case let (nil, y?): return String(y)
        case (nil, nil): return nil
        }
    }

    /// "New: Nature (2025) · In your library: bioRxiv v2 (2024)" — nil unless both sides say
    /// which version or year they are (the side cards show the rest).
    package static func versionLine(new n: DupSideSummary, existing e: DupSideSummary, lang: UILang) -> String? {
        guard let a = label(n), let b = label(e), a != b || n.versionLabel != nil else { return nil }
        return lang == .zh ? "新：\(a) · 库中：\(b)" : "New: \(a) · In your library: \(b)"
    }

    package static func historyLine(_ e: DupSideSummary, lang: UILang, calendar: Calendar) -> String? {
        let zh = lang == .zh
        func day(_ d: Date) -> String { shortDate(d, lang: lang, calendar: calendar) }
        if let purged = e.purgedAt {
            let read = e.doneAt != nil || e.readCount > 0
            return zh ? "\(day(purged)) 已彻底删除——你当时\(read ? "已读完" : "还没读完")"
                : "Removed on \(day(purged)) — you had \(read ? "finished it" : "not finished it")"
        }
        if let deleted = e.deletedAt {
            return zh ? "\(day(deleted)) 移到了「最近删除」" : "Moved to Recently Deleted on \(day(deleted))"
        }
        var parts: [String] = []
        if let added = e.addedAt { parts.append(zh ? "\(day(added)) 加入资料库" : "In your library since \(day(added))") }
        if e.status == .done, let done = e.doneAt {
            parts.append(zh ? "\(day(done)) 读完" : "finished \(day(done))")
        } else if e.status == .reading {
            parts.append(zh ? "正在读" : "reading")
        } else if e.status == .toRead {
            parts.append(zh ? "待读" : "to read")
        }
        if e.readCount > 1 { parts.append(zh ? "读过 \(e.readCount) 次" : "read \(e.readCount)×") }
        if e.checklistTotal > 0 {
            parts.append(zh ? "清单 \(e.checklistDone)/\(e.checklistTotal)" : "checklist \(e.checklistDone)/\(e.checklistTotal)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package static func line(_ ev: DupEvidence, lang: UILang) -> String {
        let zh = lang == .zh
        let v = ev.value ?? ""
        switch ev.code {
        case .sameFile: return zh ? "文件完全相同" : "Identical file (same bytes)"
        case .sharedDOI: return zh ? "DOI 相同：\(v)" : "Same DOI: \(v)"
        case .doiFamily: return zh ? "同一 DOI 的不同版本：\(v)" : "Versions of one DOI: \(v)"
        case .publishedDOI:
            return v.isEmpty ? (zh ? "预印本记录指向正式发表版本" : "The preprint's record points to the published version")
                : (zh ? "预印本的正式发表 DOI 是 \(v)" : "The preprint's published DOI is \(v)")
        case .preprintLink:
            return v.isEmpty ? (zh ? "Crossref 记录了两个版本的关联" : "Crossref links the two versions")
                : (zh ? "Crossref 记录了两个版本的关联（\(v)）" : "Crossref links the two versions (\(v))")
        case .arxiv: return zh ? "同一 arXiv 论文：\(v)" : "Same arXiv paper: \(v)"
        case .openAlex: return zh ? "OpenAlex 将两者列为同一作品" : "OpenAlex lists them as one work"
        case .title: return zh ? "标题 \(ev.percent ?? 0)% 相同" : "Title \(ev.percent ?? 0)% identical"
        case .firstAuthor: return zh ? "第一作者相同（\(display(v))）" : "Same first author (\(display(v)))"
        case .authors:
            return zh ? "作者 \(ev.count ?? 0)/\(ev.total ?? 0) 相同" : "\(ev.count ?? 0) of \(ev.total ?? 0) authors match"
        case .year:
            let a = ev.total.map(String.init) ?? "?", b = ev.count.map(String.init) ?? "?"
            if a == b { return zh ? "同年（\(a)）" : "Same year (\(a))" }
            return zh ? "年份：新 \(a) · 库中 \(b)" : "Years: new \(a) · yours \(b)"
        case .text: return zh ? "正文重合约 \(ev.percent ?? 0)%" : "Text overlap about \(ev.percent ?? 0)%"
        case .abstract: return zh ? "摘要重合约 \(ev.percent ?? 0)%" : "Abstract overlap about \(ev.percent ?? 0)%"
        case .supplement: return zh ? "文件名或标题表明这是补充材料" : "The file name or title says supplementary material"
        case .notice: return zh ? "标题像是更正或撤稿声明" : "The title reads like a correction or retraction notice"
        case .comment: return zh ? "标题像是评论或回复" : "The title reads like a comment or reply"
        case .history: return zh ? "与你删除过的一篇论文一致" : "Matches a paper you removed"
        }
    }

    /// "wang" → "Wang".
    private static func display(_ surname: String) -> String {
        surname.prefix(1).uppercased() + surname.dropFirst()
    }

    /// "Mar 3" / "3月3日" (with the year when it isn't this year's).
    package static func shortDate(_ d: Date, lang: UILang, calendar: Calendar, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        if lang == .zh {
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        }
        return f.string(from: d)
    }

    // MARK: Toasts (engine side)

    private static func short(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }

    /// The toast of one review opened at import (`existingIsLive` false: the earlier paper is in
    /// Recently Deleted).
    package static func toastMessage(_ r: DupReview, newTitle: String, existingTitle: String, existingIsLive: Bool = true,
                                     lang: UILang) -> String {
        let zh = lang == .zh
        let e = short(existingTitle)
        if r.matchesHistory { return zh ? "你以前读过：\(e)" : "You had this paper before: \(e)" }
        if !existingIsLive, r.relation.isSameWork {
            return zh ? "「最近删除」中已有：\(e)" : "Already in Recently Deleted: \(e)"
        }
        switch r.relation {
        case .supplement: return zh ? "像是「\(e)」的补充材料" : "Looks like a supplement of “\(e)”"
        case .correction: return zh ? "「\(e)」的更正声明" : "A notice about “\(e)”"
        case .comment: return zh ? "针对「\(e)」的评论或回复" : "A comment on “\(e)”"
        case .newerVersion: return zh ? "「\(e)」的新版本" : "A newer version of “\(e)”"
        case .olderVersion: return zh ? "库中已有「\(e)」的更新版本" : "You already have a newer version of “\(e)”"
        default:
            switch r.band {
            case .certain: return zh ? "同一论文已在库中：\(e)" : "Same paper already in your library: \(e)"
            case .likely, .possible: return zh ? "可能与库中论文重复：\(e)" : "May be a paper you already have: \(e)"
            }
        }
    }

    /// One summary toast for a batch ("5 files look like papers you already have").
    package static func batchToast(_ count: Int, lang: UILang) -> String {
        if lang == .zh { return "\(count) 个文件可能与库中论文重复" }
        return count == 1 ? "1 file looks like a paper you already have" : "\(count) files look like papers you already have"
    }

    /// The toast of a review (the app's duplicate model posts it in place of the import's classic
    /// same-work / lookalike toast): [Review…] plus, for a parked file, the one quick answer that
    /// never throws the library's version away — "Keep New" only for a newer version (never a
    /// supplement), "Skip" otherwise. A paper in Recently Deleted gets the sheet only.
    package static func reviewToast(_ r: DupReview, newTitle: String, existingTitle: String, existingIsLive: Bool,
                                    lang: UILang) -> Toast {
        var buttons: [Toast.Button] = [.init(title: reviewButton(lang), action: .openDuplicateReview(id: r.id))]
        if existingIsLive, let pending = r.pendingID {
            if r.relation == .newerVersion {
                buttons.append(.init(title: keepNewButton(lang), action: .replaceKeepingChecklist(pendingID: pending)))
            } else {
                buttons.append(.init(title: skipButton(lang), action: .ignorePending(pendingID: pending)))
            }
        }
        return Toast(id: "dup-" + r.id, kind: .info,
                     message: toastMessage(r, newTitle: newTitle, existingTitle: existingTitle, existingIsLive: existingIsLive,
                                           lang: lang), buttons: buttons)
    }

    /// The import's classic "same work" toast of a parked file: its pending id.
    package static func classicSameWorkPendingID(_ t: Toast) -> String? {
        guard t.buttons.count == 2 else { return nil }
        if case .replaceKeepingChecklist(let a) = t.buttons[0].action, case .ignorePending(let b) = t.buttons[1].action, a == b {
            return a
        }
        return nil
    }

    /// The enrichment's classic "May duplicate a paper already in the library" toast: the other paper's id.
    package static func classicLookalikePaperID(_ t: Toast) -> String? {
        guard t.buttons.count == 1, case .openPaper(let id) = t.buttons[0].action,
              t.message.hasPrefix("May duplicate a paper already in the library: ") || t.message.hasPrefix("可能与已有论文重复：")
        else { return nil }
        return id
    }

    package static func reviewButton(_ lang: UILang) -> String { lang == .zh ? "查看…" : "Review…" }
    package static func keepNewButton(_ lang: UILang) -> String { lang == .zh ? "保留新的" : "Keep New" }
    package static func skipButton(_ lang: UILang) -> String { lang == .zh ? "跳过" : "Skip" }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
