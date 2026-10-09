import Foundation
import Testing
@testable import PaperDeckCore

/// Chips, row actions, 「全部合并」, drop matching and card counts for document / shared-file rows.
@Suite struct DocumentInboxRulesTests {
    typealias R = MailInboxRules

    private func doc(_ state: MailPDFState, kind: String = "docx", stored: Bool = true,
                     status: MailItemStatus = .pending) -> MailItem {
        MailItem(ord: 1, cand: "c1", origin: .document, title: "Lab manuscript", relevance: .highlighted, pdfState: state,
                 status: status, documentFileName: "Lab_manuscript.\(kind)", documentKind: kind,
                 documentPath: stored ? "0f8fad5b-d9cb-469f-a165-70867728950e/1.\(kind)" : nil)
    }

    private func share(_ state: MailPDFState = .needsPDF, url: String = "https://gowustl-my.sharepoint.com/:w:/g/personal/j/Ea") -> MailItem {
        MailItem(ord: 2, cand: "c2", origin: .shareLink, url: url, urlOriginal: DocKit.safeLink(url),
                 host: "gowustl-my.sharepoint.com", relevance: .highlighted, pdfState: state, shareHost: "sharepoint.com")
    }

    @Test func chipsOfTheNewRows() {
        #expect(R.chip(doc(.convertible)) == .convertible)
        #expect(R.chip(doc(.convertible, stored: false)) == .needsPDF)              // the copy is gone
        #expect(R.chip(doc(.openOnly, kind: "pptx")) == .openOnly)
        #expect(R.chip(doc(.needsPDF)) == .needsPDF)
        #expect(R.chip(share()) == .shareLink)
        #expect(R.chip(share(.unknown)) == .shareLink)                               // never "downloadable"
        #expect(R.chip(share(.downloadable, url: "https://www.dropbox.com/s/a/paper.pdf?dl=1")) == .shareLink)
        #expect(R.chip(doc(.convertible, status: .merged)) == .merged)
        #expect(R.chip(doc(.convertible, status: .skipped)) == .skipped)
        #expect(R.chip(doc(.hasPDF)) == .attachment)
        #expect(Set(R.ItemChip.allCases).isSuperset(of: [.convertible, .openOnly, .shareLink]))
    }

    @Test func actionsOfTheNewRows() {
        let convertible = R.actions(doc(.convertible))
        #expect(convertible == [.convertAndMerge, .openDocument, .skip, .acceptsDrop])
        let slides = R.actions(doc(.openOnly, kind: "pptx"))
        #expect(slides == [.openDocument, .skip, .acceptsDrop, .dropBox])
        let gone = R.actions(doc(.convertible, stored: false))
        #expect(gone == [.skip, .acceptsDrop, .dropBox])
        let link = R.actions(share())
        #expect(link == [.openLink, .skip, .acceptsDrop, .dropBox])
        #expect(R.linkURL(share())?.host?.contains("safelinks") == true)            // the original link opens
        let merged = R.actions({ var d = doc(.inLibrary, status: .merged); d.paperID = "p1"; d.documentPath = nil; return d }())
        #expect(merged == [.openCard])
        // A skipped document can still be converted.
        #expect(R.actions(doc(.convertible, status: .skipped)).contains(.convertAndMerge))
        #expect(!R.actions(doc(.convertible, status: .skipped)).contains(.skip))
        #expect(R.ItemActions.convertAndMerge.rawValue == 1 << 8 && R.ItemActions.openDocument.rawValue == 1 << 9)
    }

    @Test func addAllNeverTakesDocumentsOrSharedFiles() {
        var pdf = MailItem(ord: 3, cand: "c3", origin: .attachment, relevance: .highlighted, pdfState: .hasPDF)
        pdf.pdfPath = "x/3.pdf"
        let items = [doc(.convertible), doc(.openOnly, kind: "pptx"), share(), pdf]
        #expect(R.mergeAllItems(items).map(\.cand) == ["c3"])
    }

    @Test func aPDFDroppedOnTheCardFindsTheDocumentRow() {
        for row in [doc(.convertible), doc(.openOnly, kind: "pptx"), share()] {
            #expect(R.matchDroppedPDF(ids: PaperIDs(), title: "Something else entirely", items: [row], soleFallback: true)?.id == row.id)
        }
        // Not when it is one of several waiting rows.
        #expect(R.matchDroppedPDF(ids: PaperIDs(), title: nil, items: [doc(.convertible), share()], soleFallback: true) == nil)
    }

    @Test func cardCountsAndTheMatcher() {
        let m = MailMessage(accountID: "a", internetMessageID: "<c@x>", fromAddress: "p@x", senderKind: .advisor,
                            subject: "s", receivedAt: Date())
        let card = MailCard(message: m, items: [doc(.convertible), doc(.openOnly, kind: "pptx"), share()], rule: nil, account: nil)
        #expect(card.needsPDFCount == 2 && card.readyCount == 1)
        #expect(MailMatcher.isWaiting(doc(.convertible)) && MailMatcher.isWaiting(doc(.openOnly)) && MailMatcher.isWaiting(share()))
        #expect(!MailMatcher.isWaiting(doc(.convertible, status: .merged)))
    }
}
