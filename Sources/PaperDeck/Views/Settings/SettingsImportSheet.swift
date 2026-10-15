import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig

/// Import Settings…: per-section choices, per-key diffs and warnings, then the import through the
/// stores' setters. `onClose(true)` after an import.
///
/// The plan is pure (`SettingsImporter.plan`); applying it (`SettingsStore.applyImport`) never
/// writes `agent.mode`, `mail.enabled` or `setup.completed`, so AI reading and Mail stay as they
/// are (the footer says so — never that they are off). Nothing is loosened silently: a privacy or
/// quota setting the file has looser than this Mac (AI triage on, a higher cap, a sender's AI
/// policy raised or a person made an alert, an IMAP account pointed at another server…) is listed
/// under "Kept stricter" and
/// keeps this Mac's value unless its own checkbox is ticked (`ImportPlan.loosenings`). A new
/// person's "Always" arrives as "Ask" unless the opt-out is ticked; an imported reader
/// description (it enters the AI's instructions) is used only after "Use this description". An
/// imported library location is switched to only when that folder holds a PaperDeck library
/// (the next launch re-indexes it, backing up first).
struct SettingsImportSheet: View {
    let settings: SettingsStore
    let fileURL: URL?
    let onClose: (Bool) -> Void

    @State private var url: URL?
    @State private var bundle: SettingsBundle?
    @State private var failure: String?
    @State private var chosen: Set<SettingsSection> = []
    @State private var keepPeopleAlways = false
    /// The kept-stricter items whose looser file value the user ticked (`ImportLoosening.id`).
    @State private var acceptLooser: Set<String> = []
    @State private var acceptReader = false
    /// "Use these instructions": the file's custom instructions for AI email sorting.
    @State private var acceptInstructions = false
    @State private var roots: [CloudRoot] = []
    @State private var working = false
    @State private var done: (count: Int, libraryNote: String?)?

    /// Renders: a file already read and this Mac's cloud roots (nothing is read from disk).
    private let preloaded: (bundle: SettingsBundle, roots: [CloudRoot])?

    init(settings: SettingsStore, fileURL: URL?, preloaded: (bundle: SettingsBundle, roots: [CloudRoot])? = nil,
         onClose: @escaping (Bool) -> Void) {
        self.settings = settings
        self.fileURL = fileURL
        self.preloaded = preloaded
        self.onClose = onClose
        if let preloaded {
            _bundle = State(initialValue: preloaded.bundle)
            _roots = State(initialValue: preloaded.roots)
            _chosen = State(initialValue: Set(Self.presentGroups(preloaded.bundle).flatMap { $0 }))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.Transfer.importTitle).font(.headline)
                Spacer()
                if done == nil {
                    Button(L.Transfer.chooseFile) { chooseFile() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 600, height: 640)
        .task {
            guard preloaded == nil else { return }
            roots = await MailSettingsIO.cloudRoots(home: SharedPaths.realHome).roots
            if url == nil, let fileURL { await load(fileURL) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let done {
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(.ok, L.Transfer.imported(done.count))
                if let note = done.libraryNote {
                    StatusLine(.warning, note).fixedSize(horizontal: false, vertical: true)
                    Button(L.Pref.restartNow) { Relaunch.now() }
                }
                NoteText(L.Transfer.footer, symbol: "lock.shield")
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let failure {
            VStack(alignment: .leading, spacing: 10) {
                StatusLine(.error, failure).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bundle {
            planForm(bundle)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 32)).foregroundStyle(.secondary)
                Text(L.Transfer.noFile).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L.Transfer.chooseFile) { chooseFile() }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func planForm(_ bundle: SettingsBundle) -> some View {
        let plan = currentPlan(bundle)
        let present = Self.presentGroups(bundle)
        let reader = plan.changes.first { $0.key == ConfigKeys.profileReaderDescription }
            ?? bundleReader(bundle)
        return Form {
            Section {
                Text(L.Transfer.header(app: bundle.app, date: SettingsFormat.shortDateTime(bundle.exportedAt)))
                    .font(.callout)
                ForEach(present, id: \.self) { group in
                    Toggle(L.Transfer.sectionName(group[0]), isOn: binding(group)).toggleStyle(.checkbox)
                }
            }
            // Before the changes: what this Mac keeps stricter is the first thing to see.
            if !plan.loosenings.isEmpty {
                Section {
                    NoteText(L.Transfer.keptStricterIntro, symbol: "lock.shield")
                    ForEach(plan.loosenings) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: Self.keptStricterLine(item))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Toggle(L.Transfer.acceptLooser, isOn: looserBinding(item.id))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text(L.Transfer.keptStricterSection)
                }
            }
            Section {
                let shown = plan.changes.filter { $0.key != ConfigKeys.profileReaderDescription }
                if shown.isEmpty {
                    Text(L.Transfer.noChanges).foregroundStyle(.secondary)
                }
                let lists = Self.listImpacts(plan, current: settings.persistedDomain)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                    if let list = lists.first(where: { $0.key == c.key }) {
                        listImpact(list)
                    } else {
                        Text(verbatim: L.Transfer.change(L.Transfer.keyLabel(c.key), old: c.old.map(Self.short), new: Self.short(c.new)))
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(L.Transfer.changesSection)
            }
            let warnings = plan.warnings.filter { $0 != .readerDescriptionNeedsConfirm && $0 != .criteriaInstructionsNeedConfirm }
            if !warnings.isEmpty || keepPeopleAlways {
                Section {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                        StatusLine(.warning, L.Transfer.warning(w)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if keepPeopleAlways || warnings.contains(where: { if case .peopleAlwaysClamped = $0 { true } else { false } }) {
                        Toggle(L.Transfer.keepPeopleAlways, isOn: $keepPeopleAlways).toggleStyle(.checkbox)
                    }
                } header: {
                    Text(L.Transfer.warningsSection)
                }
            }
            if let reader {
                Section {
                    NoteText(L.Transfer.warning(.readerDescriptionNeedsConfirm), symbol: "exclamationmark.shield")
                    Text(verbatim: reader.new)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L.Transfer.useReaderDescription, isOn: $acceptReader).toggleStyle(.checkbox)
                } header: {
                    Text(L.Transfer.readerDescription)
                }
            }
            // The reading criteria's custom instructions enter the AI triage prompt: shown verbatim,
            // used only once confirmed (like the reader description).
            if let instructions = plan.criteriaInstructions {
                Section {
                    NoteText(L.Transfer.warning(.criteriaInstructionsNeedConfirm), symbol: "exclamationmark.shield")
                    Text(verbatim: instructions)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L.Transfer.useCriteriaInstructions, isOn: $acceptInstructions).toggleStyle(.checkbox)
                } header: {
                    Text(L.Transfer.criteriaInstructions)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A list setting (senders, accounts): what the import adds, replaces and keeps — and, should
    /// a plan ever drop one of this Mac's entries, what it removes — named before Import.
    private func listImpact(_ list: ListImpact) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.Transfer.listSummary(L.Transfer.keyLabel(list.key), added: list.added.count,
                                        replaced: list.replaced.count, kept: list.kept.count))
                .font(.callout)
            ForEach([(ListImpact.Part.added, list.added), (.replaced, list.replaced), (.kept, list.kept)], id: \.0) { part, names in
                if !names.isEmpty {
                    Text(verbatim: L.Transfer.listNames(part, names.map(Self.short)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if !list.removed.isEmpty {
                StatusLine(.warning, L.Transfer.listRemoved(list.removed.map(Self.short)))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if done == nil { NoteText(L.Transfer.footer, symbol: "lock.shield").font(.callout) }
            Spacer()
            if done != nil {
                Button(L.MailPref.done) { onClose(true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L.cancel, role: .cancel) { onClose(false) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let bundle { runImport(currentPlan(bundle)) }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(L.Transfer.importButton) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || bundle == nil || chosen.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Plan

    private func currentPlan(_ bundle: SettingsBundle) -> ImportPlan {
        Self.plan(bundle, current: settings.persistedDomain, sections: chosen, keepPeopleAlways: keepPeopleAlways,
                  acceptReader: acceptReader, acceptInstructions: acceptInstructions, ticked: acceptLooser,
                  home: SharedPaths.realHome, roots: roots)
    }

    /// The sheet's plan (pure; `--selftest settings`): only the kept-stricter items the user
    /// ticked (`ticked`, `ImportLoosening.id`) take the file's looser value.
    static func plan(_ bundle: SettingsBundle, current: PersistedDomain, sections: Set<SettingsSection>,
                     keepPeopleAlways: Bool, acceptReader: Bool, acceptInstructions: Bool = false, ticked: Set<String>,
                     home: URL, roots: [CloudRoot]) -> ImportPlan {
        SettingsImporter.plan(bundle, current: current, sections: sections, keepPeopleAlways: keepPeopleAlways,
                              acceptReaderDescription: acceptReader, acceptLooser: .only(ticked),
                              acceptCriteriaInstructions: acceptInstructions, home: home, roots: roots)
    }

    /// "Kept stricter: AI triage daily limit — 30 per day (file: 200 per day)", or "Will loosen: …"
    /// once ticked (pure; `--selftest settings`, the CLI's dry run).
    static func keptStricterLine(_ item: ImportLoosening) -> String {
        let label = L.Transfer.looseningLabel(item)
        let mine = L.Transfer.looseningValue(item, item.mine), theirs = L.Transfer.looseningValue(item, item.theirs)
        return item.accepted ? L.Transfer.looserAccepted(label, mine: mine, theirs: theirs)
                             : L.Transfer.keptStricter(label, mine: mine, theirs: theirs)
    }

    private func looserBinding(_ id: String) -> Binding<Bool> {
        Binding {
            acceptLooser.contains(id)
        } set: { on in
            if on { acceptLooser.insert(id) } else { acceptLooser.remove(id) }
        }
    }

    /// One list setting's effect, by id: the plan's value against this Mac's.
    struct ListImpact: Equatable {
        enum Part: Hashable { case added, replaced, kept }
        var key: String
        /// In the file, not on this Mac.
        var added: [String] = []
        /// On this Mac and in the file, different.
        var replaced: [String] = []
        /// On this Mac and the same after the import.
        var kept: [String] = []
        /// On this Mac, gone after the import.
        var removed: [String] = []
    }

    /// The senders and accounts the plan writes (pure; `--selftest settings`): what is added,
    /// replaced and kept as the planner's merge names them (`ImportPlan.merges`), and — compared
    /// by id with this Mac's list — anything the written list would no longer hold (the planner
    /// merges, so that stays empty; shown should it ever not). Only keys the plan writes are listed.
    static func listImpacts(_ plan: ImportPlan, current: PersistedDomain) -> [ListImpact] {
        var out: [ListImpact] = []
        let senders = MailSettings.Keys.senders, accounts = MailSettings.Keys.accounts
        if case .string(let json)? = plan.writes[senders] {
            out.append(impact(senders, mine: MailSettings.list(current.values[senders] as? String, SenderRule.self, what: "sender"),
                              written: MailSettings.list(json, SenderRule.self, what: "sender"),
                              name: { $0.label.isEmpty ? $0.pattern : $0.label }))
        }
        if case .string(let json)? = plan.writes[accounts] {
            out.append(impact(accounts, mine: MailSettings.list(current.values[accounts] as? String, MailAccount.self, what: "account"),
                              written: MailSettings.list(json, MailAccount.self, what: "account"),
                              name: { $0.displayName.isEmpty ? $0.id : $0.displayName },
                              newIDs: plan.merges[accounts]?.newIDs ?? [:]))
        }
        for i in out.indices {
            if let merge = plan.merges[out[i].key] {
                out[i].added = merge.added
                out[i].replaced = merge.replaced
                out[i].kept = merge.kept
            }
        }
        return out
    }

    /// By id: `written` entries this Mac lacks are added, differing ones replaced, equal ones kept;
    /// this Mac's entries `written` lacks are removed — unless the plan replaced one under a new id
    /// (`newIDs`: an account moved to the file's server) that `written` holds.
    static func impact<T: Identifiable & Equatable>(_ key: String, mine: [T], written: [T], name: (T) -> String,
                                                    newIDs: [String: String] = [:]) -> ListImpact
        where T.ID == String {
        var r = ListImpact(key: key)
        let byID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<String> = []
        for w in written where seen.insert(w.id).inserted {
            if let m = byID[w.id] {
                if m == w { r.kept.append(name(w)) } else { r.replaced.append(name(w)) }
            } else {
                r.added.append(name(w))
            }
        }
        r.removed = mine.filter { !seen.contains($0.id) && !(newIDs[$0.id].map(seen.contains) ?? false) }.map(name)
        return r
    }

    /// The reader description a plan held back until confirmed (shown verbatim either way).
    private func bundleReader(_ bundle: SettingsBundle) -> ImportChange? {
        let plan = Self.plan(bundle, current: settings.persistedDomain, sections: chosen, keepPeopleAlways: keepPeopleAlways,
                             acceptReader: true, ticked: acceptLooser, home: SharedPaths.realHome, roots: roots)
        return plan.changes.first { $0.key == ConfigKeys.profileReaderDescription }
    }

    /// The export's checkbox groups this file has sections for.
    static func presentGroups(_ bundle: SettingsBundle) -> [[SettingsSection]] {
        let have = Set(bundle.sections.keys.compactMap(SettingsSection.init(rawValue:)))
        return SettingsExportSheet.groups.filter { !have.isDisjoint(with: $0) }
    }

    private func binding(_ group: [SettingsSection]) -> Binding<Bool> {
        Binding {
            group.allSatisfy(chosen.contains)
        } set: { on in
            if on { chosen.formUnion(group) } else { chosen.subtract(group) }
        }
    }

    static func short(_ s: String) -> String { s.count > 80 ? String(s.prefix(77)) + "…" : s }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = L.Transfer.chooseFileMessage
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        Task { await load(picked) }
    }

    private func load(_ file: URL) async {
        url = file
        failure = nil
        bundle = nil
        do {
            let data = try await BlockingIO.run { try Data(contentsOf: file) }
            let b = try SettingsImporter.decode(data)
            bundle = b
            chosen = Set(Self.presentGroups(b).flatMap { $0 })
            acceptReader = false
            acceptInstructions = false
            keepPeopleAlways = false
            acceptLooser = []
        } catch SettingsImporter.Failure.unknownFormat(let f) {
            failure = L.Transfer.unknownFormat(f)
        } catch SettingsImporter.Failure.malformed {
            failure = L.Transfer.malformed
        } catch {
            failure = L.Transfer.readFailed(error.localizedDescription)
        }
    }

    /// Applies the plan; an imported library location only when it holds a PaperDeck library.
    private func runImport(_ plan: ImportPlan) {
        working = true
        Task {
            var plan = plan
            var libraryNote: String?
            if case .string(let path)? = plan.writes[SettingsStore.Keys.libraryPath] {
                plan.writes[SettingsStore.Keys.libraryPath] = nil
                let current = settings.libraryPath
                if URL(fileURLWithPath: path).standardizedFileURL.path != URL(fileURLWithPath: current).standardizedFileURL.path,
                   case .existingLibrary = await LibraryInspector.inspect(URL(fileURLWithPath: path, isDirectory: true)) {
                    settings.scheduleLibraryChange(
                        path: path, pending: LibraryPendingAction(kind: .openExisting, path: path, previousPath: current),
                        previousPath: current)
                    libraryNote = L.Pref.switchPending(SettingsFormat.tildePath(path))
                }
            }
            let n = settings.applyImport(plan)
            done = (n + (libraryNote == nil ? 0 : 1), libraryNote)
            working = false
        }
    }
}
