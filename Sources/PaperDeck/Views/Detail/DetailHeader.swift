import AppKit
import SwiftUI
import PaperDeckCore

/// 详情页头部: selectable title, authors (collapsed after 3), the
/// `Nature · 2024 · doi ↗ · research · hard` line, then the category menu and the tags on one
/// wrapping line.
struct DetailHeader: View {
    let state: AppState
    let row: PaperRow
    let lang: UILang

    @State private var authorsExpanded = false

    private var paper: Paper { row.paper }
    private var readOnly: Bool { paper.isDeleted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleView
            authorsView
            DetailMetaLine(paper: paper)
            // The category and the tags share one wrapping line.
            DetailTagsEditor(state: state, row: row, readOnly: readOnly) {
                DetailCategoryMenu(state: state, row: row, lang: lang, readOnly: readOnly)
            }
            .padding(.top, 2)
            fileNotes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleView: some View {
        // Until metadata arrives the title is the file name (italic, like the card).
        let provisional = CardText.metadataPending(paper)
        return Text(verbatim: CardText.displayTitle(paper))
            .font(.title3.weight(.semibold))
            .italic(provisional)
            .foregroundStyle(provisional ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @ViewBuilder private var authorsView: some View {
        let names = paper.authors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if names.isEmpty {
            Text(L.Detail.authorsUnknown)
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            let collapsed = names.count > 3 && !authorsExpanded
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: collapsed ? names.prefix(3).joined(separator: ", ") + ", …" : names.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if names.count > 3 {
                    Button(authorsExpanded ? L.Detail.collapseAuthors : L.Detail.expandAuthors(names.count)) {
                        withAnimation(.snappy(duration: 0.2)) { authorsExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var fileNotes: some View {
        let notes = DetailFormat.fileNotes(paper)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notes, id: \.text) { note in
                    Label {
                        Text(note.text).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: note.icon).foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

// MARK: - Venue · year · doi ↗ · type · difficulty

private struct DetailMetaLine: View {
    let paper: Paper

    private enum Part {
        case text(String)
        case badge(String)
        case link(label: String, url: URL, copy: String, help: String)
    }

    private var parts: [Part] {
        var out: [Part] = []
        // Same venue/preprint rule as the card (bioRxiv 10.1101 / 10.64898, bare arXiv ids).
        let venue = CardText.venue(paper)
        if let name = venue.name { out.append(.text(name)) }
        if venue.preprint { out.append(.badge("Preprint")) }
        if let year = paper.year { out.append(.text(String(year))) }
        if let doi = paper.ids.doi, let url = DetailFormat.doiURL(doi) {
            out.append(.link(label: "doi ↗", url: url, copy: doi, help: doi))
        }
        if let arxiv = paper.ids.arxivID, let url = DetailFormat.arxivURL(arxiv, version: paper.ids.arxivVersion) {
            let full = arxiv + (paper.ids.arxivVersion.map { "v\($0)" } ?? "")
            out.append(.link(label: "arXiv ↗", url: url, copy: full, help: "arXiv:" + full))
        }
        if let card = paper.card {
            out.append(.text(card.paperType.rawValue))
            out.append(.text(card.difficulty.rawValue))
        }
        return out
    }

    var body: some View {
        let parts = self.parts
        if !parts.isEmpty {
            DetailFlowLayout(spacing: 5, lineSpacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    if i > 0, !isBadge(part) { DetailDot() }
                    view(for: part)
                }
            }
            .font(.subheadline)
        }
    }

    private func isBadge(_ p: Part) -> Bool {
        if case .badge = p { return true }
        return false
    }

    @ViewBuilder private func view(for part: Part) -> some View {
        switch part {
        case .text(let s):
            Text(verbatim: s).foregroundStyle(.secondary).textSelection(.enabled)
        case .badge(let s):
            DetailCapsuleTag(text: s, tint: .orange)
        case .link(let label, let url, let copy, let help):
            Link(destination: url) { Text(verbatim: label) }
                .help(help)
                .contextMenu {
                    Button(L.Detail.copyValue(copy)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy, forType: .string)
                    }
                    Button(L.Detail.openLink) { NSWorkspace.shared.open(url) }
                }
        }
    }
}

// MARK: - Category

private struct DetailCategoryMenu: View {
    let state: AppState
    let row: PaperRow
    let lang: UILang
    let readOnly: Bool

    /// Selection made here that the snapshot hasn't caught up with (`.some(nil)` = 未分类).
    @State private var pending: Int64??
    @State private var showNewCategory = false
    @State private var newCategoryName = ""

    private var categories: [PaperCategory] {
        (state.snapshot?.categories.map(\.category) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var shown: PaperCategory? {
        guard let pending else { return row.category }
        return pending.flatMap { pk in categories.first { $0.pk == pk } }
    }

    private var selection: Binding<Int64?> {
        Binding(
            get: { pending ?? row.paper.categoryPK },
            set: { new in
                guard new != (pending ?? row.paper.categoryPK) else { return }
                pending = .some(new)
                let id = row.id
                state.detailRun({ _ = try await state.engine.setCategory(paperID: id, categoryPK: new) },
                                onError: { pending = nil })
            })
    }

    var body: some View {
        DetailFlowLayout(spacing: 8, lineSpacing: 6) {
            if readOnly {
                CategoryChip(category: row.category, lang: lang)
            } else {
                Menu {
                    Picker(L.Detail.category, selection: selection) {
                        Text(L.Detail.uncategorized).tag(Int64?.none)
                        ForEach(categories) { c in
                            Text(verbatim: c.name).tag(Int64?.some(c.pk))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button(L.Detail.newCategory) {
                        newCategoryName = ""
                        showNewCategory = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        CategoryChip(category: shown, lang: lang)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.Detail.categoryHelp)
                .accessibilityLabel(L.Detail.category)

                if row.paper.needsReview, row.paper.categoryPK != nil {
                    // Tag + action wrap together.
                    HStack(spacing: 6) {
                        DetailCapsuleTag(text: L.Detail.categoryNeedsReview, systemImage: "questionmark.circle", tint: .orange)
                            .help(L.Detail.categoryNeedsReviewHelp)
                        Button(L.Detail.confirmCategory) {
                            let id = row.id, pk = row.paper.categoryPK
                            state.perform { _ = try await state.engine.setCategory(paperID: id, categoryPK: pk) }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .fixedSize()
                }
            }
        }
        .onChange(of: row.paper.categoryPK) { pending = nil }
        .alert(L.Detail.newCategoryTitle, isPresented: $showNewCategory) {
            TextField(L.Detail.newCategoryPlaceholder, text: $newCategoryName)
            Button(L.Detail.create) { createCategory() }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Detail.newCategoryMessage)
        }
    }

    private func createCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = row.id
        Task {
            do {
                let c = try await state.engine.createCategory(name: name)
                _ = try await state.engine.setCategory(paperID: id, categoryPK: c.pk)
            } catch PaperOperationError.duplicateCategory(let existing) {
                // Same name already exists → just file the paper there.
                if let c = categories.first(where: { $0.name.caseInsensitiveCompare(existing) == .orderedSame }) {
                    state.perform { _ = try await state.engine.setCategory(paperID: id, categoryPK: c.pk) }
                }
            } catch {
                state.report(error)
            }
        }
    }
}

// MARK: - Tags

private struct DetailTagsEditor<Leading: View>: View {
    let state: AppState
    let row: PaperRow
    let readOnly: Bool
    /// Drawn first on the tags' line (the category menu).
    @ViewBuilder let leading: () -> Leading

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailFlowLayout(spacing: 6, lineSpacing: 6) {
                leading()
                ForEach(row.tags, id: \.name) { tag in
                    DetailTagChip(name: tag.name, origin: tag.origin,
                                  onRemove: readOnly ? nil : { remove(tag.name) })
                }
                if !readOnly { addControl }
            }
            if adding, !draft.trimmingCharacters(in: .whitespaces).isEmpty { feedback }
        }
    }

    @ViewBuilder private var addControl: some View {
        if adding {
            TextField(L.Detail.tagPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().strokeBorder(Color.accentColor.opacity(0.6)))
                .focused($fieldFocused)
                .onSubmit(add)
                .onExitCommand { finish() }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused, draft.trimmingCharacters(in: .whitespaces).isEmpty { finish() }
                }
                .onAppear { Task { @MainActor in fieldFocused = true } }
        } else {
            Button {
                draft = ""
                adding = true
            } label: {
                Label(L.Detail.addTag, systemImage: "plus")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// Live preview of `Taxonomy.normalizeTag` so the saved form is never a surprise.
    @ViewBuilder private var feedback: some View {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = Taxonomy.normalizeTag(raw) {
            if row.tags.contains(where: { $0.name == normalized }) {
                Label(L.Detail.tagExists(normalized), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if normalized != raw {
                Label(L.Detail.tagWillSaveAs(normalized), systemImage: "arrow.right.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(L.Detail.tagPressReturn, systemImage: "return")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } else {
            Label {
                Text(L.Detail.tagInvalid).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
        }
    }

    private func add() {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { finish(); return }
        guard Taxonomy.normalizeTag(raw) != nil else { return }   // the feedback line explains why
        draft = ""
        let id = row.id
        state.perform { _ = try await state.engine.addTag(paperID: id, raw) }
        fieldFocused = true                                        // ready for the next tag
    }

    private func remove(_ name: String) {
        let id = row.id
        state.perform { _ = try await state.engine.removeTag(paperID: id, name) }
    }

    private func finish() {
        draft = ""
        adding = false
    }
}
