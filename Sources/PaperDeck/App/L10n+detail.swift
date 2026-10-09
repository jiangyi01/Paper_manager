import Foundation
import PaperDeckCore

// Strings of the detail inspector (PaperDetailView, ChecklistView, NotesEditor,
// MetadataEditSheet). Namespaced as `L.Detail.…` so they never collide with other slices.
// DDL chips, weekdays and the at-risk hint come from SharedStrings / DeadlineLabel.

extension L {
    enum Detail {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Header
        static var authorsUnknown: String { zh ? "作者未知" : "Unknown authors" }
        static func expandAuthors(_ n: Int) -> String { zh ? "展开全部 \(n) 位作者" : "Show all \(n) authors" }
        static var collapseAuthors: String { zh ? "收起" : "Show less" }
        static func copyValue(_ s: String) -> String { zh ? "复制 \(s)" : "Copy \(s)" }
        static var openLink: String { zh ? "在浏览器中打开" : "Open in Browser" }

        static var category: String { zh ? "分类" : "Category" }
        static var uncategorized: String { zh ? "未分类" : "Uncategorized" }
        static var categoryHelp: String { zh ? "更改分类" : "Change category" }
        static var categoryNeedsReview: String { zh ? "待确认" : "Review" }
        static var categoryNeedsReviewHelp: String {
            zh ? "AI 选择了最接近的现有分类，请确认或更改" : "The AI picked the closest existing category — confirm or change it"
        }
        static var confirmCategory: String { zh ? "确认" : "Confirm" }
        static var newCategory: String { zh ? "新建分类…" : "New Category…" }
        static var newCategoryTitle: String { zh ? "新建分类" : "New Category" }
        static var newCategoryPlaceholder: String { zh ? "分类名称" : "Category name" }
        static var newCategoryMessage: String {
            zh ? "新分类会出现在侧栏，这篇论文会移到其中。" : "The category appears in the sidebar and this paper moves into it."
        }
        static var create: String { zh ? "创建" : "Create" }

        static var addTag: String { zh ? "标签" : "Tag" }
        static var tagPlaceholder: String { zh ? "新标签" : "New tag" }
        static func removeTag(_ name: String) -> String { zh ? "移除标签 #\(name)" : "Remove tag #\(name)" }
        static var tagFromClaude: String { zh ? "AI 添加的标签" : "Tag added by the AI" }
        static var tagFromUser: String { zh ? "你添加的标签" : "Tag added by you" }
        static func tagWillSaveAs(_ n: String) -> String { zh ? "将保存为 #\(n)" : "Will be saved as #\(n)" }
        static func tagExists(_ n: String) -> String { zh ? "已有 #\(n)" : "Already tagged #\(n)" }
        static var tagPressReturn: String { zh ? "按 ↩ 添加" : "Press ↩ to add" }
        static var tagInvalid: String {
            zh ? "标签需至少 2 个字母或数字（a–z、0–9）" : "Tags need at least 2 letters or digits (a–z, 0–9)"
        }

        static var flagMissing: String { zh ? "找不到 PDF 文件（可能被移动或删除）" : "The PDF file is missing (moved or deleted?)" }
        static var flagLocked: String { zh ? "PDF 已加密，无法读取文本" : "The PDF is encrypted; its text can't be read" }
        static var flagUnreadable: String { zh ? "PDF 无法打开" : "The PDF can't be opened" }
        static var flagScanned: String { zh ? "扫描版 PDF，几乎没有文本层" : "Scanned PDF with little or no text layer" }
        static var textIncomplete: String { zh ? "文本不完整" : "Incomplete text" }

        // MARK: Controls
        static var status: String { zh ? "状态" : "Status" }
        static var statusToRead: String { zh ? "待读" : "To Read" }
        static var statusReading: String { zh ? "在读" : "Reading" }
        static var statusDone: String { zh ? "已读" : "Read" }
        static var priority: String { zh ? "优先级" : "Priority" }
        static var priorityLow: String { zh ? "低" : "Low" }
        static var priorityNormal: String { zh ? "普通" : "Normal" }
        static var priorityHigh: String { zh ? "高" : "High" }
        static var replanWithPriority: String { zh ? "按新优先级重新排期此论文" : "Reschedule this paper for the new priority" }
        static var replanHelp: String {
            zh ? "按新的优先级重新计算这篇论文的 DDL" : "Recompute this paper's deadline with the new priority"
        }

        static var deadline: String { zh ? "DDL" : "Deadline" }
        static var modeAuto: String { zh ? "自动" : "Auto" }
        static var modeAutoProvisional: String { zh ? "自动 · 暂定" : "Auto · tentative" }
        static var modePinned: String { zh ? "固定" : "Pinned" }
        static var modeAutoHelp: String {
            zh ? "按预算和优先级自动排期；只有你的操作会移动它" : "Scheduled from your budget and priority; only your actions move it"
        }
        static var modeAutoProvisionalHelp: String {
            zh ? "按启发式估计暂定，\(L.ai) 解读后可能调整一次" : "Tentative from a quick estimate; may be adjusted once after \(L.ai) reads it"
        }
        static var modePinnedHelp: String { zh ? "你设定的日期，排期不会移动它" : "A date you set; the planner never moves it" }
        static var postponeDay: String { zh ? "推迟一天" : "Postpone a Day" }
        static var postponeDayHelp: String { zh ? "推迟到下一个阅读日（⇧⌘P）" : "Move to the next reading day (⇧⌘P)" }
        static var postponeWeek: String { zh ? "推迟一周" : "Postpone a Week" }
        static var restoreAuto: String { zh ? "恢复自动排期" : "Restore Automatic Scheduling" }
        static var unschedule: String { zh ? "移到未排期" : "Move to Unscheduled" }
        static var scheduleAutomatically: String { zh ? "自动排期" : "Schedule Automatically" }
        static var setDate: String { zh ? "设定日期…" : "Set Date…" }
        static var pinThisDate: String { zh ? "固定到此日期" : "Pin to This Date" }
        static var moreDeadlineActions: String { zh ? "更多 DDL 操作" : "More deadline actions" }

        static var estimate: String { zh ? "预计" : "Estimate" }
        static var estimateHelp: String {
            zh ? "预计阅读时长（±5 分钟）；修改不会移动 DDL" : "Estimated reading time (±5 min); changing it never moves the deadline"
        }
        static var estimateByUser: String { zh ? "手动" : "Manual" }
        static var estimateHeuristic: String { zh ? "估算" : "Estimated" }
        /// `65′` (same in both languages).
        static func minutes(_ n: Int) -> String { "\(n)′" }
        static func remaining(_ m: Int) -> String { zh ? "剩 \(m)′" : "\(m)′ left" }
        static func plannedToday(_ m: Int) -> String { zh ? "今天计划 \(m)′" : "\(m)′ planned today" }

        // MARK: Agent bar (Claude / ChatGPT)
        static func agentRunning(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 阅读中…" : "\(p.shortName) is reading…" }
        static var agentQueued: String { zh ? "排队中" : "Queued" }
        static func agentQueuedPosition(_ n: Int) -> String { zh ? "排队中 · 第 \(n)" : "Queued · #\(n)" }
        static var agentQueuedBehind: String { zh ? "前面有论文正在解读" : "Another paper is being read first" }
        static var agentQueuedBehindEmail: String { zh ? "AI 正在先分析一封邮件" : "An email is being analyzed first" }
        static func agentModeOff(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 解读已关闭" : "\(p.shortName) reading is off" }
        static var agentModeOffDetail: String {
            zh ? "在「设置 ▸ AI 解读」中开启后即可解读这篇论文" : "Turn it on in Settings ▸ AI Reading to read this paper"
        }
        static var agentWaitingToStart: String { zh ? "等待开始" : "Waiting to start" }
        static var agentWaitingToStartDetail: String {
            zh ? "在 AI 解读关闭期间加入，点「开始解读」继续" : "Added while AI reading was off — start it when you're ready"
        }
        static var agentModeOffExplain: String {
            zh ? "AI 解读已关闭，可在「设置 ▸ AI 解读」中开启" : "AI reading is off — turn it on in Settings ▸ AI Reading"
        }
        static var agentAwaitingConfirm: String { zh ? "等待确认" : "Awaiting confirmation" }
        static var agentAwaitingConfirmDetail: String {
            zh ? "批量导入的论文需确认后才开始解读" : "Papers from a batch import wait for your go-ahead"
        }
        static var agentFailed: String { zh ? "解读失败" : "Reading failed" }
        static var agentLimited: String { zh ? "额度用尽" : "Usage limit reached" }
        static func agentLimitedUntil(_ time: String) -> String { zh ? "额度用尽 · \(time) 继续" : "Usage limit · resumes \(time)" }
        static var agentLimitedDetail: String { zh ? "额度恢复后自动继续解读" : "Resumes automatically when the limit resets" }
        static func agentNeedsLogin(_ p: AIProviderKind) -> String { zh ? "需登录 \(p.shortName)" : "Sign in to \(p.shortName)" }
        static func agentNeedsLoginDetail(_ p: AIProviderKind) -> String {
            switch p {
            case .claude: return zh ? "在终端运行 claude 后输入 /login" : "Run claude in Terminal, then enter /login"
            case .codex:
                return zh ? "在终端运行 codex login，选择「Sign in with ChatGPT」" : "Run codex login in Terminal and choose “Sign in with ChatGPT”"
            }
        }
        static var agentSkipped: String { zh ? "扫描版/加密 PDF · 未解读" : "Scanned/encrypted PDF · not read" }
        static func agentNotRead(_ p: AIProviderKind) -> String { zh ? "尚未由 \(p.shortName) 解读" : "Not read by \(p.shortName) yet" }
        static var agentNotReadDetail: String {
            zh ? "生成 Summary、Method、Results 等，占用少量订阅额度" : "Adds summary, method, results… Uses a little of your subscription"
        }
        /// `由 Claude Sonnet 解读` / `由 ChatGPT GPT-5.6-Terra 解读` (`name` nil → 「由 AI 解读」).
        static func agentReadBy(_ name: String?, model: String?) -> String {
            let who = [name ?? "AI", model].compactMap { $0 }.joined(separator: " ")
            return zh ? "由 \(who) 解读" : "Read by \(who)"
        }
        static var agentReadByMock: String { zh ? "由模拟 Agent 解读（开发）" : "Read by the mock agent (dev)" }
        static func agentReadWithClaude(_ p: AIProviderKind) -> String { zh ? "用 \(p.shortName) 解读" : "Read with \(p.shortName)" }
        static var agentReread: String { zh ? "重新解读" : "Re-read" }
        static func agentRereadHelp(_ p: AIProviderKind) -> String {
            zh ? "用 \(p.shortName) 重新解读（⌥⌘R），你编辑过的清单条目会保留" : "Read again with \(p.shortName) (⌥⌘R); steps you edited are kept"
        }
        static var agentRetry: String { zh ? "重试" : "Retry" }
        static var agentStartNow: String { zh ? "开始解读" : "Start Reading" }
        static var agentCancelHelp: String { zh ? "停止并移出队列" : "Stop and remove from the queue" }
        static func agentQuotaHelp(_ p: AIProviderKind) -> String {
            zh ? "会占用 \(p.shortName) 订阅额度" : "Uses your \(p.shortName) subscription"
        }
        static var goToSettings: String { zh ? "去设置" : "Open Settings" }

        // MARK: Sections
        static var checklist: String { zh ? "阅读清单" : "Checklist" }
        static var notes: String { zh ? "笔记" : "Notes" }
        static var file: String { zh ? "文件" : "File" }
        static var tldrPlaceholder: String { zh ? "\(L.ai) 解读后显示 TL;DR" : "The TL;DR appears after \(L.ai) reads the paper" }
        static var cardPlaceholder: String {
            zh ? "\(L.ai) 解读后在这里显示 Summary、Key contributions、Method、Results 等"
               : "Summary, key contributions, method and results appear here after \(L.ai) reads the paper"
        }
        static var cardSkippedPlaceholder: String {
            zh ? "这份 PDF 没有可用的文本层（扫描版或加密），\(L.ai) 无法解读"
               : "This PDF has no usable text layer (scanned or encrypted), so \(L.ai) can't read it"
        }
        static var sectionExpanded: String { zh ? "已展开" : "Expanded" }
        static var sectionCollapsed: String { zh ? "已折叠" : "Collapsed" }
        static var inferredHelp: String { zh ? "由 AI 推断，作者未明确说明" : "Inferred by the AI; not stated by the authors" }

        // MARK: Checklist
        static func checklistProgress(done: Int, total: Int, remaining: Int) -> String {
            if total == 0 { return zh ? "剩 \(remaining)′" : "\(remaining)′ left" }
            return zh ? "\(done)/\(total) · 剩 \(remaining)′" : "\(done)/\(total) · \(remaining)′ left"
        }
        static var checklistEmpty: String { zh ? "还没有清单条目，在下方添加" : "No steps yet — add one below" }
        static var checklistEmptyReadOnly: String { zh ? "没有清单条目" : "No checklist" }
        static var markDone: String { zh ? "标记为完成" : "Mark as Done" }
        static var markNotDone: String { zh ? "标记为未完成" : "Mark as Not Done" }
        static var itemDone: String { zh ? "已完成" : "Done" }
        static var itemNotDone: String { zh ? "未完成" : "Not done" }
        static var doubleClickToEdit: String { zh ? "双击编辑" : "Double-click to edit" }
        static var dragToReorder: String { zh ? "拖动以排序" : "Drag to reorder" }
        static var editItem: String { zh ? "编辑条目" : "Edit Step" }
        static var deleteItem: String { zh ? "删除条目" : "Delete Step" }
        static var moveUp: String { zh ? "上移" : "Move Up" }
        static var moveDown: String { zh ? "下移" : "Move Down" }
        static var itemMinutesMenu: String { zh ? "时长" : "Duration" }
        static var itemTextPlaceholder: String { zh ? "条目内容" : "Step" }
        static var itemSectionPlaceholder: String { zh ? "位置，如 Fig. 2" : "Where, e.g. Fig. 2" }
        static var addItemPlaceholder: String { zh ? "添加条目…" : "Add a step…" }
        static var addItemHelp: String { zh ? "添加条目（⌘↩）" : "Add step (⌘↩)" }
        static var add: String { zh ? "添加" : "Add" }
        static var save: String { zh ? "保存" : "Save" }
        static var originHeuristic: String { zh ? "自动生成（基础清单）" : "Auto-generated (basic checklist)" }
        static var originAgent: String { zh ? "AI 生成" : "From the AI" }
        static var originUser: String { zh ? "手动添加" : "Added by you" }
        static var originEditedSuffix: String { zh ? " · 已编辑" : " · edited" }
        static var openPDF: String { zh ? "打开 PDF" : "Open PDF" }
        static func openPDFAtPage(_ p: Int) -> String { zh ? "打开 PDF（从第 \(p) 页读起）" : "Open PDF (start at p. \(p))" }

        // MARK: Notes
        static var notesPlaceholder: String {
            zh ? "写下你的想法、问题、要追的引用…" : "Thoughts, questions, references to follow…"
        }
        static var notesEmptyReadOnly: String { zh ? "没有笔记" : "No notes" }
        static var notesAutosave: String { zh ? "自动保存 · 同步到 notes.md" : "Saved automatically to notes.md" }
        static var notesReadOnly: String { zh ? "恢复后可编辑" : "Restore the paper to edit" }
        static var notesUnsaved: String { zh ? "未保存" : "Unsaved" }
        static var notesSaving: String { zh ? "正在保存…" : "Saving…" }
        static var notesSaved: String { zh ? "已保存 · notes.md" : "Saved · notes.md" }
        static var notesSaveFailed: String { zh ? "保存失败" : "Couldn't save" }

        // MARK: File
        static var fileName: String { zh ? "名称" : "Name" }
        static var pages: String { zh ? "页数" : "Pages" }
        static var size: String { zh ? "大小" : "Size" }
        static var path: String { zh ? "路径" : "Path" }
        static var originalName: String { zh ? "原文件名" : "Original" }
        static var mayShareStorage: String {
            zh ? "可能与原文件共享存储（APFS 克隆）" : "May share storage with the original file (APFS clone)"
        }
        static var revealInFinder: String { zh ? "在 Finder 中显示" : "Show in Finder" }
        static var refreshMetadata: String { zh ? "刷新元数据" : "Refresh Metadata" }
        static var refreshMetadataHelp: String {
            zh ? "重新查询 Crossref / arXiv / bioRxiv（忽略缓存）" : "Look up Crossref / arXiv / bioRxiv again (bypasses the cache)"
        }
        static var refreshMetadataUserEditedHelp: String {
            zh ? "元数据已手动编辑，刷新不会覆盖；可在「编辑元数据…」中从 DOI 重新获取"
               : "Edited by hand, so a refresh won't overwrite it — use Edit Metadata… ▸ Fetch from DOI"
        }
        static var metadataLookupOff: String { zh ? "元数据查询已在设置中关闭" : "Metadata lookup is turned off in Settings" }
        /// A paper from an email whose title must not be sent (`titleLookupHeld`): identifiers only.
        static var titleKeptPrivate: String {
            zh ? "标题未外发：仅按标识符查询" : "Title kept private — looked up by identifier only"
        }
        static var lookUpMetadataOnline: String { zh ? "联网查询元数据" : "Look Up Metadata Online" }
        static var lookUpMetadataOnlineHelp: String {
            zh ? "这篇论文来自一封可能保密或尚未发表的邮件，所以只按 DOI / arXiv 号查询过。点此也按标题联网查询（Crossref / arXiv / bioRxiv）"
               : "This paper came from an email that may be confidential or unpublished, so it was looked up by DOI / arXiv id only. Click to also search by its title (Crossref / arXiv / bioRxiv)"
        }
        static var metadataUpdated: String { zh ? "元数据已更新" : "Metadata updated" }
        static var metadataUnchanged: String { zh ? "元数据没有变化" : "Metadata is already up to date" }
        static var metadataKeptUserEdits: String {
            zh ? "元数据已手动编辑，刷新不会覆盖" : "Metadata was edited by hand; the refresh didn't overwrite it"
        }
        static var editMetadataEllipsis: String { zh ? "编辑元数据…" : "Edit Metadata…" }
        static var editMetadataHelp: String {
            zh ? "编辑标题、作者、期刊、年份与编号（⌘E）" : "Edit title, authors, venue, year and identifiers (⌘E)"
        }

        // MARK: Metadata sheet
        static var metaSheetTitle: String { zh ? "编辑元数据" : "Edit Metadata" }
        static var metaSheetSubtitle: String {
            zh ? "保存后按新信息重命名文件夹，自动查询不会再覆盖这些字段。"
               : "Saving renames the folder to match; automatic lookups won't overwrite these fields."
        }
        static var metaTitle: String { zh ? "标题" : "Title" }
        static var metaAuthors: String { zh ? "作者" : "Authors" }
        static var metaAuthorsHint: String { zh ? "每行一位作者" : "One author per line" }
        static var metaVenue: String { zh ? "期刊" : "Venue" }
        static var metaYear: String { zh ? "年份" : "Year" }
        static var metaYearInvalid: String { zh ? "年份应为 4 位数字" : "The year needs 4 digits" }
        static var metaDOIInvalid: String { zh ? "无法识别的 DOI" : "Not a valid DOI" }
        static var metaArxivInvalid: String { zh ? "无法识别的 arXiv 编号" : "Not a valid arXiv ID" }
        static var metaFetchFromDOI: String { zh ? "从 DOI 重新获取" : "Fetch from DOI" }
        static var metaFetchHelp: String {
            zh ? "按 DOI（或 arXiv 编号）查询 Crossref / arXiv / bioRxiv" : "Look up the DOI (or arXiv ID) on Crossref / arXiv / bioRxiv"
        }
        static var metaFetchApplied: String { zh ? "已按 DOI 更新元数据" : "Metadata updated from the identifier" }
        static func metaFetchPrefilled(source: String) -> String {
            zh ? "已从 \(source) 填入，检查后点「保存」" : "Filled in from \(source) — review, then Save"
        }
        static var metaFetchNotFound: String { zh ? "没有找到该编号的元数据" : "No metadata found for this identifier" }

        // MARK: Recently deleted
        static var deletedTitle: String { zh ? "此论文在「最近删除」中" : "This paper is in Recently Deleted" }
        static func deletedBody(daysLeft: Int) -> String {
            if daysLeft <= 0 {
                return zh ? "即将永久删除。恢复后可继续阅读和编辑。" : "It will be deleted permanently soon. Restore it to keep reading and editing."
            }
            return zh ? "\(daysLeft) 天后自动永久删除。恢复后可继续阅读和编辑。"
                      : "Deleted permanently in \(daysLeft) day\(daysLeft == 1 ? "" : "s"). Restore it to keep reading and editing."
        }
        static var deletedBodyNoDate: String { zh ? "恢复后可继续阅读和编辑。" : "Restore it to keep reading and editing." }
        static var restore: String { zh ? "恢复" : "Restore" }
        static var deleteNow: String { zh ? "永久删除" : "Delete Permanently" }
        static var deleteNowEllipsis: String { zh ? "永久删除…" : "Delete Permanently…" }
        static var deleteNowConfirmTitle: String { zh ? "永久删除这篇论文？" : "Delete this paper permanently?" }
        static var deleteNowConfirmMessage: String {
            zh ? "论文文件夹会移到废纸篓，卡片、清单和笔记将从 PaperDeck 中移除。"
               : "The paper's folder goes to the Trash and its card, checklist and notes are removed from PaperDeck."
        }
    }
}
