import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

// Building blocks shared by the Help Center and the onboarding window.

/// ✓ / ○ / ⚠ / checking / – for a `CheckState` (symbol + colour, never colour alone).
struct CheckStateIcon: View {
    let state: CheckState

    var body: some View {
        Group {
            switch state {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
            case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unknown: ProgressView().controlSize(.mini)
            case .notApplicable: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(Self.label(state))
    }

    static func label(_ s: CheckState) -> String {
        switch s {
        case .done: L.Help.stepDone
        case .todo: L.Help.stepTodo
        case .problem(let why): why(L.lang)
        case .unknown: L.Help.stepChecking
        case .notApplicable: L.Help.stepNotApplicable
        }
    }
}

/// Inline Markdown (`**bold**`, `` `code` ``, links) from guide content.
struct GuideText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.attributed(text)).fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// The "Status now" header of a topic.
struct TopicStatusLine: View {
    let status: GuideEvaluator.TopicStatus
    var troubleshoot = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L.Help.statusNow).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            switch status {
            case .done: StatusLine(.ok, L.Help.statusDone)
            case .inProgress(let d, let t): StatusLine(.pending, L.Help.statusInProgress(d, t))
            case .problem(let why): StatusLine(.warning, why(L.lang))
            case .unknown: StatusLine(.working, L.Help.statusChecking)
            case .nothingToCheck: StatusLine(.neutral, troubleshoot ? L.Help.statusNotApplying : L.Help.statusNothing)
            }
        }
        .font(.callout)
    }
}

/// What a guide button does, in the app (or in the onboarding window before the engine exists:
/// actions that need the engine are then skipped).
@MainActor
struct GuideActionRunner {
    let settings: SettingsStore
    weak var state: AppState?
    var openTopic: (GuideTopicID) -> Void
    /// Presents the add-account sheet for a source (nil: nowhere to present it).
    var openMailSheet: ((MailSourceID) -> Void)?

    func title(_ action: GuideAction) -> String {
        switch action {
        case .openTopic(let id): return GuideCatalog.topic(id)?.title(L.lang) ?? L.Help.learnMore
        case .openSettings(let tab): return L.Help.openSettingsTab(tab)
        case .deepLink: return L.Help.openLink
        case .openURL(let url): return url.host ?? L.Help.openLink
        case .router(let r):
            switch r {
            case .pickAndImportFiles: return L.Help.addPDF
            case .armDropPanel: return L.Help.showDropStrip
            case .showToday: return L.Help.openToday
            case .showMail: return L.Help.openMail
            case .openFirstPaper: return L.Help.openFirstPaper
            case .showMenuBarMenu: return L.Help.showMenuBarMenu
            case .revealLibrary: return L.Help.revealLibrary
            case .exportSettings: return L.Help.exportSettings
            case .importSettings: return L.Help.importSettings
            case .openSetup: return L.Help.openSetup
            case .openTour: return L.Help.openTour
            case .reindexFullText: return L.Help.reindexFullText
            case .repairWidget: return L.Help.repairWidget
            }
        case .systemSettings: return L.Help.openSystemSettings
        case .openMailSheet: return L.Help.addAccount
        case .copyGenerated(let a):
            switch a {
            case .appleMailRuleScript: return L.Help.copyAppleScript
            case .googleAppsScript: return L.Help.copyAppsScript
            case .powerAutomatePackage: return L.Help.savePackage
            }
        }
    }

    func symbol(_ action: GuideAction) -> String? {
        switch action {
        case .openURL: "arrow.up.right.square"
        case .copyGenerated(.powerAutomatePackage): "square.and.arrow.down"
        case .copyGenerated: "doc.on.doc"
        case .openTopic: "questionmark.circle"
        default: nil
        }
    }

    /// Whether the action can run now (engine-backed actions need the library to be open).
    func isAvailable(_ action: GuideAction) -> Bool {
        switch action {
        case .openTopic, .openURL, .systemSettings, .copyGenerated(.appleMailRuleScript), .copyGenerated(.googleAppsScript):
            return true
        case .openMailSheet: return state != nil && openMailSheet != nil
        default: return state != nil
        }
    }

    func perform(_ action: GuideAction) {
        switch action {
        case .openTopic(let id):
            openTopic(id)
        case .openSettings(let tab):
            state?.router.showSettings(tab)
        case .deepLink(let link):
            if let state { URLRouter.handle(link, state: state) }
        case .openURL(let url):
            // Only the official sites the catalog may link to (a lint checks the content too).
            guard GuideLinks.isAllowed(url) else { return }
            NSWorkspace.shared.open(url)
        case .router(let r):
            run(r)
        case .systemSettings(let pane):
            switch pane {
            case .notifications: ReminderService.openSystemNotificationSettings()
            case .loginItems: SystemLinks.open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            case .filesAndFolders: SystemLinks.filesAndFolders()
            case .privacySecurity: SystemLinks.open("x-apple.systempreferences:com.apple.preference.security")
            case .screenRecording: ScreenPermission.openSystemSettings()
            case .keyboardShortcuts: ScreenPermission.openKeyboardShortcuts()
            }
        case .openMailSheet(let source):
            openMailSheet?(source)
        case .copyGenerated(let artifact):
            generate(artifact)
        }
    }

    private func run(_ r: GuideRouterAction) {
        guard let state else {
            if r == .openSetup { HelpCenter.openSetup(nil) }
            return
        }
        switch r {
        case .pickAndImportFiles: state.router.pickAndImportFiles()
        case .armDropPanel: state.router.armDropPanel(10)
        case .showToday: state.router.showToday()
        case .showMail: state.router.showMail(nil)
        case .openFirstPaper:
            if let row = state.snapshot?.rows.first { state.router.showPaper(row.id) } else { state.router.showToday() }
        case .showMenuBarMenu: state.router.showMenuBarMenu()
        case .revealLibrary: NSWorkspace.shared.activateFileViewerSelecting([state.engine.paths.library])
        case .exportSettings, .importSettings: state.router.showSettings("general")
        case .openSetup: HelpCenter.openSetup(nil)
        case .openTour: HelpCenter.openTour()
        case .reindexFullText:
            let engine = state.engine
            Task {
                let n = await engine.reindexMissingFullText()
                state.facts?.recountFullText()
                state.post(Toast(kind: .success, message: L.Help.reindexed(n)))
            }
        case .repairWidget: state.router.showSettings("widget")
        }
    }

    /// Scripts built from this Mac's settings: only folder names and the sender list, never a secret.
    private func generate(_ artifact: GeneratedArtifact) {
        let senders = settings.mailSenders.filter(\.enabled).map(\.pattern)
        switch artifact {
        case .appleMailRuleScript:
            let folder = settings.mailAccounts.first(where: { $0.kind == .folder && MailSourceResolver.source(of: $0) == .folder })?
                .folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? SharedPaths.realHome.appendingPathComponent("PaperDeck Mail", isDirectory: true)
            copy(MailRuleScripts.appleMailRule(folder: folder))
        case .googleAppsScript:
            copy(MailRuleScripts.googleAppsScript(driveFolderName: PowerAutomatePackage.defaultFlowName, senders: senders, label: nil))
        case .powerAutomatePackage:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = PowerAutomatePackage.suggestedFileName()
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try PowerAutomatePackage.makeZip(senders: PowerAutomatePackage.senders(from: settings.mailSenders),
                                                 folderPath: PowerAutomatePackage.defaultFolderPath,
                                                 flowName: PowerAutomatePackage.defaultFlowName, into: url)
            } catch {
                state?.post(Toast(kind: .error, message: String(describing: error)))
            }
        }
    }

    private func copy(_ s: String) {
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        state?.post(Toast(kind: .success, message: L.Help.copied))
    }
}

/// One row of buttons for a step's actions.
struct GuideActionButtons: View {
    let actions: [GuideAction]
    let runner: GuideActionRunner
    var prominentFirst = false

    var body: some View {
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    let button = Button {
                        runner.perform(action)
                    } label: {
                        if let symbol = runner.symbol(action) {
                            Label(runner.title(action), systemImage: symbol)
                        } else {
                            Text(runner.title(action))
                        }
                    }
                    .disabled(!runner.isAvailable(action))
                    if i == 0 && prominentFirst {
                        button.buttonStyle(.borderedProminent)
                    } else {
                        button
                    }
                }
            }
            .controlSize(.small)
        }
    }
}
