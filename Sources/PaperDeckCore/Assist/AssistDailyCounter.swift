import Foundation

/// Turns per local day (and per provider), for the assist caps (`assist.count.<day>.<provider>`)
/// and the duplicate judge's automatic cap (`dedupe.ai.count.<day>`). The counts live in kv rows of
/// the library (never exported); this class keeps them in memory so `AssistGate` can decide
/// synchronously, and hands every change to `persist` (the engine writes the kv row off the gate's
/// lock). `restore` loads today's rows at launch. Thread-safe.
package final class AssistDailyCounter: @unchecked Sendable {
    /// `assist.count` or `dedupe.ai.count`.
    package let prefix: String
    private let calendar: Calendar
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var persist: (@Sendable (_ key: String, _ value: Int) -> Void)?

    package static let assistPrefix = "assist.count"
    package static let dedupeJudgePrefix = "dedupe.ai.count"

    package init(prefix: String = AssistDailyCounter.assistPrefix, calendar: Calendar = .autoupdatingCurrent,
                 persist: (@Sendable (_ key: String, _ value: Int) -> Void)? = nil) {
        self.prefix = prefix; self.calendar = calendar; self.persist = persist
    }

    /// Where changes go (set once by the engine; tests leave it nil).
    package func setPersist(_ persist: (@Sendable (_ key: String, _ value: Int) -> Void)?) {
        lock.withLock { self.persist = persist }
    }

    /// `assist.count.2026-10-01.claude` / `dedupe.ai.count.2026-10-01`.
    package func key(day: LocalDate, provider: String?) -> String {
        [prefix, day.iso, provider].compactMap { $0 }.joined(separator: ".")
    }

    package func day(_ now: Date) -> LocalDate { LocalDate.today(now: now, calendar: calendar) }

    package func count(at now: Date, provider: String? = nil) -> Int {
        let k = key(day: day(now), provider: provider)
        return lock.withLock { counts[k] ?? 0 }
    }

    /// Adds one turn; returns the new count.
    @discardableResult
    package func increment(at now: Date, provider: String? = nil) -> Int {
        let k = key(day: day(now), provider: provider)
        let (value, sink): (Int, (@Sendable (String, Int) -> Void)?) = lock.withLock {
            let v = (counts[k] ?? 0) + 1
            counts[k] = v
            return (v, persist)
        }
        sink?(k, value)
        return value
    }

    /// Loads persisted rows (keys under `prefix`); rows of other days are kept in memory but never matter.
    package func restore(_ rows: [String: String]) {
        lock.withLock {
            for (k, v) in rows where k.hasPrefix(prefix + ".") {
                if let n = Int(v), n >= 0 { counts[k] = max(counts[k] ?? 0, n) }
            }
        }
    }

    /// The kv keys of days before `now`'s (Maintenance may delete them).
    package func staleKeys(_ keys: [String], now: Date) -> [String] {
        let today = day(now).iso
        return keys.filter { k in
            guard k.hasPrefix(prefix + ".") else { return false }
            let rest = k.dropFirst(prefix.count + 1)
            return String(rest.prefix(10)) < today
        }
    }
}
