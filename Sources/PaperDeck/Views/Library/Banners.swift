import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Dismissible banners at the top of the content column (§8 横幅):
/// Claude not signed in / not installed, at-risk DDLs, library folder or PDFs missing.
struct LibraryBanners: View {
    let state: AppState
    @Bindable var chrome: LibraryChrome
    @State private var libraryReachable = true

    var body: some View {
        let banners = currentBanners()
        VStack(spacing: 8) {
            ForEach(banners) { banner in
                LibraryBannerView(banner: banner) { dismiss(banner) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, banners.isEmpty ? 0 : 10)
        .padding(.bottom, banners.isEmpty ? 0 : 4)
        .animation(.snappy(duration: 0.25), value: banners.map(\.id))
        .task(id: state.snapshot?.generatedAt) { await checkLibraryFolder() }
        .onChange(of: atRiskCount) { old, new in
            // New at-risk papers bring the banner back even after 忽略.
            if new > old { state.atRiskBannerDismissed = false }
        }
    }

    // MARK: Model

    private var atRiskCount: Int { state.snapshot?.today.atRisk.count ?? 0 }

    private func currentBanners() -> [LibraryBanner] {
        var out: [LibraryBanner] = []
        let lib = state.engine.paths.library
        if !libraryReachable {
            out.append(LibraryBanner(
                id: "library-missing", tone: .error, symbol: "externaldrive.badge.exclamationmark",
                message: L.Shell.bannerLibraryMissing((lib.path as NSString).abbreviatingWithTildeInPath),
                detail: L.Shell.bannerLibraryMissingDetail,
                actions: [.init(title: L.Shell.goToSettings, prominent: true) { state.router.showSettings("library") }]))
        }
        if let b = claudeBanner() { out.append(b) }
        if let snap = state.snapshot {
            if !state.atRiskBannerDismissed, !snap.today.atRisk.isEmpty {
                let atRisk = snap.today.atRisk
                let rows = snap.rows.filter { atRisk.contains($0.id) }
                let movable = rows.count(where: { $0.paper.scheduleMode == .auto })
                let pinned = rows.count - movable
                var actions: [LibraryBanner.Action] = []
                if movable > 0 {
                    actions.append(.init(title: L.Shell.shiftAtRisk(movable), prominent: true) { shiftAtRisk() })
                }
                actions.append(.init(title: L.Shell.ignore, prominent: false) { state.atRiskBannerDismissed = true })
                out.append(LibraryBanner(
                    id: "at-risk", tone: .warning, symbol: "exclamationmark.triangle.fill",
                    message: L.Shell.bannerAtRisk(atRisk.count),
                    detail: pinned > 0 ? L.Shell.bannerAtRiskPinned(pinned) : nil,
                    actions: actions, dismissible: false))
            }
            let missing = snap.rows.count(where: { $0.paper.flags.contains(.missing) })
            let key = "missing-\(missing)"
            if missing > 0, libraryReachable, !chrome.dismissedBanners.contains(key) {
                out.append(LibraryBanner(
                    id: key, tone: .warning, symbol: "doc.questionmark",
                    message: L.Shell.bannerMissingFiles(missing), detail: nil,
                    actions: [.init(title: L.Shell.show, prominent: false) { state.sidebar = .needsAttention }]))
            }
        }
        return out.filter { !$0.dismissible || !chrome.dismissedBanners.contains($0.id) }
    }

    /// Only once the user opted into a real provider (mode claude / codex); mock/off need no CLI.
    /// Banner ids keep their `claude-` prefix (dismissal state), whichever provider it names.
    private func claudeBanner() -> LibraryBanner? {
        let s = state.agentStatus
        guard s.mode.providerKind != nil else { return nil }
        let kind = s.shownKind
        let provider = s.shownProvider
        let lang = state.settings.language
        let settings = LibraryBanner.Action(title: L.Shell.goToSettings, prominent: false) { state.router.showSettings("ai") }
        switch provider {
        case .notLoggedIn:
            return LibraryBanner(
                id: "claude-login", tone: .error, symbol: "person.crop.circle.badge.exclamationmark",
                message: L.Shell.bannerNotLoggedIn(kind),
                // Codex: 「需登录 ChatGPT：运行 codex login → Sign in with ChatGPT」; API key: 「只使用订阅登录」.
                detail: {
                    if case .nonSubscription = provider.reason { return provider.reasonText(lang, provider: kind) }
                    return kind == .codex ? provider.reasonText(lang, provider: kind) : nil
                }(),
                actions: [howToFix({ if case .nonSubscription = provider.reason { return .fixCLIAPIKey }; return .fixCLINotSignedIn }()),
                          .init(title: L.Shell.iveLoggedIn, prominent: false) { wakeAgent() },
                          .init(title: L.Shell.goToSettings, prominent: true) { state.router.showSettings("ai") }])
        case .notInstalled:
            return LibraryBanner(
                id: "claude-missing", tone: .error, symbol: "exclamationmark.triangle.fill",
                message: L.Shell.bannerNotInstalled(kind),
                detail: kind == .codex ? L.Shell.notInstalledExplain(kind) : nil,
                actions: [howToFix(.fixCLINotFound), .init(title: L.Shell.recheck, prominent: false) { wakeAgent() },
                          settings.prominent()])
        case .unsupported:
            return LibraryBanner(
                id: "claude-unsupported", tone: .error, symbol: "exclamationmark.triangle.fill",
                message: L.Shell.bannerUnsupported(kind), detail: provider.reasonText(lang, provider: kind),
                actions: [howToFix(.fixCLINotFound), settings.prominent()])
        default:
            return nil
        }
    }

    /// "How to Fix" → the Help Center's troubleshooting entry for this AI problem.
    private func howToFix(_ topic: GuideTopicID) -> LibraryBanner.Action {
        LibraryBanner.Action(title: L.Help.howToFix, prominent: false) { state.router.showHelp(topic) }
    }

    // MARK: Actions

    private func dismiss(_ banner: LibraryBanner) {
        chrome.dismissedBanners.insert(banner.id)
    }

    private func shiftAtRisk() {
        state.perform {
            let moved = try await state.engine.shiftAtRisk()
            if !moved.isEmpty {
                state.post(Toast(id: "shift-at-risk", kind: .success, message: L.Shell.shifted(moved.count)))
            }
        }
    }

    private func wakeAgent() {
        let agents = state.engine.agents
        Task { await agents.wake(forceDetect: true) }
    }

    /// A vanished volume must not stall the UI: stat off the main actor.
    private func checkLibraryFolder() async {
        let path = state.engine.paths.library.path
        let reachable = await Task.detached(priority: .utility) { () -> Bool in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }.value
        if reachable != libraryReachable { libraryReachable = reachable }
    }
}

// MARK: - Banner model + view

struct LibraryBanner: Identifiable {
    enum Tone { case info, warning, error }
    struct Action {
        var title: String
        var prominent: Bool
        var run: () -> Void
        init(title: String, prominent: Bool, run: @escaping () -> Void) {
            self.title = title; self.prominent = prominent; self.run = run
        }
        func prominent(_ on: Bool = true) -> Action { Action(title: title, prominent: on, run: run) }
    }

    var id: String
    var tone: Tone
    var symbol: String
    var message: String
    var detail: String?
    var actions: [Action]
    /// The at-risk banner uses its own 忽略 action (AppState.atRiskBannerDismissed) instead of ×.
    var dismissible = true

    var tint: Color {
        switch tone {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

struct LibraryBannerView: View {
    let banner: LibraryBanner
    let onDismiss: () -> Void

    var body: some View {
        // One row when it fits; otherwise the buttons move under the text (narrow window,
        // inspector open). Texts are line-limited, never vertically fixed: split-view columns
        // probe their minimum with a zero width and a fixed text column would force a huge height.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                icon
                texts
                actions
                closeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    texts
                    closeButton
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(banner.tint.opacity(0.08)))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(banner.tint.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: banner.symbol)
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(banner.tint)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.message).font(.callout.weight(.medium)).lineLimit(2)
            if let detail = banner.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ForEach(Array(banner.actions.enumerated()), id: \.offset) { _, action in
                if action.prominent {
                    Button(action.title, action: action.run).buttonStyle(.borderedProminent).tint(banner.tint)
                } else {
                    Button(action.title, action: action.run).buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder private var closeButton: some View {
        if banner.dismissible {
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L.Shell.dismiss)
            .accessibilityLabel(L.Shell.dismiss)
        }
    }
}
