import Foundation
import PaperDeckCore

/// Today's behavior as data: what `ConfigMigration` writes for an install from before institutions
/// and fields were configurable (only keys that are absent).
package enum LegacyInstall {
    package static let organizationID = OrganizationPresets.legacyInstallPreset.id
    package static let fieldID = FieldPresets.lifeSciencesCompBio.id
    /// `MailHeuristics` reads "3/10" month first today.
    package static let dateOrder: SlashDateOrder = .mdy
    /// The setup assistant's import folder today (`SetupAssistantView`).
    package static let importFolder = "~/Desktop/Paper_reading"
}
