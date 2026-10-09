import Foundation
import PaperDeckCore

/// The resolved configuration (what the app shows and the engine uses), from `ConfigResolver`.
package struct ConfigSnapshot: Sendable, Equatable {
    package var migrationVersion: Int?
    package var origin: ConfigOrigin
    package var field: FieldPreset
    package var stage: CareerStage
    package var readerOverride: String?
    package var organization: OrganizationProfile
    package var mailDateOrder: SlashDateOrder

    package init(migrationVersion: Int?, origin: ConfigOrigin, field: FieldPreset, stage: CareerStage,
                 readerOverride: String?, organization: OrganizationProfile, mailDateOrder: SlashDateOrder) {
        self.migrationVersion = migrationVersion; self.origin = origin; self.field = field; self.stage = stage
        self.readerOverride = readerOverride; self.organization = organization; self.mailDateOrder = mailDateOrder
    }

    /// The reading-card prompt's reader for this configuration.
    package var cardPromptProfile: CardPromptProfile {
        field.cardProfile(stage: stage, readerOverride: readerOverride)
    }

    /// Today's configuration (every install before this build): the legacy institution preset,
    /// life sciences & comp-bio, PhD, month-first dates.
    package static let legacy = ConfigSnapshot(
        migrationVersion: nil, origin: .legacy, field: FieldPresets.lifeSciencesCompBio, stage: .phd,
        readerOverride: nil, organization: OrganizationPresets.legacyInstallPreset, mailDateOrder: LegacyInstall.dateOrder)
}
