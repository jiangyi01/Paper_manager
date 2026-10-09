import Foundation
import PaperDeckCore
import PaperDeckConfig

/// `--selftest strings --write FILE | --check FILE [--lang en|zh] [--write-prompt FILE]`
///
/// The golden organization- and field-dependent strings (PORTABILITY_PLAN §2.7): the 13
/// organization keys (`consentNote` once per provider name), the 4 field keys, plus the sha256
/// of the reading-card system prompt. `--write` records what this build's L10n accessors say
/// (en and zh, `LangStore.lang` switched per language) into a JSON fixture; `--check` compares
/// this build against a fixture and lists every difference. `--write-prompt FILE` also writes
/// `CardSchema.systemPrompt` byte for byte. Pure: no library, no defaults domain, nothing spawned.
enum SelfTestStrings {
    /// Fixture format (`Tests/PaperDeckCoreTests/Fixtures/config/org-strings-v1.json`).
    struct Fixture: Codable, Equatable {
        var version: Int
        var organization: String
        var field: String
        var cardSystemPromptSHA256: String
        /// lang raw value ("en" / "zh") → key → text.
        var strings: [String: [String: String]]
    }

    static let version = 1
    /// The provider names `consentNote` is recorded for (`AIProviderKind.shortName`).
    static let consentProviders = ["Claude", "ChatGPT"]

    /// key → text for the current `LangStore.lang`. Keys: `org.<OrgTextKey>`,
    /// `org.consentNote.<provider>`, `field.<name>`. The key names are the contract; only the
    /// accessor behind each key may change (S2 points them at `OrgStrings` / `FieldStrings`).
    static func current() -> [String: String] {
        var s: [String: String] = [
            "org.accountsIntro": L.MailPref.noAccounts,
            "org.paTemplateName": L.MailPref.templateName(.powerAutomate),
            "org.paTemplateBlurb": L.MailPref.templateBlurb(.powerAutomate),
            "org.gmailBlurb": L.MailPref.templateBlurb(.imap(.gmail)),
            "org.paDefaultAccountName": L.MailPref.powerAutomateDefaultName,
            "org.oneDriveMissing": L.MailPref.oneDriveMissing,
            "org.paBlockedNote": L.MailPref.paBlockedNote,
            "org.paIntro": L.MailPref.paIntro,
            "org.patternInvalid": L.MailPref.patternInvalid,
            "org.personSenderWarning": L.MailPref.personSenderWarning,
            "org.policyNote": L.MailPref.policyNote,
            "org.triagePrivacy": L.MailPref.triagePrivacy,
            "field.describeHint": L.Pref.describeHint,
            "field.categoryDescriptionPlaceholder": L.Shell.categoryDescriptionPlaceholder,
            "field.customInstructionsHint": L.MailPref.customInstructionsHint,
            "field.alertsTip": L.MailPref.alertsTip(.gmail),
        ]
        for p in consentProviders { s["org.consentNote.\(p)"] = L.Mail.consentNote(p) }
        return s
    }

    static var promptSHA256: String { FileOps.sha256(of: Data(CardSchema.systemPrompt.utf8)) }

    /// Evaluates `current()` per language for an institution and field (default: every legacy
    /// install's — the fixture's configuration), restoring the UI language, institution and field
    /// afterwards.
    static func evaluate(_ langs: [UILang], org: OrganizationProfile = ConfigSnapshot.legacy.organization,
                         field: FieldPreset = ConfigSnapshot.legacy.field) -> [String: [String: String]] {
        let store = LangStore.shared
        let saved = (store.lang, store.org, store.field)
        defer { (store.lang, store.org, store.field) = saved }
        store.org = org
        store.field = field
        var out: [String: [String: String]] = [:]
        for l in langs {
            store.lang = l
            out[l.rawValue] = current()
        }
        return out
    }

    static func encode(_ f: Fixture) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try e.encode(f)
        data.append(0x0A)
        return data
    }

    static func run(_ args: CLIArgs) -> Int32 {
        let langs: [UILang]
        if let raw = args.value("--lang") {
            guard let l = UILang(rawValue: raw) else { return CLIRunner.fail("--lang en|zh") }
            langs = [l]
        } else {
            langs = [.en, .zh]
        }
        if let promptOut = args.value("--write-prompt") {
            let url = URL(fileURLWithPath: (promptOut as NSString).expandingTildeInPath)
            do { try Data(CardSchema.systemPrompt.utf8).write(to: url) } catch { return CLIRunner.fail("\(error)") }
            CLIRunner.line(["wrote": url.path, "sha256": promptSHA256])
        }
        if let out = args.value("--write") {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let fixture = Fixture(version: version, organization: LegacyInstall.organizationID,
                                  field: LegacyInstall.fieldID,
                                  cardSystemPromptSHA256: promptSHA256, strings: evaluate(langs))
            do { try encode(fixture).write(to: url) } catch { return CLIRunner.fail("\(error)") }
            CLIRunner.line(["wrote": url.path, "langs": langs.map(\.rawValue),
                            "keys": fixture.strings.values.first?.count ?? 0])
            return 0
        }
        if let input = args.value("--check") {
            let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            let fixture: Fixture
            do { fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)) } catch {
                return CLIRunner.fail("can't read \(url.path): \(error)")
            }
            var ok = true
            if fixture.cardSystemPromptSHA256 != promptSHA256 {
                ok = false
                CLIRunner.line(["mismatch": "cardSystemPromptSHA256", "expected": fixture.cardSystemPromptSHA256,
                                "actual": promptSHA256])
            }
            let now = evaluate(langs)
            var compared = 0
            for l in langs {
                guard let expected = fixture.strings[l.rawValue] else {
                    ok = false
                    CLIRunner.line(["missing": "lang", "lang": l.rawValue])
                    continue
                }
                let actual = now[l.rawValue] ?? [:]
                for key in Set(expected.keys).union(actual.keys).sorted() {
                    compared += 1
                    if expected[key] != actual[key] {
                        ok = false
                        CLIRunner.line(["mismatch": key, "lang": l.rawValue, "expected": expected[key], "actual": actual[key]])
                    }
                }
            }
            CLIRunner.line(["check": "strings", "langs": langs.map(\.rawValue), "compared": compared, "ok": ok])
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            return ok ? 0 : 1
        }
        if args.has("--write-prompt") { return 0 }
        return CLIRunner.fail("--selftest strings --write FILE | --check FILE [--lang en|zh] [--write-prompt FILE]")
    }
}
