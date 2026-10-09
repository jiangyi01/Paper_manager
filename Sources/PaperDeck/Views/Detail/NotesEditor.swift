import SwiftUI
import PaperDeckCore

/// 笔记: a TextEditor that saves 1 s after the last keystroke (`engine.setNotes`, which also
/// rewrites notes.md). Pending text is flushed when the view goes away (paper switched,
/// section collapsed, window closed). Give it `.id(paperID)` so each paper starts fresh.
struct NotesEditor: View {
    let state: AppState
    let paperID: String
    /// The stored notes (`row.paper.notes`); adopted when the user has no unsaved edits.
    let notes: String
    let readOnly: Bool

    private enum Phase: Equatable { case idle, pending, saving, saved, failed }

    @State private var text: String
    @State private var lastSaved: String
    @State private var phase: Phase = .idle
    @State private var saveTask: Task<Void, Never>?
    /// Texts this editor is saving right now (their snapshot echo is ours, never merged).
    @State private var inFlight: [String] = []

    init(state: AppState, paperID: String, notes: String, readOnly: Bool = false) {
        self.state = state
        self.paperID = paperID
        self.notes = notes
        self.readOnly = readOnly
        _text = State(initialValue: notes)
        _lastSaved = State(initialValue: notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(minHeight: 120, idealHeight: 160, maxHeight: 280)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(readOnly ? L.Detail.notesEmptyReadOnly : L.Detail.notesPlaceholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(readOnly)
                .accessibilityLabel(L.Detail.notes)
            statusLine
        }
        .onChange(of: text) { _, new in textChanged(new) }
        .onChange(of: notes) { _, stored in storedChanged(stored) }
        .onDisappear(perform: flush)
    }

    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 5) {
            switch phase {
            case .idle:
                Text(readOnly ? L.Detail.notesReadOnly : L.Detail.notesAutosave)
            case .pending:
                Circle().fill(.secondary).frame(width: 5, height: 5)
                Text(L.Detail.notesUnsaved)
            case .saving:
                ProgressView().controlSize(.mini)
                Text(L.Detail.notesSaving)
            case .saved:
                Image(systemName: "checkmark")
                Text(L.Detail.notesSaved)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(L.Detail.notesSaveFailed)
                Button(L.retry) { save(text) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func textChanged(_ new: String) {
        guard !readOnly else { return }
        saveTask?.cancel()
        guard new != lastSaved else {
            phase = phase == .pending ? .idle : phase
            return
        }
        phase = .pending
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save(new)
        }
    }

    /// The snapshot changed underneath us (our own save landing, or an external edit).
    private func storedChanged(_ stored: String) {
        if text == lastSaved {
            lastSaved = stored
            if text != stored { text = stored }
        } else if stored == text {
            lastSaved = stored
        } else if !inFlight.contains(stored),
                  let merged = NotesMerge.appendedBlocks(base: lastSaved, stored: stored, local: text) {
            // Save to Notes (Ask, Explain) appended a block while the user had unsaved edits: keep
            // both — the pending save now writes the edits with the block (R-QA-9).
            lastSaved = stored
            if merged != text { text = merged }
        }
        // Otherwise the user has unsaved edits: keep them; the pending save wins.
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        if !readOnly, text != lastSaved { save(text) }
    }

    private func save(_ value: String) {
        phase = .saving
        let id = paperID
        inFlight.append(value)
        Task {
            defer { if let i = inFlight.firstIndex(of: value) { inFlight.remove(at: i) } }
            do {
                _ = try await state.engine.setNotes(paperID: id, value)
                lastSaved = value
                phase = text == value ? .saved : .pending
            } catch {
                phase = .failed
                state.report(error)
            }
        }
    }
}
