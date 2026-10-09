import SwiftUI
import PaperDeckCore

/// Up to `maxVisible` toasts, newest last. Buttons go through
/// `AppState.handleToastAction`; × dismisses. Used by the floating panel, the
/// menu-bar popover and (optionally) the library window.
struct ToastStack: View {
    let state: AppState
    let maxVisible: Int

    init(state: AppState, maxVisible: Int = 3) {
        self.state = state
        self.maxVisible = maxVisible
    }

    var body: some View {
        let all = state.toasts
        let visible = Array(all.suffix(max(0, maxVisible)))
        let hidden = all.count - visible.count
        VStack(alignment: .leading, spacing: 8) {
            if hidden > 0 {
                Text(L.toastMore(hidden))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(visible) { toast in
                ToastCard(toast: toast,
                          onAction: { state.handleToastAction($0, toastID: toast.id) },
                          onDismiss: { state.dismissToast(toast.id) })
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .animation(.snappy(duration: 0.25), value: visible.map(\.id))
    }
}

/// One toast: kind icon (never colour alone), message, action buttons, ×.
struct ToastCard: View {
    let toast: Toast
    let onAction: (Toast.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let style = ToastStyle(toast.kind)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: 18)
                .accessibilityLabel(style.label)
            VStack(alignment: .leading, spacing: 8) {
                Text(toast.message)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !toast.buttons.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { buttons(style) }
                        VStack(alignment: .leading, spacing: 6) { buttons(style) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L.toastDismiss)
            .accessibilityLabel(L.toastDismiss)
        }
        .padding(10)
        .background(style.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style.tint.opacity(0.30), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func buttons(_ style: ToastStyle) -> some View {
        ForEach(Array(toast.buttons.enumerated()), id: \.offset) { index, button in
            Button(button.title) { onAction(button.action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(index == 0 ? style.tint : nil)
                .lineLimit(1)
        }
    }
}

private struct ToastStyle {
    let symbol: String
    let tint: Color
    let label: String

    init(_ kind: Toast.Kind) {
        switch kind {
        case .success: symbol = "checkmark.circle.fill"; tint = .green; label = L.toastKindSuccess
        case .info: symbol = "info.circle.fill"; tint = .blue; label = L.toastKindInfo
        case .warning: symbol = "exclamationmark.triangle.fill"; tint = .orange; label = L.toastKindWarning
        case .error: symbol = "xmark.octagon.fill"; tint = .red; label = L.toastKindError
        }
    }
}

extension Toast {
    /// Errors and real decisions (replace/ignore, restore, open in browser, settings)
    /// keep the panel open until handled. Convenience buttons ([查看], [设为高优先级],
    /// [撤销]) don't: a success toast must still go away on its own (§8 Toast 规则).
    var requiresAttention: Bool {
        if kind == .error { return true }
        return buttons.contains { button in
            switch button.action {
            case .replaceKeepingChecklist, .ignorePending, .restorePaper, .openInBrowser, .openSettings, .linkMailItem,
                 .openDuplicateReview:
                return true
            case .openPaper, .setHighPriority, .undo, .openMail, .undoMailLink: return false
            }
        }
    }
}

/// AppState only expires button-less toasts (`isSticky` = error or any button).
/// Toasts that merely *offer* a shortcut (e.g. 「已添加：… [查看][设为高优先级]」,
/// 「今天已跳过 [撤销]」) are dismissed here after a longer grace period, paused
/// while the pointer is over a surface that shows them.
final class ToastJanitor {
    /// A little longer than AppState's 5 s for plain toasts; undo gets most of its 30 s window.
    static func grace(for toast: Toast) -> Duration {
        toast.buttons.contains {
            switch $0.action {
            case .undo, .undoMailLink: true
            default: false
            }
        } ? .seconds(12) : .seconds(6)
    }

    private let state: AppState
    private var timers: [String: Task<Void, Never>] = [:]
    private var observer: PanelObserver?
    /// Returns true while the user is looking at the toasts (pointer over the panel).
    var isPaused: () -> Bool = { false }

    init(state: AppState) {
        self.state = state
        observer = PanelObserver { [weak self] in self?.sync() }
    }

    private func sync() {
        let toasts = state.toasts
        let live = Set(toasts.map(\.id))
        for (id, task) in timers where !live.contains(id) {
            task.cancel()
            timers[id] = nil
        }
        for toast in toasts where toast.isSticky && !toast.requiresAttention && timers[toast.id] == nil {
            let id = toast.id
            let grace = Self.grace(for: toast)
            timers[id] = Task { [weak self] in
                try? await Task.sleep(for: grace)
                while !Task.isCancelled, self?.isPaused() == true {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled, let self else { return }
                self.timers[id] = nil
                self.state.dismissToast(id)
            }
        }
    }
}
