import Foundation

// Inputs for the app's DerivedRefresher (§6.5 reminders, §6.6 widget snapshot). Core
// composes; the app does the UNUserNotificationCenter scheduling and WidgetCenter reloads.

extension Engine {
    /// The rolling daily reminders (`daily-YYYY-MM-DD`) for the next `days` days — from
    /// tomorrow once today's reminder time has passed. Feed it to `ReminderComposer.diff`
    /// with the pending/delivered requests. Empty when reminders are switched off. Includes the
    /// 「邮件待处理 N 封」 line (and reminds on mail alone) unless Settings ▸ Mail turned it off.
    package func reminderPlan(from now: Date, days: Int = ReminderComposer.planDays) async throws -> [ReminderSpec] {
        let inputs = try await ctx.planInputs()
        guard inputs.settings.reminderEnabled else { return [] }
        return ReminderComposer.plan(from: now, days: days, papers: Self.reminderPapers(inputs),
                                     settings: inputs.settings.plan, lang: inputs.settings.lang, calendar: ctx.calendar,
                                     mail: try await mailReminderInfo())
    }

    /// One day's reminder recomputed on the spot: REMIND_1H (`now` = the actual time) or the
    /// catch-up after a missed 11:00 (`now` nil = as of that day's reminder time).
    package func composeReminder(day: LocalDate, now: Date? = nil) async throws -> ReminderSpec? {
        let inputs = try await ctx.planInputs()
        guard inputs.settings.reminderEnabled else { return nil }
        return ReminderComposer.compose(day: day, papers: Self.reminderPapers(inputs), settings: inputs.settings.plan,
                                        lang: inputs.settings.lang, calendar: ctx.calendar, now: now,
                                        mail: try await mailReminderInfo())
    }

    /// Pending cards (`Database.mailCounts`) plus the snoozed ones with their wake-up times;
    /// nil when the reminder line is off in Settings ▸ Mail.
    package func mailReminderInfo() async throws -> MailReminderInfo? {
        guard loadMailSettings().includeInDailyReminder else { return nil }
        let counts = try await db.mailCounts()
        let snoozed = try await db.mailMessages(states: [.snoozed], limit: 1_000).compactMap { m -> MailReminderInfo.Snoozed? in
            guard let until = m.snoozedUntil else { return nil }
            let request = (m.senderKind == .advisor || m.senderKind == .person) && m.triage?.hasReadingRequest == true
            return MailReminderInfo.Snoozed(until: until, isRequest: request)
        }
        guard counts.pending > 0 || !snoozed.isEmpty else { return nil }
        return MailReminderInfo(pending: counts.pending, requests: counts.requests, snoozed: snoozed)
    }

    /// The widget snapshot as of now (thumbnails = papers that have a widget thumb on disk).
    package func widgetSnapshot() async throws -> WidgetSnapshot {
        let inputs = try await WidgetInputs.load(self)
        let widgetThumbs = ctx.thumbs.widgetDirectory
        return inputs.build(thumbnails: await BlockingIO.run { WidgetInputs.thumbIDs(in: widgetThumbs) })
    }

    /// Where the sandboxed widget reads the snapshot (`support/widget/snapshot.json`).
    package var widgetSnapshotURL: URL { paths.widget.appendingPathComponent("snapshot.json") }

    /// Writes the snapshot atomically unless it matches the file on disk in everything but
    /// `generatedAt`. First regenerates missing widget thumbnails of the papers it lists.
    /// True when written — the app then calls `WidgetCenter.shared.reloadAllTimelines()`.
    @discardableResult
    package func writeWidgetSnapshot() async throws -> Bool {
        let inputs = try await WidgetInputs.load(self)
        let thumbs = ctx.thumbs
        var thumbIDs = await BlockingIO.run { WidgetInputs.thumbIDs(in: thumbs.widgetDirectory) }
        var snapshot = inputs.build(thumbnails: thumbIDs)
        let missing = Set(snapshot.papers.keys).subtracting(thumbIDs)
        if !missing.isEmpty {
            let made = await BlockingIO.run {
                Set(missing.filter { (try? thumbs.regenerateWidgetThumbnail(id: $0)) == true })
            }
            if !made.isEmpty {
                thumbIDs.formUnion(made)
                snapshot = inputs.build(thumbnails: thumbIDs)
            }
        }
        let url = widgetSnapshotURL
        let final = snapshot
        let data = try final.encoded()
        return try await BlockingIO.run {
            if let old = try? WidgetSnapshot.decode(Data(contentsOf: url)), old.sameContent(as: final) { return false }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { throw FileOps.classify(error) }
            return true
        }
    }

    fileprivate static func reminderPapers(_ inputs: EngineContext.PlanInputs) -> [ReminderPaper] {
        inputs.papers.map { ReminderPaper(paper: $0, checklist: inputs.checklists[$0.pk] ?? []) }
    }
}

/// What `SnapshotBuilder.build` needs, read once.
private struct WidgetInputs: Sendable {
    var papers: [Paper]
    var checklists: [String: [ChecklistItem]]
    var categories: [Int64: PaperCategory]
    var settings: EngineSettings
    var now: Date
    var calendar: Calendar

    static func load(_ engine: Engine) async throws -> WidgetInputs {
        let inputs = try await engine.ctx.planInputs()
        let categories = try await engine.db.categories()
        return WidgetInputs(
            papers: inputs.papers,
            checklists: Dictionary(inputs.papers.map { ($0.id, inputs.checklists[$0.pk] ?? []) }, uniquingKeysWith: { a, _ in a }),
            categories: Dictionary(categories.map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a }),
            settings: inputs.settings, now: engine.ctx.now(), calendar: engine.ctx.calendar)
    }

    func build(thumbnails: Set<String>) -> WidgetSnapshot {
        SnapshotBuilder.build(papers: papers, checklists: checklists, categories: categories, settings: settings.plan,
                              lang: settings.lang, now: now, calendar: calendar, thumbnails: thumbnails)
    }

    /// Ids with `widget/thumbs/<id>.jpg` (one directory listing).
    static func thumbIDs(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { $0.hasSuffix(".jpg") ? String($0.dropLast(4)) : nil })
    }
}
