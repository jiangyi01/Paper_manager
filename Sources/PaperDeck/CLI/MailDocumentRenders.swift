import AppKit
import SwiftUI
import PaperDeckCore

/// `--render … --mail-fixtures DIR` (from `MailInboxRenders`): an advisor's card with a Word
/// manuscript attached, slides only their app can export, and cloud share links (SharePoint behind
/// Outlook Safe Links, a SharePoint folder, a Google Doc) — pending, while converting, after a failed
/// conversion and once converted — the inspector's stacked rows, a narrow inbox column and the
/// 「转换为 PDF 并合并」 popover. Synthetic rows only (no file is read, nothing converts, nothing
/// connects); the sender and account are the render suite's demo ones.
enum MailDocumentRenders {
    static func render(state: AppState, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        let card = demoCard(state: state)
        let aiMode = state.mailSnapshot?.aiMode ?? .ai
        func capture(_ c: MailCard, width: CGFloat, _ name: String) async throws {
            try await PreviewRenderer.captureView(MailCardView(state: state, card: c, aiMode: aiMode)
                                                    .frame(width: width).padding(12),
                                                  size: nil, appearance: appearance, png(name))
        }
        try await capture(card, width: 820, "mail-docs-card")
        try await capture(card, width: 520, "mail-docs-card-520")

        // 「转换为 PDF 并合并」 running: the row's progress line, its buttons disabled.
        let doc = card.items[0]
        MailDocumentActivity.shared.begin(doc.id)
        state.mailBusy.insert(doc.id)
        try await capture(card, width: 820, "mail-docs-converting")
        state.mailBusy.remove(doc.id)
        MailDocumentActivity.shared.end(doc.id)

        // The conversion failed: the reason stays on the row (the engine's `downloadError`).
        var failed = card
        failed.items[0].downloadError = L.lang == .zh ? "无法读取这个文档（可能已加密或已损坏）"
                                                      : "This document couldn't be read (it may be protected or damaged)"
        try await capture(failed, width: 820, "mail-docs-error")

        // Converted and added: 已合并 + 打开卡片, the original kept with the paper (Core clears
        // `documentPath` once it moved the original into the paper folder).
        var converted = card
        converted.items[0].status = .merged
        converted.items[0].pdfState = .inLibrary
        converted.items[0].paperID = "render-converted-paper"
        converted.items[0].documentPath = nil
        try await capture(converted, width: 820, "mail-docs-converted")

        // The inspector's stacked rows (380-pt column).
        try await PreviewRenderer.captureView(
            VStack(alignment: .leading, spacing: 5) {
                ForEach(card.items) { item in
                    MailItemRow(state: state, card: card, item: item, layout: .stacked)
                }
            }
            .frame(width: 348).padding(16),
            size: nil, appearance: appearance, png("mail-docs-inspector"))

        try await PreviewRenderer.captureView(MailMergePopover(state: state, card: card, items: [doc],
                                                               onConfirm: { _ in }, onCancel: {}),
                                              size: nil, appearance: appearance, png("mail-docs-convert-popover"))
    }

    /// The lab-manuscript email: an advisor's request with a .docx, a .pptx and share links.
    static func demoCard(state: AppState) -> MailCard {
        let zh = L.lang == .zh
        let rule = state.settings.mailSenders.first { $0.kind == .advisor }
        let account = state.settings.mailAccounts.first { $0.kind == .folder }
        let now = state.engine.ctx.now()
        let message = MailMessage(
            pk: 900_001, id: "a0c5d0c5-0000-4000-8000-00000000d0c5", accountID: account?.id ?? "demo-work",
            sourceRef: "render.eml", internetMessageID: "<render-docs@example.edu>",
            fromAddress: rule?.pattern ?? "jsmith@example.edu", fromName: "Prof. Jane Smith", ruleID: rule?.id,
            senderKind: .advisor, authState: .pass,
            subject: zh ? "实验室稿件初稿——周五前给些意见？" : "Lab manuscript draft — comments by Friday?",
            receivedAt: now.addingTimeInterval(-3 * 3600),
            snippet: nil,
            triageSource: .heuristic,
            triage: MailTriage(hasReadingRequest: true, requestKind: .advisorRequest,
                               summary: zh ? "请你读一下实验室的稿件初稿，周五前反馈意见。"
                                           : "Asks you to read the lab's manuscript draft and send comments by Friday.",
                               priority: .high, confidence: 0.7))
        let folder = message.id
        // Core's fields: `title` = the file name without extension ("_" → " "), the name itself in
        // `documentFileName`, the extension in `documentKind`, the original's size in `pdfBytes`.
        let items = [
            MailItem(pk: 900_101, id: "d0c5d0c5-0001-4000-8000-000000000001", messagePK: message.pk, ord: 0, cand: "c1",
                     origin: .document, title: "Smith lab manuscript v3", relevance: .requested,
                     pdfState: .convertible, pdfBytes: 7_549_747,
                     documentFileName: "Smith_lab_manuscript_v3.docx", documentKind: "docx", documentPath: folder + "/1.docx",
                     documentSHA256: String(repeating: "a", count: 64)),
            MailItem(pk: 900_102, id: "d0c5d0c5-0002-4000-8000-000000000002", messagePK: message.pk, ord: 1, cand: "c2",
                     origin: .shareLink,
                     url: "https://contoso-my.sharepoint.com/:w:/g/personal/jsmith_contoso_edu/EaBcD1234567?e=AbCdEf",
                     urlOriginal: "https://nam10.safelinks.protection.outlook.com/?url=https%3A%2F%2Fcontoso-my.sharepoint.com%2F%3Aw%3A%2Fg%2Fpersonal%2Fjsmith_contoso_edu%2FEaBcD1234567%3Fe%3DAbCdEf&data=05",
                     host: "contoso-my.sharepoint.com", relevance: .requested, pdfState: .needsPDF,
                     documentKind: "docx", shareHost: "sharepoint.com"),
            MailItem(pk: 900_103, id: "d0c5d0c5-0003-4000-8000-000000000003", messagePK: message.pk, ord: 2, cand: "c3",
                     origin: .document, title: "Lab meeting figures", pdfState: .openOnly, pdfBytes: 3_212_000,
                     documentFileName: "Lab_meeting_figures.pptx", documentKind: "pptx", documentPath: folder + "/2.pptx"),
            MailItem(pk: 900_104, id: "d0c5d0c5-0004-4000-8000-000000000004", messagePK: message.pk, ord: 3, cand: "c4",
                     origin: .shareLink,
                     url: "https://contoso-my.sharepoint.com/:f:/g/personal/jsmith_contoso_edu/EkFolder9876?e=QwErTy",
                     urlOriginal: "https://contoso-my.sharepoint.com/:f:/g/personal/jsmith_contoso_edu/EkFolder9876?e=QwErTy",
                     host: "contoso-my.sharepoint.com", pdfState: .needsPDF, shareHost: "sharepoint.com"),
            MailItem(pk: 900_105, id: "d0c5d0c5-0005-4000-8000-000000000005", messagePK: message.pk, ord: 4, cand: "c5",
                     origin: .shareLink, url: "https://docs.google.com/document/d/1AbCdEfGhIjKlMn/edit?usp=sharing",
                     urlOriginal: "https://docs.google.com/document/d/1AbCdEfGhIjKlMn/edit?usp=sharing",
                     host: "docs.google.com", pdfState: .needsPDF, shareHost: "docs.google.com"),
        ]
        return MailCard(message: message, items: items, rule: rule, account: account)
    }
}
