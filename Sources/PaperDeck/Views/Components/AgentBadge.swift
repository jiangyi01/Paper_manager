import SwiftUI
import PaperDeckCore

/// What a click on an actionable AgentBadge asks for (§8 AgentBadge「点击」列).
enum AgentBadgeAction: Sendable, Equatable {
    case openAISettings     // held (mode off) / needs login → 设置 ▸ AI
    case confirmHeld        // held (batch awaiting confirmation) → batch dialog
    case retry              // failed → queue again
}

/// Installed by a container that has an AppState (see `agentBadgeActions(_:)`); badges
/// without a handler in their environment render as plain, non-interactive capsules.
nonisolated struct AgentBadgeHandler: Sendable {
    var perform: @MainActor @Sendable (AgentBadgeAction, Paper) -> Void
}

nonisolated private struct AgentBadgeHandlerKey: EnvironmentKey {
    static let defaultValue: AgentBadgeHandler? = nil
}

extension EnvironmentValues {
    nonisolated var agentBadgeHandler: AgentBadgeHandler? {
        get { self[AgentBadgeHandlerKey.self] }
        set { self[AgentBadgeHandlerKey.self] = newValue }
    }
}

extension View {
    /// Makes every AgentBadge below this view clickable with the §8 default actions.
    func agentBadgeActions(_ state: AppState) -> some View {
        environment(\.agentBadgeHandler, AgentBadgeHandler { action, paper in
            CardActions.handleBadge(action, paper: paper, state: state)
        })
    }
}

/// AI (Claude / ChatGPT) status capsule shown on the card thumbnail (§8 AgentBadge table).
struct AgentBadge: View {
    let paper: Paper
    let status: AgentQueueStatus
    let queuePosition: Int?
    let lang: UILang

    @Environment(\.agentBadgeHandler) private var handler
    @State private var hovering = false

    init(paper: Paper, status: AgentQueueStatus, queuePosition: Int?, lang: UILang) {
        self.paper = paper
        self.status = status
        self.queuePosition = queuePosition
        self.lang = lang
    }

    /// The badge state for a paper, or nil when nothing should be shown.
    enum Kind: Equatable {
        case modeOff, awaitingConfirmation, queued(Int?), running(since: Date?), failed
        case limited(until: Date?), needsLogin, skipped, textIncomplete, fresh
    }

    static func kind(for paper: Paper, status: AgentQueueStatus, queuePosition: Int?) -> Kind? {
        let partialText = paper.textQuality == .partial || paper.textQuality == .poor
        switch paper.aiState {
        case .held:
            return paper.aiNote == AgentQueue.modeOffNote || status.mode == .off ? .modeOff : .awaitingConfirmation
        case .queued:
            return .queued(queuePosition)
        case .running:
            return .running(since: status.runningPaperID == paper.id ? status.runningSince : nil)
        case .failed:
            return .failed
        case .limited:
            return .limited(until: status.pausedUntil)
        case .needsLogin:
            return .needsLogin
        case .skipped:
            return .skipped
        case .done:
            if partialText { return .textIncomplete }
            return paper.aiSeen ? nil : .fresh
        case .none:
            return partialText ? .textIncomplete : nil
        }
    }

    var body: some View {
        if let kind = Self.kind(for: paper, status: status, queuePosition: queuePosition) {
            let action = Self.action(for: kind)
            if let action, let handler {
                Button { handler.perform(action, paper) } label: { capsule(kind, interactive: true) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help(help(kind) ?? "")
                    .accessibilityHint(help(kind) ?? "")
            } else {
                capsule(kind, interactive: false)
                    .help(help(kind) ?? "")
            }
        }
    }

    private static func action(for kind: Kind) -> AgentBadgeAction? {
        switch kind {
        case .modeOff, .needsLogin: return .openAISettings
        case .awaitingConfirmation: return .confirmHeld
        case .failed: return .retry
        default: return nil
        }
    }

    @ViewBuilder private func capsule(_ kind: Kind, interactive: Bool) -> some View {
        let tint = Self.tint(kind)
        HStack(spacing: 4) {
            icon(kind, tint: tint)
            if kind != .fresh {
                label(kind)
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(kind == .modeOff || kind == .skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
        }
        .padding(.horizontal, kind == .fresh ? 5 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(interactive && hovering ? tint.opacity(0.7) : Color.primary.opacity(0.10),
                                        lineWidth: interactive && hovering ? 1 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(kind))
        .accessibilityAddTraits(interactive ? .isButton : [])
    }

    @ViewBuilder private func icon(_ kind: Kind, tint: Color) -> some View {
        switch kind {
        case .running:
            ClaudeSpinner(color: tint)
        default:
            Image(systemName: Self.symbol(kind))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    @ViewBuilder private func label(_ kind: Kind) -> some View {
        switch kind {
        case .running(let since?):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(L.cardsBadgeRunning(status.shownKind, elapsed: Self.elapsed(from: since, to: ctx.date)))
            }
        default:
            Text(text(kind))
        }
    }

    private func text(_ kind: Kind) -> String {
        switch kind {
        case .modeOff: return L.cardsBadgeModeOff(status.shownKind)
        case .awaitingConfirmation: return L.cardsBadgeAwaiting
        case .queued(let n): return L.cardsBadgeQueued(position: n)
        case .running: return L.cardsBadgeRunning(status.shownKind, elapsed: nil)
        case .failed: return L.cardsBadgeFailed
        case .limited(let until): return L.cardsBadgeLimited(resume: until.map(Self.clock))
        case .needsLogin: return L.cardsBadgeNeedsLogin(status.shownKind)
        case .skipped: return L.cardsBadgeSkipped
        case .textIncomplete: return L.cardsBadgeTextIncomplete
        case .fresh: return L.cardsBadgeFreshA11y
        }
    }

    private func help(_ kind: Kind) -> String? {
        switch kind {
        case .modeOff, .needsLogin: return handler == nil ? nil : L.cardsBadgeHelpOpenAISettings
        case .awaitingConfirmation: return handler == nil ? nil : L.cardsBadgeHelpConfirm(status.shownKind)
        case .failed:
            let note = paper.aiNote.flatMap { $0.isEmpty ? nil : $0 }
            return [note, handler == nil ? nil : L.cardsBadgeHelpRetry].compactMap { $0 }.joined(separator: "\n")
        case .limited(let until): return until.map { L.cardsBadgeHelpLimited(status.shownKind, Self.clock($0)) }
        case .skipped: return L.cardsBadgeHelpSkipped
        case .textIncomplete: return L.cardsBadgeHelpTextIncomplete
        case .fresh: return L.cardsBadgeFreshA11y
        default: return nil
        }
    }

    private func accessibilityText(_ kind: Kind) -> String {
        if case .running(let since?) = kind {
            return L.cardsBadgeRunning(status.shownKind, elapsed: Self.elapsed(from: since, to: Date()))
        }
        return text(kind)
    }

    private static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .modeOff: return "pause.circle"
        case .awaitingConfirmation: return "hourglass"
        case .queued: return "clock"
        case .running: return "sparkles"
        case .failed: return "exclamationmark.triangle.fill"
        case .limited: return "gauge.with.needle"
        case .needsLogin: return "person.crop.circle.badge.exclamationmark"
        case .skipped: return "eye.slash"
        case .textIncomplete: return "doc.text.magnifyingglass"
        case .fresh: return "sparkles"
        }
    }

    private static let purple = ChipPalette.dynamic(light: 0x7B3FE4, dark: 0xB58CFF)
    private static let red = ChipPalette.dynamic(light: 0xC62828, dark: 0xFF6B61)
    private static let orange = ChipPalette.dynamic(light: 0xB85A00, dark: 0xFFA94D)

    private static func tint(_ kind: Kind) -> Color {
        switch kind {
        case .modeOff, .skipped: return .secondary
        case .awaitingConfirmation, .queued: return .accentColor
        case .running, .fresh: return purple
        case .failed: return red
        case .limited, .needsLogin, .textIncomplete: return orange
        }
    }

    /// `0:24`, `12:05`, `1:02:09`.
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// `15:45` (24-hour clock in both languages, as in the §8 table).
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Small purple ring spinner for 「Claude / ChatGPT 阅读中…」 (static under Reduce Motion).
private struct ClaudeSpinner: View {
    let color: Color
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}
