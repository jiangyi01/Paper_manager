import SwiftUI
import PaperDeckCore

/// §6.2 批量投放: one dialog for a large drop —
/// 「已添加 N 篇 · 已按顺序排期，最后 DDL 11/20 [改为放入未排期] ·
///  为 N 篇生成 AI 卡片？每篇约 30–60 秒，占用订阅额度 [全部解读] [稍后]」.
/// Presented as a sheet on the library window from `state.pendingBatch`; the view
/// itself is self-contained (`onClose`) so other surfaces can host it too.
struct BatchDialog: View {
    let state: AppState
    let summary: ImportBatchSummary
    let onClose: () -> Void

    @State private var unscheduled = false
    @State private var unscheduling = false
    @State private var aiQueued = false

    init(state: AppState, summary: ImportBatchSummary, onClose: @escaping () -> Void) {
        self.state = state
        self.summary = summary
        self.onClose = onClose
    }

    private var aiEnabled: Bool { state.settings.agentMode != AgentMode.off.rawValue }
    private var offersAI: Bool { !summary.heldForAI.isEmpty && aiEnabled && !aiQueued }
    /// > 10 papers are placed one after another at low priority (IntakeActor.sequentialThreshold).
    private var sequential: Bool { summary.added.count > IntakeActor.sequentialThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 12) {
                if !summary.added.isEmpty { scheduleSection }
                if !summary.heldForAI.isEmpty { aiSection }
            }
            buttons
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.added.isEmpty ? L.Shell.batchAITitle(summary.heldForAI.count) : L.Shell.batchTitle(summary.added.count))
                    .font(.title3.weight(.semibold))
                if let extras = L.Shell.batchExtras(duplicates: summary.duplicates, failed: summary.failed + summary.rejected) {
                    Text(extras).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scheduleSection: some View {
        DialogSection(symbol: "calendar", tint: .orange) {
            if unscheduled {
                Label(L.Shell.madeUnscheduled, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else {
                Text(sequential ? L.Shell.batchSequential : L.Shell.batchAutomatic).font(.callout.weight(.medium))
                Text(lastDeadlineText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        } trailing: {
            if !unscheduled {
                Button(L.Shell.makeUnscheduled, action: makeUnscheduled)
                    .controlSize(.small)
                    .disabled(unscheduling)
            }
        }
    }

    @ViewBuilder private var aiSection: some View {
        DialogSection(symbol: "sparkles", tint: .purple) {
            if aiQueued {
                Label(L.Shell.batchAIQueued, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else if aiEnabled {
                if !summary.added.isEmpty {
                    Text(L.Shell.batchAITitle(summary.heldForAI.count)).font(.callout.weight(.medium))
                }
                Text(L.Shell.batchAIDetail).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(L.Shell.batchAIOff).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            if !aiEnabled {
                Button(L.Shell.openAISettings) {
                    onClose()
                    state.router.showSettings("ai")
                }
                .controlSize(.small)
            }
        }
    }

    private var buttons: some View {
        HStack {
            if offersAI {
                Text(L.Shell.batchLaterHint).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(L.Shell.later, action: onClose).keyboardShortcut(.cancelAction)
                Button(L.Shell.readAll, action: readAll)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Spacer()
                Button(L.Shell.doneButton, action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var lastDeadlineText: String {
        guard let last = summary.lastDeadline else { return L.Shell.batchNoDeadline }
        let today = state.snapshot?.today.today ?? LocalDate.today()
        return L.Shell.batchLastDeadline(SharedStrings.relativeDay(last, today: today, lang: L.lang))
    }

    // MARK: Actions

    private func makeUnscheduled() {
        unscheduling = true
        let ids = summary.added
        state.perform {
            defer { unscheduling = false }
            for id in ids { _ = try await state.engine.unschedule(paperID: id) }
            unscheduled = true
        }
    }

    private func readAll() {
        let ids = summary.heldForAI
        aiQueued = true
        state.perform {
            var pks: [Int64] = []
            for id in ids {
                if let pk = state.snapshot?.row(id: id)?.paper.pk {
                    pks.append(pk)
                } else if let pk = try await state.engine.db.paper(id: id)?.pk {
                    pks.append(pk)
                }
            }
            await state.engine.agents.releaseHeld(paperPKs: pks)
        }
        onClose()
    }
}

/// Icon + text column + trailing action, on a subtle rounded background.
private struct DialogSection<Content: View, Trailing: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
