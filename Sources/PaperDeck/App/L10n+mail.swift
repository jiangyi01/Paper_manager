import Foundation
import PaperDeckCore
import PaperDeckConfig

// Strings of the Mail panel (sidebar entry, inbox, email cards, paper rows, drop boxes, the
// detail inspector, the merge popover, menu-bar / floating-panel lines, mail toasts).
// Namespaced under `L.Mail` so they never collide with the other slices' `extension L` files.
// Mail content itself (subjects, names, summaries) is never put into these format strings as
// Markdown — views render it with `Text(verbatim:)`.
extension L {
    enum Mail {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Sidebar / window

        static var section: String { zh ? "邮件" : "Mail" }
        static var inbox: String { zh ? "收件箱" : "Inbox" }
        static var title: String { zh ? "邮件" : "Mail" }
        static func badgeA11y(pending: Int, requests: Int) -> String {
            if zh { return requests > 0 ? "\(pending) 封待处理，含 \(requests) 封请求" : "\(pending) 封待处理" }
            let e = pending == 1 ? "1 email" : "\(pending) emails"
            return requests > 0 ? "\(e) to handle, \(requests) \(requests == 1 ? "request" : "requests")" : "\(e) to handle"
        }
        static func subtitle(pending: Int, needsPDF: Int) -> String {
            if zh {
                if pending == 0 { return "没有待处理的邮件" }
                return needsPDF > 0 ? "\(pending) 封待处理 · \(needsPDF) 篇需要 PDF" : "\(pending) 封待处理"
            }
            if pending == 0 { return "Nothing to handle" }
            let base = "\(pending) to handle"
            return needsPDF > 0 ? base + " · \(needsPDF) need\(needsPDF == 1 ? "s" : "") a PDF" : base
        }

        // MARK: Filters

        static func filter(_ f: MailInboxFilter) -> String {
            switch f {
            case .pending: return zh ? "待处理" : "Pending"
            case .snoozed: return zh ? "稍后" : "Snoozed"
            case .handled: return zh ? "已处理" : "Handled"
            case .dismissed: return zh ? "已忽略" : "Dismissed"
            case .noRequest: return zh ? "无阅读需求" : "No Request"
            }
        }
        static func filterWithCount(_ f: MailInboxFilter, _ n: Int) -> String {
            n > 0 && (f == .pending || f == .snoozed) ? "\(filter(f)) \(n)" : filter(f)
        }
        static var filterLabel: String { zh ? "显示" : "Show" }

        // MARK: Inbox header / status

        static var syncNow: String { zh ? "立即同步" : "Sync Now" }
        static var syncing: String { zh ? "正在同步…" : "Syncing…" }
        static var importEML: String { zh ? "导入 .eml…" : "Import .eml…" }
        static var importEMLMessage: String {
            zh ? "选择从 Outlook、Gmail 或邮件 App 存下的 .eml 邮件文件" : "Choose .eml files saved from Outlook, Gmail or Mail"
        }
        static var importPrompt: String { zh ? "导入" : "Import" }
        static var mailSettings: String { zh ? "邮件设置…" : "Mail Settings…" }
        static var setUpTitle: String { zh ? "邮件还没有设置" : "Mail isn't set up yet" }
        static var setUpBody: String {
            zh ? "在「设置 ▸ 邮件」添加账户（Power Automate 同步的文件夹，或 Gmail / iCloud 应用专用密码），只读取发件人名单里的邮件。也可以随时把 .eml 文件拖到这里。"
               : "Add an account in Settings ▸ Mail (a folder your Power Automate flow fills, or Gmail / iCloud with an app password). Only mail from your sender list is read. You can always drop .eml files here too."
        }
        static var setUp: String { zh ? "设置邮件…" : "Set Up Mail…" }
        static var disabledTitle: String { zh ? "邮件同步已关闭" : "Mail sync is off" }
        static var disabledBody: String {
            zh ? "不会读取任何账户。拖入的 .eml 文件仍会整理成卡片。" : "No account is read. Dropped .eml files still become cards."
        }
        static func accountLine(name: String, status: String) -> String { name + " · " + status }
        static var statusNotChecked: String { zh ? "尚未同步" : "Not synced yet" }
        static func statusSynced(_ ago: String) -> String { zh ? "\(ago)同步" : "synced \(ago)" }
        static var statusReady: String { zh ? "已连接" : "Connected" }
        static func statusNeedsSetup(_ why: String) -> String { zh ? "需要设置：\(why)" : "Needs setup: \(why)" }
        static func statusAuthFailed(_ why: String) -> String { zh ? "登录被拒绝：\(why)" : "Sign-in rejected: \(why)" }
        static func statusUnavailable(_ why: String) -> String { zh ? "暂时不可用：\(why)" : "Unavailable: \(why)" }
        static func triageUsage(used: Int, limit: Int) -> String {
            zh ? "今天 AI 分拣 \(used)/\(limit) 次" : "AI triage today \(used)/\(limit)"
        }
        static var triageLocalOnly: String { zh ? "邮件分拣：仅本地规则（不发送给 AI）" : "Mail triage: local rules only (nothing is sent to AI)" }
        static func triageQueued(_ n: Int) -> String { zh ? "\(n) 封等待 AI 分析" : "\(n) waiting for AI" }
        /// Folder accounts: files Power Automate wrote that are not complete emails (`notEmailFiles`).
        static func notEmailShort(_ n: Int) -> String {
            zh ? "\(n) 个文件不是完整的邮件" : (n == 1 ? "1 file isn't a complete email" : "\(n) files aren't complete emails")
        }
        /// Allowlisted emails skipped because the account's retry list was full (`skipped`).
        static func skippedShort(_ n: Int) -> String {
            zh ? "跳过 \(n) 封邮件" : (n == 1 ? "1 email skipped" : "\(n) emails skipped")
        }
        static var powerAutomateGuide: String { zh ? "Power Automate 设置指南…" : "Power Automate Guide…" }
        static var justNow: String { zh ? "刚刚" : "just now" }
        static func minutesAgo(_ n: Int) -> String { zh ? "\(n) 分钟前" : "\(n) min ago" }
        static func hoursAgo(_ n: Int) -> String { zh ? "\(n) 小时前" : "\(n) h ago" }

        // MARK: Empty states

        static func emptyTitle(_ f: MailInboxFilter) -> String {
            switch f {
            case .pending: return zh ? "没有待处理的邮件" : "No emails to handle"
            case .snoozed: return zh ? "没有稍后处理的邮件" : "Nothing snoozed"
            case .handled: return zh ? "还没有处理过的邮件" : "No handled emails yet"
            case .dismissed: return zh ? "没有忽略的邮件" : "No dismissed emails"
            case .noRequest: return zh ? "没有「无阅读需求」的邮件" : "No emails without a request"
            }
        }
        static func emptyMessage(_ f: MailInboxFilter) -> String {
            switch f {
            case .pending:
                return zh ? "发件人名单里的论文请求和提醒会出现在这里。把 .eml 拖进来也可以。"
                          : "Paper requests and alerts from your sender list show up here. You can also drop .eml files."
            case .snoozed: return zh ? "用「稍后」推迟的邮件会在到时间后回到待处理。" : "Emails you snooze come back to Pending on time."
            case .handled: return zh ? "论文全部合并或跳过后，邮件会移到这里。" : "Emails move here once their papers are added or skipped."
            case .dismissed: return zh ? "被忽略的邮件保留在这里，可以随时移回待处理。" : "Dismissed emails stay here; move them back any time."
            case .noRequest: return zh ? "分拣认为没有阅读需求的邮件会放在这里。" : "Emails triage found no reading request in land here."
            }
        }
        /// ContentUnavailableView when the Mail section has nothing at all (also EmptyStateView's `.mail` case).
        static var emptyInboxTitle: String { zh ? "还没有邮件" : "No Mail Yet" }
        static var emptyInboxMessage: String {
            zh ? "把 .eml 邮件文件拖到这里，或在「设置 ▸ 邮件」添加账户。" : "Drop .eml files here, or add an account in Settings ▸ Mail."
        }
        static var loading: String { zh ? "正在读取邮件…" : "Loading mail…" }

        // MARK: Card header

        static var manualAccount: String { zh ? "手动导入" : "Imported" }
        static var unverifiedSender: String { zh ? "未验证发件人" : "Unverified sender" }
        static var unverifiedHelp: String {
            zh ? "这封邮件的 DKIM/DMARC 检查未通过，发件人可能是伪造的。" : "This email failed DKIM/DMARC checks — the sender may be forged."
        }
        static func badge(_ b: MailInboxRules.RequestBadge, advisor: Bool) -> String {
            switch b {
            case .request: return zh ? (advisor ? "导师请求" : "阅读请求") : "Request"
            case .journalClub: return zh ? "组会" : "Journal club"
            case .alert: return zh ? "论文提醒" : "Alert"
            case .fyi: return zh ? "分享" : "FYI"
            case .other: return zh ? "其他" : "Other"
            }
        }
        static func dueChip(_ date: String, confident: Bool, past: Bool) -> String {
            let d = (confident ? "" : "≈") + date
            if past { return zh ? "邮件 DDL \(d)（已过）" : "Email due \(d) (passed)" }
            return zh ? "邮件 DDL \(d)" : "Email due \(d)"
        }
        static func dueHelp(_ evidence: String?) -> String {
            let base = zh ? "邮件里提到的日期，只有你合并时选择「固定 DDL」才会成为论文的 DDL。"
                          : "A date mentioned in the email. It becomes the paper's deadline only if you pin it when adding."
            guard let evidence else { return base }
            return base + "\n" + (zh ? "原文：“\(evidence)”" : "From the email: “\(evidence)”")
        }
        static var priorityHigh: String { zh ? "高优先级" : "High priority" }
        static var priorityLow: String { zh ? "低优先级" : "Low priority" }
        static var moreActions: String { zh ? "更多操作" : "More" }
        static var showEmail: String { zh ? "查看邮件" : "Show Email" }
        static var copyLink: String { zh ? "拷贝邮件链接" : "Copy Link to Email" }
        static func openWeb(gmail: Bool) -> String {
            gmail ? (zh ? "在 Gmail 中打开" : "Open in Gmail") : (zh ? "在网页版中打开" : "Open on the Web")
        }
        static var summaryAI: String { zh ? "AI 摘要" : "AI summary" }
        static var summaryHeuristic: String { zh ? "本地规则摘要（未发送给 AI）" : "Local-rules summary (not sent to AI)" }
        static var noSubject: String { zh ? "（无主题）" : "(No subject)" }
        static func requester(_ name: String) -> String { zh ? "请求人：\(name)" : "Requested by \(name)" }
        static func papers(_ n: Int) -> String { zh ? "\(n) 篇论文" : (n == 1 ? "1 paper" : "\(n) papers") }

        // MARK: Card triage state

        static var analyzeWithAI: String { zh ? "让 AI 分析" : "Analyze with AI" }
        static var analyzeAgain: String { zh ? "重新让 AI 分析" : "Analyze with AI Again" }
        static func consentTitle(_ provider: String) -> String {
            zh ? "这封邮件只用本地规则整理过。要让 \(provider) 分析吗？" : "Sorted by local rules only. Let \(provider) analyze it?"
        }
        /// What 「让 AI 分析」 sends, plus the configured institution's guidance (`OrgStrings`).
        static func consentNote(_ provider: String) -> String {
            OrgStrings.consentNote(provider: provider, org: L.org, lang: L.lang)
        }
        /// The compact card's ⓘ (what is sent and the guidance, in a popover / tooltip).
        static var consentInfo: String { zh ? "发送什么内容" : "What is sent" }
        static var triageRunning: String { zh ? "AI 正在分析…" : "AI is analyzing…" }
        static var triageQueuedOne: String { zh ? "等待 AI 分析…" : "Waiting for AI…" }
        static var triageHeld: String { zh ? "AI 分析已暂缓" : "AI triage is on hold" }
        static var triageLimited: String { zh ? "AI 用量已达上限，恢复后自动分拣" : "The AI usage limit is reached — triage resumes automatically" }
        static var triageNeedsLogin: String { zh ? "AI 未登录 · 登录后自动分拣" : "The AI isn't signed in — triage resumes after you sign in" }
        static var triageFailed: String { zh ? "AI 分拣失败" : "AI triage failed" }
        static var openAISettings: String { zh ? "AI 设置…" : "AI Settings…" }
        static var notSentLocal: String { zh ? "未发送给 AI（本地规则）" : "Not sent to AI (local rules)" }
        static var aiRequested: String { zh ? "已排队，等待 AI 分析" : "Queued for AI analysis" }

        // MARK: Card footer

        static func mergeAll(_ n: Int) -> String { zh ? "全部合并（\(n)）" : "Add All (\(n))" }
        static var dismiss: String { zh ? "忽略" : "Dismiss" }
        static var later: String { zh ? "稍后" : "Later" }
        static var snoozeTomorrow: String { zh ? "明天" : "Tomorrow" }
        static var snoozeNextMonday: String { zh ? "下周一" : "Next Monday" }
        static var snoozeCustom: String { zh ? "自定义…" : "Custom…" }
        static var snoozeTitle: String { zh ? "稍后提醒" : "Snooze Until" }
        static var snoozeConfirm: String { zh ? "稍后" : "Snooze" }
        static func snoozedUntil(_ when: String) -> String { zh ? "稍后：\(when)" : "Snoozed until \(when)" }
        static var unsnooze: String { zh ? "现在处理" : "Unsnooze" }
        static var reopen: String { zh ? "移回待处理" : "Move to Pending" }
        static func handledOn(_ when: String) -> String { zh ? "已处理 · \(when)" : "Handled · \(when)" }
        static var dismissedNote: String { zh ? "已忽略" : "Dismissed" }
        static var noRequestNote: String { zh ? "分拣认为这封邮件没有阅读需求" : "Triage found no reading request in this email" }
        static func rest(_ n: Int) -> String { zh ? "其余 \(n) 篇" : (n == 1 ? "1 more paper" : "\(n) more papers") }
        static var showFewer: String { zh ? "收起" : "Show Fewer" }
        static var noPapers: String { zh ? "没有找到论文链接或附件" : "No paper links or attachments found" }

        // MARK: Rows

        static func chip(_ c: MailInboxRules.ItemChip) -> String {
            switch c {
            case .attachment: return zh ? "附件 PDF" : "PDF attached"
            case .downloaded: return zh ? "已下载" : "Downloaded"
            case .downloadable: return zh ? "可下载" : "Downloadable"
            case .downloading: return zh ? "下载中" : "Downloading"
            case .needsPDF: return zh ? "需要 PDF" : "Needs PDF"
            case .inLibrary: return zh ? "已在库中" : "In library"
            case .merged: return zh ? "已合并" : "Merged"
            case .skipped: return zh ? "已跳过" : "Skipped"
            }
        }
        static var requested: String { zh ? "点名要读" : "Requested" }
        static var highlighted: String { zh ? "推荐" : "Highlighted" }
        static var foundByAI: String { zh ? "AI 找到 · 已核实" : "Found by AI · verified" }
        static var untitled: String { zh ? "未命名论文" : "Untitled paper" }
        static var merge: String { zh ? "合并到论文库" : "Add to Library" }
        static var linkExisting: String { zh ? "关联到库中论文" : "Link to Library" }
        static var downloadAndMerge: String { zh ? "自动下载并合并" : "Download & Add" }
        static var downloadOnly: String { zh ? "仅下载 PDF" : "Download PDF Only" }
        static var openLink: String { zh ? "打开链接" : "Open Link" }
        static var openCard: String { zh ? "打开卡片" : "Open Card" }
        static var skip: String { zh ? "跳过" : "Skip" }
        static var copyDOI: String { zh ? "拷贝 DOI" : "Copy DOI" }
        static var choosePDF: String { zh ? "选择 PDF…" : "Choose PDF…" }
        static var choosePDFMessage: String { zh ? "选择这篇论文的 PDF" : "Choose the PDF of this paper" }
        static var dropHere: String { zh ? "把下载好的 PDF 拖到这里" : "Drop the downloaded PDF here" }
        static var dropRelease: String { zh ? "松手作为这篇的 PDF" : "Release to use as this paper's PDF" }
        static var cardDropRelease: String { zh ? "松手匹配到这封邮件的论文" : "Release to match this email's papers" }
        static var linkHelp: String {
            zh ? "打开邮件里的原始链接（保留学校的点击安全检查）" : "Opens the link as it appeared in the email (keeps your school's click-time scan)"
        }

        // MARK: Detail inspector

        static var detailEmptyTitle: String { zh ? "未选择邮件" : "No Email Selected" }
        static var detailEmptyHint: String { zh ? "选择一封邮件查看全文和其中的论文" : "Select an email to see its text and papers" }
        static var from: String { zh ? "发件人" : "From" }
        static var account: String { zh ? "账户" : "Account" }
        static var received: String { zh ? "收到" : "Received" }
        static var senderRule: String { zh ? "发件人规则" : "Sender rule" }
        static var noRule: String { zh ? "无（手动导入）" : "None (imported)" }
        static func papersSection(_ n: Int) -> String { zh ? "论文（\(n)）" : "Papers (\(n))" }
        static var bodyTitle: String { zh ? "邮件正文" : "Email Text" }
        static var bodyPurged: String { zh ? "正文已按保留期限清除，只保留主题、发件人和论文。" : "The text was removed by the retention setting; subject, sender and papers are kept." }
        static var bodyEmpty: String { zh ? "没有正文" : "No text" }
        static var bodyLoading: String { zh ? "正在载入正文…" : "Loading the text…" }
        static var bodyMarkers: String { zh ? "[c1] 这样的标记代表邮件中的链接，与上面的论文对应。" : "Markers like [c1] stand for links in the email and match the papers above." }
        static func evidence(_ s: String) -> String { zh ? "邮件原文：“\(s)”" : "From the email: “\(s)”" }
        static var triageSection: String { zh ? "分拣" : "Triage" }
        static var triageByAI: String { zh ? "AI" : "AI" }
        static var triageByRules: String { zh ? "本地规则" : "Local rules" }

        // MARK: Sent to AI

        static var sentTitle: String { zh ? "发送给 AI 的内容" : "Sent to AI" }
        static var notSentSender: String { zh ? "未发送给 AI：此发件人设为「从不发送给 AI」" : "Not sent to AI: this sender is set to never be sent" }
        static var notSentYet: String { zh ? "尚未发送给 AI" : "Not sent to AI yet" }
        static var notSentPurged: String { zh ? "未发送给 AI：正文已清除" : "Not sent to AI: the text was removed" }
        static func sentSummary(provider: String, model: String?, size: String?, when: String?) -> String {
            var parts = [zh ? "已发送给 \(provider)" : "Sent to \(provider)"]
            if let model, !model.isEmpty { parts[0] += zh ? "（\(model)）" : " (\(model))" }
            if let size { parts.append(size) }
            if let when { parts.append(when) }
            return parts.joined(separator: " · ")
        }
        static var showContent: String { zh ? "显示内容" : "Show Content" }
        static var hideContent: String { zh ? "隐藏内容" : "Hide Content" }
        static var previewWouldSend: String { zh ? "点「让 AI 分析」时会发送下面的内容：" : "“Analyze with AI” would send exactly this:" }
        static var previewRebuilt: String {
            zh ? "按保存的文字重新生成；如果之后资料库的分类或标签变了，可能与当时略有不同。"
               : "Rebuilt from the stored text; it may differ slightly if your library's categories or tags changed since."
        }
        static var previewFixed: String {
            zh ? "另外只有 PaperDeck 固定的说明和回答格式；不带任何工具，不能上网。" : "Plus only PaperDeck's fixed instructions and answer format; no tools, no web access."
        }
        static func previewMeta(provider: String, model: String, size: String) -> String {
            "\(provider) · \(model) · \(size)"
        }
        static var previewLoading: String { zh ? "正在生成预览…" : "Building the preview…" }
        static var previewUnavailable: String { zh ? "无法生成预览" : "The preview isn't available" }
        static var copy: String { zh ? "拷贝" : "Copy" }

        // MARK: Merge popover

        static var mergeTitleOne: String { zh ? "合并到论文库" : "Add to the Library" }
        static func mergeTitleMany(_ n: Int) -> String { zh ? "合并 \(n) 篇到论文库" : "Add \(n) Papers to the Library" }
        static var priority: String { zh ? "优先级" : "Priority" }
        static func priorityName(_ p: Priority) -> String {
            switch p {
            case .low: return zh ? "低" : "Low"
            case .normal: return zh ? "普通" : "Normal"
            case .high: return zh ? "高" : "High"
            }
        }
        static func pinDue(_ date: String) -> String { zh ? "把邮件中的日期固定为 DDL（\(date)）" : "Pin the email's date as the deadline (\(date))" }
        static var duePast: String { zh ? "邮件中的日期已过" : "The date in the email has passed" }
        static var dueUncertain: String { zh ? "日期不够确定，默认不固定" : "The date is uncertain, so it isn't pinned by default" }
        static var category: String { zh ? "分类" : "Category" }
        static var categoryAuto: String { zh ? "自动（AI 归类）" : "Automatic" }
        static func readWithAI(_ ai: String) -> String { zh ? "用 \(ai) 解读" : "Read with \(ai)" }
        static var heldBatchNote: String { zh ? "一次超过 3 篇时，AI 解读会等你确认后再开始。" : "With more than 3 papers, AI reading waits for your go-ahead." }
        static var linkNote: String { zh ? "已在库中的论文只会关联这封邮件，不会重复添加。" : "Papers already in the library are linked to this email, never duplicated." }
        static var confirmOne: String { zh ? "合并" : "Add" }
        static func confirmMany(_ n: Int) -> String { zh ? "合并（\(n)）" : "Add (\(n))" }
        static var fromRule: String { zh ? "默认值来自发件人规则" : "Defaults come from the sender rule" }

        // MARK: Toasts

        static func imported(_ n: Int) -> String { zh ? "已导入 \(n) 封邮件" : (n == 1 ? "Imported 1 email" : "Imported \(n) emails") }
        static func importFailed(_ n: Int) -> String {
            zh ? "\(n) 个文件无法读取为邮件" : (n == 1 ? "1 file couldn't be read as an email" : "\(n) files couldn't be read as emails")
        }
        static var view: String { zh ? "查看" : "View" }
        static func attached(_ title: String) -> String { zh ? "已作为这篇的 PDF 合并：\(title)" : "Added as this paper's PDF: \(title)" }
        static var attachFailed: String {
            zh ? "这个文件不是可用的 PDF，这一行仍在等待 PDF" : "That file isn't a usable PDF — the row is still waiting for one"
        }
        static var oneRowOnePDF: String { zh ? "一行只能放一个 PDF，其余的已按普通方式添加" : "A row takes one PDF — the others were added to the library normally" }
        static var noRowMatched: String {
            zh ? "没有匹配到这封邮件里的论文，已按普通方式添加到论文库" : "No paper of this email matched — added to the library normally"
        }
        static func merged(_ n: Int) -> String { zh ? "已合并 \(n) 篇论文" : (n == 1 ? "Added 1 paper" : "Added \(n) papers") }
        static var mergedNone: String {
            zh ? "没有可以合并的论文：需要 PDF 的请把 PDF 拖到对应的行" : "Nothing to add yet — drop PDFs on the rows that need one"
        }
        static var downloadFailed: String { zh ? "下载没有成功，请在浏览器中下载后拖到这一行" : "The download didn't work — download it in your browser and drop it on the row" }
        static var dismissedToast: String { zh ? "已忽略这封邮件" : "Email dismissed" }
        static func snoozedToast(_ when: String) -> String { zh ? "稍后提醒：\(when)" : "Snoozed until \(when)" }
        static var syncStarted: String { zh ? "正在同步邮件…" : "Syncing mail…" }
        static var linkCopied: String { zh ? "已拷贝邮件链接" : "Link copied" }
        /// 「撤销」 on 「已匹配邮件请求」 worked / found nothing left to undo.
        static var linkUndone: String {
            zh ? "已撤销自动匹配，这封邮件的论文重新等待 PDF" : "Match undone — the email's papers are waiting for a PDF again"
        }
        static var linkUndoFailed: String {
            zh ? "无法撤销：这封邮件之后有过改动，或撤销已过期" : "Couldn't undo: the email changed since, or the undo expired"
        }

        // MARK: Notifications (Settings ▸ Mail ▸ 有新的阅读请求时通知我)

        static var notifyTitle: String { zh ? "新的论文阅读请求" : "New reading request" }
        /// `Prof. Jane Smith — Paper for Friday's meeting` (display name and subject only; never an address or body text).
        static func notifyBody(name: String?, subject: String) -> String {
            guard let name, !name.isEmpty else { return subject }
            return name + " — " + subject
        }

        // MARK: AI status lines (menu bar, queue popover)

        /// Appended to the paper reading line: 「· 1 封邮件待分析」.
        static func triageWaitingShort(_ n: Int) -> String {
            zh ? "\(n) 封邮件待分析" : (n == 1 ? "1 email waiting" : "\(n) emails waiting")
        }

        // MARK: Drop overlay

        static func dropEmails(_ n: Int) -> String { zh ? "松手导入 \(n) 封邮件" : (n == 1 ? "Release to import 1 email" : "Release to import \(n) emails") }
        static func dropAlsoPDFs(_ n: Int) -> String {
            zh ? "另有 \(n) 个 PDF 会添加到论文库" : (n == 1 ? "1 PDF goes to the library" : "\(n) PDFs go to the library")
        }
        static var dropEmailsHint: String {
            zh ? "每封邮件整理成一张卡片；是否发送给 AI 按发件人规则决定。" : "Each email becomes a card; whether it goes to AI follows your sender rules."
        }

        // MARK: Menu bar / floating panel

        /// 「邮件待处理 3 封 →」 (menu bar).
        static func menuLine(total: Int, requests: Int) -> String? {
            MailReminderInfo.line(total: total, requests: requests, L.lang).map { $0 + " →" }
        }
        /// 「📨 3 封邮件待处理」 (floating panel peek header).
        static func peekLine(total: Int, requests: Int) -> String? {
            MailReminderInfo.line(total: total, requests: requests, L.lang).map { "📨 " + $0 }
        }
        static var peekOpenMail: String { zh ? "打开邮件" : "Open Mail" }

        // MARK: Formatting

        /// `14:05` today, `9/29 14:05` this year, `2025/9/29` before.
        static func received(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            if calendar.isDate(date, inSameDayAs: now) {
                f.dateFormat = "HH:mm"
            } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                f.dateFormat = "M/d HH:mm"
            } else {
                f.dateFormat = "yyyy/M/d"
            }
            return f.string(from: date)
        }

        /// `明天 9:00`, `周一 9:00`, `10/14 9:00`.
        static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "H:mm"
            let time = f.string(from: date)
            if calendar.isDate(date, inSameDayAs: now) { return SharedStrings.today(L.lang) + " " + time }
            if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) {
                return SharedStrings.tomorrow(L.lang) + " " + time
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
            if days > 0 && days < 7 { return SharedStrings.weekday(calendar.component(.weekday, from: date), L.lang) + " " + time }
            return SharedStrings.monthDay(LocalDate(date, calendar: calendar)) + " " + time
        }

        static func ago(_ date: Date, now: Date = Date()) -> String {
            let s = max(0, now.timeIntervalSince(date))
            if s < 60 { return justNow }
            if s < 3600 { return minutesAgo(Int(s / 60)) }
            if s < 86_400 { return hoursAgo(Int(s / 3600)) }
            return received(date, now: now)
        }

        /// A size in the UI language (`L.bytes`).
        static func bytes(_ n: Int) -> String { L.bytes(Int64(n)) }
    }
}
