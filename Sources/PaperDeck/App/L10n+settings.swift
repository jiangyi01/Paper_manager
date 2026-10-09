import Foundation
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

// Strings of the settings window, the setup assistant and the reminder service
// (notification actions / test notification). Namespaced under `L.Pref` so they never
// collide with other slices' `L` extensions. Chip / reminder body text lives in SharedStrings.

extension L {
    enum Pref {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Common

        static var on: String { zh ? "开" : "On" }
        static var off: String { zh ? "关" : "Off" }
        static var copy: String { zh ? "复制" : "Copy" }
        static var copied: String { zh ? "已复制" : "Copied" }
        static var save: String { zh ? "保存" : "Save" }
        static var delete: String { zh ? "删除" : "Delete" }
        static var change: String { zh ? "更改…" : "Change…" }
        static var choose: String { zh ? "选择" : "Choose" }
        static var refresh: String { zh ? "刷新" : "Refresh" }
        static var recheck: String { zh ? "重新检测" : "Check again" }
        static var checking: String { zh ? "正在检查…" : "Checking…" }
        static var computing: String { zh ? "正在统计…" : "Calculating…" }
        static var optional: String { zh ? "可选" : "Optional" }
        static var showInFinder: String { zh ? "在 Finder 中显示" : "Show in Finder" }
        static var openSystemSettings: String { zh ? "打开系统设置" : "Open System Settings" }
        static var openTerminal: String { zh ? "打开终端" : "Open Terminal" }
        static var subscription: String { zh ? "订阅" : "Subscription" }
        static func minutes(_ n: Int) -> String { zh ? "\(n) 分钟" : "\(n) min" }

        // MARK: Tabs

        static var tabGeneral: String { zh ? "通用" : "General" }
        static var tabPlan: String { zh ? "阅读计划与提醒" : "Plan & Reminders" }
        static var tabAI: String { zh ? "AI 解读" : "AI Reading" }
        static var tabLibrary: String { zh ? "资料库与存储" : "Library & Storage" }
        static var tabWidget: String { zh ? "小组件" : "Widget" }

        // MARK: 通用

        static var languageLabel: String { zh ? "语言 / Language" : "Language / 语言" }
        static var launchAtLogin: String { zh ? "登录时自动启动 PaperDeck" : "Open PaperDeck at login" }
        static var loginNeedsApproval: String {
            zh ? "需要在「系统设置 ▸ 通用 ▸ 登录项」中允许" : "Needs approval in System Settings ▸ General ▸ Login Items"
        }
        static var openLoginItems: String { zh ? "打开登录项设置…" : "Open Login Items…" }
        static var launchAtLoginUnavailable: String {
            zh ? "开发构建（未打包为 App）无法设置开机自启。" : "Development builds (not packaged as an app) can't open at login."
        }
        static var menuBarCount: String { zh ? "菜单栏显示今日待读数量" : "Show today's count in the menu bar" }
        static var pdfOpener: String { zh ? "打开 PDF 使用" : "Open PDFs with" }
        static var openerPreview: String { zh ? "预览" : "Preview" }
        static var openerDefault: String { zh ? "系统默认 App" : "Default app" }
        static var setupAssistant: String { zh ? "设置助手" : "Setup Assistant" }
        static var setupAssistantHint: String {
            zh ? "重新检查 AI 解读（\(L.ai)）、资料库、通知与阅读计划" : "Re-check AI reading (\(L.ai)), the library, notifications and the reading plan"
        }
        static var reopenSetup: String { zh ? "重新打开设置助手" : "Open Setup Assistant" }

        // MARK: 阅读计划与提醒

        static var planSection: String { zh ? "阅读计划" : "Reading plan" }
        static var dailyBudget: String { zh ? "每日阅读预算" : "Daily reading budget" }
        static var readingDays: String { zh ? "阅读日" : "Reading days" }
        static var cutoff: String { zh ? "当天截止" : "Daily cutoff" }
        static var planFooter: String {
            zh ? "DDL 按预算自动排在阅读日上；过了截止时刻，今天不再安排新的阅读。"
               : "Deadlines are placed on reading days within the budget; after the cutoff, nothing new is planned for today."
        }
        static var reminderSection: String { zh ? "每日提醒" : "Daily reminder" }
        static var reminderEnabled: String { zh ? "每天提醒今日阅读清单" : "Remind me of today's reading list" }
        static var reminderTime: String { zh ? "提醒时间" : "Reminder time" }
        static var skipWhenEmpty: String { zh ? "无待读时不提醒" : "Skip when nothing is left to read" }
        static var reminderFooter: String {
            zh ? "每天只有一条提醒，列出今天要读的论文，末行是待读总数。非阅读日也会提醒逾期与到期的论文。"
               : "One reminder a day listing today's papers, ending with the total left. Non-reading days still remind you of overdue and due papers."
        }
        static var autoMarkDone: String { zh ? "清单全部勾选后自动标记为已读" : "Mark as read when every checklist item is done" }
        static var notifyOnAgentDone: String { zh ? "\(L.ai) 解读完成时通知" : "Notify when \(L.ai) finishes a paper" }
        static var testNotification: String { zh ? "测试通知" : "Test notification" }
        /// `time`: the configured reminder time ("11:00").
        static func testNotificationHint(time: String) -> String {
            zh ? "立即发送一条今天的提醒（内容与 \(time) 的一致）" : "Sends today's reminder now (same content as the scheduled one)"
        }
        /// "11:00" — the reminder time as the plan tab's hint names it.
        static func reminderClock(hour: Int, minute: Int) -> String { String(format: "%d:%02d", hour, minute) }
        static var sendTest: String { zh ? "发送测试通知" : "Send Test Notification" }
        static var send: String { zh ? "发送" : "Send" }
        static var notificationPermission: String { zh ? "通知权限" : "Notification permission" }
        static var allowNotifications: String { zh ? "允许通知" : "Allow Notifications" }
        static var openNotificationSettings: String { zh ? "打开系统通知设置" : "Open Notification Settings" }
        static var authAuthorized: String { zh ? "已允许" : "Allowed" }
        static var authProvisional: String { zh ? "已允许（静默递送）" : "Allowed (delivered quietly)" }
        static var authDenied: String {
            zh ? "已关闭 · 到点时改为展开悬浮窗并用系统脚本提示" : "Off · at reminder time PaperDeck opens the drop panel and shows a script notification instead"
        }
        static var authNotDetermined: String { zh ? "尚未允许" : "Not allowed yet" }
        static var notificationsUnavailable: String {
            zh ? "开发构建无法使用系统通知（将使用脚本提示）" : "Notifications need the packaged app (using script notifications instead)"
        }

        // MARK: Notification actions / test (ReminderService)

        static var actionOpenList: String { zh ? "打开阅读清单" : "Open Reading List" }
        static var actionPostponeDay: String { zh ? "今天跳过·顺延一天" : "Skip Today · Move by a Day" }
        static var actionRemindLater: String { zh ? "1 小时后提醒" : "Remind Me in 1 Hour" }
        static var testTitle: String { zh ? "PaperDeck 测试通知" : "PaperDeck test notification" }
        static var testBody: String {
            zh ? "通知工作正常。每天的阅读清单会在这里提醒你。" : "Notifications work. Your daily reading list will appear here."
        }

        // MARK: AI 解读（Claude / ChatGPT）

        static var providerPicker: String { zh ? "解读服务" : "Reading service" }
        static func providerName(_ p: AIProviderKind) -> String { p.displayName(L.lang) }
        static var providerPickerHint: String {
            zh ? "都使用你自己的订阅登录，不使用 API key" : "Both use your own subscription login, never an API key"
        }
        static var aiReading: String { zh ? "AI 解读" : "AI reading" }
        static func modeCaption(_ mode: String, provider: AIProviderKind) -> String {
            switch mode {
            case "claude": return zh ? "agent.mode = claude · 新论文由 Claude Code 解读" : "agent.mode = claude · new papers are read by Claude Code"
            case "codex": return zh ? "agent.mode = codex · 新论文由 ChatGPT（Codex CLI）解读" : "agent.mode = codex · new papers are read by ChatGPT (Codex CLI)"
            case "mock": return zh ? "agent.mode = mock · 演示数据，不调用 \(provider.shortName)（开发模式）" : "agent.mode = mock · demo cards, \(provider.shortName) is not called (development)"
            default: return zh ? "agent.mode = off · 只生成基础清单，不消耗额度" : "agent.mode = off · basic checklists only, no usage"
            }
        }
        static func privacyNote(_ p: AIProviderKind) -> String {
            switch p {
            case .claude:
                return zh ? "论文文本会发送给 Claude 解读，并占用你的订阅额度。PaperDeck 只使用 Claude Code 的订阅登录，不使用 API key。"
                          : "Paper text is sent to Claude and counts toward your subscription usage. PaperDeck only uses Claude Code's subscription login, never an API key."
            case .codex:
                return zh ? "论文文本会发送给 ChatGPT 解读，并占用你的订阅额度。PaperDeck 只使用 Codex CLI 的 ChatGPT 订阅登录，不使用 API key，也不给模型任何工具。"
                          : "Paper text is sent to ChatGPT and counts toward your subscription usage. PaperDeck only uses the Codex CLI's ChatGPT subscription login — never an API key — and gives the model no tools."
            }
        }
        static func heldPapers(_ n: Int) -> String { zh ? "\(n) 篇论文在等待解读" : "\(n) paper(s) waiting to be read" }
        static var heldPapersHint: String {
            zh ? "它们是在 AI 解读关闭时，或批量导入后加入的" : "Added while AI reading was off, or held after a batch import"
        }
        static func queueExisting(_ n: Int) -> String { zh ? "为现有 \(n) 篇论文排队解读" : "Queue \(n) Existing Paper(s)" }
        static func queueConfirmTitle(_ n: Int) -> String { zh ? "为 \(n) 篇论文排队解读？" : "Queue \(n) paper(s) for \(L.ai)?" }
        static var queueConfirmBody: String {
            let time = L.provider == .codex ? "30–120" : "30–60"
            return zh ? "每篇约 \(time) 秒，占用 \(L.ai) 订阅额度。可以随时在工具栏的解读队列中取消。"
                      : "About \(time) s per paper, counted toward your \(L.ai) subscription usage. You can cancel any time from the reading queue in the toolbar."
        }
        static var queueConfirm: String { zh ? "排队解读" : "Queue" }
        static var iLoggedIn: String { zh ? "我已登录" : "I've Signed In" }

        // Claude Code
        static var accountSection: String { zh ? "Claude Code 登录状态" : "Claude Code sign-in" }
        static func claudeReady(plan: String, path: String?, version: String) -> String {
            let p = path.map { " · \($0)" } ?? ""
            return zh ? "已登录 · \(plan) 订阅\(p) \(version)" : "Signed in · \(plan) plan\(p) \(version)"
        }
        static var claudeNotInstalled: String { zh ? "未检测到 Claude Code。在终端中运行：" : "Claude Code not found. Run this in Terminal:" }
        static var claudeNotLoggedIn: String { zh ? "Claude Code 未登录" : "Claude Code is not signed in" }
        static var claudeLoginHint: String { zh ? "在终端运行 claude 后输入 /login，完成后点「我已登录」。" : "Run claude in Terminal and type /login, then click “I've Signed In”." }
        static var claudeUnsupported: String { zh ? "PaperDeck 只使用订阅登录（claude.ai）" : "PaperDeck only uses a subscription login (claude.ai)" }
        static var claudeDetecting: String { zh ? "正在检测 Claude Code…" : "Detecting Claude Code…" }
        static var cliSection: String { zh ? "Claude Code 程序" : "Claude Code binary" }
        static var cliDetected: String { zh ? "自动检测" : "Detected" }
        static var cliNotFound: String { zh ? "未找到 Claude Code" : "Claude Code not found" }
        static var cliOverride: String { zh ? "自定义路径" : "Custom path" }
        static var cliOverridePrompt: String { zh ? "留空则自动检测" : "Leave empty to detect automatically" }
        static var cliFooter: String {
            zh ? "修改后立即重新检测。检测只运行 claude --version 与 auth status，不消耗额度。"
               : "Changes are re-detected right away. Detection only runs claude --version and auth status — no usage."
        }

        // ChatGPT (Codex CLI)
        static var codexAccountSection: String { zh ? "ChatGPT 登录状态（Codex CLI）" : "ChatGPT sign-in (Codex CLI)" }
        static func codexReady(version: String) -> String {
            zh ? "已登录 · ChatGPT · Codex CLI \(version)" : "Signed in · ChatGPT · Codex CLI \(version)"
        }
        static var codexNotInstalled: String { zh ? "未找到 Codex CLI" : "Codex CLI not found" }
        static var codexInstallHint: String {
            zh ? "Codex CLI 随 ChatGPT 桌面版一起安装（位于 ChatGPT.app 内）。也可以在终端中用 Homebrew 安装："
               : "The Codex CLI ships inside the ChatGPT desktop app (in ChatGPT.app). You can also install it with Homebrew:"
        }
        static let codexBrewCommand = "brew install --cask codex"
        static var codexNotLoggedIn: String { zh ? "Codex CLI 尚未登录 ChatGPT" : "The Codex CLI isn't signed in to ChatGPT" }
        static var codexLoginHint: String {
            zh ? "在终端运行下面的命令，选择「Sign in with ChatGPT」并在浏览器中完成登录，然后点「我已登录」。"
               : "Run this in Terminal, choose “Sign in with ChatGPT” and finish in the browser, then click “I've Signed In”."
        }
        static func codexNonSubscription(_ method: String) -> String {
            zh ? "Codex CLI 当前用 \(method) 登录。PaperDeck 不会用 API key 解读论文（也就不会按 API 计费）。要用 ChatGPT 订阅解读，请在终端运行下面的命令并选择「Sign in with ChatGPT」（会替换 Codex CLI 当前的登录方式）。"
               : "The Codex CLI is signed in with \(method). PaperDeck never reads papers on an API key (so nothing is billed per API call). To read with your ChatGPT plan, run this in Terminal and choose “Sign in with ChatGPT” (it replaces the Codex CLI's current login)."
        }
        static var codexDetecting: String { zh ? "正在检测 Codex CLI…" : "Detecting Codex CLI…" }
        static var codexCLISection: String { zh ? "Codex CLI 程序" : "Codex CLI binary" }
        static var codexCLIFooter: String {
            zh ? "修改后立即重新检测。检测只运行 codex --version、login status、exec --help 与 features list，不消耗额度。"
               : "Changes are re-detected right away. Detection only runs codex --version, login status, exec --help and features list — no usage."
        }

        static var readingSection: String { zh ? "解读方式" : "Reading" }
        static var newPapers: String { zh ? "新论文" : "New papers" }
        static var autoRead: String { zh ? "自动解读" : "Read automatically" }
        static var manualRead: String { zh ? "手动（点击「用 \(L.ai) 解读」）" : "Manually (click “Read with \(L.ai)”)" }
        static var model: String { zh ? "模型" : "Model" }
        static var modelSonnet: String { zh ? "Sonnet（默认）" : "Sonnet (default)" }
        static var modelOpus: String { zh ? "Opus（更深入，消耗更多额度）" : "Opus (deeper, uses more of your plan)" }
        static var modelHaiku: String { zh ? "Haiku（更快、更省）" : "Haiku (faster, lighter)" }
        /// `GPT-5.6-Terra · 均衡（推荐）`.
        static func codexModel(_ name: String, detail: String?) -> String {
            guard let detail, !detail.isEmpty else { return name }
            return "\(name) · \(detail)"
        }
        static var codexModelFooter: String {
            zh ? "模型列表来自 Codex CLI 的本机缓存（~/.codex/models_cache.json）；可用模型取决于你的 ChatGPT 订阅。"
               : "Models come from the Codex CLI's local cache (~/.codex/models_cache.json); which ones work depends on your ChatGPT plan."
        }
        static var effort: String { zh ? "思考强度" : "Effort" }
        static var effortLow: String { zh ? "低" : "Low" }
        static var effortMedium: String { zh ? "中（默认）" : "Medium (default)" }
        static var textBudget: String { zh ? "发送的文本上限" : "Text sent per paper" }
        static func characters(_ n: Int) -> String {
            let k = n >= 1000 ? "\(n / 1000)k" : "\(n)"
            return zh ? "\(k) 字符" : "\(k) characters"
        }
        static var allowNewCategories: String { zh ? "允许 \(L.ai) 新建分类" : "Let \(L.ai) create categories" }
        static var allowNewCategoriesHint: String {
            zh ? "分类少于 20 个时才会新建；否则选最接近的现有分类并标记待确认"
               : "Only while there are fewer than 20; otherwise the closest existing category is used and flagged for review"
        }
        static var testConnection: String { zh ? "测试连接" : "Test connection" }
        /// `model`: the display name of the model the ChatGPT test runs (nil: GPT-5.6-Luna).
        static func testConnectionHint(_ p: AIProviderKind, model: String? = nil) -> String {
            switch p {
            case .claude: return zh ? "用一篇极短的示例论文调用一次 Claude（Haiku）" : "Runs Claude (Haiku) once on a tiny sample paper"
            case .codex:
                let m = model ?? "GPT-5.6-Luna"
                return zh ? "用一篇极短的示例论文调用一次 ChatGPT（\(m)）" : "Runs ChatGPT (\(m)) once on a tiny sample paper"
            }
        }
        static func testConfirmTitle(_ p: AIProviderKind) -> String {
            zh ? "测试 \(p.shortName) 连接？" : "Test the \(p.shortName) connection?"
        }
        static func testConfirmBody(_ p: AIProviderKind) -> String {
            switch p {
            case .claude:
                return zh ? "会消耗少量订阅额度（约 1–2 次调用）。" : "This uses a small amount of your subscription (about 1–2 calls)."
            case .codex:
                return zh ? "会运行一次 codex exec，消耗少量 ChatGPT 订阅额度（1 次调用，约 30–120 秒）。"
                          : "This runs codex exec once and uses a small amount of your ChatGPT plan (1 call, about 30–120 s)."
            }
        }
        static var testRun: String { zh ? "测试" : "Test" }
        static var testButton: String { zh ? "测试…" : "Test…" }
        static var testRunning: String {
            zh ? "正在测试…（若有论文正在解读，会等它完成）" : "Testing… (waits for a paper that is being read)"
        }
        static func testOK(model: String?, seconds: Double?, cost: Double?, tokens: Int? = nil) -> String {
            var parts = [zh ? "连接正常" : "Connected"]
            if let model { parts.append(model) }
            if let seconds { parts.append(String(format: zh ? "%.1f 秒" : "%.1f s", seconds)) }
            if let cost { parts.append(estimatedCost(cost)) }
            if let tokens { parts.append(Self.tokens(tokens)) }
            return parts.joined(separator: " · ")
        }
        /// `12.3k tokens`.
        static func tokens(_ n: Int) -> String {
            let v = n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
            return "\(v) tokens"
        }
        static func testUsageLimit(_ resets: String?) -> String {
            switch (zh, resets) {
            case (true, let r?): return "额度已用尽 · \(r) 重置"
            case (true, nil): return "额度已用尽"
            case (false, let r?): return "Usage limit reached · resets \(r)"
            case (false, nil): return "Usage limit reached"
            }
        }
        static func testNotLoggedIn(_ p: AIProviderKind) -> String {
            switch p {
            case .claude: return zh ? "Claude Code 未登录" : "Claude Code is not signed in"
            case .codex: return codexNotLoggedIn
            }
        }
        static func testOverloaded(_ p: AIProviderKind) -> String {
            zh ? "\(p.shortName) 服务繁忙，请稍后再试" : "\(p.shortName) is overloaded — try again later"
        }
        static func testNotFound(_ p: AIProviderKind) -> String { p == .codex ? codexNotInstalled : cliNotFound }
        static func testInvalid(_ m: String) -> String { zh ? "输出无效：\(m)" : "Invalid output: \(m)" }
        static var testMaxTurns: String { zh ? "超出轮次上限" : "Too many turns" }
        static var testTimeout: String { zh ? "超时" : "Timed out" }
        static var testCancelled: String { zh ? "已取消" : "Cancelled" }
        static func testError(_ m: String) -> String { zh ? "出错：\(m)" : "Error: \(m)" }
        static var runLog: String { zh ? "运行日志" : "Run log" }
        static var runLogEmpty: String { zh ? "还没有解读记录" : "No runs yet" }
        static func showAll(_ n: Int) -> String { zh ? "显示全部 \(n) 条" : "Show all \(n)" }
        static var showLess: String { zh ? "收起" : "Show less" }
        static var deletedPaper: String { zh ? "（已删除的论文）" : "(deleted paper)" }
        static func estimatedCost(_ usd: Double) -> String {
            let v = String(format: "$%.3f", usd)
            return zh ? "估算 \(v)" : "est. \(v)"
        }
        static var costFooter: String {
            zh ? "费用是 Claude Code 在本机的估算值（订阅用户不会按此扣费），仅供了解额度消耗；ChatGPT 解读只记录 token 数。"
               : "Costs are Claude Code's local estimates (subscribers are not billed this amount) — shown to gauge usage. ChatGPT runs only record token counts."
        }
        static func jobState(_ s: AgentJobState) -> String {
            switch s {
            case .held: return zh ? "等待" : "Held"
            case .queued: return zh ? "排队中" : "Queued"
            case .running: return zh ? "解读中" : "Running"
            case .succeeded: return zh ? "完成" : "Done"
            case .failed: return zh ? "失败" : "Failed"
            case .cancelled: return zh ? "已取消" : "Cancelled"
            }
        }
        static var otherProviders: String { "Google (Antigravity)" }
        static var comingSoon: String { zh ? "即将支持" : "Coming soon" }

        // MARK: 资料库与存储

        static var librarySection: String { zh ? "资料库" : "Library" }
        static var location: String { zh ? "位置" : "Location" }
        static func locationPending(_ path: String) -> String {
            zh ? "重启 PaperDeck 后改用 \(path)" : "PaperDeck will use \(path) after it restarts"
        }
        static var keepCurrentLocation: String { zh ? "保留当前位置" : "Keep Current Location" }
        static var locationFooter: String {
            zh ? "论文按「年份_第一作者_标题」存放在这个文件夹中。更改位置不会移动现有论文，新位置在重启 PaperDeck 后生效。"
               : "Papers are stored here as “Year_FirstAuthor_Title”. Changing the location doesn't move existing papers; it takes effect after restarting PaperDeck."
        }
        static var chooseLibraryMessage: String {
            zh ? "选择论文库文件夹（重启 PaperDeck 后生效）" : "Choose the library folder (takes effect after restarting PaperDeck)"
        }
        static var importSection: String { zh ? "导入" : "Import" }
        static var importMode: String { zh ? "导入方式" : "When importing" }
        static var importCopy: String { zh ? "复制（APFS 克隆，推荐）" : "Copy (APFS clone, recommended)" }
        static var importMove: String { zh ? "移动（原文件移到废纸篓）" : "Move (original goes to the Trash)" }
        static var metadataLookup: String { zh ? "联网查询论文元数据" : "Look up paper metadata online" }
        static var metadataLookupHint: String {
            zh ? "按 DOI / arXiv 查询 Crossref、bioRxiv、arXiv 与 OpenAlex" : "Queries Crossref, bioRxiv, arXiv and OpenAlex by DOI / arXiv ID"
        }
        static var crossrefMail: String { zh ? "Crossref 联系邮箱" : "Crossref contact email" }
        static var storageSection: String { zh ? "存储统计" : "Storage" }
        static var paperCount: String { zh ? "论文" : "Papers" }
        static func paperCountValue(live: Int, deleted: Int) -> String {
            zh ? "\(live) 篇（最近删除 \(deleted) 篇）" : "\(live) (\(deleted) recently deleted)"
        }
        static func paperCountShort(_ n: Int) -> String { zh ? "\(n) 篇" : "\(n)" }
        static var logicalSize: String { zh ? "PDF 逻辑大小" : "PDF size (logical)" }
        static var sharedEstimate: String { zh ? "可能与原文件共享（估算）" : "May be shared with originals (estimate)" }
        static var sharedEstimateHint: String {
            zh ? "APFS 克隆与原文件共用磁盘块，实际占用可能更小" : "APFS clones share disk blocks with the originals, so real usage may be lower"
        }
        static var thumbnails: String { zh ? "缩略图缓存" : "Thumbnail cache" }
        static var textCache: String { zh ? "文本缓存" : "Text cache" }
        static var database: String { zh ? "数据库" : "Database" }
        static var recentlyDeleted: String { zh ? "最近删除" : "Recently Deleted" }
        static func missingFiles(_ n: Int) -> String {
            zh ? "\(n) 篇论文的 PDF 不在资料库中" : "\(n) paper(s) are missing their PDF"
        }
        static var largest: String { zh ? "最大的 5 篇" : "Largest 5 papers" }
        static var maintenanceSection: String { zh ? "维护" : "Maintenance" }
        static var rebuildIndex: String { zh ? "从文件夹重建索引" : "Rebuild index from folders" }
        static var rebuildIndexHint: String {
            zh ? "按每篇论文的 card.json 重建数据库" : "Rebuilds the database from every paper's card.json"
        }
        static var rebuild: String { zh ? "重建" : "Rebuild" }
        static var rebuildButton: String { zh ? "重建…" : "Rebuild…" }
        static var cleanButton: String { zh ? "清理" : "Clean Up" }
        static var backupButton: String { zh ? "备份" : "Back Up" }
        static var rebuildConfirmTitle: String { zh ? "从文件夹重建索引？" : "Rebuild the index from folders?" }
        static var rebuildConfirmBody: String {
            zh ? "数据库会被替换为各论文文件夹中 card.json 的内容。PDF 和 card.json 不会改动，重建前会自动备份数据库。"
               : "The database is replaced with what the card.json files in the paper folders say. PDFs and card.json files are not changed; the database is backed up first."
        }
        static func rebuildDone(papers: Int, deleted: Int, skipped: Int) -> String {
            var s = zh ? "已重建：\(papers) 篇论文，最近删除 \(deleted) 篇" : "Rebuilt: \(papers) paper(s), \(deleted) recently deleted"
            if skipped > 0 { s += zh ? "；跳过 \(skipped) 个" : "; \(skipped) skipped" }
            return s
        }
        static var cleanOrphans: String { zh ? "清理孤立文件" : "Clean up orphaned files" }
        static var cleanOrphansHint: String {
            zh ? "收回可识别的文件夹，删除无主缓存；含 PDF 的文件夹不会动" : "Adopts recognizable folders and removes stray caches; folders with PDFs are never touched"
        }
        static var orphansNone: String { zh ? "没有孤立文件" : "No orphans found" }
        static func orphansLeft(folders: Int, missing: Int) -> String {
            var parts: [String] = []
            if folders > 0 { parts.append(zh ? "\(folders) 个含 PDF 的文件夹不在库中（未改动）" : "\(folders) folder(s) with PDFs aren't in the library (left as is)") }
            if missing > 0 { parts.append(zh ? "\(missing) 篇论文缺少 PDF" : "\(missing) paper(s) missing their PDF") }
            if parts.isEmpty { return zh ? "已清理" : "Cleaned up" }
            return (zh ? "已清理。" : "Cleaned up. ") + parts.joined(separator: zh ? "；" : "; ")
        }
        static var backupNow: String { zh ? "立即备份" : "Back up now" }
        static var backupNowHint: String { zh ? "复制一份数据库到 Backups（保留最近 7 份）" : "Saves a copy of the database in Backups (newest 7 kept)" }
        static func backupDone(_ name: String) -> String { zh ? "已备份：\(name)" : "Backed up: \(name)" }
        static var recentlyDeletedFooter: String {
            zh ? "「最近删除」中的论文保留 30 天后彻底删除。" : "Papers in Recently Deleted are removed for good after 30 days."
        }
        static var categoriesSection: String { zh ? "分类" : "Categories" }
        static var categoriesFooter: String {
            zh ? "分类描述会发给 \(L.ai)，帮助它把论文归到一致的分类。" : "Descriptions are sent to \(L.ai) so it files papers consistently."
        }
        static var noCategories: String { zh ? "还没有分类" : "No categories yet" }
        static var newCategory: String { zh ? "新建分类…" : "New Category…" }
        static var renameCategory: String { zh ? "重命名…" : "Rename…" }
        static var describeCategory: String { zh ? "编辑描述…" : "Edit Description…" }
        static var deleteCategoryMenu: String { zh ? "删除（论文移到未分类）" : "Delete (papers become uncategorized)" }
        static var categoryName: String { zh ? "分类名称" : "Category name" }
        static var categoryDescription: String { zh ? "一句话描述" : "One-line description" }
        static var describeHint: String { FieldStrings.describeHint(L.field, L.lang) }
        static func deleteCategoryTitle(_ name: String) -> String { zh ? "删除分类「\(name)」？" : "Delete the category “\(name)”?" }
        static func deleteCategoryBody(_ n: Int) -> String {
            zh ? "其中的 \(n) 篇论文会移到未分类。" : "Its \(n) paper(s) become uncategorized."
        }
        static func categoryActions(_ name: String) -> String { zh ? "「\(name)」操作" : "Actions for \(name)" }

        // MARK: 小组件

        static var widgetIntroTitle: String { zh ? "桌面小组件" : "Desktop widget" }
        static var widgetIntro: String {
            zh ? "「今日待读」和「最近添加」两种小组件只做展示，点击会打开 PaperDeck 对应的页面。内容随资料库变化自动更新。"
               : "“Today's Reading” and “Recently Added” are display-only; clicking one opens the matching page in PaperDeck. They update as your library changes."
        }
        static var widgetStatusSection: String { zh ? "注册状态" : "Registration" }
        static var widgetRegistered: String { zh ? "小组件已注册" : "The widget is registered" }
        static var widgetDisabled: String { zh ? "小组件已注册但被停用" : "The widget is registered but disabled" }
        static var widgetNotRegistered: String {
            zh ? "未找到小组件：请把 PaperDeck 安装到「应用程序」并至少启动一次" : "Widget not found: install PaperDeck in Applications and open it once"
        }
        static var widgetProbeFailed: String { zh ? "无法查询小组件状态" : "Couldn't query the widget status" }
        static var widgetStepsSection: String { zh ? "添加到桌面" : "Add it to the desktop" }
        static var widgetSteps: [String] {
            zh ? ["在桌面空白处右键，选择「编辑小组件…」", "在搜索框中输入 PaperDeck", "把「今日待读」或「最近添加」拖到桌面"]
               : ["Right-click an empty spot on the desktop and choose “Edit Widgets…”", "Search for PaperDeck",
                  "Drag “Today's Reading” or “Recently Added” onto the desktop"]
        }
        /// Build instructions only for a copy built on this Mac (`BuildIdentity.channel == .local`).
        static var widgetStepsFooter: String {
            if BuildIdentity.current.channel == .local {
                return zh ? "如果列表里没有 PaperDeck，通常是签名变化导致的：用稳定签名证书重新构建并启动一次。"
                          : "If PaperDeck isn't listed, the signature usually changed: rebuild with the stable signing certificate and open the app once."
            }
            return zh ? "如果列表里没有 PaperDeck：把它移到「应用程序」文件夹并打开一次，然后点下方的「修复」。"
                      : "If PaperDeck isn't listed, move it to the Applications folder, open it once, then click Repair below."
        }
        static var refreshWidget: String { zh ? "刷新小组件" : "Refresh widget" }
        static var refreshWidgetHint: String { zh ? "重新生成快照并请求系统刷新" : "Rewrites the snapshot and asks macOS to reload it" }
        static func widgetRefreshed(changed: Bool, at time: String) -> String {
            switch (zh, changed) {
            case (true, true): return "已刷新 · \(time)"
            case (true, false): return "内容无变化，已请求刷新 · \(time)"
            case (false, true): return "Refreshed · \(time)"
            case (false, false): return "No changes; reload requested · \(time)"
            }
        }

        // MARK: 设置助手

        static var setupWindowTitle: String { zh ? "PaperDeck 设置助手" : "PaperDeck Setup Assistant" }
        static var setupWelcome: String { zh ? "欢迎使用 PaperDeck" : "Welcome to PaperDeck" }
        static var setupSubtitle: String {
            zh ? "花一分钟完成设置。标有「必需」的两步完成后即可开始。" : "A minute of setup. Finish the two required steps to get started."
        }
        static var setupFinishHint: String {
            zh ? "完成第 1 步（AI 解读）与第 3 步（资料库）后即可点「完成」" : "Finish step 1 (AI reading) and step 3 (library) to continue"
        }
        static var setupReady: String { zh ? "一切就绪，随时可以把论文拖进来" : "All set — drop in your papers any time" }
        static var finish: String { zh ? "完成" : "Done" }
        static var requiredTag: String { zh ? "必需" : "Required" }
        static var stepDone: String { zh ? "已完成" : "Done" }
        static var stepTodo: String { zh ? "待选择" : "To do" }
        static var stepSkipped: String { zh ? "暂不启用" : "Not now" }
        static var stepEnabled: String { zh ? "已启用" : "Enabled" }
        static var stepEnabledNeedsLogin: String { zh ? "已启用 · 等待登录" : "Enabled · waiting for sign-in" }
        static var stepNeedsAction: String { zh ? "需要处理" : "Needs attention" }
        static var stepRecommended: String { zh ? "推荐" : "Recommended" }
        static var stepOptional: String { zh ? "可选" : "Optional" }
        static var stepDefaultsOK: String { zh ? "默认即可" : "Defaults are fine" }
        static var setupClaudeTitle: String { zh ? "AI 解读" : "AI reading" }
        static func enableProvider(_ p: AIProviderKind) -> String {
            zh ? "启用 \(p.shortName) 解读" : "Turn On \(p.shortName) Reading"
        }
        static var notNow: String { zh ? "暂不启用" : "Not Now" }
        static var turnOff: String { zh ? "关闭" : "Turn Off" }
        static func claudeEnabled(_ mode: String) -> String {
            if mode == "mock" { return zh ? "演示模式（mock）已启用" : "Demo mode (mock) is on" }
            let name = AIProviderKind(rawValue: mode)?.shortName ?? L.ai
            return zh ? "\(name) 解读已启用" : "\(name) reading is on"
        }
        static var setupProviderHint: String {
            zh ? "选择用哪个订阅解读论文，之后可以在「设置 ▸ AI 解读」中切换。"
               : "Pick the subscription that reads your papers; you can switch later in Settings ▸ AI Reading."
        }
        static var setupSigningTitle: String { zh ? "稳定签名证书（推荐）" : "Stable signing certificate (recommended)" }
        static func signedWith(_ name: String) -> String { zh ? "已使用证书签名：\(name)" : "Signed with a certificate: \(name)" }
        static var signedAdhoc: String { zh ? "当前为临时签名（ad-hoc）" : "Currently ad-hoc signed" }
        static var unsignedBuild: String { zh ? "未签名（开发构建）" : "Unsigned (development build)" }
        static var signingWhy: String {
            zh ? "临时签名每次重新构建都会变：macOS 会再次询问「文稿」访问权限，小组件也可能从列表中消失。用一张自签名证书签名后就不会了。"
               : "An ad-hoc signature changes with every build: macOS asks for Documents access again and the widget may vanish from the gallery. A self-signed certificate keeps it stable."
        }
        static var signingHowTo: String { zh ? "如何创建签名证书" : "How to create the certificate" }
        static var signingSteps: [String] {
            let name = signingCertificateName
            return zh ? ["打开「钥匙串访问」，在菜单中选择「钥匙串访问 ▸ 证书助理 ▸ 创建证书…」",
                         "名称填 \(name)，身份类型选「自签名根证书」，证书类型选「代码签名」",
                         "在 PaperDeck 项目目录的终端中重新运行构建脚本："]
                      : ["Open Keychain Access and choose Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…",
                         "Name it \(name), identity type “Self-Signed Root”, certificate type “Code Signing”",
                         "Run the build script again in Terminal from the PaperDeck folder:"]
        }
        /// The certificate name the build script signs with (stamped `PDSigningIdentity`, else the default).
        static var signingCertificateName: String {
            guard let n = BuildIdentity.current.signingIdentityName, !n.isEmpty, n != "adhoc" else {
                return BuildIdentity.defaultSigningIdentityName
            }
            return n
        }
        static var setupLibraryTitle: String { zh ? "资料库文件夹" : "Library folder" }
        static var libraryOK: String { zh ? "可以读写" : "Ready" }
        static var libraryUbiquitous: String {
            zh ? "位于 iCloud / OneDrive 同步目录中：文件可能被移出本机，建议换到本地文件夹"
               : "Inside an iCloud / OneDrive folder: files may be evicted; a local folder is recommended"
        }
        static var libraryDenied: String {
            zh ? "没有访问权限：请在「系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹」中允许 PaperDeck 访问「文稿」"
               : "Access denied: allow PaperDeck to access Documents in System Settings ▸ Privacy & Security ▸ Files and Folders"
        }
        static var libraryMissing: String { zh ? "文件夹不存在" : "The folder doesn't exist" }
        static var libraryReadOnly: String { zh ? "文件夹只读" : "The folder is read-only" }
        static var restartToApply: String { zh ? "重启 PaperDeck 后生效" : "Takes effect after restarting PaperDeck" }
        static var namingPreview: String { zh ? "命名示例" : "Naming example" }
        static var setupNotificationsTitle: String { zh ? "通知" : "Notifications" }
        static var notificationsWhy: String {
            zh ? "每天在提醒时间发一条通知，列出今天要读的论文，可直接「今天跳过」或「1 小时后提醒」。"
               : "One notification a day at the reminder time lists today's papers, with “Skip Today” and “Remind Me in 1 Hour”."
        }
        static var alertStyleHint: String {
            zh ? "建议在「系统设置 ▸ 通知 ▸ PaperDeck」中把提醒样式设为「提醒」，这样清单会停留在屏幕上直到你处理。"
               : "Tip: set PaperDeck's style to “Alerts” in System Settings ▸ Notifications so the list stays until you act on it."
        }
        static var setupPlanTitle: String { zh ? "阅读计划" : "Reading plan" }
        static var setupImportTitle: String { zh ? "导入已有论文（可选）" : "Import existing papers (optional)" }
        /// Names the last import folder (`import.lastFolder`), else ~/Downloads.
        static var importHint: String {
            let folder = LangStore.shared.importFolderExample
            return zh ? "选择一个装有 PDF 的文件夹（例如 \(folder)），PaperDeck 会一次导入并排好 DDL。"
                      : "Pick a folder of PDFs (e.g. \(folder)) to import them all and schedule deadlines."
        }
        static var chooseFolder: String { zh ? "选择文件夹…" : "Choose Folder…" }
        static var chooseAnotherFolder: String { zh ? "换一个文件夹…" : "Choose Another…" }
        static var chooseImportMessage: String { zh ? "选择要导入的论文文件夹" : "Choose a folder of papers to import" }
        static func pdfCount(_ n: Int) -> String { zh ? "\(n) 个 PDF" : "\(n) PDF(s)" }
        static var scheduling: String { zh ? "排期" : "Scheduling" }
        static var scheduleSequential: String { zh ? "按顺序排期（低优先级）" : "Schedule one after another (low priority)" }
        static var scheduleNone: String { zh ? "放入未排期" : "Leave unscheduled" }
        static var claudeForImport: String { zh ? "\(L.ai) 解读" : "\(L.ai) reading" }
        static var queueAll: String { zh ? "全部排队" : "Queue All" }
        static var later: String { zh ? "稍后" : "Later" }
        static var importClaudeOff: String {
            zh ? "AI 解读未启用：导入的论文会先等待，启用后可在「设置 ▸ AI 解读」中一键排队。"
               : "AI reading is off: imported papers wait, and can be queued later from Settings ▸ AI Reading."
        }
        static func startImport(_ n: Int) -> String { zh ? "导入 \(n) 篇" : "Import \(n)" }
        static var importing: String { zh ? "正在导入…（进度见悬浮窗）" : "Importing… (progress in the drop panel)" }
        static func importDone(_ s: ImportBatchSummary) -> String {
            var parts = [zh ? "已导入 \(s.added.count) 篇" : "Imported \(s.added.count)"]
            if let d = s.lastDeadline { parts.append(zh ? "最后 DDL \(SharedStrings.monthDay(d))" : "last deadline \(SharedStrings.monthDay(d))") }
            if s.duplicates > 0 { parts.append(zh ? "重复 \(s.duplicates) 篇" : "\(s.duplicates) duplicate(s)") }
            if s.rejected + s.failed > 0 { parts.append(zh ? "未能导入 \(s.rejected + s.failed) 个" : "\(s.rejected + s.failed) not imported") }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Library change, re-index, widget repair, General's Help & Setup / Move sections

extension L.Pref {
    // Settings ▸ Library ▸ Change… (after the folder was inspected)
    static var changeSameLibrary: String {
        zh ? "这就是你当前的论文库（移动过位置？）。之后 PaperDeck 会使用这个位置。"
           : "This is your current library (moved?). PaperDeck will use it from now on."
    }
    static var useThisFolder: String { zh ? "使用这个文件夹" : "Use This Folder" }
    static func changeOtherLibrary(_ n: Int) -> String {
        zh ? "找到另一个 PaperDeck 论文库（约 \(n) 篇论文）。当前论文库保持原样，之后可以切换回来。PaperDeck 会先备份它的索引。"
           : "Found another PaperDeck library (about \(n) papers). Your current library stays where it is and you can switch back later. PaperDeck backs up its index first."
    }
    static var openThisLibrary: String { zh ? "打开这个论文库" : "Open This Library" }
    static func changeParent(_ child: String) -> String { zh ? "你是想选 \(child) 吗？" : "Did you mean \(child)?" }
    static var useIt: String { zh ? "使用它" : "Use It" }
    static var changeEmpty: String {
        zh ? "这个文件夹里还没有 PaperDeck 论文库。" : "There's no PaperDeck library in this folder yet."
    }
    static func changeOtherContent(_ n: Int) -> String {
        zh ? "这个文件夹里已有 \(n) 个项目：PaperDeck 会在里面新建一个 Papers 文件夹。"
           : "This folder already holds \(n) item(s): PaperDeck will create a Papers folder inside."
    }
    static var startNewLibrary: String { zh ? "在这里新建空的论文库" : "Start a New Empty Library Here" }
    static var moveLibraryNote: String {
        zh ? "要移动当前论文库：先退出 PaperDeck，在 Finder 中移动文件夹，再回到这里选择它。"
           : "To move your current library: quit PaperDeck, move the folder in Finder, then choose it here."
    }
    static var changeUnreadable: String { zh ? "PaperDeck 无法读取这个文件夹，请换一个。" : "PaperDeck can't read this folder. Choose another one." }
    static var changeMissing: String { zh ? "这个文件夹不存在。" : "This folder doesn't exist." }
    static var chooseAnotherLibrary: String { zh ? "换一个文件夹…" : "Choose Another…" }
    static var restartNow: String { zh ? "立即重启" : "Restart Now" }
    static func switchPending(_ path: String) -> String {
        zh ? "PaperDeck 重启后会打开 \(path)（之前的索引会先备份）。"
           : "PaperDeck opens \(path) when it restarts (the current index is backed up first)."
    }
    static func startPending(_ path: String) -> String {
        zh ? "PaperDeck 重启后会在 \(path) 新建论文库。" : "PaperDeck starts a new library in \(path) when it restarts."
    }

    // Maintenance ▸ Re-index full text
    static var reindex: String { zh ? "重建全文索引" : "Re-index full text" }
    static var reindexHint: String {
        zh ? "重新读取搜索还找不到正文的论文（例如换到另一台 Mac 之后）— 本机完成，不用 AI，不消耗额度"
           : "Re-reads papers whose text search can't find yet (e.g. after moving Macs) — on this Mac, no AI, no quota"
    }
    static var reindexButton: String { zh ? "重建" : "Re-index" }
    static func reindexDone(_ n: Int) -> String {
        n == 0 ? (zh ? "所有论文的正文都已在索引中" : "Every paper's text is already indexed")
               : (zh ? "已为 \(n) 篇论文建立全文索引" : "Indexed the text of \(n) paper(s)")
    }

    // Widget ▸ Repair registration
    static var repairRegistration: String { zh ? "修复注册" : "Repair registration" }
    static var repairRegistrationHint: String {
        zh ? "让 macOS 重新登记 PaperDeck 和它的小组件（lsregister、pluginkit）" : "Registers PaperDeck and its widget with macOS again (lsregister, pluginkit)"
    }
    static var repairButton: String { zh ? "修复" : "Repair" }
    static var repairDone: String { zh ? "已重新注册 — 请再看一下小组件列表" : "Registered again — check the widget gallery" }
    static func repairFailed(_ m: String) -> String { zh ? "无法重新注册：\(m)" : "Couldn't register again: \(m)" }
    static var repairNeedsApp: String {
        zh ? "开发构建（未打包为 App）无法注册小组件。" : "Development builds (not packaged as an app) can't register the widget."
    }

    // General ▸ Help & Setup
    static var helpSetupSection: String { zh ? "帮助与设置" : "Help & Setup" }
    static var paperDeckHelp: String { zh ? "PaperDeck 帮助" : "PaperDeck Help" }
    static var setupAssistantButton: String { zh ? "设置助手…" : "Setup Assistant…" }
    static var featureTour: String { zh ? "功能导览" : "Feature Tour" }
}

// MARK: - Settings ▸ Profile

extension L {
    enum Profile {
        private static var zh: Bool { L.lang == .zh }

        static var tab: String { zh ? "个人资料" : "Profile" }
        static var youSection: String { zh ? "你" : "You" }
        static var field: String { zh ? "研究领域" : "Research field" }
        static var stage: String { zh ? "阶段" : "Career stage" }
        static var reader: String { zh ? "AI 怎样理解你" : "How the AI should picture you" }
        static var readerHint: String {
            zh ? "作为每篇论文解读说明的一部分发送给你的 AI。" : "Sent to your AI as part of the instructions for each paper."
        }
        static func readerCount(_ n: Int, _ max: Int) -> String { "\(n)/\(max)" }
        static var resetToDefault: String { zh ? "恢复默认" : "Reset to Default" }
        static var showInstructions: String { zh ? "显示随每篇论文发送的说明" : "Show the instructions sent with each paper" }
        static var interests: String { zh ? "研究兴趣（可选）" : "Research interests (optional)" }
        static var interestsHint: String {
            zh ? "也用于从论文提醒邮件中挑出相关论文。" : "Also used to pick relevant papers from email alerts."
        }
        static var fieldNote: String {
            zh ? "研究领域决定新论文库的起始分类、解读卡片的读者设定、示例提示和推荐的提醒发件人。"
               : "Your field sets a new library's starter categories, the reading-card persona, example hints and suggested alert senders."
        }
        static var onboardingIntro: String {
            zh ? "这会调整解读卡片和建议。只有读者描述会随每篇论文发送给你的 AI。"
               : "This tunes reading cards and suggestions. Only the reader description is sent to your AI, with each paper."
        }

        // Starter categories
        static var starterSection: String { zh ? "起始分类" : "Starter categories" }
        static func starterSuggested(_ field: String, _ names: String) -> String {
            zh ? "「\(field)」建议的分类：\(names)" : "Suggested categories for \(field): \(names)"
        }
        static var addMissingCategories: String { zh ? "添加缺少的分类…" : "Add Missing Categories…" }
        static func addMissingTitle(_ n: Int) -> String { zh ? "添加 \(n) 个分类？" : (n == 1 ? "Add 1 category?" : "Add \(n) categories?") }
        static func addMissingBody(_ n: Int) -> String {
            zh ? "添加 \(n) 个分类，不会重命名或删除任何分类。" : "Adds \(n) \(n == 1 ? "category" : "categories"). Nothing is renamed or removed."
        }
        static var add: String { zh ? "添加" : "Add" }
        static func addMissingDone(_ n: Int) -> String {
            zh ? "已添加 \(n) 个分类，没有重命名或删除任何分类。" : "Added \(n) \(n == 1 ? "category" : "categories"). Nothing was renamed or removed."
        }
        static var noMissingCategories: String {
            zh ? "建议的分类都已在资料库中。" : "Every suggested category is already in your library."
        }

        // Institution
        static var institutionSection: String { zh ? "机构 AI 规定" : "Institution AI policy" }
        static var institution: String { zh ? "机构" : "Institution" }
        static var noPolicy: String {
            zh ? "无特定规定 — 提醒我查看所在机构的指引" : "No specific policy — remind me to check my institution's guidance"
        }
        static var other: String { zh ? "其他…" : "Other…" }
        static func presetTitle(name: String, short: String?) -> String {
            guard let short, !short.isEmpty, short != name else { return name }
            return zh ? "\(name)（\(short)）" : "\(name) (\(short))"
        }
        static var customName: String { zh ? "机构名称" : "Name" }
        static var customShort: String { zh ? "简称" : "Short name" }
        static var customTools: String { zh ? "获批准的 AI 工具" : "Approved AI tools" }
        static var customToolsPrompt: String { zh ? "用逗号分隔" : "Comma-separated" }
        static var customPolicyURL: String { zh ? "规定链接" : "Policy link" }
        static var customPolicyURLPrompt: String { "https://…" }
        static var invalidURL: String { zh ? "请使用 https:// 开头的链接。" : "Use a link that starts with https://." }
        static var peopleDefault: String { zh ? "个人发件人的邮件" : "People's emails" }
        static func peopleDefaultName(_ p: PeopleAIDefault) -> String {
            switch p {
            case .ask: return zh ? "每次询问" : "Ask each time"
            case .never: return zh ? "从不发给 AI" : "Never send to AI"
            }
        }
        static var previewIntro: String {
            zh ? "当有人（而不是新闻通讯）给你发论文时，PaperDeck 会显示：" : "When a person (not a newsletter) emails you a paper, PaperDeck will say:"
        }
        static var institutionFooter: String {
            zh ? "这里只改变措辞。安全默认设置（在你打开之前 AI 保持关闭，个人邮件先询问）对所有人都一样。"
               : "This changes wording only. Safety defaults (AI off until you turn it on, people's emails ask first) are the same for everyone."
        }
    }

    // MARK: - Settings transfer (General ▸ Move to another Mac, export / import sheets)

    enum Transfer {
        private static var zh: Bool { L.lang == .zh }

        static var section: String { zh ? "迁移到另一台 Mac" : "Move to another Mac" }
        static var export: String { zh ? "导出设置…" : "Export Settings…" }
        static var `import`: String { zh ? "导入设置…" : "Import Settings…" }
        static var note: String {
            zh ? "导出偏好设置、发件人列表、阅读标准和邮件账户 — 绝不包含密码或应用专用密码。导入后，AI 解读和邮件保持关闭，直到你把它们打开。"
               : "Exports preferences, the sender list, reading criteria and mail accounts — never passwords or app passwords. After an import, AI reading and Mail stay off until you turn them on."
        }
        static func lastExported(_ when: String) -> String { zh ? "上次导出：\(when)" : "Last exported \(when)" }

        static func sectionName(_ s: SettingsSection) -> String {
            switch s {
            case .profile, .organization: return zh ? "个人资料与机构" : "Profile & institution"
            case .general: return zh ? "通用" : "General"
            case .plan: return zh ? "阅读计划与提醒" : "Plan & reminder"
            case .ai: return zh ? "AI 偏好设置" : "AI preferences"
            case .library: return zh ? "资料库偏好设置" : "Library preferences"
            case .mailSenders: return zh ? "邮件发件人与阅读标准" : "Mail senders & criteria"
            case .mailAccounts: return zh ? "邮件账户（不含密码）" : "Mail accounts (no passwords)"
            case .panel: return zh ? "侧边悬浮条" : "Drop strip"
            }
        }

        // Export sheet
        static var exportTitle: String { zh ? "导出设置" : "Export Settings" }
        static var exportIntro: String {
            zh ? "选择要写进文件的内容。密码和应用专用密码永远不会导出。" : "Choose what goes into the file. Passwords and app passwords are never included."
        }
        static var accountsHaveAddresses: String {
            zh ? "邮件账户包含你的邮箱地址。" : "Mail accounts include your mailbox addresses."
        }
        static var includePersonal: String { zh ? "包含 Crossref 联系邮箱" : "Include the Crossref contact email" }
        static var exportButton: String { zh ? "导出…" : "Export…" }
        static func defaultFileName(_ date: String) -> String { "PaperDeck Settings \(date).json" }
        static var saveMessage: String { zh ? "保存 PaperDeck 设置文件" : "Save the PaperDeck settings file" }
        static func exported(_ path: String) -> String { zh ? "已导出到 \(path)" : "Exported to \(path)" }
        static func exportFailed(_ m: String) -> String { zh ? "无法导出：\(m)" : "Couldn't export: \(m)" }

        // Import sheet
        static var importTitle: String { zh ? "导入设置" : "Import Settings" }
        static var chooseFile: String { zh ? "选择文件…" : "Choose File…" }
        static var chooseFileMessage: String { zh ? "选择一个 PaperDeck 设置文件" : "Choose a PaperDeck settings file" }
        static var noFile: String {
            zh ? "选择从另一台 Mac 导出的设置文件，或实验室 / IT 给你的配置文件。" : "Choose a settings file exported on another Mac, or a setup file from your lab or IT."
        }
        static func header(app: String, date: String) -> String { zh ? "来自 \(app)，导出于 \(date)" : "From \(app), exported \(date)" }
        static func unknownFormat(_ f: String) -> String {
            zh ? "这不是 PaperDeck 设置文件（格式 \(f)）。" : "This isn't a PaperDeck settings file (format \(f))."
        }
        static var malformed: String { zh ? "无法读取这个文件：它不是有效的 PaperDeck 设置文件。" : "This file couldn't be read as a PaperDeck settings file." }
        static var noChanges: String { zh ? "没有需要更改的内容 — 这台 Mac 已经是这些设置。" : "Nothing to change — this Mac already has these settings." }
        static func change(_ label: String, old: String?, new: String) -> String {
            guard let old else { return "\(label): \(new)" }
            return "\(label): \(old) → \(new)"
        }
        static var changesSection: String { zh ? "将更改" : "Will change" }
        /// A list setting in the import diff: "Sender list: add 1 · replace 1 · keep 2".
        static func listSummary(_ label: String, added: Int, replaced: Int, kept: Int) -> String {
            zh ? "\(label)：新增 \(added) · 替换 \(replaced) · 保留 \(kept)"
               : "\(label): add \(added) · replace \(replaced) · keep \(kept)"
        }
        static func listNames(_ part: SettingsImportSheet.ListImpact.Part, _ names: [String]) -> String {
            let list = names.joined(separator: zh ? "、" : ", ")
            switch part {
            case .added: return zh ? "新增：\(list)" : "Add: \(list)"
            case .replaced: return zh ? "替换为文件中的版本：\(list)" : "Replace with the file's version: \(list)"
            case .kept: return zh ? "保留：\(list)" : "Keep: \(list)"
            }
        }
        static func listRemoved(_ names: [String]) -> String {
            let list = names.joined(separator: zh ? "、" : ", ")
            return zh ? "将从这台 Mac 移除（文件里没有）：\(list)" : "Removed from this Mac (not in the file): \(list)"
        }
        static var warningsSection: String { zh ? "注意" : "Check" }
        static func warning(_ w: ImportWarning) -> String {
            switch w {
            case .needsAppPassword(let a):
                return zh ? "\(a)：需要重新输入应用专用密码（设置 ▸ 邮件）" : "\(a): needs its app password again (Settings ▸ Mail)"
            case .folderRemapped(let a, let to):
                return zh ? "\(a)：文件夹在这台 Mac 上的位置是 \(to)" : "\(a): its folder is at \(to) on this Mac"
            case .folderUnresolved(let a, let root):
                return zh ? "\(a)：这台 Mac 上没有 \(root)，稍后再选择文件夹" : "\(a): \(root) isn't on this Mac — choose the folder later"
            case .cliPathDropped(let key):
                let p = keyLabel(key)
                return zh ? "这台 Mac 上没有文件中的「\(p)」，已忽略" : "The file's \(p) isn't on this Mac — dropped"
            case .peopleAlwaysClamped(let sender):
                return zh ? "\(sender)：「总是发给 AI」导入为「每次询问」" : "\(sender): “Always send to AI” imported as “Ask each time”"
            case .readerDescriptionNeedsConfirm:
                return zh ? "下面的读者描述会写进发送给 AI 的说明 — 只有是你自己写的才导入。"
                          : "The reader description below goes into the instructions sent to your AI — import it only if it's yours."
            case .unknownKeysIgnored(let n):
                return zh ? "忽略了 \(n) 项无法识别的设置" : "\(n) unknown setting(s) ignored"
            case .valueOutOfRange(let key):
                let p = keyLabel(key)
                return zh ? "文件中的「\(p)」不是可用的值（类型不对或超出范围），没有导入"
                          : "The file's \(p) isn't a usable value (wrong type or out of range) — not imported"
            case .entriesSkipped(let key, let n):
                let p = keyLabel(key)
                return zh ? "文件中「\(p)」有 \(n) 项含有超出范围的值，已跳过"
                          : "\(n) of the file's \(p) had a value out of range — skipped"
            case .criteriaInstructionsNeedConfirm:
                return zh ? "下面这段给 AI 的说明会写进邮件分拣发送给 AI 的提示 — 只有是你自己写的才导入。"
                          : "The instructions below go into what AI email sorting sends to your AI — import them only if they're yours."
            }
        }
        static var keepPeopleAlways: String { zh ? "保留我自己设为「总是」的个人发件人" : "Keep “Always” for people I set myself" }
        static var readerDescription: String { zh ? "读者描述" : "Reader description" }
        static var useReaderDescription: String { zh ? "使用这段描述" : "Use this description" }
        static var criteriaInstructions: String { zh ? "邮件分拣：给 AI 的说明" : "Email sorting: instructions for the AI" }
        static var useCriteriaInstructions: String { zh ? "使用这段说明" : "Use these instructions" }
        static var footer: String {
            zh ? "AI 解读和邮件保持关闭，准备好后再打开。" : "AI reading and Mail stay off. Turn them on when you're ready."
        }
        static var importButton: String { zh ? "导入" : "Import" }
        static func imported(_ n: Int) -> String { zh ? "已导入 \(n) 项设置。" : "Imported \(n) setting(s)." }
        static func readFailed(_ m: String) -> String { zh ? "无法读取文件：\(m)" : "Couldn't read the file: \(m)" }

        /// The human label of a settings key (`SettingsRegistry` — every key has one in en and zh;
        /// the import / export sheets and the CLI never show a raw key name).
        static func keyLabel(_ key: String) -> String {
            SettingsRegistry.label(key, L.lang) ?? (zh ? "其他设置" : "Other setting")
        }

        // Kept stricter (an import never loosens privacy or quota settings silently)
        static var keptStricterSection: String { zh ? "保留更严格的设置" : "Kept stricter" }
        static var keptStricterIntro: String {
            zh ? "这台 Mac 的这些设置在隐私、AI 额度或删除文件方面更严格，因此保持不变。只有勾选某一项，才会改用文件中较宽松的值。"
               : "This Mac's settings below are stricter about privacy, AI quota or deleting files, so they stay as they are. Tick an item only to use the file's looser value."
        }
        /// "Kept stricter: AI triage daily limit — 30 per day (file: 200 per day)".
        static func keptStricter(_ label: String, mine: String, theirs: String) -> String {
            zh ? "保留更严格：\(label) — \(mine)（文件：\(theirs)）" : "Kept stricter: \(label) — \(mine) (file: \(theirs))"
        }
        /// The same item once its checkbox is ticked: "Will loosen: … — 200 per day (this Mac: 30 per day)".
        static func looserAccepted(_ label: String, mine: String, theirs: String) -> String {
            zh ? "将放宽：\(label) — \(theirs)（这台 Mac：\(mine)）" : "Will loosen: \(label) — \(theirs) (this Mac: \(mine))"
        }
        static var acceptLooser: String { zh ? "改用文件中较宽松的值" : "Use the file's looser value" }
        /// What one kept-stricter item is about: a key, one field of a sender or an account ("Prof.
        /// Smith: Send to AI for triage"), the institution's people default.
        static func looseningLabel(_ l: ImportLoosening) -> String {
            if l.id == ImportLoosening.peopleDefaultID { return "\(keyLabel(ConfigKeys.orgPreset)) · \(L.Profile.peopleDefault)" }
            if let subject = l.subject {
                let what = entryFieldLabel(l.field ?? .aiPolicy, account: l.key == MailSettings.Keys.accounts)
                if let broader = l.overrides {
                    // A sender the file adds that would take over mail from this Mac's stricter rule.
                    return zh ? "\(subject)（新增，比「\(broader)」更具体）：\(what)"
                              : "\(subject) (new, more specific than \(broader)): \(what)"
                }
                return zh ? "\(subject)：\(what)" : "\(subject): \(what)"
            }
            return keyLabel(l.key)
        }
        /// One guarded field of a sender or a mail account, in words.
        static func entryFieldLabel(_ field: ImportEntryField, account: Bool) -> String {
            switch field {
            case .aiPolicy: return L.MailPref.aiPolicy
            case .enabled:
                return account ? (zh ? "检查此账户" : "Check this account") : (zh ? "读取此发件人的邮件" : "Read this sender's mail")
            case .autoMerge: return L.MailPref.autoMerge
            case .autoDownload: return L.MailPref.autoDownload
            case .lookbackDays: return L.MailPref.lookback
            case .deleteProcessedFiles: return L.MailPref.deleteProcessed
            }
        }
        /// A kept-stricter item's value in words ("30 per day", "Local rules only", "Ask", "Off", "14 days").
        static func looseningValue(_ l: ImportLoosening, _ v: JSONValue) -> String {
            if l.id == ImportLoosening.peopleDefaultID, let p = v.stringValue.flatMap(PeopleAIDefault.init(rawValue:)) {
                return L.Profile.peopleDefaultName(p)
            }
            switch l.field {
            case .aiPolicy?:
                if let p = v.stringValue.flatMap(MailAIPolicy.init(rawValue:)) { return L.MailPref.aiPolicyShort(p) }
            case .lookbackDays?:
                if let n = v.doubleValue.flatMap({ Int(exactly: $0.rounded()) }) { return L.MailPref.days(n) }
            case .enabled?, .autoMerge?, .autoDownload?, .deleteProcessedFiles?, nil:
                break
            }
            return value(l.key, v)
        }
        /// A setting's value in words for the kept-stricter list (falls back to the value as is).
        static func value(_ key: String, _ v: JSONValue) -> String {
            let n = v.doubleValue.flatMap { Int(exactly: $0.rounded()) }   // out-of-range file values must not trap
            switch key {
            case MailSettings.Keys.aiMode:
                switch v.stringValue {
                case MailSettings.AIMode.ai.rawValue: return L.MailPref.triageSection
                case MailSettings.AIMode.heuristicOnly.rawValue: return L.MailPref.modeLocal
                default: break
                }
            case MailSettings.Keys.triageDailyMax: if let n { return L.MailPref.perDay(n) }
            case MailSettings.Keys.triageProvider:
                if let p = v.stringValue.flatMap(AIProviderKind.init(rawValue:)) { return L.Pref.providerName(p) }
            case MailSettings.Keys.triageBodyCap, "agent.textBudget": if let n { return L.Pref.characters(n) }
            case MailSettings.Keys.maxAttachmentMB: if let n { return "\(n) MB" }
            case MailSettings.Keys.retentionDays: if let n { return n <= 0 ? L.MailPref.keepForever : L.MailPref.days(n) }
            case MailSettings.Keys.syncMinutes: if let n { return n <= 0 ? L.MailPref.manualOnly : L.MailPref.every(minutes: n) }
            case "agent.effort":
                switch v.stringValue {
                case "low": return L.Pref.effortLow
                case "medium": return L.Pref.effortMedium
                default: break
                }
            case "agent.model", MailSettings.Keys.triageModelClaude:
                if let s = v.stringValue, !s.isEmpty { return s.prefix(1).uppercased() + s.dropFirst() }
            default: break
            }
            if let b = v.boolValue { return b ? (zh ? "开" : "On") : (zh ? "关" : "Off") }
            return SettingsTransferValues.describe(json: v)
        }
    }
}
