import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckShared

/// What the app's mail fixes rely on from Core: the Power Automate guide shows exactly the flow the
/// user builds by hand (and 「生成导入包…」 writes the same one), the 「不是完整的邮件」 hint wording,
/// the mail-triage status lines, the notification link and the "running" card state.
@Suite struct MailAppFixesContractTests {
    private typealias PA = PowerAutomatePackage

    /// The guide's fx boxes: the package's expressions without the workflow-language `@`.
    private static func fx(_ expression: String) -> String {
        expression.hasPrefix("@") ? String(expression.dropFirst()) : expression
    }

    @Test func guideValuesAreTheHandBuiltFlow() {
        // What the user typed into Power Automate (USER CONTEXT): File Name and File Content as fx expressions.
        #expect(Self.fx(PA.fileNameExpression) == "concat(formatDateTime(utcNow(),'yyyyMMdd-HHmmss'),'-',guid(),'.eml')")
        #expect(Self.fx(PA.exportBodyExpression) == "body('Export_email_(V2)')")
        #expect(PA.defaultFolderPath == "/PaperDeck Mail")
        // The trigger's From field: exact addresses joined by ';'.
        let rules = [SenderRule(pattern: "jsmith@wustl.edu", kind: .advisor),
                     SenderRule(pattern: "lab.manager@wustl.edu", kind: .person),
                     SenderRule(pattern: "old@wustl.edu", kind: .person, enabled: false)]
        let plan = PA.senderPlan(PA.senders(from: rules))
        #expect(plan.fromFilter == "jsmith@wustl.edu;lab.manager@wustl.edu")
    }

    @Test func generatedPackageMatchesTheGuide() throws {
        // 「生成导入包…」: makeZip with the enabled sender list and the folder's OneDrive path.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent(PA.suggestedFileName())
        try PA.makeZip(senders: ["jsmith@wustl.edu", "lab.manager@wustl.edu"], into: zip)
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))

        let files = try PA.files(senders: ["jsmith@wustl.edu", "lab.manager@wustl.edu"])
        let defPath = try #require(files.keys.first { $0.hasSuffix("/definition.json") })
        let defData = try #require(files[defPath])
        let root = try #require(try JSONSerialization.jsonObject(with: defData) as? [String: Any])
        let workflow = try #require((root["properties"] as? [String: Any])?["definition"] as? [String: Any])
        let trigger = try #require((workflow["triggers"] as? [String: Any])?[PA.triggerName] as? [String: Any])
        let actions = try #require(workflow["actions"] as? [String: Any])
        func inputs(_ step: [String: Any]?) throws -> (op: String, params: [String: Any]) {
            let i = try #require(step?["inputs"] as? [String: Any])
            let host = try #require(i["host"] as? [String: Any])
            return (try #require(host["operationId"] as? String), try #require(i["parameters"] as? [String: Any]))
        }
        let t = try inputs(trigger)
        #expect(t.op == "OnNewEmailV3")
        #expect(t.params["from"] as? String == "jsmith@wustl.edu;lab.manager@wustl.edu")
        let export = try inputs(actions[PA.exportActionName] as? [String: Any])
        #expect(export.op == "ExportEmail_V2")
        #expect(export.params["messageId"] as? String == PA.messageIdExpression)
        let create = try inputs(actions[PA.createFileActionName] as? [String: Any])
        #expect(create.op == "CreateFile")
        #expect(create.params["folderPath"] as? String == "/PaperDeck Mail")
        #expect(create.params["name"] as? String == "@" + Self.fx(PA.fileNameExpression))
        // File Content is Export email's Body — never the trigger's (that makes HTML-only files).
        #expect(create.params["body"] as? String == "@body('Export_email_(V2)')")
    }

    @Test func notEmailHintNamesTheFixInBothLanguages() {
        for lang in [UILang.en, .zh] {
            for n in [1, 3] {
                let text = MailSyncText.notEmailFiles(n, lang)
                #expect(text.contains("body('Export_email_(V2)')"))
                #expect(text.contains("\(n)"))
            }
        }
        #expect(MailSyncText.notEmailFiles(1, .en).hasPrefix("1 file in this folder isn't"))
        #expect(MailSyncText.notEmailFiles(2, .en).hasPrefix("2 files in this folder aren't"))
        let info = MailAccountSyncInfo(id: "a", displayName: "WashU", kind: .folder, enabled: true,
                                       notEmailFiles: 2, notEmailHint: MailSyncText.notEmailFiles(2, .en))
        #expect(info.notEmailHint == MailSyncText.notEmailFiles(info.notEmailFiles, .en))
    }

    @Test func triageStatusLines() {
        var s = AgentQueueStatus(mode: .claude)
        #expect(s.triageText(.en) == nil && !s.triageRunning)
        s.triageQueued = 1
        #expect(s.triageText(.en) == "1 email waiting for AI analysis")
        s.triageQueued = 3
        #expect(s.triageText(.en) == "3 emails waiting for AI analysis")
        #expect(s.triageText(.zh) == "3 封邮件待 AI 分析")
        s.runningTriageMessagePK = 7
        #expect(s.triageRunning)
        #expect(s.triageText(.en) == "Analyzing email…")
        #expect(s.triageText(.zh) == "正在分析邮件…")
    }

    @Test func notificationLinkSelectsTheCard() throws {
        let id = UUID().uuidString.lowercased()
        let url = DeepLink.mail(id: id).url
        #expect(url.absoluteString == "paperdeck://mail/\(id)")
        guard case .mail(let parsed)? = DeepLink(url: url) else {
            Issue.record("paperdeck://mail/<id> must parse back to .mail")
            return
        }
        #expect(parsed == id)
    }

    @Test func runningTriageShowsOnTheCardOnly() {
        let m = MailMessage(pk: 42, accountID: "a", internetMessageID: "<x@y>", fromAddress: "a@b.edu",
                            senderKind: .alert, subject: "Alert", receivedAt: Date(), triageState: .queued)
        #expect(MailCard(message: m, items: [], rule: nil, account: nil, runningTriagePK: 42).displayTriageState == .running)
        #expect(MailCard(message: m, items: [], rule: nil, account: nil, runningTriagePK: 41).displayTriageState == .queued)
        #expect(MailCard(message: m, items: [], rule: nil, account: nil).displayTriageState == .queued)
    }
}
