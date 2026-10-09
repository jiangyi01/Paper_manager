import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Phase 1 fixes F3 and F8 (settings import never loosens):
/// - F3: a sender rule the file keeps under this Mac's id but points at other mail (its pattern
///   changed) is, for that mail, a new rule — it can't take over a stricter rule's mail without a
///   "Kept stricter" item (probes V4 / V4b, inverted);
/// - F8: an account whose port isn't a whole number (993.5, 1e300) is skipped, not imported on the
///   default port (mutation X5).
/// Pure: synthetic rules and bundles.
@Suite struct P1FImportGuardTests {
    static func rule(_ id: String, _ pattern: String, kind: SenderKind, ai: MailAIPolicy, merge: Bool = false) -> SenderRule {
        var r = SenderRule(pattern: pattern, kind: kind)
        r.id = id; r.label = id; r.aiPolicy = ai; r.autoMerge = merge
        return r
    }

    static let lab = rule("lab", "@lab.example.edu", kind: .person, ai: .never)
    /// This Mac's "digest" already merges automatically: only the move can loosen anything here.
    static let digest = rule("digest", "digest@journals.example.org", kind: .alert, ai: .always, merge: true)
    /// The file's copy of "digest" (same id) now names an address under the lab's domain.
    static let moved = rule("digest", "news@lab.example.edu", kind: .alert, ai: .always, merge: true)

    static func plan(_ rules: [SenderRule], current: [SenderRule], accept: LooserAcceptance = .none) -> ImportPlan {
        let here = [MailSettings.Keys.senders: MailSettings.encode(current)]
        let file = SettingsBundle(exportedAt: Date(timeIntervalSince1970: 1_790_000_000), app: "PaperDeck 1.0 (28)",
                                  sections: [SettingsSection.mailSenders.rawValue:
                                    .object([MailSettings.Keys.senders: (try? JSONValue.from(rules)) ?? .null])])
        return SettingsImporter.plan(file, current: PersistedDomain(here), sections: Set(SettingsSection.allCases),
                                     keepPeopleAlways: false, acceptReaderDescription: false, acceptLooser: accept,
                                     home: URL(fileURLWithPath: "/Users/example"), roots: [])
    }

    static func written(_ p: ImportPlan) -> [SenderRule] {
        MailSettings.list(p.writes[MailSettings.Keys.senders]?.stringValue, SenderRule.self, what: "s")
    }

    @Test func aSameIDRuleMovedUnderAStricterRuleKeepsThatRulesValues() throws {
        let before = SenderMatcher.match(address: "news@lab.example.edu", rules: [Self.lab, Self.digest])
        #expect(before?.id == "lab" && before?.aiPolicy == .never)
        let m = SettingsImporter.mergeSenders(current: [Self.lab, Self.digest], imported: [Self.moved], keepPeopleAlways: false)
        #expect(m.loosened.map(\.id) == [ImportLoosening.newSenderID("digest"), ImportLoosening.newSenderID("digest", .autoMerge)],
                "\(m.loosened.map(\.id))")
        #expect(m.loosened.allSatisfy { $0.overrides == "lab" && !$0.accepted })
        let governing = try #require(SenderMatcher.match(address: "news@lab.example.edu", rules: m.rules))
        #expect(governing.id == "digest" && governing.aiPolicy == .never && !governing.autoMerge)
        #expect(governing.pattern == "news@lab.example.edu")              // the move itself imports
        #expect(m.rules.first { $0.id == "lab" } == Self.lab)
    }

    @Test func thePlanListsItAsKeptStricterAndTickingItWritesTheFilesValues() throws {
        let p = Self.plan([Self.moved], current: [Self.lab, Self.digest])
        #expect(p.keptStricter.map(\.id).contains(ImportLoosening.newSenderID("digest")), "\(p.keptStricter.map(\.id))")
        #expect(SenderMatcher.match(address: "news@lab.example.edu", rules: Self.written(p))?.aiPolicy == .never)
        let all = Self.plan([Self.moved], current: [Self.lab, Self.digest], accept: .all)
        #expect(all.keptStricter.isEmpty)
        #expect(SenderMatcher.match(address: "news@lab.example.edu", rules: Self.written(all))?.aiPolicy == .always)
    }

    /// The same-id checks still run against this Mac's own rule, and a move to mail no other rule
    /// here covers loosens nothing.
    @Test func aMoveToUncoveredMailOrAnUnchangedPatternAddsNoItem() {
        let elsewhere = Self.rule("digest", "news@other.example.org", kind: .alert, ai: .always, merge: true)
        #expect(SettingsImporter.mergeSenders(current: [Self.lab, Self.digest], imported: [elsewhere],
                                              keepPeopleAlways: false).loosened.isEmpty)
        // Same pattern, written differently (case): not a move.
        let same = Self.rule("digest", "Digest@Journals.example.org", kind: .alert, ai: .always, merge: true)
        #expect(SettingsImporter.mergeSenders(current: [Self.lab, Self.digest], imported: [same],
                                              keepPeopleAlways: false).loosened.isEmpty)
        // A stricter rule here under the same id: its own guard (senderID) still applies.
        var strictDigest = Self.digest
        strictDigest.aiPolicy = .never
        let m = SettingsImporter.mergeSenders(current: [Self.lab, strictDigest], imported: [elsewhere], keepPeopleAlways: false)
        #expect(m.loosened.map(\.id) == [ImportLoosening.senderID("digest")])
        #expect(m.rules.first { $0.id == "digest" }?.aiPolicy == .never)
    }

    // MARK: F8 — non-integer port

    @Test func anAccountWhosePortIsNotAWholeNumberIsSkipped() throws {
        var ok = MailAccount(kind: .imap, displayName: "Gmail")
        ok.id = "gm"; ok.host = "imap.gmail.com"; ok.port = 993; ok.lookbackDays = 14
        guard case .array(var items) = try JSONValue.from([ok]) else { Issue.record("not an array"); return }
        for (id, port) in [("half", 993.5), ("huge", 1e300)] {
            items.append(.object(["id": .string(id), "kind": .string("imap"), "displayName": .string(id),
                                  "host": .string("imap.example.org"), "port": .number(port), "enabled": .bool(true),
                                  "lookbackDays": .number(14), "deleteProcessedFiles": .bool(false)]))
        }
        let file = SettingsBundle(exportedAt: Date(timeIntervalSince1970: 1_790_000_000), app: "PaperDeck 1.0 (28)",
                                  sections: [SettingsSection.mailAccounts.rawValue:
                                    .object([MailSettings.Keys.accounts: .array(items)])])
        for accept in [LooserAcceptance.none, .all] {
            let p = SettingsImporter.plan(file, current: PersistedDomain([:]), sections: Set(SettingsSection.allCases),
                                          keepPeopleAlways: false, acceptReaderDescription: false, acceptLooser: accept,
                                          home: URL(fileURLWithPath: "/Users/example"), roots: [])
            let written = MailSettings.list(p.writes[MailSettings.Keys.accounts]?.stringValue, MailAccount.self, what: "a")
            #expect(written.map(\.id) == ["gm"], "\(written.map(\.id))")
            #expect(p.warnings.contains(.entriesSkipped(MailSettings.Keys.accounts, 2)), "\(p.warnings)")
        }
    }
}
