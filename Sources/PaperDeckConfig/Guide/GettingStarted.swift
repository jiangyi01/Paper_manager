import Foundation
import PaperDeckCore

/// The Getting Started checklist (Help Center, and a card on Today for fresh installs only).
package enum GettingStarted {
    package struct Item: Sendable, Equatable {
        package var id: String
        package var required: Bool
        package var state: CheckState
        package var visible: Bool

        package init(id: String, required: Bool, state: CheckState, visible: Bool) {
            self.id = id; self.required = required; self.state = state; self.visible = visible
        }
    }

    // Item ids (stable: `guide.skipped` stores them).
    package static let library = "library"
    package static let firstPaper = "first-paper"
    package static let dropStrip = "drop-strip"
    package static let openCard = "open-card"
    package static let ai = "ai"
    package static let reminder = "reminder"
    package static let login = "login"
    package static let widget = "widget"
    package static let mail = "mail"
    package static let senders = "senders"
    package static let backup = "backup"

    /// Every item, in checklist order.
    package static let allIDs = [library, firstPaper, dropStrip, openCard, ai, reminder, login, widget, mail, senders, backup]
    /// The items setup can't finish without.
    package static let requiredIDs: Set<String> = [library, firstPaper, ai]

    /// The `guide.manualDone` entry of "I've added the widget" (when macOS doesn't say whether a
    /// widget is placed — the checklist's one manual tick).
    package static let widgetManualKey = "getting-started/widget"

    /// `onboarding.mailDecision` values that mean "no mail account": the mail row turns into
    /// "Not using mail · Set up".
    package static let noMailDecisions: Set<String> = ["skipped", "dragOnly"]

    /// The §3.4 table, live. Optional items in `skipped` are hidden; required items can't be skipped.
    package static func items(_ f: SetupFacts, skipped: Set<String>, mailDecision: String?,
                              manualDone: Set<String> = []) -> [Item] {
        func item(_ id: String, _ state: CheckState, visible: Bool = true) -> Item {
            let required = requiredIDs.contains(id)
            return Item(id: id, required: required, state: state, visible: visible && (required || !skipped.contains(id)))
        }
        let eval = { (c: GuideCheck) in GuideEvaluator.evaluate(c, f) }

        let reminderState: CheckState = f.notifications.known?.reminderEnabled == false
            ? .notApplicable : eval(.notificationsAllowed)

        var widgetState = eval(.widgetPlaced)
        if widgetState == .unknown {
            // macOS didn't say whether a widget is on the desktop: registered + the user's tick.
            let registered = eval(.widgetRegistered)
            widgetState = registered == .done ? (manualDone.contains(widgetManualKey) ? .done : .todo) : registered
        }

        let noMail = mailDecision.map(noMailDecisions.contains) ?? false
        let papers = f.papers.known?.live ?? 0

        return [
            item(library, eval(.libraryUsable)),
            item(firstPaper, eval(.hasPapers(1))),
            item(dropStrip, eval(.activity([.panelDrop, .menuBarDrop]))),
            item(openCard, eval(.openedPaper)),
            item(ai, eval(.aiDecided)),
            item(reminder, reminderState),
            item(login, eval(.launchAtLogin)),
            item(widget, widgetState),
            item(mail, noMail ? .notApplicable : eval(.mailAccountReady(nil))),
            item(senders, eval(.sendersAdded(nil)), visible: !f.mail.accounts.isEmpty),
            item(backup, eval(.settingsExported), visible: f.features.contains(.settingsTransfer) && papers >= 10),
        ]
    }

    /// "n of m": visible items that apply (required ones plus the optional ones shown).
    package static func progress(_ items: [Item]) -> (done: Int, total: Int) {
        let counted = items.filter { $0.visible && $0.state != .notApplicable }
        return (counted.count(where: { $0.state == .done }), counted.count)
    }

    /// The Today card and the menu-bar entry: fresh installs only (a legacy install never sees
    /// them), until dismissed or every required item is done.
    package static func showOnToday(origin: ConfigOrigin, dismissed: Bool, items: [Item]) -> Bool {
        guard origin == .fresh, !dismissed else { return false }
        return items.contains { $0.required && $0.visible && $0.state != .done }
    }

    /// The row title.
    package static func title(_ id: String) -> LocalizedText {
        switch id {
        case library: return LocalizedText(en: "Your library folder is ready", zh: "论文库文件夹已就绪")
        case firstPaper: return LocalizedText(en: "Add your first paper", zh: "添加第一篇论文")
        case dropStrip: return LocalizedText(en: "Drop a PDF on the edge strip or the menu-bar icon",
                                             zh: "把 PDF 拖到屏幕边缘的条或菜单栏图标上")
        case openCard: return LocalizedText(en: "Open a paper's reading card", zh: "打开一篇论文的阅读卡片")
        case ai: return LocalizedText(en: "Choose AI reading — or go without", zh: "选择 AI 解读——或不使用 AI")
        case reminder: return LocalizedText(en: "Allow the daily reminder", zh: "允许每日提醒")
        case login: return LocalizedText(en: "Open PaperDeck at login", zh: "登录时打开 PaperDeck")
        case widget: return LocalizedText(en: "Add the desktop widget", zh: "添加桌面小组件")
        case mail: return LocalizedText(en: "Connect your mail", zh: "连接你的邮件")
        case senders: return LocalizedText(en: "Tell PaperDeck who sends you papers", zh: "告诉 PaperDeck 谁会给你发论文")
        case backup: return LocalizedText(en: "Keep a settings backup", zh: "保存一份设置备份")
        default: return LocalizedText(id)
        }
    }

    /// The Help topic behind a row (nil: the row's own buttons are enough).
    package static func topic(_ id: String) -> GuideTopicID? {
        switch id {
        case library: return .libraryLocation
        case ai: return .aiSetup
        case widget: return .fixWidgetMissing
        case mail: return .connectMail
        case senders: return .mailSendersAndAI
        case backup: return .moveToNewMac
        case reminder: return .fixNotifications
        case login: return .fixLoginItem
        default: return nil
        }
    }
}

/// Whether the launch must run the onboarding preflight before the engine opens (fresh installs
/// only: origin fresh, no `setup.completed`, no `library.path`, no database, no `--gui-root`, no
/// `onboarding.legacy`).
package enum OnboardingGate {
    /// `p` is the persisted domain (never the registered defaults: `setup.completed` and
    /// `library.path` are registered by `SettingsStore`). An origin not written yet (the migration
    /// didn't run) is the legacy detector's answer — so an existing install never sees the preflight.
    package static func needsPreflight(_ p: PersistedDomain, databaseExists: Bool, rootOverride: Bool) -> Bool {
        guard !rootOverride, !databaseExists else { return false }
        guard !p.has("setup.completed"), !p.has("library.path") else { return false }
        if (p.values[ConfigKeys.onboardingLegacy] as? NSNumber)?.boolValue == true { return false }
        return origin(p, databaseExists: databaseExists) == .fresh
    }

    /// The stored `config.origin`, else what `LegacyInstallDetector` says.
    package static func origin(_ p: PersistedDomain, databaseExists: Bool) -> ConfigOrigin {
        if let stored = p.string(ConfigKeys.origin).flatMap(ConfigOrigin.init(rawValue:)) { return stored }
        return LegacyInstallDetector.isLegacy(p, databaseExists: databaseExists) ? .legacy : .fresh
    }
}
