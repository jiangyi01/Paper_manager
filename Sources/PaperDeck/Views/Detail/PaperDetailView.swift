import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The detail inspector (§8 详情页, single column): header, controls, Claude bar and the
/// card sections of one paper. Papers in 最近删除 are shown read-only with 恢复 / 永久删除.
/// Host it in the library window's `.inspector` with `state.selectedRow`.
struct PaperDetailView: View {
    let state: AppState
    let row: PaperRow

    init(state: AppState, row: PaperRow) {
        self.state = state
        self.row = row
    }

    var body: some View {
        // One identity per paper: drafts, optimistic values, pending notes and the scroll
        // position never leak from one paper into the next. Overview | Ask once the Ask tab ships.
        DetailTabsHost(state: state, row: row) {
            DetailContent(state: state, row: row)
        }
        .id(row.id)
        .onAppear { GuideActivity.record(.openedDetail) }      // Getting Started ▸ open a card
    }
}

private struct DetailContent: View {
    let state: AppState
    let row: PaperRow

    @State private var showMetadataSheet = false

    private var readOnly: Bool { row.paper.isDeleted }
    private var today: LocalDate { state.snapshot?.today.today ?? LocalDate.today() }

    var body: some View {
        let lang = L.lang
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if readOnly { DetailDeletedBanner(state: state, row: row) }
                DetailHeader(state: state, row: row, lang: lang)
                DuplicateChip(state: state, row: row)                  // dedupe (Slice B), once it ships
                if !readOnly {
                    DetailControls(state: state, row: row, today: today, lang: lang)
                    DetailAgentBar(state: state, row: row)
                }
                DetailSectionStack(state: state, row: row, onEditMetadata: { showMetadataSheet = true })
                ExplanationsSection(state: state, row: row)            // Explain (Slice A), once it ships
                if !readOnly, AssistRollout.policyToggles { PaperPolicyToggles(state: state, row: row) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { if !readOnly { editMetadataShortcut } }
        .sheet(isPresented: $showMetadataSheet) {
            MetadataEditSheet(state: state, row: state.snapshot?.row(id: row.id) ?? row,
                              isPresented: $showMetadataSheet)
        }
        .task(id: row.paper.aiSeen) { await markSeenAfterDwell() }
    }

    /// ⌘E works wherever the inspector is (the visible button sits in the 文件 section,
    /// which may be collapsed).
    private var editMetadataShortcut: some View {
        Button(L.Detail.editMetadataEllipsis) { showMetadataSheet = true }
            .keyboardShortcut("e", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    /// Looking at a fresh Claude card for a moment clears the card's blue NEW dot.
    private func markSeenAfterDwell() async {
        guard row.paper.isLive, !row.paper.aiSeen, row.paper.card != nil else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        _ = try? await state.engine.markAISeen(paperID: row.id)
    }
}

// MARK: - 最近删除

private struct DetailDeletedBanner: View {
    let state: AppState
    let row: PaperRow

    @State private var confirmPurge = false
    @State private var working = false

    private var daysLeft: Int? {
        guard let deletedAt = row.paper.deletedAt else { return nil }
        let purgeAt = deletedAt.addingTimeInterval(Engine.recentlyDeletedRetention)
        return max(0, Int((purgeAt.timeIntervalSinceNow / 86_400).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.Detail.deletedTitle, systemImage: "trash")
                .font(.headline)
            Text(daysLeft.map { L.Detail.deletedBody(daysLeft: $0) } ?? L.Detail.deletedBodyNoDate)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L.Detail.restore) { restore() }
                    .buttonStyle(.borderedProminent)
                Button(L.Detail.deleteNowEllipsis, role: .destructive) { confirmPurge = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(working)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
        .confirmationDialog(L.Detail.deleteNowConfirmTitle, isPresented: $confirmPurge, titleVisibility: .visible) {
            Button(L.Detail.deleteNow, role: .destructive) { purge() }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Detail.deleteNowConfirmMessage)
        }
    }

    private func restore() {
        working = true
        let id = row.id
        state.detailRun({
            _ = try await state.engine.restore(paperID: id)
            working = false
        }, onError: { working = false })
    }

    private func purge() {
        working = true
        let id = row.id
        state.detailRun({
            try await state.engine.deleteNow(paperID: id)
            if state.selectedPaperID == id { state.selectedPaperID = nil }
        }, onError: { working = false })
    }
}
