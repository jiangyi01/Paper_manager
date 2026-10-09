import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

// MARK: - 资料库与存储

struct LibrarySettingsTab: View {
    let state: AppState

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            LibraryLocationSection(state: state)
            Section {
                Picker(L.Pref.importMode, selection: $settings.importMode) {
                    Text(L.Pref.importCopy).tag("copy")
                    Text(L.Pref.importMove).tag("move")
                }
                .pickerStyle(.radioGroup)
                Toggle(isOn: $settings.metadataLookup) {
                    Text(L.Pref.metadataLookup)
                    Text(L.Pref.metadataLookupHint)
                }
                TextField(L.Pref.crossrefMail, text: $settings.crossrefMailto, prompt: Text(L.Pref.optional))
                    .disabled(!settings.metadataLookup)
                    .autocorrectionDisabled()
            } header: {
                Text(L.Pref.importSection)
            }
            DedupeSettingsSection(state: state)                 // duplicates (Slice B), once it ships
            StorageStatsSection(state: state)
            MaintenanceSection(state: state)
            CategoryManagerSection(state: state)
        }
    }
}

/// Location, Change… and the pending switch. Change… inspects the picked folder first
/// (`LibraryFolderPicker`, `LibraryChangeDecision`): the same library just moves; another library
/// or a new empty one is switched to by the next launch (`library.pendingAction`), which backs
/// the index up first — two libraries are never mixed in one index. [Restart Now] relaunches.
private struct LibraryLocationSection: View {
    let state: AppState
    /// The decision for the folder just picked (nil: none pending confirmation).
    @State private var decision: LibraryChangeDecision?
    @State private var inspecting = false
    /// Re-read after each change (`library.pendingAction` lives in the defaults).
    @State private var pending: LibraryPendingAction?

    var body: some View {
        let current = state.engine.paths.library
        let chosen = URL(fileURLWithPath: state.settings.libraryPath, isDirectory: true)
        let pendingChange = chosen.standardizedFileURL.path != current.standardizedFileURL.path
        Section {
            LabeledContent(L.Pref.location) {
                Text(SettingsFormat.tildePath(current.path))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button(L.Pref.showInFinder) { NSWorkspace.shared.open(current) }
                Button(L.Pref.change) { Task { await choose(from: current) } }
                    .disabled(inspecting)
                if inspecting { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let decision { decisionView(decision, current: current) }
            if pendingChange {
                StatusLine(.warning, pendingText(chosen))
                HStack {
                    Button(L.Pref.keepCurrentLocation) {
                        state.settings.cancelLibraryChange(keeping: current.path)
                        pending = nil
                    }
                    if pending != nil { Button(L.Pref.restartNow) { Relaunch.now() } }
                    Spacer()
                }
                .controlSize(.small)
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.Pref.librarySection)
                HelpButton(.libraryLocation)
            }
        } footer: {
            NoteText(L.Pref.locationFooter)
        }
        .onAppear { pending = state.settings.libraryPendingAction }
    }

    private func pendingText(_ chosen: URL) -> String {
        let path = SettingsFormat.tildePath(chosen.path)
        switch pending?.kind {
        case .openExisting?: return L.Pref.switchPending(path)
        case .startNew?: return L.Pref.startPending(path)
        case nil: return L.Pref.locationPending(path)
        }
    }

    @ViewBuilder
    private func decisionView(_ d: LibraryChangeDecision, current: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch d {
            case .current:
                StatusLine(.ok, L.Pref.changeSameLibrary)
            case .useSameLibrary:
                StatusLine(.ok, L.Pref.changeSameLibrary)
            case .openOther(_, let cards):
                StatusLine(.warning, L.Pref.changeOtherLibrary(cards))
            case .suggestChild(let child, _):
                StatusLine(.pending, L.Pref.changeParent(SettingsFormat.tildePath(child.path)))
            case .startNew(_, let items):
                StatusLine(.pending, items > 0 ? L.Pref.changeOtherContent(items) : L.Pref.changeEmpty)
                NoteText(L.Pref.moveLibraryNote, symbol: "info.circle")
            case .unusable(let missing):
                StatusLine(.error, missing ? L.Pref.changeMissing : L.Pref.changeUnreadable)
            }
            HStack {
                ForEach(d.offered, id: \.self) { action in
                    Button(title(action)) { Task { await perform(action, d, current: current) } }
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func title(_ a: LibraryChangeDecision.Action) -> String {
        switch a {
        case .useThisFolder: L.Pref.useThisFolder
        case .openThisLibrary: L.Pref.openThisLibrary
        case .useChild: L.Pref.useIt
        case .startNewLibrary: L.Pref.startNewLibrary
        case .chooseAnother: L.Pref.chooseAnotherLibrary
        }
    }

    private func perform(_ a: LibraryChangeDecision.Action, _ d: LibraryChangeDecision, current: URL) async {
        switch a {
        case .chooseAnother:
            decision = nil
            await choose(from: current)
        case .useChild:
            guard case .suggestChild(let child, _) = d else { return }
            await inspect(child, current: current)
        case .useThisFolder, .openThisLibrary, .startNewLibrary:
            guard let c = d.confirmation(previous: current) else { return }
            state.settings.scheduleLibraryChange(path: c.path, pending: c.pending, previousPath: current.path)
            pending = state.settings.libraryPendingAction
            decision = nil
        }
    }

    private func choose(from current: URL) async {
        guard let picked = await LibraryFolderPicker.pick(startingAt: current.deletingLastPathComponent(),
                                                          prompt: L.Pref.chooseLibraryMessage) else { return }
        await decide(picked.url, kind: picked.kind, current: current)
    }

    private func inspect(_ url: URL, current: URL) async {
        inspecting = true
        let kind = await LibraryInspector.inspect(url)
        await decide(url, kind: kind, current: current)
    }

    private func decide(_ url: URL, kind: LibraryFolderKind, current: URL) async {
        inspecting = true
        let id = try? await state.engine.db.kv("library.id")
        decision = LibraryChangeDecision.decide(url, kind: kind, currentLibrary: current, currentID: id)
        inspecting = false
    }
}

// MARK: Statistics (engine.storage.stats, estimates labelled as such)

private struct StorageStatsSection: View {
    let state: AppState
    @State private var stats: StorageStats?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        Section {
            if let stats {
                LabeledContent(L.Pref.paperCount, value: L.Pref.paperCountValue(live: stats.paperCount, deleted: stats.deletedCount))
                LabeledContent(L.Pref.logicalSize, value: SettingsFormat.bytes(stats.logicalBytes))
                LabeledContent {
                    Text(SettingsFormat.bytes(stats.estimatedSharedBytes))
                } label: {
                    Text(L.Pref.sharedEstimate)
                    Text(L.Pref.sharedEstimateHint)
                }
                LabeledContent(L.Pref.thumbnails, value: SettingsFormat.bytes(stats.thumbnailBytes))
                LabeledContent(L.Pref.textCache, value: SettingsFormat.bytes(stats.textCacheBytes))
                LabeledContent(L.Pref.database, value: SettingsFormat.bytes(stats.databaseBytes))
                LabeledContent(L.Pref.recentlyDeleted, value: SettingsFormat.bytes(stats.recentlyDeletedBytes))
                if stats.missingFiles > 0 {
                    StatusLine(.warning, L.Pref.missingFiles(stats.missingFiles))
                }
                if !stats.largest.isEmpty {
                    DisclosureGroup(L.Pref.largest) {
                        ForEach(stats.largest, id: \.id) { p in
                            LabeledContent {
                                Text(SettingsFormat.bytes(p.bytes)).monospacedDigit()
                            } label: {
                                Text(p.title).lineLimit(1).truncationMode(.tail)
                            }
                        }
                    }
                }
            } else if let failure {
                StatusLine(.error, failure)
            } else {
                StatusLine(.working, L.Pref.computing)
            }
        } header: {
            HStack {
                Text(L.Pref.storageSection)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(loading)
                .help(L.Pref.refresh)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            stats = try await state.engine.storage.stats()
            failure = nil
        } catch {
            failure = SettingsFormat.error(error)
        }
    }
}

// MARK: Maintenance

private struct MaintenanceSection: View {
    let state: AppState
    private enum Job { case rebuild, orphans, backup, reindex }
    @State private var running: Job?
    @State private var result: (kind: StatusKind, text: String)?
    @State private var lastBackup: URL?
    @State private var confirmRebuild = false

    var body: some View {
        Section {
            maintenanceRow(L.Pref.rebuildIndex, hint: L.Pref.rebuildIndexHint, button: L.Pref.rebuildButton, job: .rebuild) {
                confirmRebuild = true
            }
            maintenanceRow(L.Pref.cleanOrphans, hint: L.Pref.cleanOrphansHint, button: L.Pref.cleanButton, job: .orphans) {
                run(.orphans)
            }
            maintenanceRow(L.Pref.backupNow, hint: L.Pref.backupNowHint, button: L.Pref.backupButton, job: .backup) {
                run(.backup)
            }
            maintenanceRow(L.Pref.reindex, hint: L.Pref.reindexHint, button: L.Pref.reindexButton, job: .reindex) {
                run(.reindex)
            }
            if let result {
                HStack {
                    StatusLine(result.kind, result.text)
                    Spacer()
                    if let lastBackup {
                        Button(L.Pref.showInFinder) { SystemLinks.revealInFinder(lastBackup) }.controlSize(.small)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.Pref.maintenanceSection)
                HelpButton(.moveToNewMac)
            }
        } footer: {
            NoteText(L.Pref.recentlyDeletedFooter)
        }
        .alert(L.Pref.rebuildConfirmTitle, isPresented: $confirmRebuild) {
            Button(L.Pref.rebuild, role: .destructive) { run(.rebuild) }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.Pref.rebuildConfirmBody)
        }
    }

    private func maintenanceRow(_ title: String, hint: String, button: String, job: Job,
                                action: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(action: action) {
                if running == job { ProgressView().controlSize(.small) } else { Text(button) }
            }
            .disabled(running != nil)
        } label: {
            Text(title)
            Text(hint)
        }
    }

    private func run(_ job: Job) {
        running = job
        result = nil
        lastBackup = nil
        let engine = state.engine
        Task {
            defer { running = nil }
            do {
                switch job {
                case .rebuild:
                    // Bring card.json up to date and keep a copy of the index first.
                    await engine.ctx.sidecars.flush()
                    _ = try await engine.maintenance.backupNow()
                    let r = try await engine.rebuildFromSidecars(replacingExisting: true)
                    result = (r.skipped.isEmpty && r.unreadable.isEmpty ? .ok : .warning,
                              L.Pref.rebuildDone(papers: r.papers, deleted: r.deleted, skipped: r.skipped.count + r.unreadable.count))
                    state.scheduleRefresh(delay: .zero)
                case .orphans:
                    let left = try await engine.storage.cleanOrphans()
                    let kept = left.folders.filter { $0.pdfCount > 0 }.count
                    result = left.isEmpty ? (.ok, L.Pref.orphansNone)
                                          : (.warning, L.Pref.orphansLeft(folders: kept, missing: left.missingFiles.count))
                case .backup:
                    let url = try await engine.maintenance.backupNow()
                    lastBackup = url
                    result = (.ok, L.Pref.backupDone(url.lastPathComponent))
                case .reindex:
                    let n = await engine.reindexMissingFullText()
                    state.facts?.recountFullText()
                    result = (.ok, L.Pref.reindexDone(n))
                }
            } catch {
                result = (.error, SettingsFormat.error(error))
            }
        }
    }
}

// MARK: Categories (rename / describe / delete / new)

private struct CategoryManagerSection: View {
    let state: AppState

    private enum EditKind { case rename, describe, create }
    private struct Edit: Identifiable {
        var kind: EditKind
        var category: PaperCategory?
        var id: String { "\(kind)-\(category?.pk ?? 0)" }
    }

    @State private var edit: Edit?
    @State private var draft = ""
    @State private var deleting: CategoryRow?
    @State private var error: String?

    var body: some View {
        let rows = state.snapshot?.categories ?? []
        Section {
            if rows.isEmpty {
                Text(L.Pref.noCategories).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                CategoryManagerRow(row: row,
                                   rename: { begin(.rename, row.category) },
                                   describe: { begin(.describe, row.category) },
                                   delete: { deleting = row })
            }
            HStack {
                Button(L.Pref.newCategory) { begin(.create, nil) }
                Spacer()
            }
            if let error { StatusLine(.error, error) }
        } header: {
            Text(L.Pref.categoriesSection)
        } footer: {
            NoteText(L.Pref.categoriesFooter)
        }
        .alert(alertTitle, isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } })) {
            TextField(edit?.kind == .describe ? L.Pref.categoryDescription : L.Pref.categoryName, text: $draft)
            Button(L.Pref.save) { commit() }
            Button(L.cancel, role: .cancel) { edit = nil }
        } message: {
            if edit?.kind == .describe { Text(L.Pref.describeHint) }
        }
        .confirmationDialog(L.Pref.deleteCategoryTitle(deleting?.category.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L.Pref.delete, role: .destructive) {
                if let row = deleting { remove(row.category.pk) }
                deleting = nil
            }
            Button(L.cancel, role: .cancel) { deleting = nil }
        } message: {
            Text(L.Pref.deleteCategoryBody(deleting?.paperCount ?? 0))
        }
    }

    private var alertTitle: String {
        switch edit?.kind {
        case .rename: L.Pref.renameCategory
        case .describe: L.Pref.describeCategory
        case .create, nil: L.Pref.newCategory
        }
    }

    private func begin(_ kind: EditKind, _ category: PaperCategory?) {
        error = nil
        switch kind {
        case .rename: draft = category?.name ?? ""
        case .describe: draft = category?.description ?? ""
        case .create: draft = ""
        }
        edit = Edit(kind: kind, category: category)
    }

    private func commit() {
        guard let e = edit else { return }
        edit = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = state.engine
        Task {
            do {
                switch e.kind {
                case .rename:
                    guard let c = e.category, !text.isEmpty, text != c.name else { return }
                    _ = try await engine.renameCategory(pk: c.pk, name: text)
                case .describe:
                    guard let c = e.category else { return }
                    _ = try await engine.setCategoryDescription(pk: c.pk, text.isEmpty ? nil : text)
                case .create:
                    guard !text.isEmpty else { return }
                    _ = try await engine.createCategory(name: text)
                }
            } catch {
                self.error = SettingsFormat.error(error)
            }
        }
    }

    private func remove(_ pk: Int64) {
        let engine = state.engine
        Task {
            do { try await engine.deleteCategory(pk: pk) } catch { self.error = SettingsFormat.error(error) }
        }
    }
}

private struct CategoryManagerRow: View {
    let row: CategoryRow
    let rename: () -> Void
    let describe: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(ChipPalette.color(hue: row.category.hue))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.category.name).lineLimit(1)
                    if row.isNew {
                        Text("NEW")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                if let d = row.category.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Text(L.Pref.paperCountShort(row.paperCount)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Menu {
                Button(L.Pref.renameCategory, action: rename)
                Button(L.Pref.describeCategory, action: describe)
                Divider()
                Button(L.Pref.deleteCategoryMenu, role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L.Pref.categoryActions(row.category.name))
        }
        .contextMenu {
            Button(L.Pref.renameCategory, action: rename)
            Button(L.Pref.describeCategory, action: describe)
            Divider()
            Button(L.Pref.deleteCategoryMenu, role: .destructive, action: delete)
        }
    }
}
