import Foundation
import PaperDeckCore

// Strings of the cards slice: cards, chips, AgentBadge, grid grouping, 今天 view,
// context menu, empty states. Chips, weekdays and backlog lines come from SharedStrings.
// Every key is prefixed `cards…` so it can't collide with other slices' extensions.
extension L {
    private static var zh: Bool { L.lang == .zh }

    // MARK: Card

    static var cardsPreprint: String { "Preprint" }
    static var cardsAbstractPrefix: String { zh ? "摘要 · " : "Abstract · " }
    static var cardsTLDRPending: String { zh ? "\(L.ai) 解读后显示 TL;DR" : "TL;DR appears once \(L.ai) has read it" }
    /// `3/7 · 剩 40′`
    static func cardsProgress(done: Int, total: Int, remaining: Int) -> String {
        remaining > 0 ? (zh ? "\(done)/\(total) · 剩 \(remaining)′" : "\(done)/\(total) · \(remaining)′ left")
                      : "\(done)/\(total)"
    }
    /// `剩 40′` (no checklist yet: the estimate)
    static func cardsRemaining(_ minutes: Int) -> String { zh ? "剩 \(minutes)′" : "\(minutes)′ left" }
    /// `已读 · 9/28`
    static func cardsReadOn(_ monthDay: String?) -> String {
        guard let monthDay else { return zh ? "已读" : "Read" }
        return zh ? "已读 · \(monthDay)" : "Read · \(monthDay)"
    }
    static var cardsUncategorized: String { zh ? "未分类" : "Uncategorized" }
    static var cardsHighPriority: String { zh ? "高优先级" : "High priority" }
    static var cardsLowPriority: String { zh ? "低优先级" : "Low priority" }
    static var cardsLocked: String { zh ? "PDF 已加密" : "Encrypted PDF" }
    static var cardsMissingFile: String { zh ? "找不到 PDF 文件" : "PDF file missing" }
    static var cardsNewShort: String { zh ? "新解读" : "New" }
    static func cardsNewA11y(_ title: String) -> String { zh ? "新解读，\(title)" : "New, \(title)" }
    static func cardsCategoryA11y(_ name: String) -> String { zh ? "分类：\(name)" : "Category: \(name)" }
    static func cardsTagsA11y(_ tags: [String]) -> String {
        zh ? "标签：" + tags.joined(separator: "、") : "Tags: " + tags.joined(separator: ", ")
    }
    static func cardsChecklistA11y(done: Int, total: Int) -> String {
        total == 0 ? (zh ? "还没有阅读清单" : "No checklist yet")
                   : (zh ? "清单进度 \(done)/\(total)" : "Checklist \(done) of \(total)")
    }

    // MARK: DDL chip

    static func cardsDeadlineA11y(_ text: String) -> String { zh ? "DDL：\(text)" : "Deadline: \(text)" }
    static var cardsPinnedA11y: String { zh ? "已固定" : "pinned" }
    static var cardsProvisionalA11y: String { zh ? "暂定" : "provisional" }
    static var cardsPinnedHelp: String { zh ? "已固定的 DDL，自动排期不会移动它" : "Pinned deadline — automatic scheduling won't move it" }
    static var cardsProvisionalHelp: String {
        zh ? "暂定 DDL（≈）：阅读清单生成后可能再调整一次" : "Provisional deadline (≈): may shift once when the checklist is ready"
    }
    static var cardsAtRiskGeneric: String { zh ? "按当前预算可能无法按时读完" : "May not be finished in time at the current budget" }

    // MARK: AgentBadge

    static func cardsBadgeModeOff(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 解读已关闭" : "\(p.shortName) reading is off" }
    static var cardsBadgeAwaiting: String { zh ? "等待确认" : "Awaiting confirmation" }
    static func cardsBadgeQueued(position: Int?) -> String {
        guard let position else { return zh ? "排队中" : "Queued" }
        return zh ? "排队中 · 第 \(position)" : "Queued · #\(position)"
    }
    static func cardsBadgeRunning(_ p: AIProviderKind, elapsed: String?) -> String {
        let name = p.shortName
        guard let elapsed else { return zh ? "\(name) 阅读中…" : "\(name) is reading…" }
        return zh ? "\(name) 阅读中… \(elapsed)" : "\(name) is reading… \(elapsed)"
    }
    static var cardsBadgeFailed: String { zh ? "解读失败 · 重试" : "Reading failed · Retry" }
    static func cardsBadgeLimited(resume: String?) -> String {
        guard let resume else { return zh ? "额度用尽" : "Usage limit reached" }
        return zh ? "额度用尽 · \(resume) 继续" : "Usage limit · resumes \(resume)"
    }
    static func cardsBadgeNeedsLogin(_ p: AIProviderKind) -> String { zh ? "需登录 \(p.shortName)" : "Sign in to \(p.shortName)" }
    static var cardsBadgeSkipped: String { zh ? "扫描版/加密 PDF · 未解读" : "Scanned/encrypted PDF · not read" }
    static var cardsBadgeTextIncomplete: String { zh ? "文本不完整" : "Incomplete text" }
    static var cardsBadgeFreshA11y: String { zh ? "AI 解读已完成（未查看）" : "New AI reading (not viewed yet)" }
    static var cardsBadgeHelpOpenAISettings: String { zh ? "打开设置 ▸ AI 解读" : "Open Settings ▸ AI Reading" }
    static func cardsBadgeHelpConfirm(_ p: AIProviderKind) -> String {
        zh ? "确认是否用 \(p.shortName) 解读这批论文" : "Confirm reading this batch with \(p.shortName)"
    }
    static var cardsBadgeHelpRetry: String { zh ? "点击重新排队解读" : "Click to queue it again" }
    static func cardsBadgeHelpLimited(_ p: AIProviderKind, _ time: String) -> String {
        zh ? "\(p.shortName) 订阅额度已用尽，\(time) 自动继续解读" : "\(p.shortName) usage limit reached — reading resumes at \(time)"
    }
    static var cardsBadgeHelpSkipped: String {
        zh ? "PDF 中没有可提取的文本（扫描版）或无法解密，\(L.ai) 不会解读" : "The PDF has no extractable text (scanned) or is encrypted, so \(L.ai) skipped it"
    }
    static var cardsBadgeHelpTextIncomplete: String {
        zh ? "PDF 文本提取不完整，解读可能遗漏部分内容" : "Text extraction was incomplete; the reading may miss parts of the paper"
    }

    // MARK: 待读 grouping

    static var cardsBucketOverdue: String { zh ? "逾期" : "Overdue" }
    static var cardsBucketToday: String { zh ? "今天" : "Today" }
    static var cardsBucketThisWeek: String { zh ? "本周" : "This Week" }
    static var cardsBucketNextWeek: String { zh ? "下周" : "Next Week" }
    static var cardsBucketLater: String { zh ? "以后" : "Later" }
    static var cardsBucketUnscheduled: String { zh ? "未排期" : "Unscheduled" }

    // MARK: 今天

    private static let monthsEN = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `9月29日 周二` / `Tue, Sep 29`
    static func cardsTodayDate(_ d: LocalDate) -> String {
        let weekday = SharedStrings.weekday(d.weekday(calendar: LocalDate.gregorian(.current)), L.lang)
        return zh ? "\(d.month)月\(d.day)日 \(weekday)" : "\(weekday), \(monthsEN[max(0, min(11, d.month - 1))]) \(d.day)"
    }
    static func cardsTodaySummaryCount(_ n: Int) -> String { SharedStrings.papers(n, L.lang) }
    static func cardsTodayBudget(_ minutes: Int) -> String { zh ? "预算 \(minutes)" : "budget \(minutes)" }
    static func cardsTodayBacklog(_ n: Int) -> String { zh ? "待读共 \(n) 篇" : "\(n) in backlog" }
    static var cardsTodaySkip: String { zh ? "今天跳过" : "Skip Today" }
    static var cardsTodaySkipHelp: String {
        zh ? "把今天及以后的自动 DDL 顺延一个阅读日（30 秒内可撤销）"
           : "Move today's and later automatic deadlines by one reading day (undo within 30 s)"
    }
    static var cardsTodayOverBudgetHelp: String {
        zh ? "今天的阅读量超过了每日预算" : "Today's reading exceeds your daily budget"
    }
    static var cardsTodayGroupOverdue: String { zh ? "逾期" : "Overdue" }
    static var cardsTodayGroupDueToday: String { zh ? "今天到期" : "Due Today" }
    static var cardsTodayGroupPlanned: String { zh ? "今日计划" : "Today's Plan" }
    static var cardsTodayGroupUpcoming: String { zh ? "本周接下来" : "Coming Up This Week" }
    static func cardsTodayMinutesShort(_ minutes: Int) -> String { zh ? "约 \(minutes)′" : "~\(minutes)′" }
    /// `今天读 ~25′ · DDL 周五`
    static func cardsTodayPlanLine(minutes: Int, deadline: String?) -> String {
        switch (zh, deadline) {
        case (true, let d?): return "今天读 ~\(minutes)′ · DDL \(d)"
        case (true, nil): return "今天读 ~\(minutes)′"
        case (false, let d?): return "Read ~\(minutes)′ today · due \(d)"
        case (false, nil): return "Read ~\(minutes)′ today"
        }
    }
    static func cardsTodayMoreItems(_ n: Int) -> String { zh ? "还有 \(n) 项" : "+\(n) more" }
    static func cardsTodayTickA11y(_ text: String) -> String { zh ? "勾选：\(text)" : "Check off: \(text)" }
    static var cardsTodayOpenDetailsA11y: String { zh ? "显示详情" : "Show Details" }

    // MARK: Context menu

    static var cardsMenuOpenPDF: String { zh ? "打开 PDF" : "Open PDF" }
    static var cardsMenuOpenInPreview: String { zh ? "在「预览」中打开" : "Open in Preview" }
    static var cardsMenuStatus: String { zh ? "状态" : "Status" }
    static func cardsMenuStatusName(_ s: PaperStatus) -> String {
        switch s {
        case .toRead: return zh ? "待读" : "To Read"
        case .reading: return zh ? "在读" : "Reading"
        case .done: return zh ? "已读" : "Read"
        }
    }
    static var cardsMenuMarkDone: String { zh ? "标记为已读" : "Mark as Read" }
    static var cardsMenuMarkUnread: String { zh ? "标记为未读" : "Mark as Unread" }
    static var cardsMenuPriority: String { zh ? "优先级" : "Priority" }
    static func cardsMenuPriorityName(_ p: Priority) -> String {
        switch p {
        case .high: return zh ? "高" : "High"
        case .normal: return zh ? "普通" : "Normal"
        case .low: return zh ? "低" : "Low"
        }
    }
    static var cardsMenuDeadline: String { "DDL" }
    static var cardsMenuPostponeDay: String { zh ? "推迟一天" : "Postpone One Day" }
    static var cardsMenuPostponeWeek: String { zh ? "推迟一周" : "Postpone One Week" }
    static var cardsMenuSetDate: String { zh ? "设定日期…" : "Set Date…" }
    static var cardsMenuRestoreAuto: String { zh ? "恢复自动排期" : "Restore Automatic Scheduling" }
    static var cardsMenuReplan: String { zh ? "按优先级重新排期" : "Reschedule by Priority" }
    static var cardsMenuUnschedule: String { zh ? "移到未排期" : "Move to Unscheduled" }
    static var cardsMenuCategory: String { zh ? "分类" : "Category" }
    static var cardsMenuReadWithClaude: String { zh ? "用 \(L.ai) 解读" : "Read with \(L.ai)" }
    static var cardsMenuRereadWithClaude: String { zh ? "用 \(L.ai) 重新解读" : "Re-read with \(L.ai)" }
    static var cardsMenuAgentOffExplain: String {
        zh ? "AI 解读已关闭 · 在设置中开启…" : "AI reading is off · Turn On in Settings…"
    }
    static var cardsMenuCopyTitle: String { zh ? "复制标题" : "Copy Title" }
    static var cardsMenuCopyDOI: String { zh ? "复制 DOI" : "Copy DOI" }
    static var cardsMenuEditMetadata: String { zh ? "编辑元数据…" : "Edit Metadata…" }
    static var cardsMenuRevealInFinder: String { zh ? "在 Finder 中显示" : "Show in Finder" }
    static var cardsMenuMoveToRecentlyDeleted: String { zh ? "移到最近删除" : "Move to Recently Deleted" }
    static var cardsMenuRestore: String { zh ? "恢复" : "Restore" }
    static var cardsMenuDeleteNow: String { zh ? "永久删除…" : "Delete Permanently…" }
    static func cardsMenuDeleteNowTitle(_ title: String) -> String {
        let t = title.count > 80 ? String(title.prefix(79)) + "…" : title
        return zh ? "永久删除「\(t)」？" : "Delete “\(t)” permanently?"
    }
    static var cardsMenuDeleteNowBody: String {
        zh ? "论文文件夹会移到废纸篓，它的阅读清单、笔记和 AI 解读会从 PaperDeck 中移除。此操作无法在 PaperDeck 中撤销。"
           : "The paper's folder goes to the Trash and its checklist, notes and AI reading are removed from PaperDeck. This can't be undone in PaperDeck."
    }
    static var cardsMenuDeleteNowConfirm: String { zh ? "永久删除" : "Delete Permanently" }

    // MARK: Deadline picker

    static var cardsPickTitle: String { zh ? "设定 DDL" : "Set Deadline" }
    static var cardsPickSet: String { zh ? "设定" : "Set" }
    static var cardsPickHint: String {
        zh ? "设定后 DDL 会被固定，自动排期不再移动它" : "The deadline will be pinned; automatic scheduling won't move it"
    }
    static var cardsPickNextMonday: String { zh ? "下周一" : "Next Monday" }
    static var cardsPickInAWeek: String { zh ? "一周后" : "In a Week" }

    // MARK: Empty states

    static var cardsEmptyLoading: String { zh ? "正在载入…" : "Loading…" }
    static var cardsEmptyLibraryTitle: String { zh ? "把论文 PDF 拖到这里" : "Drop paper PDFs here" }
    static var cardsEmptyLibrarySubtitle: String {
        zh ? "或拖到屏幕边缘的 PaperDeck 竖条" : "…or onto the PaperDeck strip at the edge of your screen"
    }
    static var cardsEmptyLibraryHint: String {
        zh ? "支持 PDF、文件夹和 PDF 链接 · 自动生成阅读清单与 DDL"
           : "PDFs, folders and PDF links · a reading checklist and deadline are created automatically"
    }
    static var cardsEmptyAddPDF: String { zh ? "添加 PDF…" : "Add PDF…" }
    static var cardsEmptyImportFolder: String { zh ? "导入文件夹…" : "Import Folder…" }
    static var cardsEmptyTodayTitle: String { zh ? "今天没有要读的论文" : "Nothing to read today" }
    static var cardsEmptyTodayAllDone: String { zh ? "待读清单已经清空，休息一下吧" : "Your reading list is clear — enjoy the break" }
    static func cardsEmptyTodayNext(day: String, title: String) -> String {
        zh ? "下一个 DDL \(day)：\(title)" : "Next deadline \(day): \(title)"
    }
    static var cardsEmptyShowToRead: String { zh ? "查看待读" : "Show To Read" }
    static var cardsEmptyToReadTitle: String { zh ? "没有待读论文" : "Nothing left to read" }
    static var cardsEmptyToReadMessage: String {
        zh ? "新添加的论文会自动排期并出现在这里" : "New papers are scheduled automatically and show up here"
    }
    static var cardsEmptyReadingTitle: String { zh ? "还没有在读的论文" : "Nothing in progress" }
    static var cardsEmptyReadingMessage: String {
        zh ? "打开 PDF 或勾选清单条目后，论文会移到这里" : "Papers move here once you open the PDF or tick a checklist item"
    }
    static var cardsEmptyDoneTitle: String { zh ? "还没有读完的论文" : "No finished papers yet" }
    static var cardsEmptyDoneMessage: String {
        zh ? "勾选完全部清单条目，或按 ⌘D 标记为已读" : "Tick off every checklist item, or press ⌘D to mark a paper as read"
    }
    static var cardsEmptyAttentionTitle: String { zh ? "一切正常" : "All good" }
    static var cardsEmptyAttentionMessage: String {
        zh ? "解读失败、需要登录 \(L.ai)、加密、扫描版或文件缺失的论文会出现在这里"
           : "Papers whose reading failed, need a \(L.ai) sign-in, are encrypted, scanned or missing show up here"
    }
    static var cardsEmptyUncategorizedTitle: String { zh ? "所有论文都已分类" : "Everything is categorized" }
    static var cardsEmptyUncategorizedMessage: String {
        zh ? "\(L.ai) 解读后会自动归类；也可以在右键菜单 ▸ 分类 中手动选择"
           : "\(L.ai) files papers after reading them; you can also pick one via right-click ▸ Category"
    }
    static var cardsEmptyDeletedTitle: String { zh ? "最近删除是空的" : "Recently Deleted is empty" }
    static var cardsEmptyDeletedMessage: String {
        zh ? "删除的论文会在这里保留 30 天，之后移到废纸篓" : "Deleted papers stay here for 30 days before moving to the Trash"
    }
    static var cardsEmptyCategoryTitle: String { zh ? "这个分类还没有论文" : "No papers in this category" }
    static var cardsEmptyCategoryMessage: String {
        zh ? "在卡片的右键菜单 ▸ 分类 中把论文移到这里" : "Use right-click ▸ Category on a card to move papers here"
    }
    static func cardsEmptySearchTitle(_ query: String) -> String {
        zh ? "没有找到「\(query)」" : "No results for “\(query)”"
    }
    static var cardsEmptySearchMessage: String {
        zh ? "试试作者、期刊、DOI 或正文中的词" : "Try an author, journal, DOI or a word from the full text"
    }
}
