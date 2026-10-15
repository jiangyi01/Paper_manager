import Foundation
import PaperDeckCore

/// A probed fact: not probed yet, being probed, or known.
package enum ProbeState<T: Sendable & Equatable>: Sendable, Equatable {
    case unknown, checking, value(T)

    /// The value when known.
    package var known: T? {
        if case .value(let v) = self { return v }
        return nil
    }
}

package struct LibraryFact: Sendable, Equatable {
    package enum Volume: String, Sendable { case local, cloud, removable, network }

    package var status: LibraryStatus
    package var tildePath: String                   // "~/Documents/PaperDeck"
    package var volume: Volume
    package var hasManifest: Bool
    /// The identity guard's last result (nil: not checked).
    package var identity: LibraryIdentityCheck?

    package init(status: LibraryStatus, tildePath: String, volume: Volume, hasManifest: Bool,
                 identity: LibraryIdentityCheck? = nil) {
        self.status = status; self.tildePath = tildePath; self.volume = volume; self.hasManifest = hasManifest
        self.identity = identity
    }
}

package struct PaperCounts: Sendable, Equatable {
    package var live: Int
    package var withCard: Int
    package var opened: Int
    package var missingFiles: Int
    package var fullTextIndexed: Int

    package init(live: Int = 0, withCard: Int = 0, opened: Int = 0, missingFiles: Int = 0, fullTextIndexed: Int = 0) {
        self.live = live; self.withCard = withCard; self.opened = opened; self.missingFiles = missingFiles
        self.fullTextIndexed = fullTextIndexed
    }
}

package struct AIFact: Sendable, Equatable {
    package var mode: AgentMode
    package var provider: AIProviderKind
    /// `onboarding.aiDecision` (claude / codex / none); nil = not recorded.
    package var decision: String?
    package var statuses: [AIProviderKind: ProbeState<ProviderStatus>]
    /// The provider's usage-limit pause, when reading is paused.
    package var pausedUntil: Date?

    package init(mode: AgentMode = .off, provider: AIProviderKind = .claude, decision: String? = nil,
                 statuses: [AIProviderKind: ProbeState<ProviderStatus>] = [:], pausedUntil: Date? = nil) {
        self.mode = mode; self.provider = provider; self.decision = decision; self.statuses = statuses
        self.pausedUntil = pausedUntil
    }
}

package struct NotificationFact: Sendable, Equatable {
    package enum Authorization: String, Sendable { case notDetermined, denied, authorized, provisional, unavailable }

    package var authorization: Authorization
    package var reminderEnabled: Bool

    package init(authorization: Authorization, reminderEnabled: Bool) {
        self.authorization = authorization; self.reminderEnabled = reminderEnabled
    }
}

package struct LoginItemFact: Sendable, Equatable {
    package enum Status: String, Sendable { case enabled, notRegistered, requiresApproval, notFound }

    package var status: Status

    package init(status: Status) { self.status = status }
}

package struct WidgetFact: Sendable, Equatable {
    package enum Registration: String, Sendable { case registered, disabled, notRegistered, failed }

    package var registration: Registration
    /// Desktop widgets placed (nil: macOS didn't say).
    package var placedCount: Int?

    package init(registration: Registration, placedCount: Int? = nil) {
        self.registration = registration; self.placedCount = placedCount
    }
}

package struct AppLocationFact: Sendable, Equatable {
    package enum Location: String, Sendable { case applications, userApplications, translocated, other }

    package var location: Location
    package var quarantined: Bool

    package init(location: Location, quarantined: Bool) {
        self.location = location; self.quarantined = quarantined
    }

    /// `QTN_FLAG_USER_APPROVED`: Gatekeeper's record that the user opened the app (Open Anyway or
    /// the first approved open). macOS keeps `com.apple.quarantine` after approval and sets this bit.
    package static let userApprovedFlag: UInt32 = 0x0040

    /// Whether the app still counts as quarantined, from the value of its `com.apple.quarantine`
    /// attribute (`"<hex flags>;<hex time>;<agent>;<uuid>"`, e.g. `"0083;66f1e2a0;Safari;"`): no
    /// attribute → false; flags with the user-approved bit (`01c3;…`, `03c1`) → false; flags
    /// without it (`0083;…`) or a value that doesn't parse → true.
    package static func isQuarantined(attribute: String?) -> Bool {
        guard let attribute else { return false }
        let head = attribute.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let flags = UInt32(head.trimmingCharacters(in: .whitespaces), radix: 16) else { return true }
        return flags & userApprovedFlag == 0
    }
}

package struct SigningFact: Sendable, Equatable {
    package enum Kind: Sendable, Equatable { case certificate(String), adhoc, unsigned }

    package var kind: Kind
    package var channel: BuildIdentity.Channel

    package init(kind: Kind, channel: BuildIdentity.Channel) {
        self.kind = kind; self.channel = channel
    }
}

package struct MailAccountFact: Sendable, Equatable {
    package var id: String
    package var source: MailSourceID
    /// As the inbox pill and Settings ▸ Mail show it (`MailNoticePolicy.shownStatus`).
    package var status: MailSourceStatus?
    package var lastSuccessAt: Date?
    package var captured: Int
    package var notEmailFiles: Int
    /// IMAP: an app password is in the keychain (attributes only); nil for folders.
    package var passwordPresent: Bool?
    /// Folder: the watched folder exists; nil for IMAP.
    package var folderExists: Bool?
    /// The last pass reached the server or folder (`MailNoticePolicy.reachable`): an `.unavailable`
    /// status then words emails it skipped or couldn't download, not the connection.
    package var reachable: Bool

    package init(id: String, source: MailSourceID, status: MailSourceStatus? = nil, lastSuccessAt: Date? = nil,
                 captured: Int = 0, notEmailFiles: Int = 0, passwordPresent: Bool? = nil, folderExists: Bool? = nil,
                 reachable: Bool = false) {
        self.id = id; self.source = source; self.status = status; self.lastSuccessAt = lastSuccessAt
        self.captured = captured; self.notEmailFiles = notEmailFiles; self.passwordPresent = passwordPresent
        self.folderExists = folderExists; self.reachable = reachable
    }

    /// The fact for an account from the pipeline's sync state (nil: not synced yet): the status the
    /// inbox and Settings show (a skipped-emails suffix the notice owns is left out) and whether the
    /// last pass got through. `captured` adds the inbox's cards.
    package init(id: String, source: MailSourceID, info: MailAccountSyncInfo?, cards: Int = 0,
                 passwordPresent: Bool? = nil, folderExists: Bool? = nil) {
        self.init(id: id, source: source,
                  status: info.flatMap { MailNoticePolicy.shownStatus($0, active: $0.enabled) },
                  lastSuccessAt: info?.lastSuccessAt,
                  captured: (info?.totalCaptured ?? 0) + cards, notEmailFiles: info?.notEmailFiles ?? 0,
                  passwordPresent: passwordPresent, folderExists: folderExists,
                  reachable: info.map(MailNoticePolicy.reachable) ?? false)
    }
}

package struct MailFact: Sendable, Equatable {
    package var enabled: Bool
    /// `onboarding.mailDecision` (configured / dragOnly / skipped).
    package var decision: String?
    package var accounts: [MailAccountFact]
    package var senders: [SenderKind: Int]
    package var emlImportedManually: Bool
    /// The suggested watched folder (`<business OneDrive>/PaperDeck Mail`) exists — the Power Automate
    /// tutorial's "Create the folder" step before any account uses it (nil: no suggestion / not probed).
    package var suggestedFolderExists: Bool?

    package init(enabled: Bool = false, decision: String? = nil, accounts: [MailAccountFact] = [],
                 senders: [SenderKind: Int] = [:], emlImportedManually: Bool = false,
                 suggestedFolderExists: Bool? = nil) {
        self.enabled = enabled; self.decision = decision; self.accounts = accounts; self.senders = senders
        self.emlImportedManually = emlImportedManually; self.suggestedFolderExists = suggestedFolderExists
    }
}

package struct CloudFact: Sendable, Equatable {
    package var roots: [CloudRoot]

    package init(roots: [CloudRoot]) { self.roots = roots }
}

package struct TransferFact: Sendable, Equatable {
    package var lastExportedAt: Date?
    package var importedAt: Date?

    package init(lastExportedAt: Date? = nil, importedAt: Date? = nil) {
        self.lastExportedAt = lastExportedAt; self.importedAt = importedAt
    }
}

package struct ProfileFact: Sendable, Equatable {
    package var origin: ConfigOrigin?
    /// The stored ids (nil: not chosen yet).
    package var fieldID: String?
    package var organizationID: String?
    package var readerCustomized: Bool

    package init(origin: ConfigOrigin? = nil, fieldID: String? = nil, organizationID: String? = nil,
                 readerCustomized: Bool = false) {
        self.origin = origin; self.fieldID = fieldID; self.organizationID = organizationID
        self.readerCustomized = readerCustomized
    }
}

/// One snapshot of everything the guides check (cheap facts plus probes). Filled by the app's
/// `SetupFactsCollector` (live) or by fake sources (renders, selftests).
package struct SetupFacts: Sendable, Equatable {
    package var library: ProbeState<LibraryFact>
    package var papers: ProbeState<PaperCounts>
    package var activity: [GuideActivityKind: Date]
    package var ai: AIFact
    package var notifications: ProbeState<NotificationFact>
    package var loginItem: ProbeState<LoginItemFact>
    package var widget: ProbeState<WidgetFact>
    package var app: ProbeState<AppLocationFact>
    package var signing: ProbeState<SigningFact>
    package var mail: MailFact
    package var cloud: ProbeState<CloudFact>
    package var transfer: TransferFact
    package var profile: ProfileFact
    package var features: Set<GuideFeature>

    package init(library: ProbeState<LibraryFact> = .unknown, papers: ProbeState<PaperCounts> = .unknown,
                 activity: [GuideActivityKind: Date] = [:], ai: AIFact = AIFact(),
                 notifications: ProbeState<NotificationFact> = .unknown, loginItem: ProbeState<LoginItemFact> = .unknown,
                 widget: ProbeState<WidgetFact> = .unknown, app: ProbeState<AppLocationFact> = .unknown,
                 signing: ProbeState<SigningFact> = .unknown, mail: MailFact = MailFact(),
                 cloud: ProbeState<CloudFact> = .unknown, transfer: TransferFact = TransferFact(),
                 profile: ProfileFact = ProfileFact(), features: Set<GuideFeature> = []) {
        self.library = library; self.papers = papers; self.activity = activity; self.ai = ai
        self.notifications = notifications; self.loginItem = loginItem; self.widget = widget; self.app = app
        self.signing = signing; self.mail = mail; self.cloud = cloud; self.transfer = transfer
        self.profile = profile; self.features = features
    }

    /// Nothing probed yet.
    package static let unknown = SetupFacts()
}
