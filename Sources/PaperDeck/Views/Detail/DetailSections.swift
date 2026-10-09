import AppKit
import SwiftUI
import PaperDeckCore

// MARK: - Disclosure section

/// One collapsible inspector section; its expansion is remembered per section
/// (`@AppStorage("detail.section.<key>")`), not per paper.
struct DetailSection<Accessory: View, Content: View>: View {
    private let title: String
    @AppStorage private var expanded: Bool
    private let accessory: (Bool) -> Accessory
    private let content: () -> Content

    init(_ title: String, key: String, expandedByDefault: Bool = true,
         @ViewBuilder accessory: @escaping (_ expanded: Bool) -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _expanded = AppStorage(wrappedValue: expandedByDefault, "detail.section." + key)
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 4)
                accessory(expanded)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(DetailDisclosureStyle())
    }
}

/// Whole header row is the toggle (chevron + title), content below; no nested indentation.
struct DetailDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(configuration.isExpanded ? L.Detail.sectionExpanded : L.Detail.sectionCollapsed)
            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity)
            }
        }
    }
}

extension DetailSection where Accessory == EmptyView {
    init(_ title: String, key: String, expandedByDefault: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, key: key, expandedByDefault: expandedByDefault, accessory: { _ in EmptyView() }, content: content)
    }
}

// MARK: - Section stack

/// TL;DR → 阅读清单 → Summary → Key contributions → Method → Results → Limitations →
/// Key terms → Data & code → Abstract → 笔记 → 文件 (§8). Card text is plain text only.
struct DetailSectionStack: View {
    let state: AppState
    let row: PaperRow
    let onEditMetadata: () -> Void

    private var paper: Paper { row.paper }

    var body: some View {
        let card = paper.card
        VStack(alignment: .leading, spacing: 12) {
            DetailSection("TL;DR", key: "tldr") { tldr(card) }

            Divider()
            DetailSection(L.Detail.checklist, key: "checklist", accessory: { expanded in
                if !expanded, row.totalCount > 0 {
                    Text(verbatim: "\(row.doneCount)/\(row.totalCount)").monospacedDigit()
                }
            }) {
                ChecklistView(state: state, row: row)
            }

            if let card {
                cardSections(card)
            } else {
                Divider()
                DetailPlaceholder(text: paper.aiState == .skipped ? L.Detail.cardSkippedPlaceholder
                                                                  : L.Detail.cardPlaceholder)
                    .padding(.vertical, 2)
            }

            if let abstract = paper.abstract?.trimmingCharacters(in: .whitespacesAndNewlines), !abstract.isEmpty {
                Divider()
                DetailSection("Abstract", key: "abstract", expandedByDefault: false) {
                    DetailParagraph(text: abstract)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            DetailSection(L.Detail.notes, key: "notes") {
                NotesEditor(state: state, paperID: row.id, notes: paper.notes, readOnly: paper.isDeleted)
                    .id(row.id)
            }

            Divider()
            DetailSection(L.Detail.file, key: "file") {
                DetailFilesSection(state: state, row: row, onEditMetadata: onEditMetadata)
            }
        }
    }

    @ViewBuilder private func tldr(_ card: ReadingCard?) -> some View {
        let text = (paper.tldr ?? card?.tldr)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            DetailParagraph(text: text)
                .font(.body.weight(.medium))
        } else {
            DetailPlaceholder(text: L.Detail.tldrPlaceholder)
        }
    }

    @ViewBuilder private func cardSections(_ card: ReadingCard) -> some View {
        if !card.summary.isEmpty {
            Divider()
            DetailSection("Summary", key: "summary") { DetailParagraph(text: card.summary) }
        }
        if !card.contributions.isEmpty {
            Divider()
            DetailSection("Key contributions", key: "contributions") { DetailBulletList(items: card.contributions) }
        }
        if !card.method.isEmpty {
            Divider()
            DetailSection("Method", key: "method") { DetailParagraph(text: card.method) }
        }
        if !card.results.isEmpty {
            Divider()
            DetailSection("Results", key: "results") { DetailBulletList(items: card.results) }
        }
        if !card.limitations.isEmpty {
            Divider()
            DetailSection("Limitations", key: "limitations") { DetailLimitations(items: card.limitations) }
        }
        if !card.keyTerms.isEmpty {
            Divider()
            DetailSection("Key terms", key: "keyTerms") { DetailKeyTerms(terms: card.keyTerms) }
        }
        if !card.resources.isEmpty {
            Divider()
            DetailSection("Data & code", key: "resources") { DetailResources(resources: card.resources) }
        }
    }
}

// MARK: - Card blocks

private struct DetailLimitations: View {
    let items: [ReadingCard.Limitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: "•").foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.source == .inferred {
                            DetailCapsuleTag(text: "inferred")
                                .help(L.Detail.inferredHelp)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct DetailKeyTerms: View {
    let terms: [ReadingCard.KeyTerm]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(terms.enumerated()), id: \.offset) { _, term in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: term.term)
                        .fontWeight(.semibold)
                    Text(verbatim: term.definition)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }
}

private struct DetailResources: View {
    let resources: [ReadingCard.Resource]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(resources.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(r.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: r.name)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(verbatim: kindName(r.kind))
                                .foregroundStyle(.tertiary)
                            if let identifier = r.identifier, !identifier.isEmpty {
                                Text(verbatim: identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.caption)
                        // Only https links on CardSanitizer's allowlist become clickable.
                        if let url = DetailFormat.allowedResourceURL(r.url) {
                            Link(destination: url) {
                                Text(verbatim: (url.host ?? url.absoluteString) + " ↗")
                            }
                            .font(.caption)
                            .help(url.absoluteString)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func icon(_ kind: ReadingCard.Resource.Kind) -> String {
        switch kind {
        case .dataset: "tablecells"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .model: "cube"
        case .protocol_: "list.bullet.clipboard"
        case .other: "link"
        }
    }

    private func kindName(_ kind: ReadingCard.Resource.Kind) -> String {
        switch kind {
        case .protocol_: "protocol"
        default: kind.rawValue
        }
    }
}

// MARK: - 文件

struct DetailFilesSection: View {
    let state: AppState
    let row: PaperRow
    let onEditMetadata: () -> Void

    @State private var sharesStorage: Bool?
    @State private var fileExists = true
    @State private var refreshing = false

    private var paper: Paper { row.paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                fact(L.Detail.fileName, paper.pdfName)
                if let pages = paper.pageCount { fact(L.Detail.pages, "\(pages)") }
                fact(L.Detail.size, DetailFormat.bytes(paper.fileSize))
                GridRow {
                    factLabel(L.Detail.path)
                    Text(verbatim: paper.relativePDFPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.pdfURL.path)
                }
                if paper.originalName != paper.pdfName, !paper.originalName.isEmpty {
                    fact(L.Detail.originalName, paper.originalName)
                }
            }

            if sharesStorage == true {
                Label(L.Detail.mayShareStorage, systemImage: "square.on.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !fileExists {
                Label {
                    Text(L.Detail.flagMissing).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "questionmark.folder").foregroundStyle(.red)
                }
                .font(.caption)
            }
            if titleLookupHeld {
                Label(L.Detail.titleKeptPrivate, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DetailFlowLayout(spacing: 8, lineSpacing: 8) {
                if paper.isLive {
                    Button(L.Detail.openPDF) { state.openPDF(row) }
                        .disabled(!fileExists)
                }
                Button(L.Detail.revealInFinder) { state.revealInFinder(row) }
                    .disabled(!fileExists)
                if paper.isLive {
                    Button(action: refreshMetadata) {
                        HStack(spacing: 4) {
                            if refreshing { ProgressView().controlSize(.mini) }
                            Text(L.Detail.refreshMetadata)
                        }
                    }
                    .disabled(refreshing || !state.settings.metadataLookup)
                    .help(refreshHelp)
                    if titleLookupHeld {
                        Button(L.Detail.lookUpMetadataOnline, action: lookUpOnline)
                            .disabled(refreshing || !state.settings.metadataLookup)
                            .help(state.settings.metadataLookup ? L.Detail.lookUpMetadataOnlineHelp : L.Detail.metadataLookupOff)
                    }
                    Button(L.Detail.editMetadataEllipsis, action: onEditMetadata)
                        .help(L.Detail.editMetadataHelp)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .task(id: row.pdfURL) {
            let url = row.pdfURL
            let facts = await Task.detached {
                (FileOps.mayShareFileContent(url), FileManager.default.fileExists(atPath: url.path))
            }.value
            sharesStorage = facts.0
            fileExists = facts.1
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            factLabel(label)
            Text(verbatim: value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func factLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var refreshHelp: String {
        if !state.settings.metadataLookup { return L.Detail.metadataLookupOff }
        return paper.metaUserEdited ? L.Detail.refreshMetadataUserEditedHelp : L.Detail.refreshMetadataHelp
    }

    /// A paper from an email whose title may not leave the Mac (`PaperFlags.titleLookupHeld`):
    /// enrichment and Refresh Metadata look it up by identifiers only until the user asks here.
    private var titleLookupHeld: Bool { paper.isLive && paper.flags.contains(.titleLookupHeld) }

    private func refreshMetadata() { runLookup(online: false) }
    private func lookUpOnline() { runLookup(online: true) }

    /// `online`: clears `titleLookupHeld` first (`Engine.lookUpMetadataOnline`), then refreshes.
    private func runLookup(online: Bool) {
        refreshing = true
        let id = row.id, userEdited = paper.metaUserEdited
        Task {
            do {
                let changed = online ? try await state.engine.lookUpMetadataOnline(paperID: id)
                                     : try await state.engine.refreshMetadata(paperID: id)
                let message = changed ? L.Detail.metadataUpdated
                    : (userEdited ? L.Detail.metadataKeptUserEdits : L.Detail.metadataUnchanged)
                state.post(Toast(kind: changed ? .success : .info, message: message))
            } catch {
                state.report(error)
            }
            refreshing = false
        }
    }
}
