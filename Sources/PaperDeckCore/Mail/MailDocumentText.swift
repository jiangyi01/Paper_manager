import Foundation
import PaperDeckShared

/// en/zh hints for document and shared-file rows of the Mail inbox (the UI may show them under the
/// row's chip). Pure text — no I/O.
package enum MailDocumentText {
    /// Under 「转换为 PDF 并合并」: where the conversion happens and what it may lose.
    package static func conversionCaveat(_ lang: UILang) -> String {
        lang == .zh
            ? "在本机转换，不会上传。图片会集中放在文末，部分图片和复杂排版可能丢失；如需完整版本，请打开文档、导出 PDF 后拖到这一行。"
            : "Converted on this Mac — nothing is uploaded. Figures are gathered at the end and some figures or complex layouts may be lost; for an exact copy, open the document, export a PDF and drop it on this row."
    }

    /// Heading of the figures a converted Word document carries after its text (inside the PDF).
    package static func figuresHeading(_ lang: UILang) -> String {
        lang == .zh ? "原文档中的图片" : "Figures from the original document"
    }

    /// An `openOnly` row (slides, Pages): how to get its PDF.
    package static func openOnlyHint(_ lang: UILang) -> String {
        lang == .zh
            ? "请打开它，导出 PDF（文件 ▸ 导出为 ▸ PDF）后拖到这一行。"
            : "Open it, export a PDF (File ▸ Export To ▸ PDF) and drop it on this row."
    }

    /// A `shareLink` row: sign in, download, drop — PaperDeck never fetches shared files itself.
    package static func shareLinkHint(provider: String?, _ lang: UILang) -> String {
        if lang == .zh {
            let on = provider.map { "共享于 \($0)：" } ?? "共享文件："
            return on + "请在浏览器中登录并下载 PDF，再拖到这一行。PaperDeck 不会自动下载共享文件。"
        }
        let on = provider.map { "Shared on \($0) — " } ?? "Shared file — "
        return on + "sign in in your browser, download the PDF and drop it on this row. PaperDeck never downloads shared files."
    }
}
