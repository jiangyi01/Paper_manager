import Foundation

/// The papers the user opened from PaperDeck most recently, newest first (in memory only, never
/// persisted). Explain's paper locator prefers them when matching what is on screen. The app pushes
/// from `AppState.openPDF`. Thread-safe.
package final class RecentOpens: @unchecked Sendable {
    package struct Entry: Sendable, Equatable {
        package var paperID: String
        package var openedAt: Date
    }

    package static let capacity = 20
    private let lock = NSLock()
    private var entries: [Entry] = []

    package init() {}

    package func push(paperID: String, at date: Date = Date()) {
        lock.withLock {
            entries.removeAll { $0.paperID == paperID }
            entries.insert(Entry(paperID: paperID, openedAt: date), at: 0)
            if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        }
    }

    /// Newest first; `within` limits them to the last that many seconds.
    package func recent(now: Date = Date(), within: TimeInterval? = nil) -> [Entry] {
        lock.withLock {
            guard let within else { return entries }
            return entries.filter { now.timeIntervalSince($0.openedAt) <= within }
        }
    }
}
