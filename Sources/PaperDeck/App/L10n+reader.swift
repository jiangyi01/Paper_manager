import Foundation
import PaperDeckCore

/// Strings of the built-in reader (window, toolbar, find bar, selection and region toolbars, the
/// Settings opener option, "Open in Reader" for other surfaces). Owned by Slice C (reader). Every name sits in `L.Reader`.
extension L {
    enum Reader {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Settings ▸ General ▸ Open PDFs with

        static var openerOption: String { zh ? "PaperDeck 阅读器" : "PaperDeck Reader" }

        // MARK: Window and toolbar

        static var windowTitle: String { zh ? "PaperDeck 阅读器" : "PaperDeck Reader" }
        /// "p. 7" — a physical page; with a printed label that says something else: "p. 7 (printed 1203)".
        static func pageChip(_ physical: Int, printed: String?) -> String {
            guard let printed else { return zh ? "第 \(physical) 页" : "p. \(physical)" }
            return zh ? "第 \(physical) 页（印刷页码 \(printed)）" : "p. \(physical) (printed \(printed))"
        }
        /// The window subtitle: "Page 3 of 14" / "Page 3 of 14 · printed 1203".
        static func pageOf(_ page: Int, _ count: Int, printed: String?) -> String {
            let base = zh ? "第 \(page) 页，共 \(count) 页" : "Page \(page) of \(count)"
            guard let printed else { return base }
            return zh ? "\(base) · 印刷页码 \(printed)" : "\(base) · printed \(printed)"
        }
        static func ofCount(_ count: Int) -> String { zh ? "/ \(count) 页" : "of \(count)" }
        static var pageField: String { zh ? "页码" : "Page" }
        static var pageFieldHelp: String {
            zh ? "跳到某一页：输入页码（文件中的第几页）或论文上印的页码" : "Go to a page: its number in the file, or the page number printed on it"
        }
        static var thumbnails: String { zh ? "缩略图" : "Thumbnails" }
        static var showThumbnails: String { zh ? "显示缩略图" : "Show Thumbnails" }
        static var hideThumbnails: String { zh ? "隐藏缩略图" : "Hide Thumbnails" }
        static var zoomIn: String { zh ? "放大" : "Zoom In" }
        static var zoomOut: String { zh ? "缩小" : "Zoom Out" }
        static var actualSize: String { zh ? "实际大小" : "Actual Size" }
        static var fitWidth: String { zh ? "适合宽度" : "Fit Width" }
        static var openInPreview: String { zh ? "在「预览」中打开" : "Open in Preview" }
        static var openInPreviewHelp: String {
            zh ? "用「预览」打开这个 PDF（批注、签名、打印）" : "Open this PDF in Preview (annotate, sign, print)"
        }
        static var ask: String { zh ? "提问" : "Ask" }
        static var askHelp: String { zh ? "就这篇论文提问（AI，每次都需你点击发送）" : "Ask about this paper (AI; nothing is sent until you press Send)" }

        // MARK: Find

        static var find: String { zh ? "查找" : "Find" }
        static var findHelp: String { zh ? "在 PDF 中查找（⌘F）" : "Find in this PDF (⌘F)" }
        static var findPlaceholder: String { zh ? "在 PDF 中查找" : "Find in PDF" }
        static var findNext: String { zh ? "下一个" : "Next" }
        static var findPrevious: String { zh ? "上一个" : "Previous" }
        static func findPosition(_ i: Int, _ n: Int) -> String { zh ? "第 \(i) / \(n) 处" : "\(i) of \(n)" }
        static var findNone: String { zh ? "未找到" : "Not found" }
        static func findCapped(_ n: Int) -> String { zh ? "仅显示前 \(n) 处" : "first \(n) shown" }
        /// A find still running over a long PDF: "Searching… 40%".
        static func findSearching(_ percent: Int) -> String { zh ? "正在查找… \(percent)%" : "Searching… \(percent)%" }
        /// Matches found so far, before one after the current page: "12 found".
        static func findFound(_ n: Int) -> String { zh ? "已找到 \(n) 处" : "\(n) found" }
        static var done: String { zh ? "完成" : "Done" }

        // MARK: Selection and region toolbars

        static var copy: String { zh ? "拷贝" : "Copy" }
        static var copyQuote: String { zh ? "拷贝为引文" : "Copy as Quote" }
        static var copyQuoteHelp: String { zh ? "拷贝选中文字，附论文标题和页码" : "Copy the selection with the paper's title and page" }
        /// “…” — Title, p. 3
        static func quote(_ text: String, title: String, page: String) -> String {
            zh ? "“\(text)”——\(title)，\(page)" : "“\(text)” — \(title), \(page)"
        }
        static var copyImage: String { zh ? "拷贝图像" : "Copy Image" }
        static var copyImageHelp: String {
            zh ? "以清晰图像拷贝框选区域（直接从 PDF 渲染）" : "Copy the box as a sharp image (drawn from the PDF itself)"
        }
        static var copyText: String { zh ? "拷贝文字" : "Copy Text" }
        static var explain: String { zh ? "讲解" : "Explain" }
        static var terms: String { zh ? "术语" : "Terms" }
        static var translate: String { zh ? "翻译" : "Translate" }
        /// Ask's question field, prefilled: About “…” (p. 3):
        static func askPrefill(_ text: String, _ chip: String) -> String {
            zh ? "关于“\(text)”（\(chip)）：" : "About “\(text)” (\(chip)): "
        }
        static func askPrefillRegion(_ chip: String) -> String { zh ? "关于\(chip)框选的区域：" : "About the boxed region on \(chip): " }
        static var region: String { zh ? "框选区域" : "Select Region" }
        static var regionHelp: String {
            zh ? "拖出一个框，选中图、公式或表格（随时也可按住 ⌘ 拖动）" : "Drag a box around a figure, an equation or a table (or ⌘-drag at any time)"
        }
        static var clearRegion: String { zh ? "取消框选" : "Clear Box" }
        static var copied: String { zh ? "已拷贝" : "Copied" }

        // MARK: Going to a quote

        static func quoteNotFound(_ chip: String) -> String {
            zh ? "在\(chip)附近没有找到这段引文，已打开该页" : "The quote wasn't found near \(chip); showing the page"
        }
        static var quotePartial: String { zh ? "只找到引文的一部分，已高亮" : "Only part of the quote was found; it is highlighted" }

        // MARK: States

        static var loading: String { zh ? "正在打开…" : "Opening…" }
        static var loadingSlowHint: String {
            zh ? "仍在等待这个文件——它可能正从 iCloud 或 OneDrive 下载。" : "Still waiting for the file — it may be downloading from iCloud or OneDrive."
        }
        static var cancelOpening: String { zh ? "取消" : "Cancel" }
        static var timedOut: String { zh ? "这个 PDF 还没准备好" : "This PDF isn't available yet" }
        static var timedOutHint: String {
            zh ? "文件在规定时间内没能读取，可能仍在从云端下载。稍后再试。" : "The file couldn't be read in time; it may still be downloading from the cloud. Try again in a moment."
        }
        static var tryAgain: String { zh ? "重试" : "Try Again" }
        static var unreadable: String { zh ? "无法打开这个 PDF" : "This PDF can't be opened" }
        static var unreadableHint: String { zh ? "文件可能已损坏。可以试试在「预览」中打开。" : "The file may be damaged. Try opening it in Preview." }
        static var locked: String { zh ? "这个 PDF 有密码保护" : "This PDF is password-protected" }
        static var lockedHint: String { zh ? "在「预览」中打开并输入密码。" : "Open it in Preview and enter the password." }
        static var missingHint: String { zh ? "它可能已被移动或删除。" : "It may have been moved or deleted." }

        // MARK: Other surfaces (a context menu's or a citation panel's "Open in Reader")

        static var openInReader: String { zh ? "在 PaperDeck 阅读器中打开" : "Open in PaperDeck Reader" }
        static var openInReaderHelp: String { zh ? "在 PaperDeck 阅读器中打开（默认仍用「预览」）" : "Open in the PaperDeck Reader (Preview stays your default)" }
    }
}
