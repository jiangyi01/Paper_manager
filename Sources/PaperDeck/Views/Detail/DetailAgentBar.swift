import SwiftUI
import PaperDeckCore

/// Agent 条 (§8 详情页): what Claude / ChatGPT is doing with this paper and the one action that
/// makes sense now — 取消 while running/queued, 重试 after a failure, 重新解读 when done,
/// 用 Claude / ChatGPT 解读 when never read (disabled, with the reason, while agent.mode is off).
struct DetailAgentBar: View {
    let state: AppState
    let row: PaperRow

    /// The run that produced the current card (model + finish time for the done line).
    @State private var lastRun: AgentJob?

    private var paper: Paper { row.paper }
    private var modeOff: Bool { !state.settings.aiEnabled }
    private var status: AgentQueueStatus { state.agentStatus }
    /// Who would read it next (actions, hints): the chosen provider.
    private var chosen: AIProviderKind { state.settings.agentProvider }
    private var heldForModeOff: Bool { paper.aiNote == AgentQueue.modeOffNote }

    private struct Look {
        var icon: String
        var tint: Color
        var title: String
        var detail: String?
    }

    var body: some View {
        let look = self.look
        HStack(alignment: .center, spacing: 10) {
            leadingIcon(look)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                titleView(look)
                    .font(.callout.weight(.medium))
                if let detail = look.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if showsSettingsLink {
                    Button(L.Detail.goToSettings) { state.router.showSettings("ai") }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 6)
            actions
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(look.tint.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: runKey) { await loadLastRun() }
    }

    // MARK: Look per ai_state

    private var look: Look {
        switch paper.aiState {
        case .running:
            return Look(icon: "sparkles", tint: .purple, title: L.Detail.agentRunning(status.shownKind), detail: nil)
        case .queued:
            let title = state.queuePositions[paper.pk].map { L.Detail.agentQueuedPosition($0) } ?? L.Detail.agentQueued
            return Look(icon: "hourglass", tint: .blue, title: title,
                        detail: status.runningPaperID != nil ? L.Detail.agentQueuedBehind
                            : status.triageRunning ? L.Detail.agentQueuedBehindEmail : nil)
        case .held where heldForModeOff && modeOff:
            return Look(icon: "pause.circle", tint: .gray, title: L.Detail.agentModeOff(chosen), detail: L.Detail.agentModeOffDetail)
        case .held where heldForModeOff:
            // Held while reading was off; the mode is on again — the user starts it.
            return Look(icon: "pause.circle", tint: .blue, title: L.Detail.agentWaitingToStart,
                        detail: L.Detail.agentWaitingToStartDetail)
        case .held:
            return Look(icon: "hand.raised", tint: .orange, title: L.Detail.agentAwaitingConfirm,
                        detail: modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentAwaitingConfirmDetail)
        case .failed:
            let note = paper.aiNote.flatMap { $0.isEmpty ? nil : $0 }
            return Look(icon: "exclamationmark.triangle.fill", tint: .red, title: L.Detail.agentFailed,
                        detail: modeOff ? [note, L.Detail.agentModeOffExplain].compactMap { $0 }.joined(separator: "\n") : note)
        case .limited:
            let until = status.pausedUntil.map { DetailFormat.clock($0) }
            return Look(icon: "gauge.with.dots.needle.100percent", tint: .orange,
                        title: until.map { L.Detail.agentLimitedUntil($0) } ?? L.Detail.agentLimited,
                        detail: L.Detail.agentLimitedDetail)
        case .needsLogin:
            return Look(icon: "person.crop.circle.badge.exclamationmark", tint: .orange, title: L.Detail.agentNeedsLogin(status.shownKind),
                        detail: paper.aiNote.flatMap { $0.isEmpty ? nil : $0 } ?? L.Detail.agentNeedsLoginDetail(status.shownKind))
        case .skipped:
            return Look(icon: "doc.text.magnifyingglass", tint: .gray, title: L.Detail.agentSkipped,
                        detail: paper.aiNote.flatMap { $0.isEmpty ? nil : $0 })
        case .done:
            return Look(icon: "sparkles", tint: .purple, title: doneTitle, detail: doneDetail)
        case .none:
            return Look(icon: "sparkles", tint: .gray, title: L.Detail.agentNotRead(chosen),
                        detail: modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentNotReadDetail)
        }
    }

    /// `由 Claude Sonnet 解读` / `由 ChatGPT GPT-5.6-Terra 解读` — the provider and model of the run
    /// that produced the card (not the one chosen now).
    private var doneTitle: String {
        if lastRun?.provider == "mock" { return L.Detail.agentReadByMock }
        let kind = lastRun.flatMap { AIProviderKind(rawValue: $0.provider) }
        return L.Detail.agentReadBy(kind?.shortName, model: DetailFormat.modelName(lastRun?.model))
    }

    /// `9/29 10:42 · card v2 · 文本不完整`.
    private var doneDetail: String? {
        var parts: [String] = []
        if let at = lastRun?.finishedAt { parts.append(DetailFormat.dayAndTime(at)) }
        if let v = paper.cardVersion { parts.append("card v\(v)") }
        if paper.textQuality == .partial || paper.textQuality == .poor { parts.append(L.Detail.textIncomplete) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func leadingIcon(_ look: Look) -> some View {
        if paper.aiState == .running {
            ProgressView()
                .controlSize(.small)
                .tint(.purple)
        } else {
            Image(systemName: look.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(look.tint)
        }
    }

    @ViewBuilder private func titleView(_ look: Look) -> some View {
        if paper.aiState == .running, status.runningPaperID == paper.id, let since = status.runningSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: L.Detail.agentRunning(status.shownKind) + " " + DetailFormat.elapsed(context.date.timeIntervalSince(since)))
                    .monospacedDigit()
            }
        } else {
            Text(verbatim: look.title)
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        let pk = paper.pk
        let agents = state.engine.agents
        switch paper.aiState {
        case .running, .queued:
            Button(L.cancel) { Task { await agents.cancel(paperPK: pk) } }
                .help(L.Detail.agentCancelHelp)
        case .held where heldForModeOff && modeOff:
            settingsButton
        case .held:
            Button(L.Detail.agentStartNow) { Task { await agents.releaseHeld(paperPKs: [pk]) } }
                .disabled(modeOff)
                .help(modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentQuotaHelp(chosen))
        case .failed:
            Button(L.Detail.agentRetry) { Task { await agents.retry(paperPK: pk) } }
                .disabled(modeOff)
                .help(modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentQuotaHelp(chosen))
        case .needsLogin:
            settingsButton
        case .limited, .skipped:
            EmptyView()
        case .done:
            Button(L.Detail.agentReread) {
                let id = paper.id
                state.perform { try await state.engine.requestReread(paperID: id) }
            }
            .disabled(modeOff)
            .help(modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentRereadHelp(chosen))
        case .none:
            Button(L.Detail.agentReadWithClaude(chosen)) { Task { await agents.enqueue(paperPK: pk, hold: false) } }
                .disabled(modeOff)
                .help(modeOff ? L.Detail.agentModeOffExplain : L.Detail.agentQuotaHelp(chosen))
        }
    }

    /// Disabled AI actions explain themselves and link to 设置 ▸ AI 解读.
    private var showsSettingsLink: Bool {
        guard modeOff else { return false }
        switch paper.aiState {
        case .none, .failed, .done: return true
        case .held: return !heldForModeOff
        default: return false
        }
    }

    private var settingsButton: some View {
        Button(L.Detail.goToSettings) { state.router.showSettings("ai") }
    }

    // MARK: Last run

    private var runKey: String { "\(paper.id)|\(paper.cardVersion ?? 0)|\(paper.aiState.rawValue)" }

    private func loadLastRun() async {
        guard paper.card != nil else {
            lastRun = nil
            return
        }
        let pk = paper.pk
        let jobs = (try? await state.engine.db.jobs(states: [.succeeded])) ?? []
        lastRun = jobs.filter { $0.paperPK == pk }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }
}
