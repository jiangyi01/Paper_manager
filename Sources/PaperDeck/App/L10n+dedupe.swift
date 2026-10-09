import Foundation
import PaperDeckCore

/// Strings of the duplicate check (decision sheet, ribbon, chip, sidebar, settings). Owned by
/// Slice B. Every name sits in `L.Dedupe`; the explanation itself (headline, versions, history,
/// reasons) comes worded from Core (`DupExplainer`), which the engine's toasts share.
extension L {
    enum Dedupe {
        private static var zh: Bool { L.lang == .zh }

        /// The main menu's Library menu (it holds Check for Duplicates…).
        static var libraryMenu: String { zh ? "资料库" : "Library" }
        static var checkForDuplicates: String { zh ? "检查重复…" : "Check for Duplicates…" }

        // MARK: Sidebar, ribbon, chip

        static var sidebarRow: String { zh ? "可能重复" : "Duplicates" }
        static func sidebarHelp(_ n: Int) -> String {
            zh ? "\(n) 个重复提醒待处理" : (n == 1 ? "1 duplicate question to answer" : "\(n) duplicate questions to answer")
        }
        static var ribbon: String { zh ? "重复？" : "Duplicate?" }
        /// What the review actually holds back (`DupReview.hold`): a paper held at import, one the
        /// enrichment matched (AI only), a library check's question (nothing).
        static func ribbonHelp(_ hold: DupHold) -> String {
            switch hold {
            case .scheduleAndAI:
                return zh ? "可能与库中论文重复：决定前不排 DDL、不做 AI 解读。点按查看。"
                    : "May duplicate a paper in your library — no DDL or AI reading until you decide. Click to review."
            case .aiOnly:
                return zh ? "可能与库中论文重复：决定前不做 AI 解读。点按查看。"
                    : "May duplicate a paper in your library — no AI reading until you decide. Click to review."
            case .none:
                return zh ? "可能与库中论文重复。点按查看。" : "May duplicate a paper in your library. Click to review."
            }
        }
        static func chipHeld(_ title: String) -> String {
            zh ? "可能与「\(title)」重复" : "May duplicate “\(title)”"
        }
        static func chipPossible(_ title: String) -> String {
            zh ? "可能与「\(title)」是同一篇" : "Possibly the same paper as “\(title)”"
        }
        static func chipRemoved(_ title: String) -> String {
            zh ? "与你删除过的「\(title)」一致" : "Matches “\(title)”, a paper you removed"
        }
        /// The chip's note: what waits for the decision (nil: nothing does).
        static func chipHeldNote(_ hold: DupHold) -> String? {
            switch hold {
            case .scheduleAndAI: return zh ? "决定前不排 DDL，也不做 AI 解读。" : "No DDL or AI reading until you decide."
            case .aiOnly: return zh ? "决定前不做 AI 解读。" : "No AI reading until you decide."
            case .none: return nil
            }
        }
        static func chipExisting(_ n: Int) -> String {
            zh ? (n == 1 ? "有一个新文件可能与这篇重复" : "有 \(n) 个新文件可能与这篇重复")
                : (n == 1 ? "A new file may duplicate this paper" : "\(n) new files may duplicate this paper")
        }
        static var review: String { zh ? "查看…" : "Review…" }

        // MARK: Decision sheet

        static var sheetTitle: String { zh ? "重复？" : "Duplicate?" }
        static func counter(_ i: Int, _ n: Int) -> String { zh ? "第 \(i)/\(n) 个" : "\(i) of \(n)" }
        static var newSide: String { zh ? "新文件" : "New" }
        static var existingSide: String { zh ? "库中已有" : "In your library" }
        static var existingDeleted: String { zh ? "在「最近删除」中" : "In Recently Deleted" }
        static var existingRemoved: String { zh ? "已从资料库删除" : "Removed from your library" }
        static var newer: String { zh ? "较新" : "newer" }
        static func pages(_ n: Int) -> String { zh ? "\(n) 页" : (n == 1 ? "1 page" : "\(n) pages") }
        static func checklist(_ done: Int, _ total: Int) -> String {
            zh ? "清单 \(done)/\(total)" : "Checklist \(done)/\(total)"
        }
        static func notes(_ chars: Int) -> String { zh ? "笔记 \(chars) 字" : "Notes · \(chars) characters" }
        static var readingCard: String { zh ? "有阅读卡片" : "Reading card" }
        static func readTimes(_ n: Int) -> String { zh ? "读过 \(n) 次" : (n == 1 ? "read once" : "read \(n)×") }
        static var why: String { zh ? "原因" : "Why" }
        static var whatToDo: String { zh ? "怎么处理" : "What to do" }
        static var parkedHint: String {
            zh ? "新文件会一直等到你退出 PaperDeck；之后需要重新拖入。"
                : "The new file waits until you quit PaperDeck; after that, drop it again."
        }
        /// The sheet's line about the new paper while the question is open ("" when nothing waits).
        static func heldHint(_ hold: DupHold) -> String {
            switch hold {
            case .scheduleAndAI:
                return zh ? "决定之前，新论文不排 DDL，也不做 AI 解读。" : "Until you decide, the new paper has no DDL and isn't read by AI."
            case .aiOnly: return zh ? "决定之前，新论文不做 AI 解读。" : "Until you decide, the new paper isn't read by AI."
            case .none: return ""
            }
        }
        static var loading: String { zh ? "正在载入…" : "Loading…" }
        static var decideLater: String { zh ? "稍后决定" : "Decide Later" }
        static var apply: String { zh ? "应用" : "Apply" }
        static var close: String { zh ? "关闭" : "Close" }

        static var keepNew: String { zh ? "保留新的" : "Keep the new one" }
        static var keepNewDetail: String {
            zh ? "换成新文件；清单、笔记和阅读记录都保留，标题和 DOI 更新为新版本的"
                : "Replace the file; keep the checklist, notes and history; the title and DOI follow the new version"
        }
        static var restoreWithNew: String { zh ? "用新文件恢复旧的" : "Restore it with the new file" }
        static var restoreWithNewDetail: String {
            zh ? "从「最近删除」恢复并换成新文件；清单、笔记和阅读记录都保留"
                : "Back from Recently Deleted with the new file; the checklist, notes and history are kept"
        }
        static var moveBackToRead: String { zh ? "并移回「待读」" : "and move it back to To Read" }

        static var rereadEarlier: String { zh ? "重读旧的" : "Re-read the earlier one" }
        static var rereadEarlierDetail: String {
            zh ? "移回「待读」，重新排 DDL；不添加新文件" : "Back to To Read with a new DDL; the new file isn't added"
        }
        static var restoreEarlier: String { zh ? "恢复旧的" : "Restore the earlier one" }
        static var restoreEarlierDetail: String {
            zh ? "从「最近删除」恢复到「待读」；不添加新文件" : "Back from Recently Deleted to To Read; the new file isn't added"
        }
        static var checklistLabel: String { zh ? "清单" : "Checklist" }
        static var keepProgress: String { zh ? "保留进度" : "Keep progress" }
        static var uncheckAll: String { zh ? "全部取消勾选" : "Uncheck all" }
        static var regenerate: String { zh ? "按阅读卡片重新生成" : "Rebuild from the reading card" }
        static var deadlineLabel: String { zh ? "DDL" : "Deadline" }
        static var deadlineAuto: String { zh ? "自动排期" : "Automatic" }
        static var deadlinePick: String { zh ? "指定日期" : "Pick a date" }
        static var deadlineNone: String { zh ? "不排期" : "No deadline" }
        static var useNewFile: String { zh ? "同时换成新文件" : "Use the new file too" }

        static var keepBoth: String { zh ? "两篇都留" : "Keep both" }
        static var keepBothDetail: String {
            zh ? "它们是不同的论文——以后不再提醒" : "They're different papers — don't ask again"
        }
        static var keepBothRelated: String { zh ? "两篇都留，标记为相关" : "Keep both, linked as related" }
        static var keepBothRelatedDetail: String {
            zh ? "更正、评论或配套论文不是同一篇——以后不再提醒" : "A correction, comment or companion isn't the same paper — don't ask again"
        }
        static var linkAsRelated: String { zh ? "标记为相关论文" : "Link them as related" }

        static var skip: String { zh ? "跳过" : "Skip" }
        static var skipParkedDetail: String { zh ? "不添加新文件" : "Don't add the new file" }
        static var skipCommitted: String { zh ? "删除新的副本" : "Remove the new copy" }
        static var skipCommittedDetail: String {
            zh ? "移到「最近删除」（30 天内可恢复）" : "It goes to Recently Deleted (recoverable for 30 days)"
        }
        static var attachSupplement: String { zh ? "作为补充材料附到论文" : "Attach to the paper" }
        static var attachSupplementDetail: String {
            zh ? "存进这篇论文文件夹的 supplements 子文件夹，不单独成卡" : "Saved in the paper's folder (supplements), not as a paper of its own"
        }
        static var addAgain: String { zh ? "重新加入" : "Add it again" }
        static var addAgainDetail: String {
            zh ? "照常排 DDL，记为再读一次" : "Scheduled as usual; it counts as another read"
        }

        // MARK: Results

        static var undo: String { zh ? "撤销" : "Undo" }
        static var open: String { zh ? "查看" : "Open" }
        static func expired(_ n: Int) -> String {
            zh ? "\(n) 个重复提醒已过期（PaperDeck 重新启动过），请重新拖入文件"
                : (n == 1 ? "1 duplicate question expired (PaperDeck was restarted) — drop the file again"
                   : "\(n) duplicate questions expired (PaperDeck was restarted) — drop the files again")
        }

        // MARK: Duplicates list

        static var listTitle: String { zh ? "可能重复的论文" : "Duplicates" }
        static func listCount(_ n: Int) -> String { zh ? "待处理 \(n) 个" : (n == 1 ? "1 to review" : "\(n) to review") }
        static var listEmpty: String { zh ? "没有待处理的重复提醒。" : "No duplicate questions to answer." }
        static func checking(_ done: Int, _ total: Int) -> String {
            zh ? "正在检查资料库… \(done)/\(total)" : "Checking your library… \(done) of \(total)"
        }
        static func checkFound(_ n: Int) -> String {
            zh ? (n == 0 ? "没有发现新的重复。" : "发现 \(n) 个新的可能重复。")
                : (n == 0 ? "No new duplicates found." : (n == 1 ? "Found 1 new possible duplicate." : "Found \(n) new possible duplicates."))
        }
        static var checkStopped: String { zh ? "检查已停止。" : "Check stopped." }
        static var checkLibrary: String { zh ? "检查资料库" : "Check Library" }
        static var stop: String { zh ? "停止" : "Stop" }
        static var reviewAll: String { zh ? "逐个处理" : "Review All" }
        static var done: String { zh ? "完成" : "Done" }
        static func newLine(_ title: String) -> String { zh ? "新：\(title)" : "New: \(title)" }
        static func libraryLine(_ title: String) -> String { zh ? "库中：\(title)" : "Library: \(title)" }
        static func removedLine(_ title: String) -> String { zh ? "已删除：\(title)" : "Removed: \(title)" }
        static func band(_ b: DupBand) -> String {
            switch b {
            case .certain: return zh ? "同一篇" : "Same paper"
            case .likely: return zh ? "很可能相同" : "Probably the same"
            case .possible: return zh ? "可能相同" : "Possibly the same"
            }
        }
        static var waitingFile: String { zh ? "新文件等待中" : "New file waiting" }

        // MARK: Settings ▸ Library ▸ Duplicates

        static var section: String { zh ? "重复检查" : "Duplicates" }
        static var enabled: String { zh ? "新论文与资料库比对查重" : "Check new papers against your library" }
        static var enabledHint: String {
            zh ? "相同 DOI/arXiv 编号、预印本与正式版、相同标题和正文。未经你点按，不会替换或删除任何内容。"
                : "The same DOI or arXiv ID, preprint and journal versions, the same title and text. Nothing is replaced or removed without your click."
        }
        static var offHint: String {
            zh ? "关闭时：DOI 或 arXiv 编号相同的文件仍像以前一样询问「替换 / 忽略」。"
                : "Off: a file with the same DOI or arXiv ID still asks Replace / Ignore, as before."
        }
        static var sensitivity: String { zh ? "灵敏度" : "Sensitivity" }
        static func sensitivityName(_ s: DedupeSettings.Sensitivity) -> String {
            switch s {
            case .strict: return zh ? "严格" : "Strict"
            case .balanced: return zh ? "均衡" : "Balanced"
            case .loose: return zh ? "宽松" : "Loose"
            }
        }
        static var sensitivityHint: String {
            zh ? "只影响按标题和正文的判断；DOI、arXiv 编号和相同文件始终算作重复。"
                : "Only the title-and-text matches move; the same DOI, arXiv ID or file always counts."
        }
        static var history: String { zh ? "记住已删除的论文" : "Remember papers you removed" }
        static var historyHint: String {
            zh ? "「最近删除」30 天后清除的论文仍保留标题、编号和阅读记录（不含正文和笔记），重新下载时会提示「你 5 月读过」。「永久删除」的论文、标记为保密或暂缓的未发表论文不保留。关闭后不再比对；「清除记录」可删除已保留的。"
                : "Papers cleared from Recently Deleted after 30 days keep their title, identifiers and when you read them (no text, no notes), so a re-download says “you read this in May”. Papers you delete permanently, or marked confidential or held as unpublished, aren't kept. Off: no matching; Clear History removes what was kept."
        }
        static func clearHistory(_ n: Int) -> String { zh ? "清除记录（\(n)）…" : "Clear History (\(n))…" }
        static func clearHistoryTitle(_ n: Int) -> String {
            zh ? "忘记 \(n) 篇已删除的论文？" : (n == 1 ? "Forget 1 removed paper?" : "Forget \(n) removed papers?")
        }
        static var clearHistoryMessage: String {
            zh ? "重复检查将不再认出它们。资料库本身不受影响。" : "The duplicate check won't recognize them anymore. Your library isn't changed."
        }
        static var clear: String { zh ? "清除" : "Clear" }
        static var checkLibraryEllipsis: String { zh ? "检查资料库中的重复…" : "Check Library for Duplicates…" }

        // MARK: Batch review (B3)

        static func batchTitle(_ n: Int) -> String {
            zh ? "\(n) 个可能重复" : (n == 1 ? "1 possible duplicate" : "\(n) possible duplicates")
        }
        static var batchSubtitle: String {
            zh ? "每一行已选好建议的处理方式，可逐行修改。点按「应用」之前不会改动任何内容。"
                : "Each row starts on the suggested choice; change any row. Nothing changes until you click Apply."
        }
        static var setAll: String { zh ? "全部设为" : "Set all to" }
        static func preset(_ p: DupBatchPreset) -> String {
            switch p {
            case .suggested: return zh ? "建议的处理" : "Suggested"
            case .keepNew: return zh ? "保留新的（可行时）" : "Keep the new one where possible"
            case .keepBoth: return zh ? "两篇都留（可行时）" : "Keep both where possible"
            case .skip: return zh ? "跳过新文件（可行时）" : "Skip the new file where possible"
            }
        }
        static func changed(_ n: Int) -> String { zh ? "已改 \(n) 行" : (n == 1 ? "1 row changed" : "\(n) rows changed") }
        static var suggestedMark: String { zh ? "建议" : "suggested" }
        static var details: String { zh ? "详情…" : "Details…" }
        static func applyN(_ n: Int) -> String { zh ? "应用（\(n)）" : "Apply \(n)" }
        static var batchUndoHint: String {
            zh ? "应用后 30 秒内可一次撤销全部。" : "One Undo reverts them all for 30 seconds after Apply."
        }
        static func batchLeft(_ n: Int) -> String {
            zh ? "\(n) 个未能处理（可能已在别处处理过）" : (n == 1 ? "1 couldn't be applied (answered elsewhere?)" : "\(n) couldn't be applied (answered elsewhere?)")
        }
        static func reviewFound(_ n: Int) -> String { zh ? "处理这 \(n) 个…" : "Review \(n)…" }

        // MARK: AI judge (B3)

        static var askAI: String { zh ? "问 AI" : "Ask AI" }
        static var askAIAgain: String { zh ? "再问一次 AI" : "Ask AI Again" }
        static var askingAI: String { zh ? "正在询问 AI…" : "Asking AI…" }
        static func judgeCost(_ used: Int, _ cap: Int) -> String {
            zh ? "用一次快速 AI 调用（今天 \(used)/\(cap)）；AI 只会调整可信度，不会替你处理。"
                : "One quick AI call (\(used) of \(cap) today); the AI only adjusts how sure the match is — it decides nothing."
        }
        static func judgeVerdict(_ v: DupJudgeVerdict) -> String {
            switch v {
            case .sameWork: return zh ? "同一篇、同一版本" : "same paper, same version"
            case .newVersion: return zh ? "同一篇的另一个版本" : "same paper, another version"
            case .related: return zh ? "相关但不是同一篇" : "related, not the same paper"
            case .different: return zh ? "不是同一篇" : "different papers"
            }
        }
        static func judgeLine(_ v: DupJudgeVerdict, _ percent: Int) -> String {
            zh ? "AI 判断：\(judgeVerdict(v))（\(percent)%）" : "AI: \(judgeVerdict(v)) (\(percent)%)"
        }
        static func judgeMoved(_ from: DupBand, _ to: DupBand) -> String {
            zh ? "可信度：\(band(from)) → \(band(to))" : "Moved from “\(band(from))” to “\(band(to))”"
        }
        static var judgeUnsure: String {
            zh ? "AI 不够确定，可信度未变。" : "The AI wasn't sure enough — nothing moved."
        }
        static func judgeBlocked(_ b: DupJudgeBlock) -> String? {
            switch b {
            case .privateNew, .privateExisting:
                return zh ? "不会发送给 AI：其中一篇标记为保密、禁止 AI，或可能是未发表稿件。"
                    : "Not sent to AI: one of them is marked confidential or never-AI, or may be unpublished."
            case .dailyCap:
                return zh ? "今天的 AI 查重次数已用完。" : "Today's AI duplicate checks are used up."
            case .busy:
                return zh ? "AI 正在判断另一对论文。" : "The AI is judging another pair."
            case .switchedOff, .dedupeOff, .assistOff, .reviewClosed, .certain, .removedPaper:
                return nil
            }
        }
        static func judgeFailed(_ e: DupJudgeError) -> String {
            switch e {
            case .blocked(let b): return judgeBlocked(b) ?? (zh ? "现在不能询问 AI。" : "AI can't be asked now.")
            case .refused(let v):
                switch v {
                case .disabled, .wrongProvider:
                    return zh ? "「讲解与问答」已关闭。" : "Explain & Ask is off."
                case .paused(let until):
                    return zh ? "AI 额度暂停到 \(clock(until))。" : "AI is paused until \(clock(until))."
                case .dailySoftCap, .dailyHardCap, .budgetExhausted, .burst:
                    return zh ? "今天的 AI 次数已达上限。" : "Today's AI limit is reached."
                default:
                    return zh ? "AI 没有收到这次请求，请再点一次。" : "The AI didn't get the request — click again."
                }
            case .failed(let f):
                switch f {
                case .notLoggedIn: return zh ? "AI 账号未登录。" : "The AI account isn't signed in."
                case .usageLimit: return zh ? "AI 额度已用完，稍后再试。" : "The AI usage limit is reached — try later."
                case .timeout: return zh ? "AI 没有及时回答。" : "The AI didn't answer in time."
                case .cancelled: return zh ? "已停止。" : "Stopped."
                default: return zh ? "AI 没能回答。" : "The AI couldn't answer."
                }
            case .unreadable: return zh ? "AI 的回答无法读取，未做任何改动。" : "The AI's answer couldn't be read — nothing changed."
            }
        }

        // MARK: Settings ▸ Duplicates ▸ AI judge (B3)

        static var judgeToggle: String { zh ? "可以请 AI 判断疑似重复" : "Let me ask AI about a possible duplicate" }
        static func judgeToggleHint(_ cap: Int) -> String {
            zh ? "只在你点按「问 AI」时运行，每天最多 \(cap) 次，使用快速小模型；只发送书目信息和首页摘录。标记为保密、禁止 AI 或可能未发表的论文永不发送。AI 只调整可信度，不会替换、合并或删除任何内容。需要先打开「讲解与问答」。"
                : "Runs only when you click Ask AI, at most \(cap) a day, on a quick model; sends only the records and a first-page excerpt. Papers marked confidential or never-AI, or possibly unpublished, are never sent. The AI only adjusts how sure a match is — it never replaces, merges or removes anything. Needs Explain & Ask turned on."
        }

        // MARK: Mail merge popover (B3)

        /// `15:45` (24-hour, both languages).
        static func clock(_ date: Date) -> String {
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }

        static var mailLooksLike: String { zh ? "看起来是资料库中的这篇" : "Looks like a paper in your library" }
        static func mailChoice(_ c: MailDupChoice) -> String {
            switch c {
            case .link: return zh ? "关联到这篇" : "Link to it"
            case .reread: return zh ? "关联并重读" : "Link and re-read it"
            case .useThisVersion: return zh ? "使用邮件中的版本" : "Use this version"
            case .addSeparately: return zh ? "作为另一篇添加" : "Add as a separate paper"
            }
        }
        static func mailChoiceDetail(_ c: MailDupChoice, deleted: Bool) -> String {
            switch c {
            case .link:
                return deleted ? (zh ? "从「最近删除」恢复并关联邮件；不添加文件" : "Restore it from Recently Deleted and link the email; the file isn't added")
                    : (zh ? "不添加文件；邮件关联到这篇，优先级和 DDL 不变" : "Don't add the file; the email is linked, priority and DDL stay")
            case .reread: return zh ? "关联邮件，并移回「待读」重新排 DDL" : "Link the email and move the paper back to To Read with a new DDL"
            case .useThisVersion:
                return zh ? "换成邮件中的 PDF；清单、笔记和阅读记录都保留" : "Replace its file with the email's PDF; keep the checklist, notes and history"
            case .addSeparately: return zh ? "它们是不同的论文——以后不再提醒" : "They're different papers — don't ask again"
            }
        }
        static func mailConfirm(_ c: MailDupChoice) -> String {
            switch c {
            case .link: return zh ? "关联" : "Link"
            case .reread: return zh ? "关联并重读" : "Link and Re-read"
            case .useThisVersion: return zh ? "使用此版本" : "Use This Version"
            case .addSeparately: return zh ? "添加" : "Add"
            }
        }
        static var mailOptionsApplyToAdd: String {
            zh ? "以下选项只用于新添加的论文。" : "The options below apply to a paper that is added."
        }
        static func mailMatches(_ n: Int) -> String {
            zh ? "其中 \(n) 篇看起来已在资料库中：相同编号的会关联，其余添加后可在「可能重复」中处理。"
                : (n == 1 ? "1 of these looks like a paper you have: the same ID is linked; otherwise it is added and you can review it under Duplicates."
                   : "\(n) of these look like papers you have: the same IDs are linked; the others are added and you can review them under Duplicates.")
        }

        /// Every string of this file in the current language (the self-test checks en ≠ zh).
        static var all: [String] {
            [libraryMenu, checkForDuplicates, sidebarRow, sidebarHelp(2), ribbon, ribbonHelp(.scheduleAndAI),
             ribbonHelp(.aiOnly), ribbonHelp(.none), chipHeld("T"), chipPossible("T"),
             chipRemoved("T"), chipHeldNote(.scheduleAndAI) ?? "", chipHeldNote(.aiOnly) ?? "", chipExisting(2), review,
             sheetTitle, counter(1, 3), newSide, existingSide,
             existingDeleted, existingRemoved, newer, pages(3), checklist(1, 2), notes(5), readingCard, readTimes(2), why,
             whatToDo, parkedHint, heldHint(.scheduleAndAI), heldHint(.aiOnly), loading, decideLater, apply, close, keepNew,
             keepNewDetail, restoreWithNew,
             restoreWithNewDetail, moveBackToRead, rereadEarlier, rereadEarlierDetail, restoreEarlier, restoreEarlierDetail,
             checklistLabel, keepProgress, uncheckAll, regenerate, deadlineLabel, deadlineAuto, deadlinePick, deadlineNone,
             useNewFile, keepBoth, keepBothDetail, keepBothRelated, keepBothRelatedDetail, linkAsRelated, skip,
             skipParkedDetail, skipCommitted, skipCommittedDetail, attachSupplement, attachSupplementDetail, addAgain,
             addAgainDetail, undo, open, expired(2), listTitle, listCount(2), listEmpty, checking(1, 2), checkFound(2),
             checkStopped, checkLibrary, stop, reviewAll, done, newLine("T"), libraryLine("T"), removedLine("T"),
             band(.certain), band(.likely), band(.possible), waitingFile, section, enabled, enabledHint, offHint,
             sensitivity, sensitivityName(.strict), sensitivityName(.balanced), sensitivityName(.loose), sensitivityHint,
             history, historyHint, clearHistory(2), clearHistoryTitle(2), clearHistoryMessage, clear, checkLibraryEllipsis]
                + b3
        }

        /// The B3 strings (batch review, AI judge, mail popover), every case worded.
        static var b3: [String] {
            var out = [batchTitle(3), batchSubtitle, setAll, changed(2), suggestedMark, details, applyN(3), batchUndoHint,
                       batchLeft(2), reviewFound(3), askAI, askAIAgain, askingAI, judgeCost(3, 10), judgeLine(.sameWork, 90),
                       judgeMoved(.possible, .likely), judgeUnsure, judgeToggle, judgeToggleHint(10), mailLooksLike,
                       mailOptionsApplyToAdd, mailMatches(2), judgeFailed(.unreadable)]
            out += DupBatchPreset.allCases.map(preset)
            out += DupJudgeVerdict.allCases.map(judgeVerdict)
            out += DupJudgeBlock.allCases.compactMap(judgeBlocked)
            out += MailDupChoice.allCases.flatMap { [mailChoice($0), mailChoiceDetail($0, deleted: false), mailConfirm($0)] }
            out.append(mailChoiceDetail(.link, deleted: true))
            out += [judgeFailed(.refused(.disabled)), judgeFailed(.refused(.burst)), judgeFailed(.refused(.consentExpired)),
                    judgeFailed(.failed(.timeout)), judgeFailed(.failed(.cancelled)), judgeFailed(.failed(.overloaded)),
                    judgeFailed(.failed(.notLoggedIn(.loggedOut))), judgeFailed(.refused(.paused(until: Date(timeIntervalSince1970: 0)))), judgeFailed(.failed(.usageLimit(resetsAt: nil)))]
            return out
        }
    }
}
