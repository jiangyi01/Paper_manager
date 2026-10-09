import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig

/// What the 「添加账户…」 sheet sets up.
enum MailAccountTemplate: Hashable {
    case powerAutomate                          // work / school Microsoft 365 → Power Automate → OneDrive .eml folder
    case imap(MailAccount.IMAPPreset)           // Gmail / iCloud / Yahoo / Fastmail / other, app password
    case folder                                 // any watched folder of .eml files

    static let choices: [MailAccountTemplate] = [
        .powerAutomate, .imap(.gmail), .imap(.icloud), .imap(.yahoo), .imap(.fastmail), .imap(.custom), .folder,
    ]

    /// The editor used for an existing account: its stored source, else today's inference
    /// (`MailSourceResolver`: a folder in OneDrive or named "… Power Automate" is Power Automate).
    init(_ account: MailAccount) {
        let source = MailSourceResolver.source(of: account)
        switch account.kind {
        case .imap: self = .imap(account.imapPreset ?? source.imapPreset ?? .custom)
        case .folder: self = source == .m365PowerAutomate ? .powerAutomate : .folder
        }
    }

    var symbol: String {
        switch self {
        case .powerAutomate: "icloud.and.arrow.down"
        case .imap(.gmail): "envelope.badge"
        case .imap(.icloud): "icloud"
        case .imap: "envelope"
        case .folder: "folder"
        }
    }
}

/// 「添加账户…」 / 「编辑…」: pick a kind, fill in the form, save. IMAP accounts are saved only
/// after 「测试并保存」 signed in (the app password goes to the login keychain, never to
/// UserDefaults or a log).
struct MailAddAccountSheet: View {
    let state: AppState
    let editing: MailAccount?
    /// Opens straight into this kind's form (renders); nil shows the chooser.
    var initialTemplate: MailAccountTemplate? = nil
    let onClose: () -> Void

    /// Where the Power Automate form looks for OneDrive folders (renders point it at a scratch home).
    static var detectionHome: URL = SharedPaths.realHome

    @State private var template: MailAccountTemplate?
    @State private var draft: MailAccount
    @State private var portText: String
    @State private var password = ""
    @State private var working = false
    @State private var result: (kind: StatusKind, text: String)?
    @State private var saved = false
    @State private var folder: MailSettingsIO.FolderState?
    @State private var detectingOneDrive = false
    /// The existing OneDrive 「PaperDeck Mail」 folder the form preselected.
    @State private var detectedFolder: String?
    /// The cloud roots of this Mac (nil until the Power Automate form looked).
    @State private var detectedRoots: [CloudRoot]?
    @State private var showAppleMailRule = false
    @State private var scriptResult: (kind: StatusKind, text: String)?

    /// `editedDraft`: renders only — the form as if the user already changed some fields of `editing`.
    init(state: AppState, editing: MailAccount?, initialTemplate: MailAccountTemplate? = nil,
         editedDraft: MailAccount? = nil, onClose: @escaping () -> Void) {
        self.state = state
        self.editing = editing
        self.initialTemplate = initialTemplate
        self.onClose = onClose
        let draft = editing.flatMap { e in editedDraft.map { $0.id == e.id ? $0 : e } ?? e }
            ?? MailAccount(kind: .folder, displayName: "")
        _draft = State(initialValue: draft)
        _template = State(initialValue: editing.map(MailAccountTemplate.init))
        _portText = State(initialValue: draft.port.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let template {
                    Form { form(template) }
                        .formStyle(.grouped)
                } else {
                    chooser
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 600, height: 700)
        .task(id: draft.folderPath) { await checkFolder() }
        .task {
            if let initialTemplate, editing == nil, template == nil { start(initialTemplate) }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            if template != nil, editing == nil, !saved {
                Button {
                    template = nil
                    result = nil
                } label: {
                    Label(L.MailPref.back, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var title: String {
        guard let template else { return L.MailPref.addAccountTitle }
        if editing != nil { return L.MailPref.editAccountTitle(L.MailPref.templateName(template)) }
        return L.MailPref.templateName(template)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let result, template != nil {
                StatusLine(result.kind, result.text)
                    .font(.callout)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if saved {
                if !state.settings.mailEnabled {
                    Button(L.MailPref.turnOnAndClose) {
                        state.settings.mailEnabled = true
                        onClose()
                    }
                }
                Button(L.MailPref.done) { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L.cancel, role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                if let template {
                    Button {
                        save(template)
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text(saveTitle(template)) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !canSave(template))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func saveTitle(_ t: MailAccountTemplate) -> String {
        if case .imap = t { return L.MailPref.testAndSave }
        return editing == nil ? L.MailPref.addAccountButton : L.Pref.save
    }

    // MARK: Chooser

    /// "Set up an account" (`MailSourceCatalog`'s rows in today's order, worded by L10n), then
    /// "Other ways to get mail in": guide-only routes that open their Help topic.
    private var chooser: some View {
        let entries = MailSourceCatalog.entries(org: L.org)
        let others = entries.filter { $0.section == .otherWays }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !others.isEmpty { chooserHeader(L.MailPref.chooserSetUp) }
                ForEach(MailAccountTemplate.setUpChoices(entries), id: \.self) { t in
                    HStack(spacing: 6) {
                        chooserRow(symbol: t.symbol, title: L.MailPref.templateName(t), blurb: L.MailPref.templateBlurb(t),
                                   beta: false, trailing: "chevron.right") { start(t) }
                        if let topic = entries.first(where: { $0.id == t.sourceID })?.helpTopic { HelpButton(topic) }
                    }
                }
                if !others.isEmpty {
                    chooserHeader(L.MailPref.chooserOtherWays).padding(.top, 8)
                    ForEach(others) { e in
                        chooserRow(symbol: e.symbol, title: e.title(L.lang), blurb: e.blurb(L.lang), beta: e.beta,
                                   trailing: "questionmark.circle", compact: true) { HelpCenter.openTopic(e.helpTopic) }
                            .help(L.MailPref.opensHelp)
                    }
                }
                NoteText(L.MailPref.dropAlwaysWorks, symbol: "tray.and.arrow.down")
                    .padding(.top, 6)
            }
            .padding(16)
        }
    }

    private func chooserHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    /// `compact`: the guide-only rows (smaller, so the whole list stays in view).
    private func chooserRow(symbol: String, title: String, blurb: String, beta: Bool, trailing: String,
                            compact: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(compact ? .medium : .semibold)
                        if beta {
                            Text(L.MailPref.beta)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(blurb)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: trailing).foregroundStyle(.tertiary)
            }
            .padding(compact ? 8 : 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.fill.quinary))
        }
        .buttonStyle(.plain)
    }

    private func start(_ t: MailAccountTemplate) {
        result = nil
        password = ""
        detectedFolder = nil
        detectedRoots = nil
        scriptResult = nil
        switch t {
        case .powerAutomate:
            // Before the cloud roots are looked at: the organization's fallback (none for most).
            let suggested = CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: [], existingMailFolders: [],
                                                             org: L.org, lastChoice: state.settings.config.cloudRoot,
                                                             home: Self.detectionHome)?.path
            draft = MailAccount(kind: .folder, displayName: L.MailPref.powerAutomateDefaultName, folderPath: suggested,
                                source: t.sourceID.rawValue)
            detectOneDrive(replacing: suggested)
        case .folder:
            draft = MailAccount(kind: .folder, displayName: "", source: t.sourceID.rawValue)
        case .imap(let preset):
            draft = MailAccount(kind: .imap, displayName: "", imapPreset: preset,
                                host: preset.host.isEmpty ? nil : preset.host, port: preset.port, mailbox: "INBOX",
                                source: t.sourceID.rawValue)
        }
        portText = draft.port.map(String.init) ?? ""
        template = t
    }

    // MARK: Forms

    @ViewBuilder
    private func form(_ t: MailAccountTemplate) -> some View {
        switch t {
        case .powerAutomate:
            folderSection(powerAutomate: true)
            Section {
                MailPowerAutomateGuide(senders: state.settings.mailSenders, localFolder: draft.folderPath)
            } header: {
                Text(L.MailPref.paGuideSection)
            }
            Section {
                NoteText(L.MailPref.paBlockedNote, symbol: "exclamationmark.shield")
                if editing == nil {
                    HStack {
                        Button(L.MailPref.useGmailInstead) { start(.imap(.gmail)) }
                        Button(L.MailPref.otherWays) { HelpCenter.openTopic(.mailM365Blocked) }
                        Spacer()
                    }
                }
            }
            nameSection
        case .folder:
            folderSection(powerAutomate: false)
            Section {
                NoteText(L.MailPref.folderHowTo, symbol: "info.circle")
                NoteText(L.MailPref.dropAlwaysWorks, symbol: "tray.and.arrow.down")
            }
            appleMailRuleSection
            nameSection
        case .imap(let preset):
            imapSections(preset)
        }
    }

    private var nameSection: some View {
        Section {
            TextField(L.MailPref.displayName, text: $draft.displayName, prompt: Text(defaultName))
            Picker(L.MailPref.lookback, selection: $draft.lookbackDays) {
                ForEach(MailSettingsFormat.options(MailAccountsSection.lookbackChoices, including: draft.lookbackDays), id: \.self) {
                    Text(L.MailPref.days($0)).tag($0)
                }
            }
        } footer: {
            NoteText(L.MailPref.lookbackHelp)
        }
    }

    private func folderSection(powerAutomate: Bool) -> some View {
        Section {
            LabeledContent(L.MailPref.watchedFolder) {
                Text(MailSettingsFormat.path(draft.folderPath))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            folderStatus(powerAutomate: powerAutomate)
            HStack {
                if let f = folder, !f.exists, f.parentExists {
                    Button(L.MailPref.createFolder) { createFolder() }
                }
                Button(L.MailPref.chooseFolder) { chooseFolder() }
                if folder?.isFolder == true, let p = draft.folderPath {
                    Button(L.Pref.showInFinder) {
                        SystemLinks.revealInFinder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
                    }
                }
                Spacer()
            }
            .controlSize(.small)
            Toggle(isOn: $draft.deleteProcessedFiles) {
                Text(L.MailPref.deleteProcessed)
                Text(powerAutomate ? L.MailPref.deleteProcessedHint : L.MailPref.deleteProcessedHint(folderProvider))
            }
        } header: {
            Text(powerAutomate ? L.MailPref.paFolderSection : L.MailPref.folderSection)
        } footer: {
            if powerAutomate { NoteText(L.MailPref.oneDrivePrompt, symbol: "lock.shield") }
        }
    }

    @ViewBuilder
    private func folderStatus(powerAutomate: Bool) -> some View {
        if powerAutomate && detectingOneDrive {
            StatusLine(.working, L.MailPref.oneDriveLooking)
        } else if let f = folder {
            if f.isFolder {
                StatusLine(.ok, detectedFolder != nil && detectedFolder == draft.folderPath
                           ? L.MailPref.oneDriveFound : L.MailPref.folderExists)
            } else if f.exists {
                StatusLine(.error, L.MailPref.notAFolder)
            } else if f.parentExists {
                StatusLine(.warning, powerAutomate ? L.MailPref.folderMissingCreate : L.MailPref.folderMissingCreate(folderProvider))
            } else {
                StatusLine(.warning, powerAutomate ? L.MailPref.oneDriveMissing(found: otherRootNames) : L.MailPref.folderMissing)
            }
        } else if (draft.folderPath ?? "").isEmpty {
            if powerAutomate, let roots = detectedRoots, !roots.contains(where: { $0.provider == .oneDriveBusiness }) {
                // No OneDrive for work or school on this Mac: say so (and what is there).
                StatusLine(.warning, L.MailPref.oneDriveMissing(found: otherRootNames))
            } else {
                StatusLine(.pending, L.MailPref.noFolderYet)
            }
        } else {
            StatusLine(.working, L.Pref.checking)
        }
    }

    @ViewBuilder
    private func imapSections(_ preset: MailAccount.IMAPPreset) -> some View {
        Section {
            if editing == nil {
                Picker(L.MailPref.provider, selection: presetBinding) {
                    ForEach(MailAccount.IMAPPreset.allCases, id: \.self) { Text(L.MailPref.presetName($0)).tag($0) }
                }
            }
            TextField(L.MailPref.address, text: usernameBinding, prompt: Text(L.MailPref.addressPrompt(preset)))
                .textContentType(.username)
                .autocorrectionDisabled()
            TextField(L.MailPref.displayName, text: $draft.displayName, prompt: Text(defaultName))
        } header: {
            Text(L.MailPref.accountSection)
        } footer: {
            if let note = L.MailPref.presetNote(preset) { NoteText(note, symbol: "info.circle") }
        }

        Section {
            TextField(L.MailPref.server, text: hostBinding, prompt: Text(preset.host.isEmpty ? "imap.example.org" : preset.host))
                .autocorrectionDisabled()
            TextField(L.MailPref.port, text: $portText, prompt: Text("993"))
                .onChange(of: portText) { _, s in draft.port = Int(s.trimmingCharacters(in: .whitespaces)) }
            TextField(L.MailPref.mailbox, text: mailboxBinding, prompt: Text("INBOX"))
                .autocorrectionDisabled()
        } header: {
            Text(L.MailPref.serverSection)
        } footer: {
            NoteText(L.MailPref.mailboxHint(preset))
        }

        Section {
            if let url = preset.appPasswordURL {
                LabeledContent {
                    Button(L.MailPref.openAppPasswordPage) { NSWorkspace.shared.open(url) }
                } label: {
                    Text(L.MailPref.appPasswordStep)
                    Text(url.host ?? url.absoluteString)
                }
            }
            SecureField(L.MailPref.appPassword, text: $password, prompt: Text(passwordPrompt))
                .textContentType(.password)
        } header: {
            Text(L.MailPref.appPasswordSection)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if editing != nil, !saved, !mayReuseSavedPassword {
                    NoteText(L.MailPref.serverChangedNote, symbol: "exclamationmark.shield")
                }
                NoteText(L.MailPref.readOnlyNote, symbol: "lock.shield")
                if preset == .gmail { NoteText(L.MailPref.gmailTwoStep, symbol: "checkmark.shield") }
            }
        }

        Section {
            Picker(L.MailPref.lookback, selection: $draft.lookbackDays) {
                ForEach(MailSettingsFormat.options(MailAccountsSection.lookbackChoices, including: draft.lookbackDays), id: \.self) {
                    Text(L.MailPref.days($0)).tag($0)
                }
            }
        } footer: {
            NoteText(L.MailPref.alertsTip(preset), symbol: "lightbulb")
        }
    }

    // MARK: Bindings

    private var presetBinding: Binding<MailAccount.IMAPPreset> {
        Binding {
            draft.imapPreset ?? .custom
        } set: { p in
            let old = draft.imapPreset ?? .custom
            guard p != old else { return }
            draft.imapPreset = p
            // Keep a host the user typed for "Other"; presets fill their own.
            if !p.host.isEmpty || (draft.host ?? "") == old.host { draft.host = p.host.isEmpty ? nil : p.host }
            draft.port = p.port
            portText = String(p.port)
            template = .imap(p)
            if editing == nil { draft.source = MailAccountTemplate.imap(p).sourceID.rawValue }
            result = nil
        }
    }

    private var usernameBinding: Binding<String> {
        Binding { draft.username ?? "" } set: { draft.username = $0 }
    }

    private var hostBinding: Binding<String> {
        Binding { draft.host ?? "" } set: { draft.host = $0 }
    }

    private var mailboxBinding: Binding<String> {
        Binding { draft.mailbox ?? "" } set: { draft.mailbox = $0 }
    }

    /// The cloud provider syncing the chosen folder (nil: a local folder).
    private var folderProvider: CloudProvider? {
        guard let p = draft.folderPath, !p.isEmpty else { return nil }
        return CloudRootLocator.split((p as NSString).expandingTildeInPath, home: Self.detectionHome)?.root.provider
    }

    /// The detected roots the missing-OneDrive line lists ("Found: …").
    private var otherRootNames: [String] {
        (detectedRoots ?? []).filter { $0.provider != .oneDriveBusiness }.map(\.displayName)
    }

    // MARK: Apple Mail rule (Beta)

    /// The folder form's Apple Mail rule: a script that saves new emails' source into this folder.
    private var appleMailRuleSection: some View {
        Section {
            DisclosureGroup(L.MailPref.appleMailRuleTitle, isExpanded: $showAppleMailRule) {
                VStack(alignment: .leading, spacing: 8) {
                    NoteText(L.MailPref.appleMailRuleIntro, symbol: "envelope.open")
                    NoteText(L.MailPref.appleMailRuleNote, symbol: "info.circle")
                    let script = appleMailScript
                    HStack {
                        Button(L.MailPref.copyScript) {
                            guard let script else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(script, forType: .string)
                            scriptResult = (.ok, L.Pref.copied)
                        }
                        Button(L.MailPref.saveScript) { if let script { saveScript(script) } }
                        Spacer()
                    }
                    .controlSize(.small)
                    .disabled(script == nil)
                    if script == nil {
                        StatusLine(.pending, L.MailPref.chooseFolderFirst).font(.callout)
                    } else if let scriptResult {
                        StatusLine(scriptResult.kind, scriptResult.text).font(.callout)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// The rule's AppleScript for the chosen folder (nil without a folder).
    private var appleMailScript: String? {
        guard let p = draft.folderPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        let script = MailRuleScripts.appleMailRule(folder: URL(fileURLWithPath: (p as NSString).expandingTildeInPath,
                                                               isDirectory: true))
        return script.isEmpty ? nil : script
    }

    /// Save Script… into Mail's script folder (the user confirms the save panel).
    private func saveScript(_ script: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PaperDeck Save Email.applescript"
        panel.allowedContentTypes = [.appleScript]
        panel.canCreateDirectories = true
        panel.directoryURL = SharedPaths.realHome.appendingPathComponent("Library/Application Scripts/com.apple.mail",
                                                                         isDirectory: true)
        panel.message = L.MailPref.saveScriptMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await BlockingIO.run { try Data(script.utf8).write(to: url, options: .atomic) }
                scriptResult = (.ok, L.MailPref.scriptSaved(SettingsFormat.tildePath(url.path)))
            } catch {
                scriptResult = (.error, L.MailPref.scriptFailed(error.localizedDescription))
            }
        }
    }

    private var defaultName: String {
        switch template {
        case .powerAutomate?: return L.MailPref.powerAutomateDefaultName
        case .imap(let p)?:
            let user = (draft.username ?? "").trimmingCharacters(in: .whitespaces)
            return user.isEmpty ? L.MailPref.presetName(p) : "\(L.MailPref.presetName(p)) — \(user)"
        case .folder?, nil:
            let name = draft.folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return name.isEmpty ? L.MailPref.folderDefaultName : "\(L.MailPref.folderDefaultName) — \(name)"
        }
    }

    // MARK: Validation & save

    /// Editing with the same server, port and address: an empty password field keeps (and tests
    /// with) the saved one. Any change there needs the password typed again (never the stored
    /// secret sent to another host).
    private var mayReuseSavedPassword: Bool {
        MailAccountEditRules.mayReuseSavedPassword(original: editing, edited: draft)
    }

    private var passwordPrompt: String {
        if editing == nil { return L.MailPref.appPasswordPrompt }
        // Once saved, the new password is the saved one.
        return saved || mayReuseSavedPassword ? L.MailPref.keepSavedPassword : L.MailPref.retypePasswordPrompt
    }

    private func canSave(_ t: MailAccountTemplate) -> Bool {
        switch t {
        case .powerAutomate, .folder:
            // A missing folder may still be saved (OneDrive may not have synced it yet); a file may not.
            guard !(draft.folderPath ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if let f = folder, f.exists, !f.isFolder { return false }
            return true
        case .imap:
            let user = (draft.username ?? "").trimmingCharacters(in: .whitespaces)
            let host = (draft.host ?? "").trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty, !host.isEmpty, let port = draft.port, (1...65_535).contains(port) else { return false }
            return !password.isEmpty || mayReuseSavedPassword
        }
    }

    /// Trimmed fields, a default display name, preset host / port / mailbox when left empty.
    private func normalized() -> MailAccount {
        var a = draft
        func clean(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        a.displayName = clean(a.displayName) ?? defaultName
        switch a.kind {
        case .folder:
            a.folderPath = clean(a.folderPath).map { ($0 as NSString).expandingTildeInPath }
        case .imap:
            a.username = clean(a.username)
            a.host = clean(a.host) ?? a.imapPreset.flatMap { $0.host.isEmpty ? nil : $0.host }
            a.port = a.port ?? a.imapPreset?.port ?? 993
            a.mailbox = clean(a.mailbox) ?? "INBOX"
        }
        return a
    }

    private func save(_ t: MailAccountTemplate) {
        let account = normalized()
        switch t {
        case .powerAutomate, .folder:
            state.settings.upsertMailAccount(account)
            state.settings.notifyMailNow(accountID: account.id)
            recordCloudRoot(account.folderPath)
            draft = account
            result = (.ok, L.MailPref.savedFolder)
            saved = true
        case .imap:
            testAndSave(account)
        }
    }

    /// LOGIN + EXAMINE off the main actor with the typed password (or, when editing with the
    /// field empty and the same server, port and address, the saved one); on success the password
    /// goes to the keychain and the account to Settings, and the engine retries at once.
    private func testAndSave(_ account: MailAccount) {
        working = true
        result = (.working, L.MailPref.testing(account.host ?? ""))
        let typed = password
        let isEdit = editing != nil
        // Decided on the account as it will be saved and tested (never the stored secret for a new host).
        let reuse = MailAccountEditRules.mayReuseSavedPassword(original: editing, edited: account)
        let store = MailSecrets.store
        let lang = L.lang
        Task {
            var secret = typed
            if secret.isEmpty, reuse { secret = await store.secret(for: account.secretKey) ?? "" }
            guard !secret.isEmpty else {
                result = (.warning, isEdit && !reuse ? L.MailPref.reenterAppPassword : L.MailPref.enterAppPassword)
                working = false
                return
            }
            let status = await MailSettingsIO.testIMAP(account, password: secret, lang: lang)
            if case .ready(let detail) = status {
                do {
                    if !typed.isEmpty { try await store.setSecret(typed, for: account.secretKey) }
                    state.settings.upsertMailAccount(account)
                    state.settings.notifyMailNow(accountID: account.id)
                    draft = account
                    password = ""
                    result = (.ok, L.MailPref.savedIMAP(detail))
                    saved = true
                } catch {
                    result = (.error, L.MailPref.keychainFailed(String(describing: error)))
                }
            } else {
                result = MailStatusText.status(status)
            }
            working = false
        }
    }

    // MARK: Folder helpers

    /// Looks at this Mac's cloud roots (root names in `~/Library/CloudStorage` and existence
    /// checks only, off the main actor) and lets `CloudRootLocator` pick the folder: an existing
    /// 「PaperDeck Mail」 wins, then OneDrive for work or school (the organization's hint first,
    /// then the last choice); Personal and shared libraries never.
    private func detectOneDrive(replacing suggested: String?) {
        detectingOneDrive = true
        let home = Self.detectionHome
        let org = L.org
        let lastChoice = state.settings.config.cloudRoot
        Task {
            let found = await MailSettingsIO.cloudRoots(home: home)
            detectingOneDrive = false
            detectedRoots = found.roots
            // The user may have chosen another folder (or another kind) meanwhile.
            guard template == .powerAutomate, editing == nil, !saved, draft.folderPath == suggested else { return }
            guard let url = CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: found.roots,
                                                             existingMailFolders: found.mailFolders, org: org,
                                                             lastChoice: lastChoice, home: home) else { return }
            draft.folderPath = url.path
            if found.mailFolders.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                detectedFolder = url.path
            }
        }
    }

    /// `mail.cloudRoot`: the root of the folder just saved (the next form ranks it first).
    private func recordCloudRoot(_ path: String?) {
        guard let path, let split = CloudRootLocator.split(path, home: Self.detectionHome) else { return }
        if state.settings.config.cloudRoot != split.root.name { state.settings.config.cloudRoot = split.root.name }
    }

    private func checkFolder() async {
        guard let p = draft.folderPath, !p.isEmpty else { folder = nil; return }
        folder = await MailSettingsIO.folderState(p)
    }

    private func createFolder() {
        guard let p = draft.folderPath else { return }
        Task {
            do {
                try await MailSettingsIO.createFolder(p)
                result = (.ok, L.MailPref.folderCreated)
            } catch {
                result = (.error, L.MailPref.folderCreateFailed(error.localizedDescription))
            }
            await checkFolder()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L.Pref.choose
        panel.message = L.MailPref.chooseFolderMessage
        if let p = draft.folderPath {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            // The checked state, not a fresh stat: a OneDrive path can block the main thread.
            panel.directoryURL = folder?.isFolder == true ? url : url.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.folderPath = url.path
    }
}
