import Foundation
import WidgetKit
import PaperDeckShared

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    var lang: UILang { snapshot?.lang ?? SnapshotProvider.systemLang }
    /// Gregorian like the snapshot's days, whatever calendar the Mac is set to.
    var today: LocalDate { LocalDate(date, calendar: LocalDate.localGregorian) }

    /// The day list for this entry's date (after midnight the snapshot's second day applies).
    var day: WidgetSnapshot.Day? { snapshot?.day(today) }
    var isStale: Bool { snapshot?.isStale(now: date) ?? false }
}

/// Reads the JSON snapshot the app writes to
/// ~/Library/Application Support/PaperDeck/widget/ (sandbox read-only exception).
struct SnapshotProvider: TimelineProvider {
    /// Before the app has written a snapshot (and for the gallery names) use the app's
    /// default UI language, English; afterwards the snapshot carries the chosen language.
    static var systemLang: UILang { .en }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: SharedPaths.widgetSnapshotURL) else { return nil }
        return try? WidgetSnapshot.decode(data)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: Self.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snap = Self.loadSnapshot()
        let now = Date()
        let cal = LocalDate.localGregorian
        let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
        var dates = [now]
        if let r = snap?.reminder,
           let reminder = cal.nextDate(after: now, matching: DateComponents(hour: r.h, minute: r.m), matchingPolicy: .nextTime),
           reminder < midnight {
            dates.append(reminder)
        }
        dates.append(midnight)
        let entries = dates.map { SnapshotEntry(date: $0, snapshot: snap) }
        // The app reloads timelines whenever the library changes; otherwise refresh after midnight.
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
}
