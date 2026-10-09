import Foundation
import PaperDeckCore

/// Strings of multi-select (selection bar, multi-inspector, Select menu, batch actions). Owned by
/// Slice C. Every name sits in `L.Select`.
extension L {
    enum Select {
        private static var zh: Bool { L.lang == .zh }
        private static func papers(_ n: Int) -> String { zh ? "\(n) 篇" : (n == 1 ? "1 paper" : "\(n) papers") }

        // MARK: Edit ▸ Select ▸ … (the Lead's menu) and the toolbar's Select ▾

        static var submenu: String { zh ? "选择" : "Select" }
        static var allPapers: String { zh ? "选择全部论文" : "All Papers" }
        static var none: String { zh ? "取消选择" : "Deselect All" }
        static var menu: String { zh ? "选择" : "Select" }
        static var menuHelp: String { zh ? "选择多篇论文，一次修改或导出" : "Select several papers to change or export them at once" }
        static var menuDisabledHint: String {
            zh ? "多选适用于论文列表（「今天」和「邮件」除外）" : "Multi-select works in the paper lists (not in Today or Mail)"
        }
        static func allIn(_ section: String) -> String { zh ? "全选「\(section)」" : "Select All in “\(section)”" }
        static func kindTitle(_ kind: SelectN.Kind) -> String {
            switch kind {
            case .mostRecentlyAdded: return zh ? "最近添加的" : "Most Recently Added"
            case .oldestUnread: return zh ? "最早到期的待读（按 DDL）" : "Oldest Unread (by DDL)"
            case .recentlyOpened: return zh ? "最近打开的" : "Recently Opened"
            }
        }
        static func count(_ n: Int) -> String { papers(n) }
        static func allCount(_ n: Int) -> String { zh ? "全部 \(n) 篇" : "All \(n)" }

        // MARK: Selection bar

        static func selected(_ n: Int) -> String { zh ? "已选 \(n) 篇" : "\(n) selected" }
        /// The window subtitle while several papers are selected: "12 papers · 3 selected".
        static func subtitle(papers: String, selected n: Int) -> String { zh ? "\(papers) · 已选 \(n) 篇" : "\(papers) · \(n) selected" }
        static var tags: String { zh ? "标签" : "Tags" }
        static var addTag: String { zh ? "添加标签…" : "Add Tag…" }
        static var removeTag: String { zh ? "移除标签" : "Remove Tag" }
        static var noTags: String { zh ? "所选论文没有标签" : "The selected papers have no tags" }
        static func read(_ n: Int) -> String { zh ? "用 \(L.ai) 解读 \(papers(n))…" : "Read \(papers(n)) with \(L.ai)…" }
        static func reread(_ n: Int) -> String { zh ? "用 \(L.ai) 重新解读 \(papers(n))…" : "Re-read \(papers(n)) with \(L.ai)…" }
        /// The selection bar's short titles (each button's help has the full one).
        static var readShort: String { zh ? "用 \(L.ai) 解读…" : "Read with \(L.ai)…" }
        static var trashShort: String { zh ? "删除" : "Delete" }
        static var checkDuplicates: String { zh ? "检查重复" : "Check for Duplicates" }
        static var export: String { zh ? "导出" : "Export" }
        static func formatName(_ f: BatchExport.Format) -> String {
            switch f {
            case .bibtex: return "BibTeX"
            case .ris: return "RIS"
            case .csv: return "CSV"
            case .markdown: return "Markdown"
            }
        }
        static func copyAs(_ f: BatchExport.Format) -> String { zh ? "复制为 \(formatName(f))" : "Copy as \(formatName(f))" }
        static func saveAs(_ f: BatchExport.Format) -> String { zh ? "存储为 \(formatName(f))…" : "Save as \(formatName(f))…" }
        static var exportNote: String { zh ? "只导出题录信息（不含 PDF、笔记和 AI 解读）" : "Metadata only (no PDFs, notes or AI readings)" }
        static func moveToTrash(_ n: Int) -> String { zh ? "将 \(papers(n))移到最近删除" : "Move \(papers(n)) to Recently Deleted" }
        static var clear: String { zh ? "取消选择（Esc）" : "Deselect All (Esc)" }
        static var actions: String { zh ? "操作" : "Actions" }
        static func restore(_ n: Int) -> String { zh ? "恢复 \(papers(n))" : "Restore \(papers(n))" }
        static func deleteNow(_ n: Int) -> String { zh ? "永久删除 \(papers(n))…" : "Delete \(papers(n)) Permanently…" }
        static func deleteNowTitle(_ n: Int) -> String { zh ? "永久删除这 \(papers(n))论文？" : "Delete \(papers(n)) permanently?" }
        static var deleteNowBody: String {
            zh ? "这些论文的文件夹会移到废纸篓，它们的阅读清单、笔记和 AI 解读会从 PaperDeck 中移除。此操作无法在 PaperDeck 中撤销。"
               : "Their folders go to the Trash and their checklists, notes and AI readings are removed from PaperDeck. This can't be undone in PaperDeck."
        }
        static func openPDFs(_ n: Int) -> String { zh ? "打开 \(n) 个 PDF" : "Open \(n) PDFs" }
        static var copyTitles: String { zh ? "复制标题" : "Copy Titles" }

        // MARK: Toasts

        /// The toast of a committed batch (`BatchNotice.operation`).
        static func applied(_ code: String, _ n: Int) -> String {
            let p = papers(n)
            switch code {
            case "setStatus.to_read": return zh ? "已将 \(p)移到「待读」" : "Moved \(p) to To Read"
            case "setStatus.reading": return zh ? "已将 \(p)移到「在读」" : "Moved \(p) to Reading"
            case "setStatus.done": return zh ? "已将 \(p)标记为已读" : "Marked \(p) as read"
            case "setPriority.high": return zh ? "已将 \(p)设为高优先级" : "Set \(p) to high priority"
            case "setPriority.normal": return zh ? "已将 \(p)设为普通优先级" : "Set \(p) to normal priority"
            case "setPriority.low": return zh ? "已将 \(p)设为低优先级" : "Set \(p) to low priority"
            case "setCategory": return zh ? "已修改 \(p)的分类" : "Changed the category of \(p)"
            case "addTags": return zh ? "已为 \(p)添加标签" : "Added the tag to \(p)"
            case "removeTags": return zh ? "已从 \(p)移除标签" : "Removed the tag from \(p)"
            case "moveToTrash": return zh ? "已将 \(p)移到最近删除" : "Moved \(p) to Recently Deleted"
            case "pinDeadline": return zh ? "已设定 \(p)的 DDL" : "Set the deadline of \(p)"
            case "postponeDay": return zh ? "已将 \(p)推迟一天" : "Postponed \(p) by one day"
            case "postponeWeek": return zh ? "已将 \(p)推迟一周" : "Postponed \(p) by one week"
            case "unschedule": return zh ? "已将 \(p)移到未排期" : "Moved \(p) to Unscheduled"
            case "restoreAuto": return zh ? "已为 \(p)恢复自动排期" : "Rescheduled \(p) automatically"
            case "restore": return zh ? "已恢复 \(p)" : "Restored \(p)"
            case BatchOperation.rereadCode: return zh ? "已将 \(p)加入 \(L.ai) 解读队列" : "Queued \(p) for reading with \(L.ai)"
            default: return zh ? "已修改 \(p)" : "Changed \(p)"
            }
        }
        static var undo: String { zh ? "撤销" : "Undo" }
        /// A batch toast's [Undo] after the 30-second window (`UndoToken.lifetime`).
        static var undoExpired: String { zh ? "撤销已过期（仅保留 30 秒）" : "Undo expired (available for 30 seconds)" }
        /// [Undo] reached the engine too late (or the change was already undone).
        static var undoUnavailable: String { zh ? "无法撤销：撤销已过期" : "Couldn't undo: the undo has expired" }
        static func skippedDone(_ n: Int) -> String {
            zh ? "\(papers(n))已读论文的 DDL 未改动" : "\(papers(n)) marked as read kept their deadline"
        }
        static func skippedRestore(_ n: Int) -> String {
            zh ? "\(papers(n))无法恢复：库中已有同一论文" : "\(papers(n)) couldn't be restored: the same paper is in the library again"
        }
        static func copied(_ f: BatchExport.Format, _ n: Int) -> String {
            zh ? "已复制 \(papers(n))（\(formatName(f))）" : "Copied \(papers(n)) as \(formatName(f))"
        }
        static func saved(_ n: Int, _ name: String) -> String { zh ? "已将 \(papers(n))存储到「\(name)」" : "Saved \(papers(n)) to “\(name)”" }
        static var saveFailed: String { zh ? "无法存储导出文件" : "Couldn't save the export file" }
        static func exportFileName(_ n: Int) -> String { zh ? "PaperDeck-\(n)-篇论文" : "PaperDeck-\(n)-papers" }

        // MARK: Re-read confirmation

        static func rereadTitle(_ n: Int) -> String { zh ? "用 \(L.ai) 解读这 \(papers(n))论文？" : "Read \(papers(n)) with \(L.ai)?" }
        static var rereadDetail: String {
            zh ? "它们会作为普通的卡片任务排进解读队列，逐篇进行。" : "They join the reading queue as ordinary card jobs and are read one by one."
        }
        static func rereadConfirm(_ n: Int) -> String { zh ? "解读 \(papers(n))" : "Read \(papers(n))" }
        static var rereadOff: String {
            zh ? "AI 解读已关闭。在「设置 ▸ AI 解读」中开启后，才能为这些论文排队。"
               : "AI reading is off. Turn it on in Settings ▸ AI Reading to queue these papers."
        }
        /// Every selected paper waits for its own confirmation (or is marked "Never use AI").
        static var rereadNothing: String { zh ? "这些论文都不能批量解读" : "None of these papers can be read in a batch" }
        /// The papers batch "Read with AI" leaves out (`BatchOutcome.held`), for the sheet and the
        /// toast: "2 held (1 possibly unpublished, 1 under duplicate review) — open them to confirm."
        /// nil when none is held.
        static func rereadHeld(_ held: [RereadHeld]) -> String? {
            func n(_ r: RereadHold) -> Int { held.count { $0.reason == r } }
            var parts: [String] = []
            if n(.possiblyUnpublished) > 0 {
                parts.append(zh ? "\(n(.possiblyUnpublished)) 篇可能未发表" : "\(n(.possiblyUnpublished)) possibly unpublished")
            }
            if n(.duplicateReview) > 0 {
                parts.append(zh ? "\(n(.duplicateReview)) 篇待查重确认" : "\(n(.duplicateReview)) under duplicate review")
            }
            if n(.confidential) > 0 {
                parts.append(zh ? "\(n(.confidential)) 篇标为保密" : "\(n(.confidential)) marked confidential")
            }
            var lines: [String] = []
            let waiting = n(.possiblyUnpublished) + n(.duplicateReview) + n(.confidential)
            if waiting > 0 {
                let list = parts.joined(separator: zh ? "、" : ", ")
                lines.append(zh ? "\(waiting) 篇暂缓（\(list)）——请逐篇打开确认。"
                                : "\(waiting) held (\(list)) — open them to confirm.")
            }
            let never = n(.neverAI)
            if never > 0 {
                lines.append(zh ? "\(never) 篇标为「不使用 AI」，不会解读。"
                                : (never == 1 ? "1 paper is marked “Never use AI” and is left out."
                                              : "\(never) papers are marked “Never use AI” and are left out."))
            }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
        }

        // MARK: Add tag

        static func addTagTitle(_ n: Int) -> String { zh ? "为 \(papers(n))添加标签" : "Add a Tag to \(papers(n))" }
        static var tagPlaceholder: String { zh ? "标签名" : "tag-name" }
        static var tagHint: String {
            zh ? "标签会写成小写加连字符（如 single-cell）。" : "Tags are written in lowercase with hyphens (e.g. single-cell)."
        }
        static var tagInvalid: String { zh ? "这个标签名不可用" : "That tag name can't be used" }
        static var add: String { zh ? "添加" : "Add" }
        static var frequentTags: String { zh ? "常用标签" : "Frequent tags" }

        // MARK: Multi-inspector

        static func inspectorTitle(_ n: Int) -> String { zh ? "已选 \(papers(n))论文" : "\(papers(n)) selected" }
        static func minutesLeft(_ m: Int) -> String { zh ? "约剩 \(m) 分钟" : "~\(m) min left" }
        static func withCards(_ k: Int) -> String { zh ? "\(k) 篇有 AI 卡片" : "\(k) with an AI card" }
        static func overdue(_ j: Int) -> String { zh ? "\(j) 篇逾期" : "\(j) overdue" }
        static func ddlRange(_ a: String, _ b: String) -> String { a == b ? "DDL \(a)" : "DDL \(a) – \(b)" }
        static var noDDL: String { zh ? "都没有 DDL" : "No deadlines" }
        static var papersHeader: String { zh ? "论文" : "Papers" }
        /// Below the multi-inspector's list when it shows only the first papers (`MultiInspector.listLimit`).
        static func morePapers(_ n: Int) -> String { zh ? "还有 \(n) 篇（见卡片列表）" : "+\(n) more (shown in the grid)" }
        static var showOnly: String { zh ? "只看这篇" : "Show only this paper" }
        static var removeFromSelection: String { zh ? "从所选中移除" : "Remove from the selection" }
        static var selectedA11y: String { zh ? "已选" : "Selected" }
    }
}
