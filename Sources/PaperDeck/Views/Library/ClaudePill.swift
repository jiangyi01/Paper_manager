import AppKit
import SwiftUI
import PaperDeckCore

// MARK: - Status summary (pill, sidebar footer, banners)

/// One reading of `AgentQueueStatus` for the library chrome: text + symbol +
/// tone. Colour always comes with text (never colour-only).
struct ClaudePillStatus: Equatable {
    enum Kind: Equatable { case checking, off, notInstalled, notLoggedIn, unsupported, limited, active, held, ready }
    enum Tone: Equatable { case neutral, good, busy, warning, error }

    var kind: Kind
    var text: String
    var symbol: String
    var tone: Tone

    init(_ s: AgentQueueStatus, now: Date = Date()) {
        let running = s.runningPaperID == nil ? 0 : 1
        let kind = s.shownKind
        let provider = s.shownProvider
        if s.mode == .off || s.provider == .disabled {
            self.init(.off, L.Shell.pillOff, "sparkles", .neutral)
            return
        }
        // Mock mode never talks to the CLI, so provider problems don't apply.
        if s.mode.providerKind != nil {
            switch provider {
            case .notInstalled: self.init(.notInstalled, L.Shell.pillNotInstalled(kind), "exclamationmark.triangle.fill", .error); return
            case .notLoggedIn: self.init(.notLoggedIn, L.Shell.pillNeedsLogin, "person.crop.circle.badge.exclamationmark", .error); return
            case .unsupported: self.init(.unsupported, L.Shell.pillUnsupported, "exclamationmark.triangle.fill", .error); return
            default: break
            }
        }
        if let until = s.pausedUntil, until > now {
            self.init(.limited, L.Shell.pillLimited(ClaudePillStatus.clock(until, now: now)), "hourglass", .warning)
        } else if running > 0 {
            self.init(.active, L.Shell.pillActive(running: running, queued: s.queued), "sparkles", .busy)
        } else if s.triageRunning {
            // The one AI slot is analyzing an email (mail triage lane); queued papers wait behind it.
            self.init(.active, L.Shell.pillTriageRunning, "sparkles", .busy)
        } else if s.queued > 0 {
            self.init(.active, L.Shell.pillActive(running: 0, queued: s.queued), "sparkles", .busy)
        } else if s.triageQueued > 0 {
            self.init(.active, L.Shell.pillTriageQueued(s.triageQueued), "sparkles", .busy)
        } else if s.held > 0 {
            self.init(.held, L.Shell.pillHeld(s.held), "pause.circle", .warning)
        } else if s.mode.providerKind != nil, provider == .unknown {
            self.init(.checking, L.Shell.pillChecking(kind), "sparkles", .neutral)
        } else {
            self.init(.ready, L.Shell.pillReady(kind), "sparkles", .good)
        }
    }

    private init(_ kind: Kind, _ text: String, _ symbol: String, _ tone: Tone) {
        self.kind = kind; self.text = text; self.symbol = symbol; self.tone = tone
    }

    var color: Color {
        switch tone {
        case .neutral: .secondary
        case .good: .green
        case .busy: .purple
        case .warning: .orange
        case .error: .red
        }
    }

    var needsAttention: Bool { tone == .error }

    /// `15:45`, or `10/2 15:45` when the time is not today.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return cal.isDate(date, inSameDayAs: now) ? time : "\(c.month ?? 0)/\(c.day ?? 0) \(time)"
    }

    /// `0:24`, `12:05`, `1:02:03`.
    static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Small status dot; pulses while Claude / ChatGPT is reading.
struct ClaudePillDot: View {
    let summary: ClaudePillStatus
    var body: some View {
        Image(systemName: summary.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(summary.color)
            .symbolEffect(.pulse, options: .repeating, isActive: summary.kind == .active)
            .accessibilityHidden(true)
    }
}

// MARK: - Toolbar pill

/// Toolbar pill: `阅读中 1 · 排队 2` / `额度用尽 15:45` / `需要登录` / `解读已关闭`.
/// Click → queue popover.
struct ClaudePill: View {
    let state: AppState
    @State private var showQueue = false

    var body: some View {
        let summary = ClaudePillStatus(state.agentStatus)
        Button { showQueue.toggle() } label: {
            HStack(spacing: 5) {
                ClaudePillDot(summary: summary)
                Text(summary.text)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .help(L.Shell.queueTitle(state.agentStatus.shownKind))
        .accessibilityLabel(L.Shell.claudeStatusA11y(state.agentStatus.shownKind))
        .accessibilityValue(summary.text)
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            ClaudeQueuePopover(state: state)
        }
    }
}

// MARK: - Queue popover

/// Running / queued / limited / held papers with 立即解读 · 取消, plus 为现有论文排队解读.
struct ClaudeQueuePopover: View {
    let state: AppState
    @State private var confirmQueueExisting = false

    private static let listLimit = 200

    var body: some View {
        let status = state.agentStatus
        let summary = ClaudePillStatus(status)
        let entries = ClaudeQueueEntry.entries(state: state)
        let candidates = Self.existingCandidates(state)
        let aiEnabled = status.mode != .off

        VStack(alignment: .leading, spacing: 0) {
            header(status, summary)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            explanation(status, summary)
            Divider()
            if let triage = status.triageText(state.settings.language) {
                triageRow(status, text: triage)
                Divider()
            }
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                    Text(L.Shell.queueEmpty).font(.callout.weight(.medium))
                    Text(L.Shell.queueEmptyHint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.vertical, 22)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.prefix(Self.listLimit)) { entry in
                            ClaudeQueueEntryRow(state: state, entry: entry, modeOff: !aiEnabled)
                            Divider().padding(.leading, 40)
                        }
                        if entries.count > Self.listLimit {
                            Text(L.Shell.queueMore(entries.count - Self.listLimit))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            footer(status: status, candidates: candidates, aiEnabled: aiEnabled)
                .padding(12)
        }
        .frame(width: 380)
        .alert(L.Shell.queueExistingConfirmTitle(candidates.count + status.held), isPresented: $confirmQueueExisting) {
            Button(L.Shell.queueExistingConfirm) { queueExisting(candidates) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Shell.queueExistingConfirmBody)
        }
    }

    // MARK: Sections

    private func header(_ status: AgentQueueStatus, _ summary: ClaudePillStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ClaudePillDot(summary: summary).font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.Shell.queueTitle(status.shownKind)).font(.headline)
                if let detail = providerDetail(status) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(summary.text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(summary.color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(summary.color.opacity(0.14)))
        }
    }

    private func providerDetail(_ s: AgentQueueStatus) -> String? {
        if s.mode == .mock { return L.Shell.mockMode(s.shownKind) }
        if case .ready(let plan, let version) = s.shownProvider {
            return L.Shell.signedIn(plan: plan, version: "\(s.shownKind.cliName) \(version)")
        }
        return nil
    }

    @ViewBuilder
    private func explanation(_ status: AgentQueueStatus, _ summary: ClaudePillStatus) -> some View {
        switch summary.kind {
        case .off:
            NoticeBlock(symbol: "sparkles", tint: .secondary, text: L.Shell.offExplain) {
                Button(L.Shell.openAISettings) { state.router.showSettings("ai") }
            }
        case .notLoggedIn:
            NoticeBlock(symbol: "person.crop.circle.badge.exclamationmark", tint: .red, text: loginExplain(status)) {
                Button(L.Shell.openTerminal) { LibraryShellActions.openTerminal() }
                Button(L.Shell.iveLoggedIn) { wake() }.buttonStyle(.borderedProminent)
            }
        case .notInstalled:
            NoticeBlock(symbol: "exclamationmark.triangle.fill", tint: .red, text: L.Shell.notInstalledExplain(status.shownKind)) {
                Button(L.Shell.goToSettings) { state.router.showSettings("ai") }
                Button(L.Shell.recheck) { wake() }
            }
        case .unsupported:
            NoticeBlock(symbol: "exclamationmark.triangle.fill", tint: .red,
                        text: L.Shell.unsupportedExplain(status.shownKind, status.providerText(state.settings.language))) {
                Button(L.Shell.goToSettings) { state.router.showSettings("ai") }
            }
        case .limited:
            if let until = status.pausedUntil {
                NoticeBlock(symbol: "hourglass", tint: .orange,
                            text: L.Shell.limitedExplain(status.shownKind, ClaudePillStatus.clock(until)), actions: { EmptyView() })
            }
        default:
            EmptyView()
        }
    }

    /// Mail triage shares the slot: 「正在分析邮件… 0:12」 / 「2 封邮件待 AI 分析」 + 打开邮件.
    private func triageRow(_ status: AgentQueueStatus, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.triageRunning ? "envelope.open" : "envelope")
                .foregroundStyle(status.triageRunning ? AnyShapeStyle(.purple) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, options: .repeating, isActive: status.triageRunning)
                .frame(width: 20)
                .accessibilityHidden(true)
            if status.triageRunning, let since = status.triageRunningSince {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(text + " " + ClaudePillStatus.elapsed(since: since, now: ctx.date))
                }
                .font(.callout).monospacedDigit()
            } else {
                Text(text).font(.callout)
            }
            Spacer(minLength: 8)
            Button(L.Mail.peekOpenMail) { state.router.showMail(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Not signed in, or signed in with something other than the subscription (API key…).
    private func loginExplain(_ status: AgentQueueStatus) -> String {
        if case .nonSubscription = status.shownProvider.reason {
            return status.providerText(state.settings.language) + "\n" + L.Shell.needsLoginExplain(status.shownKind)
        }
        return L.Shell.needsLoginExplain(status.shownKind)
    }

    private func footer(status: AgentQueueStatus, candidates: [Int64], aiEnabled: Bool) -> some View {
        HStack(spacing: 8) {
            if status.held > 0 {
                Button(L.Shell.readAllNow(status.held)) {
                    let agents = state.engine.agents
                    Task { await agents.releaseHeld(paperPKs: nil) }
                }
                .disabled(!aiEnabled)
            }
            Spacer(minLength: 0)
            Button(L.Shell.queueExisting(candidates.count + status.held)) { confirmQueueExisting = true }
                .disabled(!aiEnabled || candidates.count + status.held == 0)
        }
        .controlSize(.small)
    }

    // MARK: Actions

    private func wake() {
        let agents = state.engine.agents
        Task { await agents.wake() }
    }

    /// Papers without a card that were never queued (ai_state none).
    private static func existingCandidates(_ state: AppState) -> [Int64] {
        (state.snapshot?.rows ?? []).filter { $0.paper.card == nil && $0.paper.aiState == .none }.map(\.paper.pk)
    }

    private func queueExisting(_ pks: [Int64]) {
        let agents = state.engine.agents
        Task {
            await agents.releaseHeld(paperPKs: nil)
            for pk in pks { await agents.enqueue(paperPK: pk, hold: false) }
        }
    }
}

// MARK: - Rows

/// A paper in the popover list.
struct ClaudeQueueEntry: Identifiable, Equatable {
    enum Phase: Int, Comparable {
        case running, queued, limited, held
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String
    var pk: Int64
    var title: String
    var phase: Phase
    var position: Int?

    static func entries(state: AppState) -> [ClaudeQueueEntry] {
        guard let rows = state.snapshot?.rows else { return [] }
        let positions = state.queuePositions
        let runningID = state.agentStatus.runningPaperID
        var out: [ClaudeQueueEntry] = []
        for row in rows {
            let p = row.paper
            let phase: Phase
            if p.id == runningID || p.aiState == .running { phase = .running }
            else {
                switch p.aiState {
                case .queued: phase = .queued
                case .limited: phase = .limited
                case .held: phase = .held
                default: continue
                }
            }
            out.append(ClaudeQueueEntry(id: p.id, pk: p.pk, title: p.title, phase: phase, position: positions[p.pk]))
        }
        return out.sorted {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            return ($0.position ?? .max, $0.title) < ($1.position ?? .max, $1.title)
        }
    }
}

private struct ClaudeQueueEntryRow: View {
    let state: AppState
    let entry: ClaudeQueueEntry
    let modeOff: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            phaseIcon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Button { state.router.showPaper(entry.id) } label: {
                    Text(entry.title)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                phaseText.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if entry.phase == .held && !modeOff {
                Button(L.Shell.readNow) {
                    let agents = state.engine.agents, pk = entry.pk
                    Task { await agents.releaseHeld(paperPKs: [pk]) }
                }
                .controlSize(.small)
            }
            Button {
                let agents = state.engine.agents, pk = entry.pk
                Task { await agents.cancel(paperPK: pk) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L.Shell.cancelJob)
            .accessibilityLabel(L.Shell.cancelJob)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var phaseIcon: some View {
        switch entry.phase {
        case .running: ProgressView().controlSize(.small).tint(.purple)
        case .queued:
            Text(entry.position.map(String.init) ?? "·")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().strokeBorder(.tertiary))
        case .limited: Image(systemName: "hourglass").foregroundStyle(.orange)
        case .held: Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var phaseText: some View {
        switch entry.phase {
        case .running:
            if let since = state.agentStatus.runningSince {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(L.Shell.statusRunning(state.agentStatus.shownKind, ClaudePillStatus.elapsed(since: since, now: ctx.date)))
                }
            } else {
                Text(L.Shell.statusRunning(state.agentStatus.shownKind, "…"))
            }
        case .queued: Text(L.Shell.statusQueued(entry.position))
        case .limited: Text(L.Shell.statusLimited)
        case .held: Text(modeOff ? L.Shell.statusHeldOff : L.Shell.statusHeld)
        }
    }
}

/// Explanation strip with actions (popover top).
private struct NoticeBlock<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.10)))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

// MARK: - Shared actions

enum LibraryShellActions {
    static func openTerminal() {
        // Synchronous open: the completion-handler variant calls back on a background queue.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
