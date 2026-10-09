import Foundation
import PaperDeckCore

/// Strings of Explain (the system-wide explanation panel, its overlay, menus, Settings section and
/// history). Owned by the Explain UI lane (Slice A); every name sits in `L.Explain`. Each accessor
/// answers in both languages (`ExplainUI` lint: distinct en / zh, the zh one Chinese, no institution).
extension L {
    enum Explain {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Menus (Slice 0)

        /// The main menu's Explain menu.
        static var menu: String { zh ? "讲解" : "Explain" }
        /// Explain ▸ Explain…  (⌃⌥E).
        static var explainEllipsis: String { zh ? "讲解…" : "Explain…" }
        static var explainCopiedText: String { zh ? "讲解已复制的文字" : "Explain Copied Text" }
        static var history: String { zh ? "讲解记录" : "Explanation History" }

        // MARK: Panel header

        static var notFromLibrary: String { zh ? "不在你的论文库中" : "Not from your library" }
        static func page(_ n: Int) -> String { zh ? "第 \(n) 页" : "p. \(n)" }
        static func source(_ s: ExplainSource) -> String {
            switch s {
            case .services: return zh ? "来自服务菜单" : "From Services"
            case .clipboard: return zh ? "已复制的文字" : "Copied text"
            case .screenshot: return zh ? "截图" : "Screenshot"
            case .region: return zh ? "屏幕框选" : "Screen region"
            case .lens: return zh ? "放大镜" : "Lens"
            case .reader: return zh ? "PaperDeck 阅读器" : "PaperDeck Reader"
            case .drop: return zh ? "拖入的图片" : "Dropped image"
            }
        }
        static var languageHelp: String {
            zh ? "回答语言（⌘L）：中 = 中文讲解并保留英文术语" : "Answer language (⌘L): 中 = Chinese with the English terms kept"
        }
        static var pin: String { zh ? "钉住" : "Pin" }
        static var unpin: String { zh ? "取消钉住" : "Unpin" }
        static var pinHelp: String {
            zh ? "钉住后，下一次讲解不会替换这个浮窗，讲解记录也会一直保留（⌘P）" : "A pinned panel stays when you explain something else, and its explanations are kept in history (⌘P)"
        }
        static var pinLimit: String { zh ? "最多钉住 3 个浮窗" : "At most 3 panels can be pinned" }
        static var close: String { zh ? "关闭（Esc）" : "Close (Esc)" }
        static var sendImage: String { zh ? "以图片发送" : "Send as image" }
        static var sendImageHelp: String {
            zh ? "把这张截图一起发给 AI（适合公式和图表）；关闭则只发识别出的文字（⌘I）" : "Send the image too (best for formulas and figures); off sends only the recognized text (⌘I)"
        }
        static var expandQuote: String { zh ? "展开" : "Show more" }
        static var collapseQuote: String { zh ? "收起" : "Show less" }

        // MARK: Chips, follow-up, footer

        static func chip(_ c: ExplainChip) -> String {
            switch c {
            case .simpler: return zh ? "更浅显" : "Simpler"
            case .technical: return zh ? "更专业" : "More technical"
            case .terms: return zh ? "解释术语" : "Define terms"
            case .figure: return zh ? "讲解这张图" : "Explain the figure"
            case .translate: return zh ? "翻译" : "Translate"
            }
        }
        /// The chip's short title (a narrow panel).
        static func chipShort(_ c: ExplainChip) -> String {
            switch c {
            case .simpler: return zh ? "浅显" : "Simpler"
            case .technical: return zh ? "专业" : "Technical"
            case .terms: return zh ? "术语" : "Terms"
            case .figure: return zh ? "图" : "Figure"
            case .translate: return zh ? "译" : "Translate"
            }
        }
        static func chipHelp(_ digit: Character) -> String {
            zh ? "⌘\(digit)；按住 ⌥ 点击则用「深入」模型" : "⌘\(digit); ⌥-click uses the Thorough model"
        }
        static var optionThorough: String { zh ? "按住 ⌥ 点击：用「深入」模型" : "⌥-click: the Thorough model" }
        static var followUpPlaceholder: String { zh ? "继续追问…（⏎ 发送）" : "Ask a follow-up… (⏎ to send)" }
        static var questionPlaceholder: String { zh ? "就所选内容提一个问题…（⏎ 发送）" : "Ask about the selection… (⏎ to send)" }
        static var send: String { zh ? "发送" : "Send" }
        static var copy: String { zh ? "复制" : "Copy" }
        static var copyHelp: String { zh ? "复制回答（⌘⇧C）" : "Copy the answer (⌘⇧C)" }
        static var copied: String { zh ? "已复制" : "Copied" }
        static var saveToNotes: String { zh ? "存进笔记" : "Save to Notes" }
        static var saveHelp: String { zh ? "把这段讲解追加到这篇论文的笔记里，带页码（⌘S）" : "Append this explanation to the paper's notes, with the page (⌘S)" }
        static var saveNeedsPaper: String { zh ? "只有库中的论文才能存进笔记" : "Only a paper from your library can take notes" }
        static var saved: String { zh ? "已存进笔记" : "Saved to notes" }
        static var historyHelp: String { zh ? "讲解记录（⌘Y）" : "Explanation history (⌘Y)" }
        static var stop: String { zh ? "停止" : "Stop" }
        static var stopHelp: String { zh ? "停止生成（⌘.）" : "Stop generating (⌘.)" }
        static var regenerate: String { zh ? "重新讲解" : "Regenerate" }
        static var regenerateHelp: String { zh ? "重新讲解（⌘R；⌥⌘R 用「深入」模型）" : "Regenerate (⌘R; ⌥⌘R with the Thorough model)" }
        static func reexplain(in lang: UILang) -> String {
            lang == .zh ? (zh ? "用中文重新讲解" : "Explain again in Chinese") : (zh ? "用英文重新讲解" : "Explain again in English")
        }
        static func today(_ n: Int) -> String { zh ? "今天 \(n) 次" : "today \(n)" }
        static func todayHelp(_ cap: Int) -> String {
            zh ? "今天用了多少次讲解与问答；超过 \(cap) 次会先问你" : "Explanations and questions today; past \(cap) PaperDeck asks first"
        }
        static func seconds(_ s: Int) -> String { zh ? "\(s) 秒" : "\(s) s" }
        static var thorough: String { zh ? "深入" : "Thorough" }
        static var onDevice: String { zh ? "本机模型" : "on-device model" }

        // MARK: Phases

        static var locating: String { zh ? "正在读取所选内容…" : "Reading the selection…" }
        static func starting(_ ai: String) -> String { zh ? "正在启动 \(ai)…" : "Starting \(ai)…" }
        static func waiting(_ ai: String) -> String { zh ? "\(ai) 正在阅读…" : "\(ai) is reading…" }
        static func stillWaiting(_ ai: String) -> String { zh ? "仍在等待 \(ai)…" : "Still waiting for \(ai)…" }
        static var codexWhole: String { zh ? "ChatGPT 的回答会整段出现" : "ChatGPT's answers arrive all at once" }
        static var stopped: String { zh ? "已停止" : "Stopped" }
        static var cutOff: String { zh ? "回答超出长度上限，已截断" : "The answer passed the length limit and was cut off" }
        static var idleHint: String {
            zh ? "在下面输入问题，按 ⏎ 发送；按 ⌘1–⌘5 选择讲解方式" : "Type a question below and press ⏎, or pick a way to explain it (⌘1–⌘5)"
        }
        static var dropHere: String { zh ? "拖入图片即可讲解" : "Drop an image to explain it" }

        // MARK: Refusals and errors

        static var offTitle: String { zh ? "讲解与问答已关闭" : "Explain & Ask is off" }
        static var offBody: String {
            zh ? "讲解使用你自己的 Claude 或 ChatGPT 订阅。打开开关本身不会发送任何内容；每次讲解都要你亲手点击或按键。"
               : "Explanations use your own Claude or ChatGPT subscription. Turning this on sends nothing; every explanation needs your click or key press."
        }
        static var nowOn: String { zh ? "讲解与问答已打开。现在讲解吗？" : "Explain & Ask is on. Explain this now?" }
        static var explainNow: String { zh ? "讲解" : "Explain" }
        static func useProvider(_ name: String) -> String { zh ? "使用 \(name)" : "Use \(name)" }
        static var openSettings: String { zh ? "设置…" : "Settings…" }
        static func confirmTitle(_ ai: String) -> String { zh ? "要把这段内容发给 \(ai) 吗？" : "Send this to \(ai)?" }
        static var sendAnyway: String { zh ? "仍然发送" : "Send Anyway" }
        static func askBeforeSendTitle(_ ai: String) -> String { zh ? "把所选内容发给 \(ai) 讲解？" : "Send the selection to \(ai) to explain it?" }
        static var askBeforeSendHint: String {
            zh ? "你在设置中打开了「每次发送前询问」。" : "You turned on “Ask before every send” in Settings."
        }
        static func softCap(_ n: Int) -> String {
            zh ? "今天已经用了 \(n) 次讲解与问答，还要继续吗？" : "You've used \(n) explanations and questions today. Continue?"
        }
        static var continueAnyway: String { zh ? "继续" : "Continue" }
        static func hardCap(_ n: Int) -> String {
            zh ? "已达到今天的上限（\(n) 次），明天会自动恢复。" : "Today's limit of \(n) is reached; it resets tomorrow."
        }
        static var burst: String { zh ? "一分钟内次数太多，请稍等再试。" : "Too many in a minute. Wait a moment, then try again." }
        static var budget: String { zh ? "本次运行的 AI 调用次数已用完。" : "This session's AI run budget is used up." }
        static var expired: String { zh ? "这次点击已失效，请再点一次。" : "That click is too old. Press again." }
        static var emptyCapture: String { zh ? "没有可讲解的内容：没有找到文字。" : "Nothing to explain: no text was found." }
        static var privacyUnchecked: String {
            zh ? "读不到这篇论文的隐私设置，因此没有发送任何内容。" : "This paper's privacy settings couldn't be read, so nothing was sent."
        }
        static var timeout: String { zh ? "没有按时得到回答。" : "No answer in time." }
        static func overloaded(_ ai: String) -> String { zh ? "\(ai) 现在太忙了。" : "\(ai) is busy right now." }
        static var invalidOutput: String { zh ? "读不懂这次的回答。" : "The answer couldn't be read." }
        static func notInstalled(_ cli: String) -> String { zh ? "没有安装 \(cli)。" : "\(cli) isn't installed." }
        static func unsupported(_ ai: String) -> String { zh ? "这个版本的 \(ai) 不支持讲解，请先更新。" : "This version of \(ai) can't explain. Update it first." }
        static var failed: String { zh ? "出了点问题。" : "Something went wrong." }
        static func limited(_ ai: String, _ time: String?) -> String {
            if let time { return zh ? "\(ai) 用量已达上限，\(time) 恢复" : "\(ai) usage limit; available again at \(time)" }
            return zh ? "\(ai) 用量已达上限" : "\(ai) usage limit reached"
        }
        static var retry: String { zh ? "重试" : "Try Again" }
        static var serviceNoText: String { zh ? "没有选中文字" : "No text selected" }

        // MARK: Overlay

        static var modeFrame: String { zh ? "框选" : "Box" }
        static var modeLens: String { zh ? "放大镜" : "Lens" }
        static var hudHint: String {
            zh ? "拖一个框，或点一下某段 · ⌥：当作图 · 空格：放大镜 · Esc：取消"
               : "Drag a box or click a paragraph · ⌥: as a figure · Space: lens · Esc: cancel"
        }
        static var hudLensHint: String {
            zh ? "点一下讲解这一段 · ⇧ 点击：术语 · 滚动：缩放 · 空格：框选 · Esc：取消"
               : "Click a paragraph · ⇧-click: a term · Scroll: zoom · Space: box · Esc: cancel"
        }
        /// The badge beside the cursor while ⌥ is held (the capture goes as an image).
        static var asFigure: String { zh ? "当作图" : "As a figure" }
        /// The badge beside the cursor while ⇧ is held (a click explains the word under it).
        static var asTerm: String { zh ? "术语" : "A term" }
        static var clipboardOffer: String { zh ? "讲解已复制的文字" : "Explain copied text" }
        static var clipboardImageOffer: String { zh ? "讲解已复制的图片" : "Explain copied image" }
        static var clipboardNone: String { zh ? "先选中文字按 ⌘C，再按快捷键" : "Select text and press ⌘C first, then the shortcut" }
        static var captureOffTitle: String { zh ? "屏幕截取未开启" : "Screen capture is off" }
        static func captureOffBody(_ hotkey: String) -> String {
            zh ? "可以先按 ⌘C 再按 \(hotkey)，或用 ⌃⇧⌘4 截图到剪贴板再按 \(hotkey)；也可以开启屏幕截取，直接框选。"
               : "Press ⌘C, then \(hotkey); or ⌃⇧⌘4 to copy a screenshot, then \(hotkey). Or turn on screen capture to draw a box."
        }
        static var enableCapture: String { zh ? "开启屏幕截取…" : "Enable Screen Capture…" }
        static var openSystemSettings: String { zh ? "打开系统设置" : "Open System Settings" }
        static var captureFailedTitle: String { zh ? "这次没能截取屏幕" : "Couldn't capture the screen" }
        static func captureFailedBody(_ hotkey: String) -> String {
            zh ? "按 Esc 后再按一次 \(hotkey) 重试；也可以先按 ⌘C 或用 ⌃⇧⌘4 截图到剪贴板，再按 \(hotkey)。"
               : "Press Esc and \(hotkey) to try again, or press ⌘C (or ⌃⇧⌘4 to copy a screenshot), then \(hotkey)."
        }

        // MARK: Screen Recording explainer

        static var explainerTitle: String { zh ? "为「框选讲解」开启屏幕录制" : "Screen Recording for Explain" }
        static var explainerCaptured: String {
            // The overlay freezes every display when it opens (phase-3 fix F11 / PR-5), not when the box is drawn.
            zh ? "遮罩打开时给每块屏幕定格一张画面，只留在内存里；只用你框选或点到的那部分。"
               : "One still of each display while the overlay is open, in memory only; only the part you mark is used."
        }
        static var explainerSent: String {
            zh ? "松开鼠标后，这个框（以及匹配到的论文附近原文）才会发给你的 AI 订阅。" : "When you release the box, that box (and the matched paper's nearby text) goes to your AI subscription."
        }
        static var explainerStored: String {
            zh ? "除非你钉住或存进笔记，否则什么都不保留。" : "Nothing is kept unless you pin the explanation or save it to notes."
        }
        static var explainerRelaunch: String {
            zh ? "macOS 会要求你退出并重新打开 PaperDeck，之后也可能不时再次确认。复制和服务菜单这两种方式不需要这个权限。"
               : "macOS asks you to quit and reopen PaperDeck, and may ask again from time to time. Copying and Services never need this permission."
        }
        static var explainerContinue: String { zh ? "继续" : "Continue" }
        static var notNow: String { zh ? "暂不" : "Not Now" }

        // MARK: Settings ▸ Explain & Ask ▸ Explain

        static var settingsSection: String { zh ? "讲解" : "Explain" }
        static var settingsShortcut: String { zh ? "快捷键" : "Shortcut" }
        static var recordShortcut: String { zh ? "录制…" : "Record…" }
        static var recordingShortcut: String { zh ? "按下新的快捷键（Esc 取消）" : "Press the new shortcut (Esc cancels)" }
        static var resetShortcut: String { zh ? "恢复默认" : "Reset" }
        static var shortcutReady: String { zh ? "已生效" : "Ready" }
        static var shortcutInUse: String { zh ? "已被其他 App 占用，请换一个" : "Used by another app. Pick another." }
        static var shortcutFailed: String { zh ? "注册失败，请换一个" : "Couldn't register it. Pick another." }
        static var shortcutNeedsSwitch: String {
            zh ? "打开上面的「讲解与问答」后快捷键才生效；菜单栏里的「讲解…」随时可用。"
               : "The shortcut works once Explain & Ask is on above; the menu bar's Explain… works anyway."
        }
        static func shortcutProblem(_ p: HotKeySpec.Problem) -> String {
            switch p {
            case .needsControlOrCommand:
                return zh ? "请配合 ⌃ 或 ⌘ 使用（macOS 不接受只有 ⌥ 的组合）" : "Use ⌃ or ⌘ with the key (macOS refuses ⌥-only shortcuts)"
            case .reservedKey: return zh ? "这个键不能做快捷键" : "That key can't be a shortcut"
            case .systemShortcut: return zh ? "系统已经在用这个快捷键" : "macOS already uses that shortcut"
            }
        }
        static var settingsOpens: String { zh ? "快捷键打开" : "The shortcut opens" }
        static var opensFrame: String { zh ? "框选" : "A box" }
        static var opensLens: String { zh ? "放大镜" : "The lens" }
        static var settingsLanguage: String { zh ? "讲解语言" : "Explanation language" }
        static var langZhTerms: String { zh ? "中文（保留英文术语）" : "Chinese, with English terms" }
        static var langEnglish: String { zh ? "英文" : "English" }
        static var langFollowUI: String { zh ? "跟随界面语言" : "Follow the interface" }
        static var settingsDepth: String { zh ? "模型" : "Model" }
        static func depthQuick(_ models: String) -> String { zh ? "快速（\(models)）" : "Quick (\(models))" }
        static func depthThorough(_ models: String) -> String { zh ? "深入（\(models)）" : "Thorough (\(models))" }
        static var settingsDailyCap: String { zh ? "每天超过多少次先问我" : "Ask me first after" }
        static func dailyCapValue(_ n: Int) -> String { zh ? "\(n) 次（讲解与问答合计）" : "\(n) a day (Explain & Ask together)" }
        static func settingsKeepWarm(_ ai: String) -> String { zh ? "讲解模式打开时让 \(ai) 预先就绪" : "Keep \(ai) ready while Explain is open" }
        static var keepWarmFooter: String {
            zh ? "回答更快；空闲 3 分钟后自动关闭，不会额外消耗额度。" : "Faster answers. The idle process closes after 3 minutes and uses no quota by itself."
        }
        static var settingsAskBeforeSend: String { zh ? "每次发送前都先问我" : "Ask before every send" }
        static var settingsHistory: String { zh ? "讲解记录保留" : "Keep explanations for" }
        static func historyDays(_ n: Int) -> String { zh ? "\(n) 天" : "\(n) days" }
        static var settingsScreen: String { zh ? "屏幕录制" : "Screen Recording" }
        static var screenOn: String { zh ? "已开启" : "On" }
        static var screenOff: String { zh ? "未开启：框选和放大镜需要它；复制与服务菜单不需要" : "Off: box and lens need it; copying and Services don't" }
        static var settingsServices: String {
            zh ? "在任意 App 中右键 ›「服务」›「Explain with PaperDeck」，不需要任何权限；也可以在键盘快捷键设置里给它指定一个快捷键。"
               : "Right-click › Services › “Explain with PaperDeck” works in most apps without any permission; you can give it a key in Keyboard Shortcuts."
        }
        static var openKeyboardShortcuts: String { zh ? "键盘快捷键…" : "Keyboard Shortcuts…" }
        static var settingsFooter: String {
            zh ? "每次讲解都要你亲手触发（快捷键后拖框、⏎、点击或服务菜单），按今天的次数计入订阅额度。可能未发表或保密的论文、邮件或聊天窗口里的内容，发送前一定先问你。"
               : "Every explanation needs your own gesture (a box after the shortcut, ⏎, a click or Services) and counts once on your subscription. "
                 + "Possibly unpublished or confidential papers, and content from mail or chat windows, always ask before sending."
        }

        // MARK: History

        static var historyTitle: String { zh ? "讲解记录" : "Explanation History" }
        static var historyEmpty: String { zh ? "还没有讲解记录" : "No explanations yet" }
        static var historyEmptyHint: String {
            zh ? "钉住或存进笔记的讲解会一直保留，其余的按设置的天数保留。" : "Pinned and saved explanations are kept; the others for the days set in Settings."
        }
        static var sectionTitle: String { zh ? "讲解" : "Explanations" }
        static func showAll(_ n: Int) -> String { zh ? "显示全部（\(n)）" : "Show All (\(n))" }
        static func followUps(_ n: Int) -> String { zh ? "\(n) 条追问" : (n == 1 ? "1 follow-up" : "\(n) follow-ups") }
        static func openAt(_ page: String) -> String { zh ? "在阅读器中打开 \(page)" : "Open at \(page)" }
        static var openPaper: String { zh ? "打开论文" : "Open Paper" }
        static func action(_ code: String) -> String {
            switch code {
            case "simpler": return zh ? "更浅显" : "Simpler"
            case "technical": return zh ? "更专业" : "More technical"
            case "terms": return zh ? "术语" : "Terms"
            case "figure": return zh ? "图" : "Figure"
            case "translate": return zh ? "翻译" : "Translation"
            case "ask": return zh ? "追问" : "Question"
            default: return zh ? "讲解" : "Explanation"
            }
        }
        static var pinned: String { zh ? "已钉住" : "Pinned" }
        static func question(_ q: String) -> String { zh ? "问：\(q)" : "Q: \(q)" }

        /// Every worded string with sample arguments (the `ExplainUI` self-check: en ≠ zh, none empty).
        static var all: [String] {
            var out = [menu, explainEllipsis, explainCopiedText, history, notFromLibrary, page(3), languageHelp, pin, unpin,
                       pinHelp, pinLimit, close, sendImage, sendImageHelp, expandQuote, collapseQuote, chipHelp("1"),
                       optionThorough, followUpPlaceholder, questionPlaceholder, send, copy, copyHelp, copied, saveToNotes, saveHelp,
                       saveNeedsPaper, saved, historyHelp, stop, stopHelp, regenerate, regenerateHelp, reexplain(in: .zh),
                       reexplain(in: .en), today(3), todayHelp(50), seconds(4), thorough, onDevice, locating,
                       starting("Claude"), waiting("Claude"), stillWaiting("Claude"), codexWhole, stopped, cutOff, idleHint,
                       dropHere, offTitle, offBody, nowOn, explainNow, useProvider("Claude"), openSettings, confirmTitle("Claude"), sendAnyway,
                       askBeforeSendTitle("Claude"), askBeforeSendHint, softCap(50), continueAnyway, hardCap(150), burst,
                       budget, expired, emptyCapture, privacyUnchecked, timeout, overloaded("Claude"), invalidOutput,
                       notInstalled("claude"), unsupported("Claude"), failed, limited("Claude", "15:00"),
                       limited("Claude", nil), retry, serviceNoText, modeFrame, modeLens, hudHint, hudLensHint,
                       clipboardOffer, clipboardImageOffer, clipboardNone, captureOffTitle, captureOffBody("⌃⌥E"),
                       enableCapture, openSystemSettings, captureFailedTitle, captureFailedBody("⌃⌥E"), asFigure, asTerm,
                       shortcutNeedsSwitch, explainerTitle, explainerCaptured, explainerSent,
                       explainerStored, explainerRelaunch, explainerContinue, notNow, settingsSection, settingsShortcut,
                       recordShortcut, recordingShortcut, resetShortcut, shortcutReady, shortcutInUse, shortcutFailed,
                       settingsOpens, opensFrame, opensLens, settingsLanguage, langZhTerms, langEnglish, langFollowUI,
                       settingsDepth, depthQuick("haiku"), depthThorough("sonnet"), settingsDailyCap, dailyCapValue(50),
                       settingsKeepWarm("Claude"), keepWarmFooter, settingsAskBeforeSend, settingsHistory, historyDays(90),
                       settingsScreen, screenOn, screenOff, settingsServices, openKeyboardShortcuts, settingsFooter,
                       historyTitle, historyEmpty, historyEmptyHint, sectionTitle, showAll(9), followUps(2), openAt("p. 3"),
                       openPaper, pinned, question("why?")]
            out += ExplainSource.allCases.map(source)
            out += ExplainChip.allCases.map(chip)
            out += ExplainChip.allCases.map(chipShort)
            out += [HotKeySpec.Problem.needsControlOrCommand, .reservedKey, .systemShortcut].map(shortcutProblem)
            out += ["explain", "simpler", "technical", "terms", "figure", "translate", "ask"].map(action)
            return out
        }
    }
}
