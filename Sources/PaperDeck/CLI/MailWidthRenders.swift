import AppKit
import SwiftUI
import PaperDeckCore

/// `--render … --mail-fixtures DIR --mail-widths "720,900,1100,1280,1440,1680,2000,2560"`: the
/// Mail inbox inside whole windows of those widths (split views can't be captured, so the columns
/// side by side): sidebar (236 pt; collapsed below 900 pt) + inbox, and from 1280 pt also with the
/// inspector open (380 pt) on an advisor's card. Only the isolated `--root`'s data; nothing
/// connects and no CLI is probed. `--mail-widths-only` skips the other inbox pages.
enum MailWidthRenders {
    /// The widths asked for on the command line, nil without `--mail-widths`.
    static func requestedWidths() -> [Int]? {
        let args = CLIArgs(CommandLine.arguments)
        guard let raw = args.value("--mail-widths") else { return nil }
        let widths = raw.split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }.filter { (400...4000).contains($0) }
        return widths.isEmpty ? nil : widths
    }

    static var widthsOnly: Bool { CLIArgs(CommandLine.arguments).has("--mail-widths-only") }

    /// One notice above the inbox (`NoticeQueue.showsOverInbox`): with the AI provider "not signed
    /// in" (a synthetic status event — no CLI is asked) the window at `width` while the inbox shows
    /// its own notice (the library's error banner must stay away), then with every inbox notice
    /// hidden for the session (the banner takes the place). Both restored afterwards.
    static func bannerCheck(state: AppState, width: Int, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        let chrome = LibraryChrome()
        let previous = state.sidebar
        let status = state.agentStatus
        let dismissals = MailNoticeDismissals.shared
        let saved = dismissals.keys
        state.sidebar = .mail
        state.selectedMailID = nil
        defer {
            state.sidebar = previous
            dismissals.restore(saved)
        }
        state.engine.events.send(.agentStatus(AgentQueueStatus(provider: .notLoggedIn("logged_out"), providerKind: .claude,
                                                               mode: .claude, queued: 1, held: 1)))
        try await Task.sleep(for: .milliseconds(300))
        let w = CGFloat(width), height: CGFloat = 900
        let sidebar: CGFloat = width < 900 ? 0 : 236
        try await PreviewRenderer.captureView(
            window(state: state, chrome: chrome, sidebar: sidebar, inspector: nil).environment(chrome).frame(width: w, height: height),
            size: NSSize(width: w, height: height), appearance: appearance,
            out.appendingPathComponent("mail-banner\(width)-inboxnotice-\(suffix).png"))
        if let snap = state.mailSnapshot {
            for notice in MailNoticePolicy.notices(snap.accounts) { dismissals.dismiss(notice.dismissKey) }
            dismissals.dismiss(MailInboxHeader.setupKey(snap))
        }
        try await PreviewRenderer.captureView(
            window(state: state, chrome: chrome, sidebar: sidebar, inspector: nil).environment(chrome).frame(width: w, height: height),
            size: NSSize(width: w, height: height), appearance: appearance,
            out.appendingPathComponent("mail-banner\(width)-inboxquiet-\(suffix).png"))
        state.engine.events.send(.agentStatus(status))
        try await Task.sleep(for: .milliseconds(300))
    }

    static func render(state: AppState, widths: [Int], appearance: NSAppearance?, out: URL, suffix: String,
                       name: String = "mail-w") async throws {
        let chrome = LibraryChrome()
        let previous = state.sidebar
        state.sidebar = .mail
        defer { state.sidebar = previous }
        let cards = state.mailSnapshot?.cards(.pending) ?? []
        let selectedCard = cards.first(where: { $0.message.senderKind == .advisor }) ?? cards.first
        let height: CGFloat = 900
        for width in widths {
            let w = CGFloat(width)
            let sidebar: CGFloat = width < 900 ? 0 : 236
            state.selectedMailID = nil
            try await PreviewRenderer.captureView(
                window(state: state, chrome: chrome, sidebar: sidebar, inspector: nil).environment(chrome).frame(width: w, height: height),
                size: NSSize(width: w, height: height), appearance: appearance,
                out.appendingPathComponent("\(name)\(width)-closed-\(suffix).png"))
            if width >= 1280, let card = selectedCard {
                state.selectedMailID = card.id
                try await PreviewRenderer.captureView(
                    window(state: state, chrome: chrome, sidebar: sidebar, inspector: card.id).environment(chrome).frame(width: w, height: height),
                    size: NSSize(width: w, height: height), appearance: appearance,
                    out.appendingPathComponent("\(name)\(width)-open-\(suffix).png"))
                state.selectedMailID = nil
            }
        }
    }

    /// The window's columns as `LibraryRootView` lays them out: the library's banners sit above the
    /// inbox too (they make room for the inbox's own notice — `NoticeQueue.showsOverInbox`).
    @ViewBuilder private static func window(state: AppState, chrome: LibraryChrome, sidebar: CGFloat, inspector: String?) -> some View {
        HStack(spacing: 0) {
            if sidebar > 0 {
                LibrarySidebarView(state: state).frame(width: sidebar)
                Divider()
            }
            VStack(spacing: 0) {
                LibraryBanners(state: state, chrome: chrome)
                MailInboxView(state: state)
            }
            .frame(maxWidth: .infinity)
            if let id = inspector {
                Divider()
                MailDetailView(state: state, id: id).frame(width: 380)
            }
        }
    }
}
