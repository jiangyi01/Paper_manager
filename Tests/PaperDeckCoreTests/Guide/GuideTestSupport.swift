import Foundation
@testable import PaperDeckCore
import PaperDeckConfig

/// Synthetic guide content and facts for the Guide suites (the real catalog is `GuideContent`).
enum GuideSamples {
    static func text(_ en: String, _ zh: String) -> LocalizedText { LocalizedText(en: en, zh: zh) }

    static let m365 = GuideTopic(
        id: .mailM365PowerAutomate, kind: .tutorial,
        title: text("Microsoft 365 with Power Automate", "Microsoft 365 + Power Automate"),
        summary: text("Save allowlisted emails to OneDrive.", "把白名单邮件存到 OneDrive。"),
        keywords: [text("OneDrive", "OneDrive"), text("Outlook", "Outlook")],
        steps: [
            GuideStep(id: "onedrive", text: text("Install OneDrive", "安装 OneDrive"), verification: .check(.oneDriveBusinessPresent)),
            GuideStep(id: "folder", text: text("Create the folder", "创建文件夹"), verification: .check(.mailFolderExists)),
            GuideStep(id: "flow", text: text("Build the flow", "创建流程"), verification: .impliedBy(step: 5),
                      actions: [.openURL(URL(string: "https://make.powerautomate.com")!)]),
            GuideStep(id: "account", text: text("Add the account", "添加账户"), verification: .check(.mailAccountExists(.m365PowerAutomate))),
            GuideStep(id: "on", text: text("Turn on Mail", "开启邮件"), verification: .check(.mailEnabled)),
            GuideStep(id: "first", text: text("First email arrives", "收到第一封邮件"),
                      verification: .check(.mailFirstCapture(.m365PowerAutomate))),
        ],
        related: [.mailM365Blocked], lastReviewed: "2026-10")

    static let blocked = GuideTopic(
        id: .mailM365Blocked, kind: .tutorial,
        title: text("When Microsoft 365 blocks Power Automate", "Microsoft 365 禁用 Power Automate 时"),
        summary: text("Other ways to get mail in.", "其他获取邮件的方式。"),
        keywords: [text("blocked", "禁用"), text("email", "邮件")],
        steps: [GuideStep(id: "drag", text: text("Drag emails in", "拖入邮件"),
                          verification: .manual(reason: text("no local signal until you drag", "拖入之前本机没有信号")))],
        related: [.mailM365PowerAutomate], lastReviewed: "2026-10")

    static let widget = GuideTopic(
        id: .fixWidgetMissing, kind: .troubleshoot,
        title: text("The widget isn't in the gallery", "小组件不在列表中"),
        summary: text("Move PaperDeck to Applications and launch it once.", "把 PaperDeck 移到「应用程序」并打开一次。"),
        keywords: [text("widget", "小组件")],
        steps: [GuideStep(id: "apps", text: text("Move to Applications", "移到应用程序"), verification: .check(.appInApplications),
                          commands: ["open -a PaperDeck"])],
        diagnosis: .widgetRegistered, lastReviewed: "2026-10")

    static let documents = GuideTopic(
        id: .fixDocumentsAccess, kind: .troubleshoot,
        title: text("Can't use the library folder", "无法使用论文库文件夹"),
        summary: text("Documents access was denied.", "访问「文稿」被拒绝。"),
        diagnosis: .documentsDenied, lastReviewed: "2026-10")

    static let all = [m365, blocked, widget, documents]

    // MARK: Facts

    static let library = LibraryFact(status: .ok, tildePath: "~/Documents/PaperDeck", volume: .local, hasManifest: true)

    static func facts(_ edit: (inout SetupFacts) -> Void = { _ in }) -> SetupFacts {
        var f = SetupFacts(library: .value(library), papers: .value(PaperCounts()),
                           ai: AIFact(statuses: [.claude: .value(.notInstalled), .codex: .value(.notInstalled)]),
                           notifications: .value(NotificationFact(authorization: .notDetermined, reminderEnabled: true)),
                           loginItem: .value(LoginItemFact(status: .notRegistered)),
                           widget: .value(WidgetFact(registration: .registered, placedCount: 0)),
                           app: .value(AppLocationFact(location: .applications, quarantined: false)),
                           signing: .value(SigningFact(kind: .certificate("Local"), channel: .local)),
                           cloud: .value(CloudFact(roots: [])),
                           profile: ProfileFact(origin: .fresh),
                           features: [.settingsTransfer, .libraryFlows, .widgetRepair])
        edit(&f)
        return f
    }

    static let ready = ProviderStatus.ready(plan: "max", version: "2.1", path: "/Users/someone/.local/bin/claude")

    static func root(_ provider: CloudProvider, _ name: String) -> CloudRoot {
        CloudRoot(provider: provider, name: name, url: URL(fileURLWithPath: "/tmp/cloud/\(name)"), displayName: name)
    }
}
