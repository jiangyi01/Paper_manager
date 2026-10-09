import Foundation
import PaperDeckCore
import PaperDeckConfig

extension MailAccountTemplate {
    /// The add-account form for a mail source; nil for guide-only routes (they open a Help topic).
    init?(source: MailSourceID) {
        switch source {
        case .m365PowerAutomate: self = .powerAutomate
        case .folder: self = .folder
        default:
            guard let preset = source.imapPreset else { return nil }
            self = .imap(preset)
        }
    }

    /// The source a new account of this form stores (`MailAccount.source`).
    var sourceID: MailSourceID {
        switch self {
        case .powerAutomate: return .m365PowerAutomate
        case .folder: return .folder
        case .imap(let preset):
            switch preset {
            case .gmail: return .imapGmail
            case .icloud: return .imapICloud
            case .yahoo: return .imapYahoo
            case .fastmail: return .imapFastmail
            case .custom: return .imapCustom
            }
        }
    }

    /// The chooser's "Set up an account" rows, in the catalog's order (today's seven). An empty
    /// catalog falls back to `choices` — the chooser is never empty.
    static func setUpChoices(_ entries: [MailSourceEntry]) -> [MailAccountTemplate] {
        let rows = entries.filter { $0.section == .setUp }.compactMap { MailAccountTemplate(source: $0.id) }
        var unique: [MailAccountTemplate] = []
        for t in rows where !unique.contains(t) { unique.append(t) }
        return unique.isEmpty ? choices : unique
    }
}
