import SwiftUI
import PaperDeckCore

/// Slot (READING_ASSIST_PLAN §6.1, C4): Settings ▸ General ▸ "Open PDFs with" gains the built-in
/// reader (`pdf.opener = "paperdeck"`), placed inside that picker after Preview and Default app.
/// Preview stays the default; nothing changes until the user picks this. Owned by Slice C.
struct ReaderOpenerOption: View {
    var body: some View {
        if ReaderRouter.isAvailable {
            Text(L.Reader.openerOption).tag(ReaderRoute.Opener.paperDeck)
        }
    }
}
