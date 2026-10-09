import Foundation
import PaperDeckShared

/// Builds the transport for a configured account (Settings ▸ Mail ▸ Accounts).
package enum MailSourceFactory {
    package static func make(_ account: MailAccount, secrets: any MailSecretStore, lang: UILang = .en) -> any MailSource {
        switch account.kind {
        case .folder: return FolderMailSource(account: account, lang: lang)
        case .imap: return IMAPMailSource(account: account, secrets: secrets, lang: lang)
        }
    }

    /// The accounts of a run into an isolated library (`--mail-sync --root`): nothing is ever
    /// written back to the real mail source — a watched folder keeps its processed `.eml`
    /// files (IMAP is read-only anyway: EXAMINE + BODY.PEEK).
    package static func isolated(_ accounts: [MailAccount]) -> [MailAccount] {
        accounts.map { a in
            var copy = a
            copy.deleteProcessedFiles = false
            return copy
        }
    }
}
