import SwiftUI
import WidgetKit
import PaperDeckShared

/// Display-only widgets (no App Intents: their metadata needs Xcode's toolchain).
/// Taps deep-link into the app via paperdeck:// URLs.
struct PaperDeckWidgets: WidgetBundle {
    var body: some Widget {
        TodayReadingWidget()
        RecentCardsWidget()
    }
}

struct TodayReadingWidget: Widget {
    let kind = "TodayReading"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            TodayReadingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(SharedStrings.Widget.todayKind(SnapshotProvider.systemLang))
        .description(SnapshotProvider.systemLang == .zh ? "今天要读的论文、DDL 与进度" : "Today's papers, deadlines and progress")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentCardsWidget: Widget {
    let kind = "RecentCards"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            RecentCardsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(SharedStrings.Widget.recentKind(SnapshotProvider.systemLang))
        .description(SnapshotProvider.systemLang == .zh ? "最近添加的论文卡片" : "Recently added paper cards")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
