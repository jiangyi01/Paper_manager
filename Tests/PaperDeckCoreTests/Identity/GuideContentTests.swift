import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// The Help Center content (`GuideContent`, PORTABILITY_PLAN §3.4, §3.8): every catalog topic,
/// bilingual, institution-neutral, with the structure the Help Center views expect (the tour's
/// pages, the checklist's item ids, troubleshooting diagnoses). The generic content rules are
/// also `GuideLint`'s; these tests keep them for the content itself.
@Suite("Guide content")
struct GuideContentTests {
    static let topics = GuideCatalog.topics
    static func topic(_ id: GuideTopicID) throws -> GuideTopic { try #require(GuideCatalog.topic(id), "\(id.rawValue)") }

    /// The official sites a guide may open (the Help Center's allowlist).
    static let allowedHosts: Set<String> = [
        "make.powerautomate.com", "myaccount.google.com", "script.google.com", "account.apple.com",
        "support.apple.com", "support.google.com", "support.microsoft.com", "claude.ai", "chatgpt.com",
        "openai.com", "login.yahoo.com", "app.fastmail.com",
    ]
    /// The Settings window's tabs (`SettingsTab`; "assist" = Explain & Ask, shown since phase 2).
    static let settingsTabs: Set<String> = ["general", "profile", "plan", "ai", "assist", "mail", "library", "widget"]

    /// Names, short names, OneDrive hints and sender domains of the built-in institutions (never a
    /// literal here).
    static var institutionLiterals: [String] {
        OrganizationPresets.builtIn.filter { $0.id != OrganizationPresets.generic.id }
            .flatMap { o in [o.name?.en, o.name?.zh, o.shortName, o.mail.oneDriveRootHint].compactMap { $0 } + o.mail.knownSenderDomains }
            .map { $0.lowercased() }.filter { $0.count >= 3 }
    }

    static func texts(_ t: GuideTopic) -> [LocalizedText] {
        var out = [t.title, t.summary] + t.keywords
        for s in t.steps {
            out.append(s.text)
            if case .manual(let reason) = s.verification { out.append(reason) }
        }
        return out
    }

    @Test func everyCatalogIDHasExactlyOneTopic() {
        let ids = Self.topics.map(\.id)
        #expect(ids.count == GuideTopicID.catalog.count)
        #expect(Set(ids) == Set(GuideTopicID.catalog))
        #expect(Set(ids).count == ids.count)
        for id in GuideTopicID.catalog { #expect(GuideCatalog.topic(id)?.id == id, "\(id.rawValue)") }
        // Every group contributes, in catalog order within the group.
        #expect(!GuideContent.tour.isEmpty && !GuideContent.tutorials.isEmpty && !GuideContent.mail.isEmpty
                && !GuideContent.troubleshooting.isEmpty)
        let order = Dictionary(uniqueKeysWithValues: GuideTopicID.catalog.enumerated().map { ($1, $0) })
        for group in [GuideContent.tour, GuideContent.tutorials, GuideContent.mail, GuideContent.troubleshooting] {
            let positions = group.compactMap { order[$0.id] }
            #expect(positions == positions.sorted())
        }
    }

    @Test func everyTextIsInEnglishAndChinese() {
        for t in Self.topics {
            for text in Self.texts(t) {
                #expect(!text.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(t.id.rawValue): empty en")
                #expect(!text.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(t.id.rawValue): empty zh")
                // The Chinese text is a translation, not a copy (short proper nouns such as "Gmail" excepted).
                if text.en.count > 24 { #expect(text.en != text.zh, "\(t.id.rawValue): zh = en: \(text.en)") }
            }
            #expect(t.lastReviewed.range(of: "^20[0-9]{2}-[01][0-9]$", options: .regularExpression) != nil)
        }
    }

    @Test func stepsFollowTheVerificationRules() {
        for t in Self.topics {
            let ids = t.steps.map(\.id)
            #expect(Set(ids).count == ids.count && !ids.contains(""), "\(t.id.rawValue): step ids \(ids)")
            var manual = 0
            for (i, s) in t.steps.enumerated() {
                switch s.verification {
                case .manual: manual += 1
                case .impliedBy(let later):
                    #expect(later > i && later < t.steps.count, "\(t.id.rawValue) step \(i): impliedBy \(later)")
                    if later > i, later < t.steps.count, case .check = t.steps[later].verification {} else {
                        Issue.record("\(t.id.rawValue) step \(i): impliedBy must point at a checked step")
                    }
                case .check, .info: break
                }
                // One paragraph per step (the tour's "Title\nBody" pages excepted): the Markdown
                // export numbers them as a list.
                if t.kind != .tour {
                    #expect(!s.text.en.contains("\n") && !s.text.zh.contains("\n"), "\(t.id.rawValue)/\(s.id)")
                }
            }
            #expect(manual <= 1, "\(t.id.rawValue): \(manual) manual steps")
        }
    }

    @Test func linksTopicsAndSettingsTabsExist() {
        let ids = Set(GuideTopicID.catalog)
        for t in Self.topics {
            for r in t.related {
                #expect(ids.contains(r), "\(t.id.rawValue): related \(r.rawValue)")
                #expect(r != t.id, "\(t.id.rawValue) relates to itself")
            }
            for s in t.steps {
                for a in s.actions {
                    switch a {
                    case .openURL(let url):
                        #expect(url.scheme == "https" && Self.allowedHosts.contains(url.host ?? ""), "\(t.id.rawValue): \(url)")
                    case .openTopic(let id):
                        #expect(ids.contains(id) && id != t.id, "\(t.id.rawValue): topic \(id.rawValue)")
                    case .openSettings(let tab):
                        #expect(Self.settingsTabs.contains(tab), "\(t.id.rawValue): tab \(tab)")
                    case .openMailSheet(let source):
                        #expect(source.createsAccount, "\(t.id.rawValue): \(source.rawValue) has no form")
                    case .deepLink:
                        Issue.record("\(t.id.rawValue): use a router action or a topic instead of a deep link")
                    case .router, .systemSettings, .copyGenerated:
                        break
                    }
                }
            }
        }
    }

    @Test func commandsAreSafeToCopy() throws {
        let address = try NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\\.[A-Za-z]{2,})")
        var count = 0
        for t in Self.topics {
            for c in t.steps.flatMap(\.commands) {
                count += 1
                #expect(!c.contains("/Users/"), "\(t.id.rawValue): \(c)")
                #expect(!c.contains("\n") && !c.isEmpty)
                for m in address.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
                    let domain = (c as NSString).substring(with: m.range(at: 1)).lowercased()
                    #expect(["example.com", "example.edu", "example.org"].contains(domain), "\(t.id.rawValue): \(c)")
                }
                // Never a command that spends quota, deletes data or touches another app's settings.
                for banned in ["--agent-smoke", "rm -", "defaults write", "defaults delete", "killall", "sudo "] {
                    #expect(!c.contains(banned), "\(t.id.rawValue): \(c)")
                }
            }
        }
        #expect(count > 10)
    }

    @Test func theContentNamesNoInstitutionOrPerson() {
        let literals = Self.institutionLiterals
        #expect(!literals.isEmpty)
        for t in Self.topics {
            for text in Self.texts(t) + t.steps.flatMap({ $0.commands.map { LocalizedText($0) } }) {
                for side in [text.en.lowercased(), text.zh.lowercased()] {
                    for literal in literals { #expect(!side.contains(literal), "\(t.id.rawValue): names \(literal)") }
                    #expect(!side.contains("paper_reading"), "\(t.id.rawValue)")
                }
            }
        }
    }

    @Test func theTourHasTheSevenPagesTheTourViewDraws() throws {
        let tour = try Self.topic(.tour)
        #expect(tour.kind == .tour)
        #expect(tour.steps.map(\.id) == ["tour-drop", "tour-today", "tour-card", "tour-ai", "tour-mail", "tour-reminders", "tour-data"])
        let checks: [GuideCheck] = [.activity([.panelDrop, .menuBarDrop, .openWith]), .hasPapers(1), .activity([.openedDetail]),
                                    .aiDecided, .mailAccountReady(nil), .notificationsAllowed, .libraryUsable]
        let showMe: [GuideAction] = [.router(.armDropPanel), .router(.showToday), .router(.openFirstPaper), .openSettings(tab: "ai"),
                                     .router(.showMail), .openSettings(tab: "widget"), .router(.revealLibrary)]
        for (i, step) in tour.steps.enumerated() {
            #expect(step.verification == .check(checks[i]), "\(step.id)")
            #expect(step.actions.first == showMe[i], "\(step.id)")
            for text in [step.text.en, step.text.zh] {
                let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
                #expect(parts.count == 2 && !parts[0].isEmpty && parts[1].count > parts[0].count, "\(step.id): Title\\nBody")
            }
        }
    }

    @Test func theChecklistPageListsTheGettingStartedItems() throws {
        let page = try Self.topic(.gettingStarted)
        #expect(page.kind == .checklist)
        #expect(page.steps.map(\.id) == ["library", "first-paper", "drop-strip", "open-card", "ai", "reminder", "login",
                                         "widget", "mail", "senders", "backup"])
        #expect(page.steps.allSatisfy { if case .check = $0.verification { return true }; return false })
    }

    @Test func troubleshootingEntriesDiagnoseAndOthersDont() {
        for t in Self.topics {
            if t.id.rawValue.hasPrefix("fix-") {
                #expect(t.kind == .troubleshoot, "\(t.id.rawValue)")
                #expect(t.diagnosis != nil, "\(t.id.rawValue): no diagnosis")
            } else {
                #expect(t.kind != .troubleshoot && t.diagnosis == nil, "\(t.id.rawValue)")
            }
        }
        #expect(GuideContent.troubleshooting.count == 17)
        #expect(GuideContent.troubleshooting.allSatisfy { $0.kind == .troubleshoot })
    }

    @Test func theNormativeTutorialsKeepTheirVerifications() throws {
        // §3.4: the Power Automate route, any tenant.
        let m365 = try Self.topic(.mailM365PowerAutomate)
        let v = m365.steps.map(\.verification)
        #expect(Array(v.prefix(7)) == [.check(.oneDriveBusinessPresent), .check(.mailFolderExists), .impliedBy(step: 5),
                                       .check(.mailAccountExists(.m365PowerAutomate)), .check(.mailEnabled),
                                       .check(.mailFirstCapture(.m365PowerAutomate)), .check(.mailNoNotEmailFiles)])
        #expect(m365.steps[2].actions.contains(.openURL(URL(string: "https://make.powerautomate.com")!)))
        // Moving Macs: the old Mac is the one manual step; then the live checks.
        let move = try Self.topic(.moveToNewMac)
        #expect(move.steps.first.map { if case .manual = $0.verification { return true }; return false } == true)
        let moveChecks = move.steps.compactMap { s -> GuideCheck? in if case .check(let c) = s.verification { return c }; return nil }
        for c in [GuideCheck.appInApplications, .settingsImported, .aiDecided, .imapPasswordsPresent, .fullTextIncomplete] {
            #expect(moveChecks.contains(c), "\(c)")
        }
        // Gmail: the website steps are confirmed by Test & Save.
        let gmail = try Self.topic(.mailGmail)
        #expect(gmail.steps.prefix(2).allSatisfy { $0.verification == .impliedBy(step: 2) })
        #expect(gmail.steps[2].verification == .check(.mailAccountReady(.imapGmail)))
        // Build from source and giving the app away check the signing and the quarantine.
        #expect(try Self.topic(.buildFromSource).steps.contains { $0.verification == .check(.stableSigning) })
        #expect(try Self.topic(.installForLabmate).steps.contains { $0.verification == .check(.notQuarantined) })
    }

    @Test func searchTermsTheHelpCenterRelieson() throws {
        func haystack(_ id: GuideTopicID, _ lang: UILang) throws -> String {
            let t = try Self.topic(id)
            return ([t.title(lang), t.summary(lang)] + t.keywords.map { $0(lang) }).joined(separator: " ").lowercased()
        }
        #expect(try haystack(.mailM365PowerAutomate, .en).contains("onedrive"))
        #expect(try haystack(.connectMail, .zh).contains("邮件"))
        #expect(try haystack(.fixWidgetMissing, .en).contains("widget"))
        #expect(try haystack(.fixWidgetMissing, .zh).contains("小组件"))
    }

    @Test func noTopicSpellsOutThisBuildsIdentity() throws {
        // The docs are generated from these topics, so no text or command names a bundle id: the
        // commands ask the installed app for its id instead.
        let id = BuildIdentity.current
        for t in Self.topics {
            for text in Self.texts(t) + t.steps.flatMap({ $0.commands.map { LocalizedText($0) } }) {
                for side in [text.en, text.zh] {
                    #expect(!side.contains(id.bundleID) && !side.contains(BuildIdentity.defaultBundleID), "\(t.id.rawValue): \(side)")
                }
            }
        }
        let lookup = "$(defaults read /Applications/PaperDeck.app/Contents/Info CFBundleIdentifier)"
        let widget = try Self.topic(.fixWidgetMissing).steps.flatMap(\.commands)
        #expect(widget.contains("pluginkit -m -v -i \"\(lookup).widget\""))
        let reset = try Self.topic(.fixDocumentsAccess).steps.flatMap(\.commands)
        #expect(reset.contains("tccutil reset SystemPolicyDocumentsFolder \"\(lookup)\""))
        // The certificate name comes from BuildIdentity (one literal in the code base).
        let cert = try Self.topic(.buildFromSource).steps.first { $0.id == "certificate" }
        #expect(cert?.text.en.contains(BuildIdentity.defaultSigningIdentityName) == true)
        #expect(cert?.text.zh.contains(BuildIdentity.defaultSigningIdentityName) == true)
    }
}
