import Foundation
import PaperDeckCore
import PaperDeckConfig

// Strings of the library window shell (sidebar, toolbar, AI pill + queue,
// banners, batch dialog, drop overlay). Namespaced under `L.Shell` so they can
// never collide with the other UI slices' `extension L` files.
extension L {
    enum Shell {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Sidebar

        static var sectionLibrary: String { zh ? "资料库" : "Library" }
        static var today: String { zh ? "今天" : "Today" }
        static var toRead: String { zh ? "待读" : "To Read" }
        static var reading: String { zh ? "在读" : "Reading" }
        static var done: String { zh ? "已读" : "Read" }
        static var all: String { zh ? "全部" : "All Papers" }
        static var needsAttention: String { zh ? "需要处理" : "Needs Attention" }
        static var categories: String { zh ? "分类" : "Categories" }
        static var uncategorized: String { zh ? "未分类" : "Uncategorized" }
        static var recentlyDeleted: String { zh ? "最近删除" : "Recently Deleted" }
        static var newBadge: String { "NEW" }
        static var newCategoryA11y: String { zh ? "新分类" : "New category" }
        static func overdueCount(_ n: Int) -> String {
            zh ? "\(n) 篇，含逾期" : "\(n), including overdue"
        }
        static func count(_ n: Int) -> String { zh ? "\(n) 篇" : "\(n)" }

        static var renameCategory: String { zh ? "重命名…" : "Rename…" }
        static var editCategoryDescription: String { zh ? "编辑描述…" : "Edit Description…" }
        static var deleteCategory: String { zh ? "删除（论文移到未分类）" : "Delete (Papers Become Uncategorized)" }
        static var renameCategoryTitle: String { zh ? "重命名分类" : "Rename Category" }
        static var categoryName: String { zh ? "名称" : "Name" }
        static var categoryDescriptionTitle: String { zh ? "编辑分类描述" : "Edit Category Description" }
        static var categoryDescriptionHint: String {
            zh ? "一句话描述这个分类。\(L.ai) 归类时会参考它，保持前后一致。"
               : "One line describing this category. \(L.ai) reads it to categorize papers consistently."
        }
        static var categoryDescriptionPlaceholder: String { FieldStrings.categoryDescriptionPlaceholder(L.field, L.lang) }
        static var save: String { zh ? "保存" : "Save" }
        static var delete: String { zh ? "删除" : "Delete" }
        static func deleteCategoryConfirmTitle(_ name: String) -> String {
            zh ? "删除分类「\(name)」？" : "Delete the category “\(name)”?"
        }
        static func deleteCategoryConfirmBody(_ n: Int) -> String {
            if zh { return n == 0 ? "这个分类里没有论文。" : "其中 \(n) 篇论文会移到「未分类」，论文本身不会被删除。" }
            return n == 0 ? "No papers are in this category."
                : "Its \(n == 1 ? "paper" : "\(n) papers") will become uncategorized. No papers are deleted."
        }

        // Footer
        static func footerTotals(count: Int, size: String) -> String {
            zh ? "\(count) 篇 · \(size)" : "\(count == 1 ? "1 paper" : "\(count) papers") · \(size)"
        }
        static func footerShared(_ size: String) -> String {
            zh ? "约 \(size) 可能与原文件共享（估算）" : "~\(size) may be shared with the originals (estimate)"
        }
        static func footerClaude(_ p: AIProviderKind, _ status: String) -> String { p.shortName + " · " + status }

        // MARK: Content / inspector

        static var loading: String { zh ? "正在打开资料库…" : "Opening library…" }
        static var inspectorEmptyTitle: String { zh ? "未选择论文" : "No Paper Selected" }
        static var inspectorEmptyHint: String { zh ? "选择一篇论文查看详情与阅读清单" : "Select a paper to see its details and checklist" }
        static func todaySubtitle(count: Int, minutes: Int) -> String {
            count == 0 ? (zh ? "今天没有计划" : "Nothing planned")
                : SharedStrings.papers(count, L.lang) + " · " + SharedStrings.aboutMinutes(minutes, L.lang)
        }

        // MARK: Toolbar

        static var searchPrompt: String { zh ? "搜索标题、作者、全文" : "Search titles, authors, full text" }
        static var sort: String { zh ? "排序" : "Sort" }
        static var sortDeadline: String { zh ? "DDL" : "Deadline" }
        static var sortAdded: String { zh ? "添加时间" : "Date Added" }
        static var sortTitle: String { zh ? "标题" : "Title" }
        static var sortDisabledHint: String { zh ? "此分区有固定顺序" : "This section has a fixed order" }
        static var add: String { zh ? "添加" : "Add" }
        static var addPDF: String { zh ? "添加 PDF…" : "Add PDFs…" }
        static var importFolder: String { zh ? "导入文件夹…" : "Import Folder…" }
        static var showInspector: String { zh ? "显示详情" : "Show Inspector" }
        static var hideInspector: String { zh ? "隐藏详情" : "Hide Inspector" }
        static var addPrompt: String { zh ? "添加" : "Add" }
        static var importPrompt: String { zh ? "导入" : "Import" }
        static var addPDFMessage: String { zh ? "选择要添加到 PaperDeck 的论文 PDF" : "Choose paper PDFs to add to PaperDeck" }
        static var importFolderMessage: String {
            zh ? "选择包含论文 PDF 的文件夹（递归查找，每次最多 500 篇）"
               : "Choose folders that contain paper PDFs (searched recursively, up to 500 at a time)"
        }

        // MARK: AI pill (Claude / ChatGPT)

        static func claudeStatusA11y(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 状态" : "\(p.shortName) status" }
        static var pillOff: String { zh ? "解读已关闭" : "Reading Off" }
        static func pillNotInstalled(_ p: AIProviderKind) -> String {
            switch p {
            case .claude: return zh ? "未安装 Claude" : "Claude Not Installed"
            case .codex: return zh ? "未找到 Codex" : "Codex Not Found"
            }
        }
        static var pillNeedsLogin: String { zh ? "需要登录" : "Sign-in Needed" }
        static var pillUnsupported: String { zh ? "版本不受支持" : "Unsupported Version" }
        static func pillLimited(_ time: String) -> String { zh ? "额度用尽 \(time)" : "Limit Reached · \(time)" }
        static func pillActive(running: Int, queued: Int) -> String {
            switch (running > 0, queued > 0) {
            case (true, true): return zh ? "阅读中 \(running) · 排队 \(queued)" : "Reading \(running) · \(queued) Queued"
            case (true, false): return zh ? "阅读中 \(running)" : "Reading \(running)"
            default: return zh ? "排队 \(queued)" : "\(queued) Queued"
            }
        }
        /// The AI slot is analyzing an email (mail triage) / emails wait for it.
        static var pillTriageRunning: String { zh ? "正在分析邮件" : "Analyzing Email" }
        static func pillTriageQueued(_ n: Int) -> String { zh ? "邮件排队 \(n)" : (n == 1 ? "1 Email Queued" : "\(n) Emails Queued") }
        static func pillHeld(_ n: Int) -> String { zh ? "等待确认 \(n)" : "\(n) Awaiting" }
        static func pillReady(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 就绪" : "\(p.shortName) Ready" }
        static func pillChecking(_ p: AIProviderKind) -> String { "\(p.shortName)…" }

        // MARK: Queue popover

        static func queueTitle(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 解读队列" : "\(p.shortName) Queue" }
        static func signedIn(plan: String?, version: String) -> String {
            let p = plan.map { " · " + $0.capitalized } ?? ""
            return zh ? "已登录\(p) · \(version)" : "Signed in\(p) · \(version)"
        }
        static func statusRunning(_ p: AIProviderKind, _ elapsed: String) -> String {
            zh ? "\(p.shortName) 阅读中… \(elapsed)" : "\(p.shortName) reading… \(elapsed)"
        }
        static func statusQueued(_ pos: Int?) -> String {
            guard let pos else { return zh ? "排队中" : "Queued" }
            return zh ? "排队中 · 第 \(pos)" : "Queued · #\(pos)"
        }
        static var statusHeld: String { zh ? "等待确认" : "Awaiting confirmation" }
        static var statusHeldOff: String { zh ? "解读已关闭 · 等待开启" : "Reading off · waiting" }
        static var statusLimited: String { zh ? "额度用尽 · 稍后继续" : "Usage limit · resumes later" }
        static var readNow: String { zh ? "立即解读" : "Read Now" }
        static func readAllNow(_ n: Int) -> String { zh ? "全部立即解读（\(n)）" : "Read All Now (\(n))" }
        static var cancelJob: String { zh ? "取消解读" : "Cancel Reading" }
        static func queueExisting(_ n: Int) -> String {
            zh ? "为现有论文排队解读（\(n) 篇）" : "Queue Existing Papers (\(n))"
        }
        static func queueExistingConfirmTitle(_ n: Int) -> String {
            zh ? "为 \(n) 篇论文排队 \(L.ai) 解读？" : "Queue \(n == 1 ? "1 paper" : "\(n) papers") for \(L.ai)?"
        }
        static var queueExistingConfirmBody: String {
            let time = L.provider == .codex ? "30–120" : "30–60"
            return zh ? "每篇约 \(time) 秒，占用 \(L.ai) 订阅额度。可以随时在这里取消。"
                      : "About \(time) seconds each; this uses your \(L.ai) subscription quota. You can cancel any time here."
        }
        static var queueExistingConfirm: String { zh ? "排队解读" : "Queue" }
        static var queueEmpty: String { zh ? "队列为空" : "Nothing in the queue" }
        static var queueEmptyHint: String {
            zh ? "新论文会自动排队；也可以在论文的右键菜单里选「用 \(L.ai) 重新解读」。"
               : "New papers are queued automatically. You can also choose “Re-read with \(L.ai)” from a paper's context menu."
        }
        static func queueMore(_ n: Int) -> String { zh ? "还有 \(n) 篇" : "\(n) more" }
        static var offExplain: String {
            zh ? "AI 解读已关闭。新论文只生成基础清单。" : "AI reading is off. New papers only get a basic checklist."
        }
        static var openAISettings: String { zh ? "打开设置 ▸ AI 解读" : "Open Settings ▸ AI Reading" }
        static var goToSettings: String { zh ? "去设置" : "Settings…" }
        static func needsLoginExplain(_ p: AIProviderKind) -> String {
            switch p {
            case .claude:
                return zh ? "Claude 未登录。在终端运行 claude 后输入 /login，然后点「我已登录」。PaperDeck 只使用订阅登录。"
                          : "Claude isn't signed in. Run claude in Terminal and type /login, then click “I've Signed In”. PaperDeck only uses subscription sign-in."
            case .codex:
                return zh ? "ChatGPT 未登录。在终端运行 codex login，选择「Sign in with ChatGPT」，然后点「我已登录」。PaperDeck 只使用 ChatGPT 订阅登录，不使用 API key。"
                          : "ChatGPT isn't signed in. Run codex login in Terminal, choose “Sign in with ChatGPT”, then click “I've Signed In”. PaperDeck only uses the ChatGPT subscription login, never an API key."
            }
        }
        static var iveLoggedIn: String { zh ? "我已登录" : "I've Signed In" }
        static var openTerminal: String { zh ? "打开终端" : "Open Terminal" }
        static func notInstalledExplain(_ p: AIProviderKind) -> String {
            switch p {
            case .claude:
                return zh ? "没有找到 Claude Code 命令行工具。安装后点「重新检测」。"
                          : "The Claude Code CLI wasn't found. Install it, then click “Check Again”."
            case .codex:
                return zh ? "没有找到 Codex CLI。它随 ChatGPT 桌面版一起安装，也可以用 brew install --cask codex 安装；安装后点「重新检测」。"
                          : "The Codex CLI wasn't found. It ships with the ChatGPT desktop app, or install it with brew install --cask codex; then click “Check Again”."
            }
        }
        static func unsupportedExplain(_ p: AIProviderKind, _ why: String) -> String {
            zh ? "当前 \(p.cliName) 版本不受支持：\(why)" : "This \(p.cliName) version isn't supported: \(why)"
        }
        static var recheck: String { zh ? "重新检测" : "Check Again" }
        static func limitedExplain(_ p: AIProviderKind, _ time: String) -> String {
            zh ? "\(p.shortName) 额度已用尽，\(time) 自动继续解读。" : "\(p.shortName) usage limit reached — reading resumes at \(time)."
        }
        static func mockMode(_ p: AIProviderKind) -> String {
            zh ? "模拟模式（不调用 \(p.shortName)）" : "Mock mode (\(p.shortName) is not called)"
        }

        // MARK: Banners

        static func bannerNotLoggedIn(_ p: AIProviderKind) -> String {
            zh ? "\(p.shortName) 未登录 · 新论文只生成基础清单" : "\(p.shortName) isn't signed in · new papers only get a basic checklist"
        }
        static func bannerNotInstalled(_ p: AIProviderKind) -> String {
            zh ? "未找到 \(p.cliName) · 新论文只生成基础清单" : "\(p.cliName) not found · new papers only get a basic checklist"
        }
        static func bannerUnsupported(_ p: AIProviderKind) -> String {
            zh ? "\(p.cliName) 版本不受支持 · 新论文只生成基础清单" : "Unsupported \(p.cliName) version · new papers only get a basic checklist"
        }
        static func bannerAtRisk(_ n: Int) -> String {
            zh ? "\(n) 篇论文按当前预算无法按 DDL 读完"
               : "\(n == 1 ? "1 paper" : "\(n) papers") can't be finished by the deadline at the current budget"
        }
        static func bannerAtRiskPinned(_ m: Int) -> String {
            zh ? "其中 \(m) 篇是固定 DDL，不会被移动" : "\(m) of them have pinned deadlines and won't move"
        }
        static func shiftAtRisk(_ n: Int) -> String { zh ? "顺延这 \(n) 篇" : "Push Back \(n)" }
        static var ignore: String { zh ? "忽略" : "Ignore" }
        static func shifted(_ n: Int) -> String {
            zh ? "已顺延 \(n) 篇论文的 DDL" : "Moved \(n == 1 ? "1 deadline" : "\(n) deadlines")"
        }
        static func bannerLibraryMissing(_ path: String) -> String {
            zh ? "找不到资料库文件夹 \(path)" : "Library folder not found: \(path)"
        }
        static var bannerLibraryMissingDetail: String {
            zh ? "导入已暂停。请连接所在磁盘，或在设置中更改资料库位置。"
               : "Imports are paused. Reconnect the disk, or change the library location in Settings."
        }
        static func bannerMissingFiles(_ n: Int) -> String {
            zh ? "\(n) 篇论文的 PDF 文件找不到了" : "\(n == 1 ? "1 paper's PDF is" : "\(n) papers' PDFs are") missing"
        }
        static var show: String { zh ? "查看" : "Show" }
        static var dismiss: String { zh ? "关闭" : "Dismiss" }

        // MARK: Batch dialog

        static func batchTitle(_ n: Int) -> String {
            zh ? "已添加 \(n) 篇论文" : "Added \(n == 1 ? "1 paper" : "\(n) papers")"
        }
        static func batchAITitle(_ n: Int) -> String {
            zh ? "为 \(n) 篇论文生成 AI 卡片？" : "Generate AI cards for \(n == 1 ? "1 paper" : "\(n) papers")?"
        }
        static func batchExtras(duplicates: Int, failed: Int) -> String? {
            var parts: [String] = []
            if duplicates > 0 { parts.append(zh ? "\(duplicates) 篇已在库中" : "\(duplicates) already in the library") }
            if failed > 0 { parts.append(zh ? "\(failed) 个无法导入" : "\(failed) couldn't be imported") }
            guard !parts.isEmpty else { return nil }
            return (zh ? "另有 " : "Also: ") + parts.joined(separator: zh ? "，" : ", ")
        }
        static var batchSequential: String { zh ? "已按顺序排期（低优先级）" : "Scheduled one after another (low priority)" }
        static var batchAutomatic: String { zh ? "已自动排期" : "Scheduled automatically" }
        static func batchLastDeadline(_ label: String) -> String { zh ? "最后 DDL \(label)" : "Last deadline \(label)" }
        static var batchNoDeadline: String { zh ? "没有排进计划的论文" : "None of them got a deadline" }
        static var makeUnscheduled: String { zh ? "改为放入未排期" : "Leave Unscheduled Instead" }
        static var madeUnscheduled: String { zh ? "已放入未排期" : "Moved to Unscheduled" }
        static var batchAIDetail: String {
            zh ? "每篇约 \(L.provider == .codex ? "30–120" : "30–60") 秒，占用订阅额度。"
               : "About \(L.provider == .codex ? "30–120" : "30–60") seconds each; this uses your subscription quota."
        }
        static var batchAIOff: String {
            zh ? "AI 解读已关闭，这些论文只生成了基础清单。开启后可在工具栏的解读队列里为它们排队。"
               : "AI reading is off, so these papers only got a basic checklist. After turning it on, queue them from the reading queue in the toolbar."
        }
        static var batchAIQueued: String { zh ? "已加入 \(L.ai) 队列" : "Added to the \(L.ai) queue" }
        static var batchLaterHint: String {
            zh ? "稍后可以在工具栏的解读队列里「立即解读」。" : "You can start them later from the reading queue in the toolbar."
        }
        static var readAll: String { zh ? "全部解读" : "Read All" }
        static var later: String { zh ? "稍后" : "Later" }
        static var doneButton: String { zh ? "完成" : "Done" }

        // MARK: Drop overlay

        static func dropRelease(_ what: String) -> String { zh ? "松手添加 \(what)" : "Drop to add \(what)" }
        static func nPDFs(_ n: Int) -> String { zh ? "\(n) 个 PDF" : (n == 1 ? "1 PDF" : "\(n) PDFs") }
        static func nFolders(_ n: Int) -> String { zh ? "\(n) 个文件夹" : (n == 1 ? "1 folder" : "\(n) folders") }
        static func nLinks(_ n: Int) -> String { zh ? "\(n) 个链接" : (n == 1 ? "1 link" : "\(n) links") }
        static var listSeparator: String { zh ? "、" : ", " }
        static func dropIgnored(_ n: Int) -> String {
            zh ? "另有 \(n) 个非 PDF 文件将被忽略" : "\(n == 1 ? "1 non-PDF file" : "\(n) non-PDF files") will be ignored"
        }
        static var dropHint: String { zh ? "自动生成阅读清单与 DDL" : "A checklist and deadline are created automatically" }

        // MARK: Fallback main menu (only when the app has none)

        static var menuAbout: String { zh ? "关于 PaperDeck" : "About PaperDeck" }
        static var menuHide: String { zh ? "隐藏 PaperDeck" : "Hide PaperDeck" }
        static var menuHideOthers: String { zh ? "隐藏其他" : "Hide Others" }
        static var menuShowAll: String { zh ? "全部显示" : "Show All" }
        static var menuFile: String { zh ? "文件" : "File" }
        static var menuEdit: String { zh ? "编辑" : "Edit" }
        static var menuUndo: String { zh ? "撤销" : "Undo" }
        static var menuRedo: String { zh ? "重做" : "Redo" }
        static var menuCut: String { zh ? "剪切" : "Cut" }
        static var menuCopy: String { zh ? "拷贝" : "Copy" }
        static var menuPaste: String { zh ? "粘贴" : "Paste" }
        static var menuDelete: String { zh ? "删除" : "Delete" }
        static var menuSelectAll: String { zh ? "全选" : "Select All" }
        /// The Paper menu (`PaperMenu`): the card menu's shortcuts for the selected papers.
        static var menuPaper: String { zh ? "论文" : "Paper" }
        static var menuWindow: String { zh ? "窗口" : "Window" }
        static var menuMinimize: String { zh ? "最小化" : "Minimize" }
        static var menuZoom: String { zh ? "缩放" : "Zoom" }
        static var menuCloseWindow: String { zh ? "关闭窗口" : "Close Window" }
        static var menuBringAllToFront: String { zh ? "前置全部窗口" : "Bring All to Front" }
    }
}
