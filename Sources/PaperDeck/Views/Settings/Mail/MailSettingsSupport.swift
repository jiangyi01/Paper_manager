import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

// Shared pieces of Settings ▸ Mail. Every type is prefixed `Mail…` so it never collides with
// the Mail inbox slice (Views/Mail).

// MARK: - Secrets

/// Where Settings ▸ Mail keeps IMAP app passwords: the app's own login-keychain items (the
/// engine's default `KeychainMailSecretStore`, same service). The preview renderer swaps in an
/// in-memory store so offscreen renders never touch the real keychain.
enum MailSecrets {
    static var store: any MailSecretStore = KeychainMailSecretStore()
}

// MARK: - Account edits

/// 「编辑…」 of an IMAP account: the saved app password may only be reused to sign in to the same
/// server as the same user. A changed host, port or username (the address) needs the password
/// typed again, so the stored secret never goes to another host — a mistyped or pasted server name
/// only needs a valid certificate for its own name to receive it. The keychain item is keyed by
/// the account id alone, so this check is the only thing binding it to its server.
enum MailAccountEditRules {
    /// Where (and as whom) an IMAP account signs in, normalised the way the form saves it:
    /// trimmed, case-insensitive host (an empty host means the preset's) and username, default port.
    struct ServerIdentity: Equatable {
        var host: String
        var port: Int
        var username: String
    }

    static func identity(_ a: MailAccount) -> ServerIdentity {
        func clean(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var host = clean(a.host)
        if host.isEmpty { host = clean(a.imapPreset?.host) }
        while host.hasSuffix(".") { host.removeLast() }          // `imap.gmail.com.` is the same host
        return ServerIdentity(host: host, port: a.port ?? a.imapPreset?.port ?? 993, username: clean(a.username))
    }

    /// Whether 「测试并保存」 may sign in to `edited` with the password saved for `original` (the
    /// account as it was saved). False for a new account, a different account or another kind,
    /// and whenever the host, port or username changed.
    static func mayReuseSavedPassword(original: MailAccount?, edited: MailAccount) -> Bool {
        guard let original, original.id == edited.id, original.kind == .imap, edited.kind == .imap else { return false }
        return identity(original) == identity(edited)
    }
}

// MARK: - Sheets

/// The one sheet Settings ▸ Mail can show at a time.
enum MailSettingsSheet: Identifiable {
    case addAccount
    case editAccount(MailAccount)
    case sender(SenderRule?)
    case triageSample
    /// The Power Automate guide on its own (the 「不是完整的邮件」 hints).
    case powerAutomateGuide(MailAccount?)

    var id: String {
        switch self {
        case .addAccount: "add-account"
        case .editAccount(let a): "account-" + a.id
        case .sender(let r): "sender-" + (r?.id ?? "new")
        case .triageSample: "triage-sample"
        case .powerAutomateGuide(let a): "pa-guide-" + (a?.id ?? "")
        }
    }
}

// MARK: - Status wording

enum MailStatusText {
    /// The account rows of Settings ▸ Mail ▸ Accounts, worded in `lang` by the engine
    /// (`MailSyncActor.accountSyncInfo(lang:)`: statuses, their details and hints — the pipeline's
    /// 「同步失败」 / 「部分邮件暂时无法读取」, the undownloadable suffix, IMAP 「已登录为 …」).
    static func read(_ mail: MailSyncActor, lang: UILang) async -> [MailAccountSyncInfo] {
        await mail.accountSyncInfo(lang: lang)
    }

    /// The rows to show in `lang`. Rows read in another language (just after a language switch,
    /// until the next read lands) keep their state but lose the engine's sentences: each status
    /// then shows only its kind in `lang` (「就绪」, 「需要设置」, 「登录失败」, 「暂时无法访问」), and the
    /// hints (not-email files, skipped emails) wait for that read — never a sentence in the old language.
    static func current(_ infos: [MailAccountSyncInfo], readIn: UILang?, lang: UILang) -> [MailAccountSyncInfo] {
        guard readIn != lang else { return infos }
        return infos.map { info in
            var out = info
            out.status = info.status.map(textless)
            out.notEmailHint = nil
            out.skippedHint = nil
            return out
        }
    }

    /// The same status without its text.
    static func textless(_ s: MailSourceStatus) -> MailSourceStatus {
        switch s {
        case .ready: return .ready(detail: "")
        case .needsSetup: return .needsSetup("")
        case .authFailed: return .authFailed("")
        case .unavailable: return .unavailable("")
        }
    }

    /// `MailSourceStatus` → icon + text (the engine words its texts in the UI language; a status
    /// without text shows its kind).
    static func status(_ s: MailSourceStatus) -> (kind: StatusKind, text: String) {
        switch s {
        case .ready(let detail): return (.ok, detail.isEmpty ? L.MailPref.statusReady : detail)
        case .needsSetup(let m): return (.warning, m.isEmpty ? L.MailPref.statusNeedsSetup : m)
        case .authFailed(let m): return (.error, m.isEmpty ? L.MailPref.statusSignInFailed : m)
        case .unavailable(let m): return (.warning, m.isEmpty ? L.MailPref.statusUnavailable : m)
        }
    }

    /// The main status line of one account row (without the skipped sentence its notice shows —
    /// `MailAccountNotice.shownStatus`).
    static func line(account: MailAccount, info: MailAccountSyncInfo?, masterOn: Bool) -> (kind: StatusKind, text: String) {
        if !masterOn { return (.neutral, L.MailPref.statusMailOff) }
        if !account.enabled { return (.neutral, L.MailPref.statusPaused) }
        if info?.isSyncing == true { return (.working, L.MailPref.statusSyncing) }
        guard let status = MailAccountNotice.shownStatus(info, active: true) else { return (.pending, L.MailPref.statusNotChecked) }
        return self.status(status)
    }

    /// Second line: last success, retry time, parked state.
    static func detail(info: MailAccountSyncInfo?, account: MailAccount, masterOn: Bool) -> String? {
        guard masterOn, account.enabled, let info else { return nil }
        var parts: [String] = []
        if let last = info.lastSuccessAt {
            parts.append(L.MailPref.lastChecked(SettingsFormat.shortDateTime(last), new: info.lastCaptured))
        }
        if info.waitingForSettings {
            parts.append(L.MailPref.waitingForSettings)
        } else if let retry = info.nextRetryAt, info.consecutiveFailures > 0 {
            parts.append(L.MailPref.nextRetry(SettingsFormat.time(retry)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The master section's summary over every account.
    static func summary(settings: SettingsStore, infos: [MailAccountSyncInfo]) -> (kind: StatusKind, text: String) {
        guard settings.mailEnabled else { return (.neutral, L.MailPref.summaryOff) }
        let accounts = settings.mailAccounts.filter(\.enabled)
        if settings.mailAccounts.isEmpty { return (.warning, L.MailPref.summaryNoAccounts) }
        if accounts.isEmpty { return (.neutral, L.MailPref.summaryAllPaused) }
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = accounts.compactMap { byID[$0.id] }
        if live.contains(where: \.isSyncing) { return (.working, L.MailPref.summarySyncing(accounts.count)) }
        let problems = live.filter {
            switch $0.status {
            case .needsSetup?, .authFailed?, .unavailable?: return true
            default: return false
            }
        }
        if !problems.isEmpty { return (.warning, L.MailPref.summaryProblems(problems.count)) }
        guard let last = live.compactMap(\.lastSuccessAt).max() else {
            return (.pending, L.MailPref.summaryOK(accounts: accounts.count, last: nil))
        }
        return (.ok, L.MailPref.summaryOK(accounts: accounts.count, last: SettingsFormat.shortDateTime(last)))
    }
}

// MARK: - Off-main helpers

/// Network and file-system work of the settings tab (never on the main actor).
nonisolated enum MailSettingsIO {
    /// 「测试并保存」: LOGIN + EXAMINE + LOGOUT with the typed (not yet saved) password.
    static func testIMAP(_ account: MailAccount, password: String, lang: UILang) async -> MailSourceStatus {
        await Task.detached(priority: .userInitiated) {
            await IMAPMailSource.test(account: account, password: password, lang: lang)
        }.value
    }

    nonisolated struct FolderState: Sendable, Equatable {
        var exists: Bool
        var isFolder: Bool
        var parentExists: Bool
    }

    /// Existence only — never lists the folder (a OneDrive folder may be offline / placeholder).
    static func folderState(_ path: String) async -> FolderState {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        return await BlockingIO.run {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let parent = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
            return FolderState(exists: exists, isFolder: exists && isDir.boolValue, parentExists: parent)
        }
    }

    nonisolated struct CloudRoots: Sendable, Equatable {
        /// The synced roots of `~/Library/CloudStorage`, classified by name (`CloudRootLocator`).
        var roots: [CloudRoot]
        /// The roots' existing 「PaperDeck Mail」 folders.
        var mailFolders: [URL]
    }

    /// The folder forms' cloud roots (`CloudRootLocator.classify`). Lists only the provider root
    /// names in CloudStorage and checks whether `<root>/PaperDeck Mail` exists — never lists or
    /// reads anything inside a provider's folder.
    static func cloudRoots(home: URL) async -> CloudRoots {
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let folderName = String(PowerAutomatePackage.defaultFolderPath.drop { $0 == "/" })
        return await BlockingIO.run {
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: cloud.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            let roots = CloudRootLocator.classify(names: names, cloudStorage: cloud)
            let found = roots.map { $0.url.appendingPathComponent(folderName, isDirectory: true) }.filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            return CloudRoots(roots: roots, mailFolders: found)
        }
    }

    static func createFolder(_ path: String) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try await BlockingIO.run {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    /// Writes the Power Automate import package (Core's byte-stable ZIP).
    static func writeFlowPackage(senders: [String], folderPath: String, to url: URL) async throws {
        try await BlockingIO.run {
            try PowerAutomatePackage.makeZip(senders: senders, folderPath: folderPath, into: url)
        }
    }
}

// MARK: - Keyword chips

/// Chips with ✕ plus a field: Return, comma or semicolon adds the typed keyword(s).
struct MailKeywordField: View {
    @Binding var words: [String]
    let prompt: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !words.isEmpty {
                DetailFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(words, id: \.self) { word in chip(word) }
                }
            }
            TextField(prompt, text: $draft, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .onChange(of: draft) { _, new in
                    if new.contains(where: { ",;，；\n".contains($0) }) { commit() }
                }
        }
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 3) {
            Text(word).lineLimit(1)
            Button {
                words.removeAll { $0 == word }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L.MailPref.removeKeyword(word))
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }

    private func commit() {
        let parts = draft.split(whereSeparator: { ",;，；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        draft = ""
        guard !parts.isEmpty else { return }
        var out = words
        for p in parts where !out.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
            out.append(String(p.prefix(60)))
        }
        if out != words { words = out }
    }
}

// MARK: - Small views

/// A value to paste somewhere else (Power Automate fields): wraps instead of truncating, [复制].
struct MailCopyBox: View {
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? L.Pref.copied : L.Pref.copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// A tinted capsule for a sender kind (text always present — never colour alone).
struct MailSenderKindBadge: View {
    let kind: SenderKind

    var body: some View {
        Text(L.MailPref.kindName(kind))
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.13)))
            .fixedSize()
    }

    private var tint: Color {
        switch kind {
        case .advisor: .red
        case .person: .blue
        case .alert: .purple
        case .manual: .secondary
        }
    }
}

/// A multi-line text box that reads well inside a grouped form.
struct MailTextBox: View {
    @Binding var text: String
    var height: CGFloat = 54

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.fill.quaternary))
    }
}

enum MailSettingsFormat {
    /// `~/Library/CloudStorage/<root>/PaperDeck Mail`.
    static func path(_ p: String?) -> String {
        guard let p, !p.isEmpty else { return "—" }
        return SettingsFormat.tildePath((p as NSString).expandingTildeInPath)
    }

    /// `imap.gmail.com · INBOX · me@gmail.com` / `~/…/PaperDeck Mail`.
    static func accountDetail(_ a: MailAccount) -> String {
        switch a.kind {
        case .folder:
            return path(a.folderPath)
        case .imap:
            let host = (a.host?.isEmpty == false ? a.host : a.imapPreset?.host) ?? "?"
            let port = a.port ?? a.imapPreset?.port ?? 993
            var parts = [port == 993 ? host : "\(host):\(port)"]
            parts.append((a.mailbox?.isEmpty == false ? a.mailbox : nil) ?? "INBOX")
            if let u = a.username, !u.isEmpty { parts.append(u) }
            return parts.joined(separator: " · ")
        }
    }

    static func symbol(_ a: MailAccount) -> String {
        switch a.kind {
        case .folder: return MailSourceResolver.source(of: a) == .m365PowerAutomate ? "icloud.and.arrow.down" : "folder"
        case .imap: return "envelope"
        }
    }

    /// Options offered by a picker plus the current value when it isn't one of them.
    static func options(_ base: [Int], including current: Int) -> [Int] {
        Array(Set(base + [current])).sorted()
    }
}
