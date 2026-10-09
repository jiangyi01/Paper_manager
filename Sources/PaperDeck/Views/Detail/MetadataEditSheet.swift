import SwiftUI
import PaperDeckCore

/// 编辑元数据 (⌘E): title, authors (one per line), venue, year, DOI, arXiv, plus
/// [从 DOI 重新获取]. Save → `editMetadata` (meta_user_edited = 1, refiled under the new
/// name). Engine refusals are shown inline via `PaperOperationError.message`.
struct MetadataEditSheet: View {
    let state: AppState
    let row: PaperRow
    @Binding var isPresented: Bool

    @State private var title: String
    @State private var authors: String
    @State private var venue: String
    @State private var year: String
    @State private var doi: String
    @State private var arxiv: String

    @State private var errorMessage: String?
    @State private var fetchNote: String?
    @State private var saving = false
    @State private var fetching = false
    /// Return in the authors editor starts a new line; it must not trigger 保存.
    @FocusState private var authorsFocused: Bool

    init(state: AppState, row: PaperRow, isPresented: Binding<Bool>) {
        self.state = state
        self.row = row
        _isPresented = isPresented
        let f = Fields(row.paper)
        _title = State(initialValue: f.title)
        _authors = State(initialValue: f.authors)
        _venue = State(initialValue: f.venue)
        _year = State(initialValue: f.year)
        _doi = State(initialValue: f.doi)
        _arxiv = State(initialValue: f.arxiv)
    }

    /// The editable form of a paper's bibliographic header.
    private struct Fields: Equatable {
        var title = "", authors = "", venue = "", year = "", doi = "", arxiv = ""

        init(_ p: Paper) {
            title = p.title
            authors = p.authors.joined(separator: "\n")
            venue = p.venue ?? ""
            year = p.year.map(String.init) ?? ""
            doi = p.ids.doi ?? ""
            arxiv = p.ids.arxivID.map { $0 + (p.ids.arxivVersion.map { "v\($0)" } ?? "") } ?? ""
        }

        init(meta: BiblioMetadata, keeping old: Fields) {
            self = old
            if let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { title = t }
            if !meta.authors.isEmpty { authors = meta.authors.joined(separator: "\n") }
            if let v = meta.venue, !v.isEmpty { venue = v }
            if let y = meta.year { year = String(y) }
            if let d = meta.ids.doi { doi = d }
            if let a = meta.ids.arxivID { arxiv = a + (meta.ids.arxivVersion.map { "v\($0)" } ?? "") }
        }
    }

    private var fields: Fields {
        get {
            var f = Fields(row.paper)
            f.title = title; f.authors = authors; f.venue = venue; f.year = year; f.doi = doi; f.arxiv = arxiv
            return f
        }
    }

    private func apply(_ f: Fields) {
        title = f.title; authors = f.authors; venue = f.venue; year = f.year; doi = f.doi; arxiv = f.arxiv
    }

    // MARK: Validation (the engine re-validates; these are for immediate feedback)

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedYear: String { year.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDOI: String { doi.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedArxiv: String { arxiv.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var yearError: String? {
        guard !trimmedYear.isEmpty else { return nil }
        guard let y = Int(trimmedYear), (1000...9999).contains(y) else { return L.Detail.metaYearInvalid }
        return nil
    }
    private var doiError: String? {
        trimmedDOI.isEmpty || FTSQuery.parseDOI(trimmedDOI) != nil ? nil : L.Detail.metaDOIInvalid
    }
    private var arxivError: String? {
        trimmedArxiv.isEmpty || FTSQuery.parseArxivID(trimmedArxiv) != nil ? nil : L.Detail.metaArxivInvalid
    }
    private var canSave: Bool {
        !trimmedTitle.isEmpty && yearError == nil && doiError == nil && arxivError == nil && !saving && !fetching
    }
    private var canFetch: Bool {
        state.settings.metadataLookup && !fetching && !saving
            && ((!trimmedDOI.isEmpty && doiError == nil) || (!trimmedArxiv.isEmpty && arxivError == nil))
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.Detail.metaSheetTitle)
                    .font(.title3.weight(.semibold))
                Text(L.Detail.metaSheetSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Divider().padding(.top, 12)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    fieldLabel(L.Detail.metaTitle)
                    TextField(L.Detail.metaTitle, text: $title, axis: .vertical)
                        .lineLimit(1...4)
                        .labelsHidden()
                }
                GridRow {
                    fieldLabel(L.Detail.metaAuthors)
                    VStack(alignment: .leading, spacing: 3) {
                        TextEditor(text: $authors)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                            .frame(height: 104)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator)
                            }
                            .focused($authorsFocused)
                            .accessibilityLabel(L.Detail.metaAuthors)
                        Text(L.Detail.metaAuthorsHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    fieldLabel(L.Detail.metaVenue)
                    TextField(L.Detail.metaVenue, text: $venue).labelsHidden()
                }
                GridRow {
                    fieldLabel(L.Detail.metaYear)
                    validated(TextField(L.Detail.metaYear, text: $year).labelsHidden().frame(width: 90), error: yearError)
                }
                Divider().gridCellColumns(2)
                GridRow {
                    fieldLabel("DOI")
                    validated(TextField("DOI", text: $doi, prompt: Text(verbatim: "10.1038/…")).labelsHidden(),
                              error: doiError)
                }
                GridRow {
                    fieldLabel("arXiv")
                    validated(TextField("arXiv", text: $arxiv, prompt: Text(verbatim: "2606.24530")).labelsHidden(),
                              error: arxivError)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(action: fetchFromIdentifier) {
                            HStack(spacing: 5) {
                                if fetching { ProgressView().controlSize(.mini) }
                                Text(L.Detail.metaFetchFromDOI)
                            }
                        }
                        .disabled(!canFetch)
                        .help(state.settings.metadataLookup ? L.Detail.metaFetchHelp : L.Detail.metadataLookupOff)
                        if let fetchNote {
                            Text(fetchNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if let errorMessage {
                Label {
                    Text(errorMessage).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            Divider()
            HStack {
                Spacer()
                Button(L.cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    HStack(spacing: 5) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text(L.Detail.save)
                    }
                }
                .keyboardShortcut(authorsFocused ? nil : .defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func validated(_ field: some View, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            field
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Actions

    private func save() {
        guard canSave else { return }
        let current = fields
        guard current != Fields(row.paper) else {
            isPresented = false                                   // nothing changed: don't mark user-edited
            return
        }
        errorMessage = nil
        saving = true
        let id = row.id
        let authorList = authors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let venue = self.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let yearValue = Int(trimmedYear)
        let title = trimmedTitle, doi = trimmedDOI, arxiv = trimmedArxiv
        Task {
            do {
                _ = try await state.engine.editMetadata(paperID: id, title: title, authors: authorList, year: yearValue,
                                                        venue: venue.isEmpty ? nil : venue,
                                                        doi: doi.isEmpty ? nil : doi,
                                                        arxivID: arxiv.isEmpty ? nil : arxiv)
                saving = false
                isPresented = false
            } catch {
                saving = false
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// [从 DOI 重新获取]. Untouched paper + same identifiers → `refreshMetadata` applies the
    /// canonical record directly (keeps it "not user-edited", brings the abstract). Otherwise
    /// the record for the typed DOI/arXiv id prefills the form; nothing is saved until 保存.
    private func fetchFromIdentifier() {
        guard canFetch else { return }
        errorMessage = nil
        fetchNote = nil
        fetching = true
        let paper = row.paper
        let doiNorm = trimmedDOI.isEmpty ? nil : FTSQuery.parseDOI(trimmedDOI)
        let arxivNorm = trimmedArxiv.isEmpty ? nil : FTSQuery.parseArxivID(trimmedArxiv)
        let sameIDs = doiNorm == paper.ids.doi?.lowercased()
            && arxivNorm?.lowercased() == paper.ids.arxivID?.lowercased()
        let untouched = fields == Fields(paper)
        let engine = state.engine
        Task {
            defer { fetching = false }
            if !paper.metaUserEdited, sameIDs, untouched {
                do {
                    let changed = try await engine.refreshMetadata(paperID: paper.id)
                    if let fresh = try await engine.db.paper(id: paper.id) { apply(Fields(fresh)) }
                    fetchNote = changed ? L.Detail.metaFetchApplied : L.Detail.metadataUnchanged
                } catch {
                    errorMessage = Self.message(for: error)
                }
                return
            }
            let resolver = MetadataResolver(fetcher: URLSessionHTTPFetcher(), cache: DBMetadataCache(db: engine.db),
                                            gate: engine.gate, mailto: state.settings.crossrefMailto)
            let meta = await resolver.resolve(ids: PaperIDs(doi: doiNorm, arxivID: arxivNorm), titleGuess: nil,
                                              firstAuthorGuess: nil, forceRefresh: true)
            if let meta, meta.title != nil || !meta.authors.isEmpty {
                apply(Fields(meta: meta, keeping: fields))
                fetchNote = L.Detail.metaFetchPrefilled(source: Self.sourceName(meta.source))
            } else {
                fetchNote = L.Detail.metaFetchNotFound
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? PaperOperationError { return e.message(L.lang) }
        return String(describing: error)
    }

    private static func sourceName(_ s: MetaSource) -> String {
        switch s {
        case .crossref: "Crossref"
        case .arxiv: "arXiv"
        case .biorxiv: "bioRxiv"
        case .openalex: "OpenAlex"
        case .pdf: "PDF"
        case .agent: "AI"          // Claude or ChatGPT (the card may come from either)
        case .user, .none: "—"
        }
    }
}
