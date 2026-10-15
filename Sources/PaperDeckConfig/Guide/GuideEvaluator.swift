import Foundation
import PaperDeckCore

/// Evaluates checks and steps over `SetupFacts` (pure: no I/O, no clock).
///
/// Two kinds of checks:
/// - **goals** (`libraryUsable`, `hasPapers`, `mailEnabled`, …): `.done` once reached, `.todo` before,
///   `.problem(reason)` when something blocks them;
/// - **symptoms** (`documentsDenied`, `libraryMismatchNow`, `papersMissing`, `fullTextIncomplete`,
///   `usageLimitPaused`, `loginItemNeedsApproval`, `mailAccountAuthFailed`, `libraryOnRemovableVolume`,
///   `libraryUbiquitous`): `.problem(reason)` while the symptom is present (a troubleshooting entry
///   "applies now"), `.done` when it is absent.
///
/// A fact that is still being probed is `.unknown` — never shown as done.
package enum GuideEvaluator {
    package static func evaluate(_ c: GuideCheck, _ f: SetupFacts) -> CheckState {
        switch c {
        // MARK: Library
        case .libraryUsable:
            guard let lib = f.library.known else { return .unknown }
            switch lib.status {
            case .ok, .ubiquitous: return .done
            case .denied: return .problem(Reason.libraryDenied)
            case .missing: return .problem(Reason.libraryMissing)
            case .readOnly: return .problem(Reason.libraryReadOnly)
            }
        case .libraryLocal:
            guard let lib = f.library.known else { return .unknown }
            return lib.volume == .local && lib.status != .ubiquitous ? .done : .todo
        case .libraryHasManifest:
            guard let lib = f.library.known else { return .unknown }
            return lib.hasManifest ? .done : .todo
        case .libraryUbiquitous:
            guard let lib = f.library.known else { return .unknown }
            return lib.volume == .cloud || lib.status == .ubiquitous ? .problem(Reason.libraryInCloud) : .done
        case .libraryOnRemovableVolume:
            guard let lib = f.library.known else { return .unknown }
            let external = lib.volume == .removable || lib.volume == .network || lib.tildePath.hasPrefix("/Volumes/")
            return external && lib.status == .missing ? .problem(Reason.diskDisconnected) : .done
        case .documentsDenied:
            guard let lib = f.library.known else { return .unknown }
            return lib.status == .denied ? .problem(Reason.libraryDenied) : .done
        case .libraryMismatchNow:
            guard let lib = f.library.known else { return .unknown }
            if case .mismatch(_, _, let n)? = lib.identity { return .problem(Reason.mismatch(n)) }
            return .done
        case .papersMissing:
            guard let p = f.papers.known else { return .unknown }
            return p.missingFiles > 0 ? .problem(Reason.papersMissing(p.missingFiles)) : .done
        case .fullTextIncomplete:
            guard let p = f.papers.known else { return .unknown }
            let missing = max(0, p.live - p.fullTextIndexed)
            return missing > 0 ? .problem(Reason.fullText(missing)) : .done
        case .hasPapers(let n):
            guard let p = f.papers.known else { return .unknown }
            return p.live >= max(1, n) ? .done : .todo
        case .openedPaper:
            if f.activity[.openedDetail] != nil { return .done }
            guard let p = f.papers.known else { return .unknown }
            return p.opened > 0 ? .done : .todo
        case .activity(let kinds):
            return kinds.contains { f.activity[$0] != nil } ? .done : .todo

        // MARK: AI
        case .aiDecided:
            return aiDecided(f)
        case .aiReady:
            // The provider reading runs with; nothing to check while AI reading is off.
            guard let kind = f.ai.mode.providerKind else { return .notApplicable }
            return providerReady(kind, f)
        case .usageLimitPaused:
            if let until = f.ai.pausedUntil { return .problem(Reason.paused(until)) }
            return .done
        case .providerInstalled(let k):
            guard let s = f.ai.statuses[k]?.known else { return .unknown }
            if case .notInstalled = s { return .todo }
            return .done
        case .providerSignedIn(let k):
            guard let s = f.ai.statuses[k]?.known else { return .unknown }
            switch s {
            case .ready: return .done
            case .notInstalled: return .todo
            case .notLoggedIn(let code):
                if case .nonSubscription = ProviderReason(code: code) { return .problem(Reason.provider(s, k)) }
                return .todo
            case .unsupported: return .problem(Reason.provider(s, k))
            }
        case .providerSubscription(let k):
            guard let s = f.ai.statuses[k]?.known else { return .unknown }
            switch s {
            case .ready: return .done
            case .notLoggedIn(let code):
                if case .nonSubscription = ProviderReason(code: code) { return .problem(Reason.provider(s, k)) }
                return .todo
            case .notInstalled, .unsupported: return .todo
            }

        // MARK: Notifications, login item, widget
        case .notificationsAllowed:
            guard let n = f.notifications.known else { return .unknown }
            switch n.authorization {
            case .authorized, .provisional: return .done
            case .denied: return .problem(Reason.notificationsDenied)
            case .notDetermined: return .todo
            case .unavailable: return .notApplicable
            }
        case .reminderEnabled:
            guard let n = f.notifications.known else { return .unknown }
            return n.reminderEnabled ? .done : .todo
        case .launchAtLogin:
            guard let l = f.loginItem.known else { return .unknown }
            switch l.status {
            case .enabled: return .done
            case .requiresApproval: return .problem(Reason.loginApproval)
            case .notRegistered: return .todo
            case .notFound: return .notApplicable
            }
        case .loginItemNeedsApproval:
            guard let l = f.loginItem.known else { return .unknown }
            return l.status == .requiresApproval ? .problem(Reason.loginApproval) : .done
        case .widgetRegistered:
            guard let w = f.widget.known else { return .unknown }
            switch w.registration {
            case .registered: return .done
            case .disabled: return .problem(Reason.widgetDisabled)
            case .notRegistered: return .todo
            case .failed: return .unknown
            }
        case .widgetPlaced:
            guard let w = f.widget.known, let placed = w.placedCount else { return .unknown }
            return placed > 0 ? .done : .todo

        // MARK: The app itself
        case .appInApplications:
            guard let a = f.app.known else { return .unknown }
            switch a.location {
            case .applications, .userApplications: return .done
            case .translocated: return .problem(Reason.translocated)
            case .other: return .problem(Reason.notInApplications)
            }
        case .notTranslocated:
            guard let a = f.app.known else { return .unknown }
            return a.location == .translocated ? .problem(Reason.translocated) : .done
        case .notQuarantined:
            guard let a = f.app.known else { return .unknown }
            return a.quarantined ? .problem(Reason.quarantined) : .done
        case .stableSigning:
            guard let s = f.signing.known else { return .unknown }
            switch s.kind {
            case .certificate: return .done
            case .adhoc: return .problem(Reason.adhoc)
            case .unsigned: return .problem(Reason.unsigned)
            }

        // MARK: Cloud folders
        case .cloudRootPresent(let provider):
            guard let c = f.cloud.known else { return .unknown }
            return c.roots.contains { $0.provider == provider } ? .done : .todo
        case .oneDriveBusinessPresent:
            guard let c = f.cloud.known else { return .unknown }
            return c.roots.contains { $0.provider == .oneDriveBusiness } ? .done : .todo

        // MARK: Mail
        case .mailEnabled:
            return f.mail.enabled ? .done : .todo
        case .mailAccountExists(let source):
            return accounts(f, source).isEmpty ? .todo : .done
        case .mailAccountReady(let source):
            let matching = accounts(f, source)
            // Ready, or reachable: a pass that got through but left emails skipped or undownloadable
            // is a warning about those emails (the inbox pill), not "the server isn't reachable".
            if matching.contains(where: { if case .ready? = $0.status { return true }; return $0.reachable }) { return .done }
            let failed = matching.filter { if case .authFailed? = $0.status { return true }; return false }
            if !failed.isEmpty { return .problem(Reason.authFailed(failed.count)) }
            if matching.contains(where: { if case .unavailable? = $0.status { return true }; return false }) {
                return .problem(Reason.mailUnavailable)
            }
            return .todo
        case .mailAccountAuthFailed:
            let failed = f.mail.accounts.filter { if case .authFailed? = $0.status { return true }; return false }
            return failed.isEmpty ? .done : .problem(Reason.authFailed(failed.count))
        case .mailFirstCapture(let source):
            return accounts(f, source).contains { $0.captured > 0 } ? .done : .todo
        case .mailFolderExists:
            let folders = f.mail.accounts.filter { $0.folderExists != nil }
            if folders.contains(where: { $0.folderExists == true }) || f.mail.suggestedFolderExists == true { return .done }
            if !folders.isEmpty { return .problem(Reason.folderMissing) }
            return .todo
        case .mailNoNotEmailFiles:
            let bad = f.mail.accounts.reduce(0) { $0 + $1.notEmailFiles }
            if bad > 0 { return .problem(Reason.notEmailFiles(bad)) }
            return f.mail.accounts.contains { $0.captured > 0 } ? .done : .todo
        case .sendersAdded(let kind):
            let n = kind.map { f.mail.senders[$0] ?? 0 } ?? f.mail.senders.values.reduce(0, +)
            return n > 0 ? .done : .todo
        case .imapPasswordsPresent:
            let imap = f.mail.accounts.filter { $0.source.imapPreset != nil }
            if imap.isEmpty { return .notApplicable }
            if imap.contains(where: { $0.passwordPresent == nil }) { return .unknown }
            let missing = imap.count(where: { $0.passwordPresent == false })
            return missing > 0 ? .problem(Reason.passwordsMissing(missing)) : .done
        case .emlImportedManually:
            return f.mail.emlImportedManually || f.activity[.emlImported] != nil ? .done : .todo

        // MARK: Settings transfer & profile
        case .settingsExported:
            guard f.features.contains(.settingsTransfer) else { return .notApplicable }
            return f.transfer.lastExportedAt != nil ? .done : .todo
        case .settingsImported:
            guard f.features.contains(.settingsTransfer) else { return .notApplicable }
            return f.transfer.importedAt != nil ? .done : .todo
        case .profileSet:
            return f.profile.fieldID != nil && f.profile.organizationID != nil ? .done : .todo
        }
    }

    /// One step of a topic (0-based `step`): its check, the later step that implies it, the user's
    /// tick (`manualDone` holds `manualKey(topic:step:)`), or nothing to check (`.notApplicable`).
    package static func evaluate(step: Int, in t: GuideTopic, _ f: SetupFacts, manualDone: Set<String>) -> CheckState {
        evaluate(step: step, in: t, f, manualDone: manualDone, depth: 0)
    }

    private static func evaluate(step: Int, in t: GuideTopic, _ f: SetupFacts, manualDone: Set<String>,
                                 depth: Int) -> CheckState {
        guard t.steps.indices.contains(step), depth <= t.steps.count else { return .unknown }
        let s = t.steps[step]
        switch s.verification {
        case .check(let c):
            return evaluate(c, f)
        case .impliedBy(let later):
            // Only a later step can confirm an external one (a website step, a flow). Its problem
            // stays with it: this step is just not confirmed yet.
            guard later > step else { return .unknown }
            switch evaluate(step: later, in: t, f, manualDone: manualDone, depth: depth + 1) {
            case .done: return .done
            case .unknown: return .unknown
            case .todo, .problem, .notApplicable: return .todo
            }
        case .manual:
            return manualDone.contains(manualKey(topic: t.id, step: s.id)) ? .done : .todo
        case .info:
            return .notApplicable
        }
    }

    /// The `guide.manualDone` entry for a step the user ticked.
    package static func manualKey(topic: GuideTopicID, step: String) -> String {
        "\(topic.rawValue)/\(step)"
    }

    /// A topic's "Status now" header.
    package enum TopicStatus: Sendable, Equatable {
        case done
        case inProgress(done: Int, total: Int)
        case problem(LocalizedText)
        case unknown
        /// Nothing on this page can be checked (reference pages) — or a troubleshooting entry
        /// whose symptom is absent.
        case nothingToCheck
    }

    /// Troubleshooting entries: their `diagnosis` (a problem = "applies now"); other topics: their
    /// steps (the first problem wins; done when every checkable step is done).
    package static func status(of t: GuideTopic, _ f: SetupFacts, manualDone: Set<String>) -> TopicStatus {
        if t.kind == .troubleshoot, let d = t.diagnosis {
            switch evaluate(d, f) {
            case .problem(let why): return .problem(why)
            case .unknown: return .unknown
            case .done, .todo, .notApplicable: return .nothingToCheck
            }
        }
        let states = t.steps.indices.map { evaluate(step: $0, in: t, f, manualDone: manualDone) }
        if let why = states.lazy.compactMap({ if case .problem(let r) = $0 { return r }; return nil }).first {
            return .problem(why)
        }
        let checkable = states.filter { $0 != .notApplicable }
        if checkable.isEmpty { return .nothingToCheck }
        if checkable.allSatisfy({ $0 == .done }) { return .done }
        if checkable.allSatisfy({ $0 == .unknown }) { return .unknown }
        return .inProgress(done: checkable.count(where: { $0 == .done }), total: checkable.count)
    }

    /// Whether a troubleshooting entry's symptom is present now ("Applies now").
    package static func appliesNow(_ t: GuideTopic, _ f: SetupFacts) -> Bool {
        guard t.kind == .troubleshoot, let d = t.diagnosis, case .problem = evaluate(d, f) else { return false }
        return true
    }

    // MARK: Helpers

    private static func accounts(_ f: SetupFacts, _ source: MailSourceID?) -> [MailAccountFact] {
        guard let source else { return f.mail.accounts }
        return f.mail.accounts.filter { $0.source == source }
    }

    private static func aiDecided(_ f: SetupFacts) -> CheckState {
        if let kind = f.ai.mode.providerKind {
            // Reading is on: decided — and it has to work.
            switch providerReady(kind, f) {
            case .problem(let why): return .problem(why)
            case .unknown: return .unknown
            default: return .done
            }
        }
        // Off: an explicit "not now" is a decision; a provider picked but never turned on is not.
        return f.ai.decision == "none" ? .done : .todo
    }

    private static func providerReady(_ kind: AIProviderKind, _ f: SetupFacts) -> CheckState {
        guard let s = f.ai.statuses[kind]?.known else { return .unknown }
        switch s {
        case .ready: return .done
        case .notInstalled: return .problem(Reason.provider(s, kind))
        case .notLoggedIn, .unsupported: return .problem(Reason.provider(s, kind))
        }
    }

    /// Problem reasons (display text; never sent anywhere).
    enum Reason {
        static let libraryDenied = LocalizedText(
            en: "PaperDeck isn't allowed to use this folder (System Settings ▸ Privacy & Security ▸ Files and Folders).",
            zh: "PaperDeck 没有权限使用这个文件夹（系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹）。")
        static let libraryMissing = LocalizedText(
            en: "The library folder isn't there (a disk may be disconnected).",
            zh: "找不到论文库文件夹（可能断开了磁盘）。")
        static let libraryReadOnly = LocalizedText(
            en: "The library folder can't be written to.",
            zh: "论文库文件夹无法写入。")
        static let libraryInCloud = LocalizedText(
            en: "Your library is in a cloud-synced folder: use it on one Mac at a time and keep it downloaded.",
            zh: "论文库在云同步文件夹中：同一时间只在一台 Mac 上使用，并保持文件已下载。")
        static let diskDisconnected = LocalizedText(
            en: "The disk with your library isn't connected.",
            zh: "存放论文库的磁盘没有连接。")
        static func mismatch(_ n: Int) -> LocalizedText {
            LocalizedText(en: "This folder holds a different PaperDeck library than the index (\(n) papers).",
                          zh: "这个文件夹里的论文库与 PaperDeck 的索引不一致（\(n) 篇论文）。")
        }
        static func papersMissing(_ n: Int) -> LocalizedText {
            LocalizedText(en: "\(n) PDF\(n == 1 ? " is" : "s are") missing from the library folder.",
                          zh: "论文库文件夹中缺少 \(n) 个 PDF。")
        }
        static func fullText(_ n: Int) -> LocalizedText {
            LocalizedText(en: "\(n) paper\(n == 1 ? " has" : "s have") no full-text index yet.",
                          zh: "\(n) 篇论文还没有全文索引。")
        }
        static func paused(_ until: Date) -> LocalizedText {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            let t = f.string(from: until)
            return LocalizedText(en: "AI reading is paused by a usage limit until \(t); nothing is lost.",
                                 zh: "AI 解读因用量上限暂停到 \(t)，不会丢失任何内容。")
        }
        static func provider(_ s: ProviderStatus, _ k: AIProviderKind) -> LocalizedText {
            LocalizedText(en: s.reasonText(.en, provider: k), zh: s.reasonText(.zh, provider: k))
        }
        static let notificationsDenied = LocalizedText(
            en: "Notifications are turned off for PaperDeck in System Settings.",
            zh: "已在系统设置中关闭 PaperDeck 的通知。")
        static let loginApproval = LocalizedText(
            en: "Waiting for your approval in System Settings ▸ General ▸ Login Items.",
            zh: "等待你在「系统设置 ▸ 通用 ▸ 登录项」中允许。")
        static let widgetDisabled = LocalizedText(
            en: "The widget is turned off in System Settings.",
            zh: "小组件已在系统设置中关闭。")
        static let translocated = LocalizedText(
            en: "macOS is running PaperDeck from a temporary copy. Move it to Applications and open it again.",
            zh: "macOS 正在从临时副本运行 PaperDeck。请把它移到「应用程序」文件夹后重新打开。")
        static let notInApplications = LocalizedText(
            en: "PaperDeck isn't in your Applications folder.",
            zh: "PaperDeck 不在「应用程序」文件夹中。")
        static let quarantined = LocalizedText(
            en: "macOS still marks PaperDeck as downloaded from the internet.",
            zh: "macOS 仍把 PaperDeck 标记为从互联网下载的应用。")
        static let adhoc = LocalizedText(
            en: "Signed ad hoc: macOS forgets PaperDeck's permissions after each rebuild.",
            zh: "临时（ad hoc）签名：每次重新构建后 macOS 都会忘记 PaperDeck 的权限。")
        static let unsigned = LocalizedText(
            en: "This build isn't signed.",
            zh: "这个版本没有签名。")
        static func authFailed(_ n: Int) -> LocalizedText {
            LocalizedText(en: "Sign-in failed for \(n) mail account\(n == 1 ? "" : "s") — check the app password.",
                          zh: "\(n) 个邮件账户登录失败——请检查应用专用密码。")
        }
        static let mailUnavailable = LocalizedText(
            en: "The mail server or folder isn't reachable right now.",
            zh: "邮件服务器或文件夹暂时无法访问。")
        static let folderMissing = LocalizedText(
            en: "The watched folder doesn't exist on this Mac.",
            zh: "这台 Mac 上没有被监视的文件夹。")
        static func notEmailFiles(_ n: Int) -> LocalizedText {
            LocalizedText(en: "\(n) file\(n == 1 ? " is" : "s are") not complete emails.",
                          zh: "有 \(n) 个文件不是完整的邮件。")
        }
        static func passwordsMissing(_ n: Int) -> LocalizedText {
            LocalizedText(en: "\(n) mail account\(n == 1 ? " needs its" : "s need their") app password on this Mac.",
                          zh: "\(n) 个邮件账户需要在这台 Mac 上重新输入应用专用密码。")
        }
    }
}
