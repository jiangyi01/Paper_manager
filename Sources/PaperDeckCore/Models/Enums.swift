import Foundation

// Raw values are the exact strings/ints stored in SQLite and card.json — never change them.

package enum PaperStatus: String, Codable, Sendable, CaseIterable {
    case toRead = "to_read", reading, done
}

package enum Priority: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = -1, normal = 0, high = 1
    package static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// auto = placed by the scheduler; pinned = user picked the date; none = unscheduled.
package enum ScheduleMode: String, Codable, Sendable, CaseIterable {
    case auto, pinned, none
}

/// Who last wrote `deadline`: the scheduler's place() or an explicit user action.
package enum DeadlineOrigin: String, Codable, Sendable {
    case place, user
}

/// Import pipeline progress, persisted so a crash/quit resumes where it stopped.
package enum PaperStage: String, Codable, Sendable, CaseIterable {
    case committed, enriched, filed, ready
}

package enum AIState: String, Codable, Sendable, CaseIterable {
    case none, held, queued, running, done, failed, skipped, limited
    case needsLogin = "needs_login"
}

package struct PaperFlags: OptionSet, Codable, Sendable, Hashable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }
    package static let locked = PaperFlags(rawValue: 1)       // encrypted, could not unlock
    package static let scanned = PaperFlags(rawValue: 2)      // < ~200 chars/page of text
    package static let unreadable = PaperFlags(rawValue: 4)   // PDFKit failed to open
    package static let missing = PaperFlags(rawValue: 8)      // file vanished from the library
    /// Identifier lookups only: the paper came from a confidential email or a person's possibly
    /// unpublished PDF (`MailSyncActor.mayLookUpTitles` said no), so its title never goes to a
    /// metadata title search until the user asks (`Engine.lookUpMetadataOnline`).
    package static let titleLookupHeld = PaperFlags(rawValue: 16)
}

package enum EstSource: String, Codable, Sendable {
    case heuristic, agent, user
}

/// Where the bibliographic header came from.
package enum MetaSource: String, Codable, Sendable {
    case none, pdf, crossref, arxiv, biorxiv, openalex, agent, user
}

/// Precedence of title candidates; a higher rank overwrites a lower one.
package enum TitleRank: Int, Codable, Sendable, Comparable {
    case filename = 0, pdfAttribute = 1, font = 2, agent = 3, api = 4, user = 5
    package static func < (a: TitleRank, b: TitleRank) -> Bool { a.rawValue < b.rawValue }
}

package enum ChecklistKind: String, Codable, Sendable, CaseIterable {
    case overview, figure, method, stats, data, supplementary, discussion, other
}

package enum ItemOrigin: String, Codable, Sendable {
    case heuristic, agent, user
}

package enum CategoryOrigin: String, Codable, Sendable {
    case starter, agent, user
}

/// `suppressed` remembers a tag the user deleted so re-reads don't re-add it.
package enum TagOrigin: String, Codable, Sendable {
    case agent, user, suppressed
}

package enum AgentJobState: String, Codable, Sendable, CaseIterable {
    case held, queued, running, succeeded, failed, cancelled
}

package enum TextQuality: String, Codable, Sendable {
    case good, partial, poor
}

package enum Difficulty: String, Codable, Sendable {
    case easy, medium, hard
}

package enum PaperType: String, Codable, Sendable, CaseIterable {
    case research, methods, resource, benchmark, review, perspective, other
}
