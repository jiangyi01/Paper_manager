import AppKit
import SwiftUI
import PaperDeckCore

/// `--render … --mail-fixtures DIR`: the Mail inbox pages — inbox, one card with a row targeted by
/// a drop, a long alert digest (「其余 N 篇」), the detail inspector, 「发送给 AI 的内容」 expanded,
/// the merge popover, the sidebar and the floating panel's peek line. The `.eml` files of DIR are
/// imported into the isolated `--root` (`MailSyncActor.importEML`); the sync loop never runs,
/// nothing connects anywhere and no AI is called (the preview only builds the stdin).
enum MailInboxRenders {
    static func render(state: AppState, fixtures: URL, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        let engine = state.engine
        let files = ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        _ = await engine.mail.importEML(files)
        await engine.mail.waitUntilIdle()
        // The state's own refreshes may have read a snapshot mid-import: wait for the complete one.
        let snap = try await engine.mailSnapshot()
        var waited = 0
        while state.mailSnapshot?.cards(.pending).count != snap.cards(.pending).count && waited < 50 {
            state.scheduleMailRefresh(delay: .zero)
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let chrome = LibraryChrome()
        let previous = state.sidebar
        state.sidebar = .mail
        defer { state.sidebar = previous }

        try await PreviewRenderer.captureView(MailInboxView(state: state).environment(chrome).frame(width: 900, height: 2400),
                                              size: NSSize(width: 900, height: 2400), appearance: appearance, png("mail-inbox"))
        // The inbox column of the default 1280-pt window (sidebar 236): 1044 pt without the
        // inspector, 664 pt with it (380); 520 pt is the 900-pt minimum window with the inspector,
        // 400 pt that window with a wider sidebar too (taller pages: the cards grow when narrow).
        for (width, height) in [(1044, 2400), (664, 3000), (520, 3600), (400, 4400)] {
            let size = NSSize(width: CGFloat(width), height: CGFloat(height))
            try await PreviewRenderer.captureView(MailInboxView(state: state).environment(chrome)
                                                    .frame(width: size.width, height: size.height),
                                                  size: size, appearance: appearance, png("mail-inbox-\(width)"))
        }
        let cards = snap.cards(.pending)
        // The whole default window (split views can't be captured, so the columns side by side):
        // without the inspector, then with an advisor's card selected and the inspector open.
        let window = NSSize(width: 1280, height: 820)
        try await PreviewRenderer.captureView(
            HStack(spacing: 0) {
                LibrarySidebarView(state: state).frame(width: 236)
                Divider()
                MailInboxView(state: state).frame(maxWidth: .infinity)
            }
            .environment(chrome).frame(width: window.width, height: window.height),
            size: window, appearance: appearance, png("mail-window"))
        if let card = cards.first(where: { $0.message.senderKind == .advisor }) ?? cards.first {
            state.selectedMailID = card.id
            try await PreviewRenderer.captureView(
                HStack(spacing: 0) {
                    LibrarySidebarView(state: state).frame(width: 236)
                    Divider()
                    MailInboxView(state: state).frame(maxWidth: .infinity)
                    Divider()
                    MailDetailView(state: state, id: card.id).frame(width: 380)
                }
                .environment(chrome).frame(width: window.width, height: window.height),
                size: window, appearance: appearance, png("mail-window-inspector"))
            state.selectedMailID = nil
        }
        if let card = cards.first(where: { $0.message.senderKind == .advisor }) ?? cards.first {
            state.selectedMailID = card.id
            try await PreviewRenderer.captureView(MailDetailView(state: state, id: card.id).environment(chrome)
                                                    .frame(width: 380, height: 1600),
                                                  size: NSSize(width: 380, height: 1600), appearance: appearance,
                                                  png("mail-detail"))
            // Before the full card arrives (`Engine.mailCard(id:)`): the text's placeholder.
            try await PreviewRenderer.captureView(MailDetailView(state: state, id: card.id, loadsFullCard: false)
                                                    .environment(chrome).frame(width: 380, height: 900),
                                                  size: NSSize(width: 380, height: 900), appearance: appearance,
                                                  png("mail-detail-loading"))
            try await PreviewRenderer.captureView(MailSentPreview(state: state, card: card, aiMode: snap.aiMode, startExpanded: true)
                                                    .frame(width: 380).padding(12),
                                                  size: nil, appearance: appearance, png("mail-sent"))
            try await PreviewRenderer.captureView(MailMergePopover(state: state, card: card,
                                                                   items: MailInboxRules.mergeAllItems(card.items),
                                                                   onConfirm: { _ in }, onCancel: {}),
                                                  size: nil, appearance: appearance, png("mail-merge"))
            // A single PDF hovering a row (the registry drives the highlight).
            if let row = card.items.first(where: { MailInboxRules.actions($0).contains(.acceptsDrop) }) {
                state.dropTargets.setHovered(.mailItem(itemID: row.id))
                try await PreviewRenderer.captureView(MailCardView(state: state, card: card, aiMode: snap.aiMode)
                                                        .frame(width: 820).padding(12),
                                                      size: nil, appearance: appearance, png("mail-card-drop"))
                state.dropTargets.setHovered(nil)
            }
        }
        // A long digest (synthetic rows from a real alert card) → 「其余 N 篇」.
        if let alert = cards.first(where: { MailInboxRules.isDigest($0.message) && !$0.items.isEmpty }) {
            var items: [MailItem] = []
            for i in 0..<14 {
                var item = alert.items[i % alert.items.count]
                item.id = UUID().uuidString.lowercased()
                item.pk = Int64(100_000 + i)
                item.ord = i
                item.relevance = i == 5 ? .requested : (i == 2 || i == 9 ? .highlighted : .listed)
                items.append(item)
            }
            let long = MailCard(message: alert.message, items: items, rule: alert.rule, account: alert.account)
            try await PreviewRenderer.captureView(MailCardView(state: state, card: long, aiMode: snap.aiMode)
                                                    .frame(width: 820).padding(12),
                                                  size: nil, appearance: appearance, png("mail-card-digest"))
        }
        try await PreviewRenderer.captureView(LibrarySidebarView(state: state).environment(chrome).frame(width: 250, height: 780),
                                              size: NSSize(width: 250, height: 780), appearance: appearance, png("mail-sidebar"))
        try await PreviewRenderer.captureView(PeekList(state: state, onOpenPaper: { _ in }, onOpenToday: {}).frame(width: 280),
                                              size: nil, appearance: appearance, png("mail-peek"))
    }
}
