import Foundation
import PaperDeckCore

/// Strings of paper Q&A (the Ask tab, the Ask window, citations, the estimate line, PagePeek,
/// Settings ▸ Ask). Owned by Slice C. Every name sits in `L.QA`; `all` lists every worded string
/// for `--selftest qa` (en ≠ zh, none empty, no institution literal).
extension L {
    enum QA {
        private static var zh: Bool { L.lang == .zh }

        /// The detail inspector's tabs (Overview | Ask).
        static var tabOverview: String { zh ? "概览" : "Overview" }
        static var tabAsk: String { zh ? "提问" : "Ask" }

        // MARK: Header and toggles

        static var newThread: String { zh ? "新对话" : "New Thread" }
        static var threads: String { zh ? "对话" : "Threads" }
        static var untitledThread: String { zh ? "新对话" : "New thread" }
        static var deleteThread: String { zh ? "删除对话" : "Delete Thread" }
        static var threadHelp: String { zh ? "这篇论文的问答记录" : "Earlier questions about this paper" }
        static var depthQuick: String { zh ? "快速" : "Quick" }
        static var depthThorough: String { zh ? "深入" : "Thorough" }
        static var depthHelp: String {
            zh ? "快速：Haiku / Luna，省额度；深入：Sonnet / Terra，回答更细，用量更多。"
               : "Quick: Haiku / Luna, light on your quota. Thorough: Sonnet / Terra, more detail, more of your quota."
        }
        /// The answer-language toggle (symbols, the same in both languages).
        static var langAuto: String { zh ? "自动" : "Auto" }
        static let langEN = "EN"
        static let langZH = "中"
        static var langHelp: String {
            zh ? "回答语言：自动＝和问题相同" : "Answer language: Auto follows the question's language"
        }
        static var modeCards: String { zh ? "卡片" : "Cards" }
        static var modeExcerpts: String { zh ? "摘录" : "Excerpts" }
        static var modeFullText: String { zh ? "全文" : "Full text" }
        static func modeName(_ m: QAContextMode) -> String {
            switch m {
            case .cards: return modeCards
            case .excerpts: return modeExcerpts
            case .fullText: return modeFullText
            }
        }
        static var modeHelp: String {
            zh ? "卡片最省；摘录按问题挑选相关页；全文最多 3 篇。"
               : "Cards are cheapest; excerpts pick the pages that match the question; full text for up to 3 papers."
        }

        // MARK: Composer and estimate

        static var placeholder: String { zh ? "就这篇论文提问…" : "Ask about this paper…" }
        static func placeholderMulti(_ n: Int) -> String { zh ? "就这 \(n) 篇论文提问…" : "Ask across these \(n) papers…" }
        static var send: String { zh ? "提问" : "Ask" }
        static var sendHelp: String {
            zh ? "提问（⌘↩）：每个问题使用一次你的订阅额度" : "Ask (⌘↩): each question uses your subscription once"
        }
        static var stop: String { zh ? "停止" : "Stop" }
        /// Under the composer when the draft is longer than a question sends (dive-cli §7).
        static func questionTooLong(_ limit: Int) -> String {
            zh ? "问题只发送前 \(limit) 个字符，后面的部分不会发送。"
               : "Only the first \(limit.formatted()) characters of a question are sent."
        }
        static func estimateTokens(_ compact: String) -> String { zh ? "约 \(compact) tokens" : "≈ \(compact) tokens" }
        static func pagesAll(_ n: Int) -> String { zh ? "全部 \(n) 页" : (n == 1 ? "1 page" : "all \(n) pages") }
        static func pagesSome(_ sent: Int, _ total: Int) -> String {
            zh ? "\(total) 页中最相关的 \(sent) 页" : "\(sent) of \(total) pages (best matches)"
        }
        static var cardsOnly: String { zh ? "仅卡片" : "cards only" }
        static var noText: String { zh ? "没有文字层" : "no text layer" }
        static func papersCount(_ n: Int) -> String { zh ? "\(n) 篇论文" : "\(n) papers" }
        static func latency(_ r: ClosedRange<Int>) -> String { zh ? "约 \(r.lowerBound)–\(r.upperBound) 秒" : "~\(r.lowerBound)–\(r.upperBound) s" }
        static func today(_ n: Int, _ cap: Int) -> String { zh ? "今天 \(n)/\(cap)" : "today \(n)/\(cap)" }
        static func usesSubscription(_ provider: String) -> String {
            zh ? "使用你的 \(provider) 订阅；按「提问」才会发送" : "Uses your \(provider) subscription; nothing is sent until you press Ask"
        }
        static var mockAssistant: String { zh ? "模拟助手（不调用 AI）" : "Mock assistant (no AI)" }

        // MARK: Streaming and states

        static var preparing: String { zh ? "正在准备论文…" : "Preparing the paper…" }
        static func starting(_ ai: String) -> String { zh ? "正在启动 \(ai)…" : "Starting \(ai)…" }
        static func reading(_ ai: String) -> String { zh ? "\(ai) 正在阅读…" : "\(ai) is reading…" }
        static var stillWaiting: String { zh ? "仍在等待回答…" : "Still waiting for the answer…" }
        static func answering(_ ai: String) -> String { zh ? "\(ai) 正在回答…" : "\(ai) is answering…" }
        static var stopped: String { zh ? "已停止" : "Stopped" }
        static var interrupted: String { zh ? "已中断（PaperDeck 退出时）" : "Interrupted (PaperDeck quit)" }
        /// An answer stopped at the output cap: its text so far is kept.
        static var cutOff: String { zh ? "回答过长，已在此处截断" : "Cut off here: the answer was too long" }
        static var didNotFinish: String { zh ? "没有完成" : "Didn't finish" }
        static var you: String { zh ? "你" : "You" }

        // MARK: Answer actions

        static var copy: String { zh ? "拷贝" : "Copy" }
        static var saveToNotes: String { zh ? "存入笔记" : "Save to Notes" }
        static var saveToNotesOf: String { zh ? "存入笔记…" : "Save to Notes of…" }
        static func allPapers(_ n: Int) -> String { zh ? "全部 \(n) 篇" : "All \(n) Papers" }
        static var savedToNotes: String { zh ? "已存入笔记" : "Saved to notes" }
        static var askThoroughly: String { zh ? "深入回答" : "Ask Thoroughly" }
        static func answerIn(_ target: UILang) -> String {
            switch target {
            case .zh: return zh ? "用中文回答" : "Answer in Chinese"
            case .en: return zh ? "用英文回答" : "Answer in English"
            }
        }
        /// The follow-up a translation sends (shown as the user's question).
        static func translateRequest(_ target: UILang) -> String {
            switch target {
            case .zh: return "请用中文重新回答上一个问题（保留引用标记）。"
            case .en: return "Please give your previous answer again in English (keep the citation markers)."
            }
        }
        static var delete: String { zh ? "删除" : "Delete" }

        // MARK: Citations

        static func printedPage(_ label: String) -> String { zh ? "印刷页码 \(label)" : "printed \(label)" }
        static func openPage(_ n: Int) -> String { zh ? "打开第 \(n) 页" : "Open p. \(n)" }
        static func pageMissing(_ n: Int) -> String { zh ? "这份 PDF 里没有第 \(n) 页" : "Page \(n) isn't in this PDF" }
        static func unverified(_ n: Int) -> String {
            zh ? "在第 \(n) 页没有找到这句话的依据，请自己核对" : "Couldn't find support for this on p. \(n) — check it"
        }
        static var fromCard: String { zh ? "来自论文卡片" : "From the paper's card" }
        static var unknownPaper: String { zh ? "这次提问里没有这篇论文" : "That paper isn't part of this question" }
        /// `[p. 5]` without a paper label in a question about several papers.
        static func ambiguousPaper(_ n: Int) -> String {
            zh ? "这条引用没有注明是哪篇论文的第 \(n) 页" : "This citation doesn't say which paper's p. \(n) it means"
        }
        /// A page the budget (or a cards-only question) left out: the AI never saw it.
        static func notSent(_ n: Int) -> String {
            zh ? "第 \(n) 页没有随这次提问发送，AI 没有看到这一页，无法核对"
               : "p. \(n) wasn't sent with this question — the AI never saw it, so this can't be checked"
        }

        // MARK: Suggestions

        static var tryAsking: String { zh ? "可以这样问" : "Try asking" }
        static var suggestMain: String { zh ? "主要发现是什么？" : "What's the main finding?" }
        static var suggestMethod: String { zh ? "用简单的话解释方法。" : "Explain the method simply." }
        static var suggestLimits: String { zh ? "有哪些局限？" : "What are the limitations?" }
        static var suggestReproduce: String { zh ? "怎样复现关键结果？" : "How would I reproduce the key result?" }
        static func suggestTerm(_ term: String) -> String { zh ? "这里的「\(term)」是什么意思？" : "What does “\(term)” mean here?" }
        static var suggestCompare: String { zh ? "这些论文的方法有什么不同？" : "How do these papers differ in approach?" }
        static var suggestAgree: String { zh ? "它们在哪些结论上一致、哪些有分歧？" : "Where do they agree, and where do they disagree?" }
        static var suggestStrongest: String { zh ? "哪篇的证据最充分？" : "Which one has the strongest evidence?" }

        // MARK: Notices

        static var offTitle: String { zh ? "提问会使用你的 AI 订阅" : "Ask uses your AI subscription" }
        static var offBody: String {
            zh ? "问题和论文文字会通过本机官方应用发给 Claude 或 ChatGPT。按「提问」之前什么都不会发送，每个问题计一次额度。"
               : "Your question and the paper's text go to Claude or ChatGPT through their official app on this Mac. "
                 + "Nothing is sent until you press Ask, and each question counts once against your plan."
        }
        static func useProvider(_ name: String) -> String { zh ? "使用 \(name)" : "Use \(name)" }
        static var offFooter: String {
            zh ? "以后可以在设置 ▸ 讲解与问答 里关闭。" : "You can turn it off again in Settings ▸ Explain & Ask."
        }
        static func loginHint(_ provider: AIProviderKind) -> String {
            switch provider {
            case .claude: return zh ? "在终端运行 claude，然后输入 /login。" : "In Terminal, run claude, then type /login."
            case .codex: return zh ? "在终端运行 codex login。" : "In Terminal, run codex login."
            }
        }
        static func limited(_ ai: String, _ until: String?) -> String {
            if let until { return zh ? "已达到 \(ai) 的用量上限，\(until) 重置。" : "\(ai) usage limit reached — resets \(until)." }
            return zh ? "已达到 \(ai) 的用量上限，请稍后再试。" : "\(ai) usage limit reached — try again later."
        }
        static func softCap(_ n: Int) -> String { zh ? "今天已经问了 \(n) 个问题。要继续吗？" : "You've asked \(n) questions today. Continue?" }
        static var continueAnyway: String { zh ? "继续" : "Continue" }
        static func hardCap(_ n: Int) -> String { zh ? "今天的 \(n) 个问题上限已用完，明天再问。" : "Today's limit of \(n) questions is used up. Ask again tomorrow." }
        static var burst: String { zh ? "一分钟内问得太多了，稍等再试。" : "Several questions in a minute — wait a moment, then try again." }
        static var budget: String { zh ? "这次运行的 AI 次数已用完。" : "The AI run budget of this session is used up." }
        static func notInstalled(_ cli: String) -> String { zh ? "这台 Mac 上没有安装 \(cli)。" : "\(cli) isn't installed on this Mac." }
        static var unsupported: String { zh ? "这台 Mac 上无法使用这个助手。" : "This assistant isn't available on this Mac." }
        static var expired: String { zh ? "等待太久了，请再按一次。" : "That took too long — please press Try Again." }
        static var timeout: String { zh ? "回答超时。" : "No answer in time." }
        static var overloaded: String { zh ? "模型繁忙，请稍后再试。" : "The model is busy — try again in a moment." }
        static var failed: String { zh ? "没有得到回答。" : "Couldn't get an answer." }
        static var retry: String { zh ? "重试" : "Try Again" }
        static func confirmTitle(_ ai: String) -> String { zh ? "把这篇论文发给 \(ai)？" : "Send this paper to \(ai)?" }
        static var confirmSend: String { zh ? "仍然发送" : "Send Anyway" }
        static var privacyNote: String {
            zh ? "这篇论文可能未发表或保密：发送前会先问你。" : "This paper may be unpublished or confidential: Ask confirms before sending it."
        }
        static var blockedHint: String {
            zh ? "在「概览」里关闭「不对这篇论文使用 AI」后才能提问。" : "Turn off “Never use AI for this paper” in Overview to ask about it."
        }
        static var dismiss: String { zh ? "关闭" : "Dismiss" }
        /// A paper's privacy settings couldn't be read (fail closed: nothing was sent).
        static var privacyUnchecked: String {
            zh ? "没能读取这篇论文的隐私设置，所以什么都没有发送。" : "Couldn't check this paper's privacy settings, so nothing was sent."
        }
        static var privacyUncheckedHint: String {
            zh ? "稍后再试；如果一直这样，请重新打开这篇论文。" : "Try again in a moment; if it keeps happening, open the paper again."
        }
        /// Several papers: which ones block or need a confirmation ("P2, P4").
        static func blockedPapers(_ labels: [String]) -> String {
            let list = labels.joined(separator: zh ? "、" : ", ")
            return zh ? "\(list) 设置了「不使用 AI」。" : (labels.count == 1 ? "\(list) is set to never use AI." : "\(list) are set to never use AI.")
        }
        static var blockedPapersHint: String {
            zh ? "把它从这次提问中移除，就能问其余的论文。" : "Remove it from this question to ask about the others."
        }
        static func removeLabel(_ label: String) -> String { zh ? "移除 \(label)" : "Remove \(label)" }
        static func privacyNotePapers(_ labels: [String]) -> String {
            let list = labels.joined(separator: zh ? "、" : ", ")
            return zh ? "\(list) 可能未发表或保密：发送前会先问你。" : "\(list) may be unpublished or confidential: Ask confirms before sending."
        }

        // MARK: Window

        static func windowTitle(_ n: Int) -> String { zh ? "提问 · \(n) 篇论文" : "Ask · \(n) Papers" }
        static var papersHeader: String { zh ? "论文" : "Papers" }
        static func capNote(_ kept: Int, _ selected: Int) -> String {
            zh ? "只包含所选 \(selected) 篇中的前 \(kept) 篇。" : "Only the first \(kept) of the \(selected) selected papers are included."
        }
        static var removePaper: String { zh ? "从这次提问中移除" : "Remove from This Question" }
        static var contextMode: String { zh ? "上下文" : "Context" }
        static var fullTextLimit: String { zh ? "全文最多用于 3 篇论文。" : "Full text is available for up to 3 papers." }
        static func askAcross(_ n: Int) -> String { zh ? "跨 \(n) 篇提问…" : "Ask Across \(n)…" }
        static var askAcrossHelp: String {
            zh ? "就选中的论文提一个问题（标为 P1…Pn）" : "Ask one question about the selected papers (labelled P1…Pn)"
        }

        // MARK: PagePeek

        static func peekTitle(_ page: Int) -> String { zh ? "第 \(page) 页" : "Page \(page)" }
        static var openPDF: String { zh ? "打开 PDF" : "Open PDF" }
        static var close: String { zh ? "关闭" : "Close" }
        static var noPDF: String { zh ? "找不到这篇论文的 PDF。" : "This paper's PDF isn't available." }
        static var quoteNotHighlighted: String {
            zh ? "没能在页面上标出引用的句子。" : "The cited sentence couldn't be highlighted on the page."
        }

        // MARK: Settings ▸ Ask

        static var settingsSection: String { zh ? "提问" : "Ask" }
        static var settingsDepth: String { zh ? "默认回答深度" : "Default answer depth" }
        static var settingsLanguage: String { zh ? "回答语言" : "Answer language" }
        static var settingsBudget: String { zh ? "每次提问发送的论文文字" : "Paper text per question" }
        static func settingsBudgetValue(_ chars: Int) -> String {
            let k = chars / 1_000
            return zh ? "\(k)k 字符（约 \(k / 4)k tokens）" : "\(k)k characters (~\(k / 4)k tokens)"
        }
        static var settingsMultiMax: String { zh ? "一次提问最多几篇论文" : "Papers per question, at most" }
        static var settingsModels: String { zh ? "模型" : "Models" }
        static func settingsModelsValue(_ quick: String, _ thorough: String) -> String {
            zh ? "快速：\(quick) · 深入：\(thorough)" : "Quick: \(quick) · Thorough: \(thorough)"
        }
        static var settingsFooter: String {
            zh ? "每个问题都要你点一下才发送，计一次额度。问答记录随论文保存（标为保密的论文只存在本机数据库里）。"
               : "Every question needs your click and counts once against your plan. Q&A is saved with the paper "
                 + "(for papers marked confidential, only in PaperDeck's database)."
        }

        /// Every worded string (both-language checks of `--selftest qa`). The EN / 中 toggle labels are symbols.
        static var all: [String] {
            [tabOverview, tabAsk, newThread, threads, untitledThread, deleteThread, threadHelp, depthQuick, depthThorough,
             depthHelp, langAuto, langHelp, modeCards, modeExcerpts, modeFullText, modeHelp, placeholder, placeholderMulti(3),
             send, sendHelp, stop, estimateTokens("2k"), pagesAll(12), pagesSome(8, 40), cardsOnly, noText, papersCount(3),
             latency(5...15), today(3, 50), usesSubscription("Claude"), mockAssistant, preparing, starting("Claude"),
             reading("Claude"), stillWaiting, answering("Claude"), stopped, interrupted, didNotFinish, you, copy, saveToNotes,
             saveToNotesOf, allPapers(3), savedToNotes, askThoroughly, answerIn(.zh), answerIn(.en), delete,
             printedPage("1203"), openPage(7), pageMissing(40), unverified(7), fromCard, unknownPaper, ambiguousPaper(5),
             notSent(11), questionTooLong(1_000), cutOff, privacyUnchecked, privacyUncheckedHint, tryAsking, suggestMain,
             suggestMethod, suggestLimits, suggestReproduce, suggestTerm("UMAP"), suggestCompare, suggestAgree, suggestStrongest,
             offTitle, offBody, useProvider("Claude"), offFooter, loginHint(.claude), loginHint(.codex), limited("Claude", "3:45 PM"),
             limited("Claude", nil), softCap(50), continueAnyway, hardCap(150), burst, budget, notInstalled("Claude Code"),
             unsupported, expired, timeout, overloaded, failed, retry, confirmTitle("Claude"), confirmSend, privacyNote, blockedHint,
             dismiss, blockedPapers(["P4"]), blockedPapers(["P2", "P4"]), blockedPapersHint, removeLabel("P4"),
             privacyNotePapers(["P3"]), windowTitle(3), papersHeader, capNote(10, 14), removePaper, contextMode, fullTextLimit, askAcross(4),
             askAcrossHelp, peekTitle(7), openPDF, close, noPDF, quoteNotHighlighted, settingsSection, settingsDepth,
             settingsLanguage, settingsBudget, settingsBudgetValue(80_000), settingsMultiMax, settingsModels,
             settingsModelsValue("haiku", "sonnet"), settingsFooter]
        }
    }
}
