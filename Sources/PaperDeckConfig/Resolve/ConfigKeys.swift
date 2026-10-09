import Foundation
import PaperDeckCore

/// Every settings key of the configuration layer (PORTABILITY_PLAN §2.5). None of them is ever
/// passed to `register(defaults:)`: absent always means "not chosen" (resolved by origin).
package enum ConfigKeys {
    // Migration markers (ConfigMigration)
    package static let migrationVersion = "config.migrationVersion"
    package static let origin = "config.origin"
    package static let migratedAt = "config.migratedAt"
    package static let migrationNote = "config.migrationNote"

    // Organization & profile
    package static let orgPreset = "org.preset"
    package static let orgCustom = "org.custom"
    package static let profileField = "profile.field"
    package static let profileStage = "profile.stage"
    package static let profileReaderDescription = "profile.readerDescription"

    // Mail
    package static let mailDateOrder = MailSettings.Keys.dateOrder        // "mail.dateOrder"
    package static let mailCloudRoot = "mail.cloudRoot"

    // Import & library flows
    package static let importLastFolder = "import.lastFolder"
    package static let libraryPendingAction = "library.pendingAction"
    package static let libraryPreviousPath = "library.previousPath"

    // Onboarding
    package static let onboardingVersion = "onboarding.version"
    package static let onboardingCompletedAt = "onboarding.completedAt"
    package static let onboardingAIDecision = "onboarding.aiDecision"
    package static let onboardingMailDecision = "onboarding.mailDecision"
    package static let onboardingLegacy = "onboarding.legacy"

    // Help Center
    package static let guideChecklistDismissed = "guide.checklist.dismissed"
    package static let guideSkipped = "guide.skipped"
    package static let guideManualDone = "guide.manualDone"
    package static let guideActivity = "guide.activity"

    // Settings transfer
    package static let transferLastExportedAt = "transfer.lastExportedAt"
    package static let transferImportedAt = "transfer.importedAt"

    /// Every key above.
    package static let all: [String] = [
        migrationVersion, origin, migratedAt, migrationNote,
        orgPreset, orgCustom, profileField, profileStage, profileReaderDescription,
        mailDateOrder, mailCloudRoot,
        importLastFolder, libraryPendingAction, libraryPreviousPath,
        onboardingVersion, onboardingCompletedAt, onboardingAIDecision, onboardingMailDecision, onboardingLegacy,
        guideChecklistDismissed, guideSkipped, guideManualDone, guideActivity,
        transferLastExportedAt, transferImportedAt,
    ]
}
