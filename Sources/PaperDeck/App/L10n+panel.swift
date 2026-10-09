import Foundation
import PaperDeckCore

/// Strings of the floating drop panel, toasts, the menu-bar item and URL routing.
/// Every name carries a `panel` / `menuBar` / `toast` / `router` prefix so it can't
/// collide with the other slices' `L` extensions.
extension L {
    private static var zh: Bool { L.lang == .zh }

    // MARK: Drop zone (armed / targeted)

    static var panelDropHere: String { zh ? "拖到这里 · 自动生成清单与 DDL" : "Drop here · checklist and deadline are made for you" }
    static var panelDropKinds: String { zh ? "PDF、文件夹、PDF 链接" : "PDFs, folders, PDF links" }

    /// `松手添加 3 个 PDF` / `松手添加 2 个 PDF、1 个文件夹`.
    static func panelReleaseToAdd(pdfs: Int, folders: Int, links: Int) -> String {
        var parts: [String] = []
        if zh {
            if pdfs > 0 { parts.append("\(pdfs) 个 PDF") }
            if folders > 0 { parts.append("\(folders) 个文件夹") }
            if links > 0 { parts.append("\(links) 个链接") }
            return "松手添加 " + (parts.isEmpty ? "PDF" : parts.joined(separator: "、"))
        }
        if pdfs > 0 { parts.append(pdfs == 1 ? "1 PDF" : "\(pdfs) PDFs") }
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if links > 0 { parts.append(links == 1 ? "1 link" : "\(links) links") }
        return "Release to add " + (parts.isEmpty ? "PDFs" : parts.joined(separator: ", "))
    }

    static func panelIgnoredOthers(_ n: Int) -> String {
        zh ? "另有 \(n) 个非 PDF 文件将被忽略" : (n == 1 ? "1 non-PDF file will be ignored" : "\(n) non-PDF files will be ignored")
    }
    static var panelNothingToImport: String { zh ? "没有找到可导入的 PDF" : "Nothing importable was found" }
    static var panelDropMore: String { zh ? "松手继续添加" : "Release to add more" }

    // MARK: Processing

    static func panelAdding(_ n: Int) -> String {
        zh ? "正在添加 \(n) 个文件" : (n == 1 ? "Adding 1 file" : "Adding \(n) files")
    }
    static var panelAddDone: String { zh ? "添加完成" : "Done" }
    static var panelNotices: String { zh ? "通知" : "Notifications" }
    static func panelMoreRows(_ n: Int) -> String { zh ? "还有 \(n) 个文件" : "+\(n) more files" }

    static var panelStageReceiving: String { zh ? "接收中…" : "Receiving…" }
    static var panelDroppedFiles: String { zh ? "拖入的文件" : "Dropped files" }
    static func panelStageDownloading(_ percent: Int?) -> String {
        guard let percent else { return zh ? "下载中…" : "Downloading…" }
        return zh ? "下载中 \(percent)%" : "Downloading \(percent)%"
    }
    static var panelStageCloud: String { zh ? "等待云端下载…" : "Waiting for cloud download…" }
    static var panelStageVerifying: String { zh ? "校验中…" : "Verifying…" }
    static var panelStageParsing: String { zh ? "解析文本…" : "Reading text…" }
    static var panelStageMetadata: String { zh ? "查询元数据…" : "Looking up metadata…" }
    static var panelStageFiling: String { zh ? "归档…" : "Filing…" }
    /// `✓ 已添加 · DDL ≈周五`; `chip` nil → unscheduled.
    static func panelStageAdded(chip: String?) -> String {
        switch (zh, chip) {
        case (true, let c?): return "✓ 已添加 · DDL \(c)"
        case (true, nil): return "✓ 已添加 · 未排期"
        case (false, let c?): return "✓ Added · due \(c)"
        case (false, nil): return "✓ Added · unscheduled"
        }
    }
    static var panelStageClaudeQueued: String { zh ? "\(L.ai) 排队中" : "Queued for \(L.ai)" }
    static var panelStageClaudeReading: String { zh ? "\(L.ai) 阅读中…" : "\(L.ai) is reading…" }
    static var panelStageClaudeDone: String { zh ? "\(L.ai) 已解读" : "Read by \(L.ai)" }
    static var panelStageDuplicate: String { zh ? "已在库中" : "Already in your library" }
    static var panelStageSameWork: String { zh ? "同一论文已在库中 · 请选择" : "Same paper already in library · choose below" }
    static func panelStageRejected(_ reason: String) -> String { zh ? "未导入：\(reason)" : "Not imported: \(reason)" }
    static func panelStageFailed(_ reason: String) -> String { zh ? "失败：\(reason)" : "Failed: \(reason)" }

    // MARK: Tab + context menu

    static var panelCollapse: String { zh ? "收起" : "Collapse" }
    static var panelOpenLibrary: String { zh ? "打开主窗口" : "Open Main Window" }
    static var panelShowToday: String { zh ? "显示今日清单" : "Show Today's List" }
    static var panelDock: String { zh ? "停靠" : "Dock" }
    static var panelDockLeft: String { zh ? "左侧" : "Left" }
    static var panelDockRight: String { zh ? "右侧" : "Right" }
    static var panelOpacity: String { zh ? "透明度" : "Opacity" }
    static var panelExpandOnDrag: String { zh ? "拖动文件时自动展开" : "Expand While Dragging Files" }
    static var panelHoverToday: String { zh ? "悬停时显示今日清单" : "Show Today on Hover" }
    static var panelHide: String { zh ? "隐藏悬浮窗" : "Hide Floating Panel" }
    static var panelShow: String { zh ? "显示悬浮窗" : "Show Floating Panel" }
    static var panelHiddenHint: String {
        zh ? "悬浮窗已隐藏 · 可从菜单栏图标重新显示，也可以把 PDF 拖到图标上"
           : "Floating panel hidden · show it again from the menu bar icon, or drop PDFs on the icon"
    }
    static var panelAttention: String { zh ? "有待处理的通知" : "Needs your attention" }
    static var panelBusy: String { zh ? "正在添加" : "Adding" }

    static func panelTabLabel(count: Int, overdue: Int) -> String {
        let base = zh ? "PaperDeck 悬浮窗 · 今天 \(count) 篇" : "PaperDeck panel · \(SharedStrings.papers(count, .en)) today"
        guard overdue > 0 else { return base }
        return base + (zh ? "（逾期 \(overdue) 篇）" : " (\(overdue) overdue)")
    }
    static var panelTabHint: String {
        zh ? "点按打开今日清单 · 悬停预览 · 拖动可移动 · 右键更多" : "Click to open Today · hover to preview · drag to move · right-click for more"
    }

    // MARK: Peek list

    static func peekHeader(count: Int, minutes: Int) -> String {
        zh ? "今天 · \(count) 篇 · 约 \(minutes) 分钟" : "Today · \(SharedStrings.papers(count, .en)) · ~\(minutes) min"
    }
    static var peekNothing: String { zh ? "今天没有要读的论文" : "Nothing to read today" }
    static var peekLoading: String { zh ? "正在载入…" : "Loading…" }
    static var peekOpenToday: String { zh ? "打开今日清单" : "Open Today" }
    static func peekMinutesToday(_ m: Int) -> String { zh ? "今天 \(m)′" : "\(m)′ today" }

    // MARK: Toasts

    static func toastMore(_ n: Int) -> String { zh ? "还有 \(n) 条通知" : "+\(n) more" }
    static var toastDismiss: String { zh ? "关闭" : "Dismiss" }
    static var toastKindSuccess: String { zh ? "完成" : "Done" }
    static var toastKindInfo: String { zh ? "提示" : "Info" }
    static var toastKindWarning: String { zh ? "注意" : "Warning" }
    static var toastKindError: String { zh ? "错误" : "Error" }

    // MARK: Menu bar

    static func menuBarHeader(count: Int, minutes: Int, backlog: Int) -> String {
        zh ? "今天 · 剩 \(count) 篇 · 约 \(minutes) 分钟 · 待读共 \(backlog) 篇"
           : "Today · \(count) left · ~\(minutes) min · \(backlog) to read"
    }
    static func menuBarHeaderEmpty(backlog: Int) -> String {
        if backlog == 0 { return zh ? "今天没有要读的 · 待读已清空" : "Nothing to read today · backlog clear" }
        return zh ? "今天没有要读的 · 待读共 \(backlog) 篇" : "Nothing due today · \(backlog) to read"
    }
    static var menuBarLoading: String { zh ? "正在载入资料库…" : "Loading library…" }
    static var menuBarOpenDetails: String { zh ? "打开详情" : "Show Details" }
    static var menuBarOpenPDF: String { zh ? "打开 PDF" : "Open PDF" }
    static var menuBarMarkDone: String { zh ? "标记已读" : "Mark as Read" }
    static var menuBarPostpone: String { zh ? "推迟一天" : "Postpone One Day" }
    static func menuBarPostponed(title: String, chip: String) -> String {
        zh ? "已推迟：\(title) · DDL \(chip)" : "Postponed: \(title) · due \(chip)"
    }
    static func menuBarSeeAll(_ n: Int) -> String { zh ? "查看全部 \(n) 篇…" : "See All \(n) Papers…" }
    static func menuBarSeeAllToday(_ n: Int) -> String { zh ? "查看今天全部 \(n) 篇…" : "See All \(n) for Today…" }
    static var menuBarAddPDF: String { zh ? "添加 PDF…" : "Add PDF…" }
    static var menuBarSkipToday: String { zh ? "今天跳过" : "Skip Today" }
    static func menuBarTooltip(count: Int, overdue: Int, reading: Bool, analyzingEmail: Bool = false) -> String {
        var s = zh ? "PaperDeck · 今天 \(count) 篇" : "PaperDeck · \(SharedStrings.papers(count, .en)) today"
        if overdue > 0 { s += zh ? " · 逾期 \(overdue) 篇" : " · \(overdue) overdue" }
        if reading { s += zh ? " · \(L.ai) 阅读中" : " · \(L.ai) is reading" }
        if analyzingEmail { s += zh ? " · 正在分析邮件" : " · analyzing an email" }
        return s
    }

    static func menuBarClaudeReading(_ p: AIProviderKind, running: Int, queued: Int) -> String {
        zh ? "\(p.shortName) 阅读中 \(running) · 排队 \(queued)" : "\(p.shortName) reading \(running) · queued \(queued)"
    }
    /// The AI slot is busy with mail triage (`AgentQueueStatus.triageText`): 「正在分析邮件… · 排队 2 篇」.
    static func menuBarTriage(_ triage: String, queuedPapers: Int) -> String {
        guard queuedPapers > 0 else { return triage }
        return zh ? "\(triage) · 排队 \(queuedPapers) 篇" : "\(triage) · \(queuedPapers) \(queuedPapers == 1 ? "paper" : "papers") queued"
    }
    static func menuBarClaudePaused(_ p: AIProviderKind, _ time: String) -> String {
        zh ? "\(p.shortName) 额度用尽，\(time) 自动继续" : "\(p.shortName) usage limit reached · resumes \(time)"
    }
    static func menuBarClaudeNeedsLogin(_ p: AIProviderKind) -> String {
        zh ? "需要登录 \(p.shortName) → 打开设置" : "\(p.shortName) sign-in required → Open Settings"
    }
    static var menuBarClaudeOff: String { zh ? "AI 解读已关闭 → 开启" : "AI reading is off → Turn On…" }
    static func menuBarClaudeNotInstalled(_ p: AIProviderKind) -> String {
        zh ? "未找到 \(p.cliName) → 打开设置" : "\(p.cliName) not found → Open Settings"
    }
    static func menuBarClaudeUnavailable(_ p: AIProviderKind) -> String {
        zh ? "\(p.shortName) 暂不可用 → 打开设置" : "\(p.shortName) unavailable → Open Settings"
    }
    static func menuBarClaudeHeld(_ n: Int) -> String { zh ? "\(n) 篇等待确认 → 查看" : "\(n) awaiting confirmation → Review" }
    static func menuBarClaudeIdle(_ p: AIProviderKind) -> String { zh ? "\(p.shortName) 空闲" : "\(p.shortName) idle" }
    static func menuBarClaudeChecking(_ p: AIProviderKind) -> String { zh ? "正在检测 \(p.shortName)…" : "Checking \(p.shortName)…" }
    static var menuBarClaudeMock: String { zh ? "（模拟）" : " (mock)" }

    // MARK: URL routing

    static var routerPaperNotFound: String {
        zh ? "找不到这篇论文（可能已被删除）" : "That paper can't be found (it may have been deleted)"
    }
}
