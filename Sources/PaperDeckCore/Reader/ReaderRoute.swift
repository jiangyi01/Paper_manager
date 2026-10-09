import Foundation

/// Where "open this paper's PDF" goes (READING_ASSIST_PLAN §6.4 C4; dive-ui §2.5). Preview stays the
/// default opener (`pdf.opener = "preview"`): opening a paper without a page behaves exactly as before
/// unless the user picks Settings ▸ General ▸ Open PDFs with ▸ PaperDeck Reader. Preview can't be told
/// to open at a page, so a request WITH a page (a checklist "p. N" chip, a citation) always opens the
/// built-in reader there. Pure; owned by Slice C (reader).
package enum ReaderRoute: Sendable, Equatable {
    /// The built-in reader at `page` (physical, 1-based; nil: the remembered page) with `quote`
    /// highlighted when it is found.
    case reader(page: Int?, quote: String?)
    /// Preview (`com.apple.Preview`).
    case preview
    /// The system's default app for PDFs.
    case defaultApp

    /// `pdf.opener` values. Anything else (a value from a newer build) means the default app, as
    /// before the reader.
    package enum Opener {
        package static let preview = "preview"
        package static let defaultApp = "default"
        package static let paperDeck = "paperdeck"
    }

    /// - Parameters:
    ///   - opener: `pdf.opener`.
    ///   - page: the page asked for (nil: just open the paper).
    ///   - readerAvailable: the reader ships in this build (`ReaderRouter.isAvailable`); without it
    ///     a page can't be honoured and "paperdeck" falls back to Preview, the default.
    package static func decide(opener: String, page: Int?, quote: String?, readerAvailable: Bool) -> ReaderRoute {
        let quote = quote.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if readerAvailable {
            if let page { return .reader(page: max(page, 1), quote: quote) }
            if opener == Opener.paperDeck { return .reader(page: nil, quote: quote) }
        }
        switch opener {
        case Opener.preview, Opener.paperDeck: return .preview
        default: return .defaultApp
        }
    }
}
