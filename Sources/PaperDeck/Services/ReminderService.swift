import AppKit
import Observation
import UserNotifications
import PaperDeckCore
import PaperDeckShared

/// The single daily reminder (§6.5, §3.5): 14 rolling one-shot `daily-YYYY-MM-DD`
/// requests, diffed against what the notification center already holds; catch-up for a
/// missed reminder; the three actions; an osascript fallback when notifications are denied.
///
/// Created in `applicationWillFinishLaunching` (the UN delegate must be set before launch
/// finishes so a click that launched the app is delivered). The state provider is lazy
/// because the engine opens later; responses that arrive first are queued.
///
/// Concurrency: only the async UN APIs are used from here. The delegate methods are
/// `nonisolated async`, pull Sendable strings out of the UN objects and hop to the main actor.
@Observable
final class ReminderService: NSObject, UNUserNotificationCenterDelegate {
    enum ActionID {
        static let openList = "OPEN_LIST"
        static let postponeDay = "POSTPONE_DAY"
        static let remindLater = "REMIND_1H"
    }

    static let lastDeliveredKey = "reminder.lastDeliveredDay"
    /// Fire times of the `daily-*` requests this app left pending (tells "the system delivered
    /// it" from "it was never scheduled" for catch-up).
    static let scheduledKey = "reminder.scheduledFires"
    static let remindLaterPrefix = "remind-1h-"
    static let catchUpGrace: TimeInterval = 120       // 11:02 for an 11:00 reminder
    static let catchUpEndHour = 22

    /// Views that are built without the service (settings tabs, setup assistant) reach it here.
    private(set) static weak var shared: ReminderService?

    /// Last authorization status read from the notification center (observable for the UI).
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// False when the process has no bundle identifier (bare `swift build` binary):
    /// UNUserNotificationCenter would crash there, so everything goes through the fallback.
    let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    @ObservationIgnored private let stateProvider: () -> AppState?
    @ObservationIgnored private var queuedResponses: [Response] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackCheckedDay: LocalDate?
    @ObservationIgnored private var registeredLanguage: UILang?
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Sendable extract of a UNNotificationResponse.
    private struct Response: Sendable {
        var action: String
        var requestID: String
        var url: String?
    }

    init(stateProvider: @escaping () -> AppState?) {
        self.stateProvider = stateProvider
        super.init()
        ReminderService.shared = self
    }

    private var center: UNUserNotificationCenter? {
        notificationsAvailable ? UNUserNotificationCenter.current() : nil
    }

    // MARK: - Install

    /// Sets the delegate, registers the DAILY_LIST category and installs the
    /// `paperdeck://debug/…` hook. Call from `applicationWillFinishLaunching`.
    func install() {
        URLRouter.debugHandler = { [weak self] link in self?.handleDebug(link) }
        guard let center else {
            Log.reminder.notice("no bundle identifier: notifications unavailable, using the osascript fallback")
            return
        }
        center.delegate = self
        registerCategories()
    }

    /// Action titles follow the UI language, so they are re-registered when it changes.
    private func registerCategories() {
        guard let center else { return }
        registeredLanguage = L.lang
        let open = UNNotificationAction(identifier: ActionID.openList, title: L.Pref.actionOpenList, options: [.foreground])
        let postpone = UNNotificationAction(identifier: ActionID.postponeDay, title: L.Pref.actionPostponeDay, options: [])
        let later = UNNotificationAction(identifier: ActionID.remindLater, title: L.Pref.actionRemindLater, options: [])
        let category = UNNotificationCategory(identifier: ReminderSpec.categoryIdentifier, actions: [open, postpone, later],
                                              intentIdentifiers: [], options: [.customDismissAction])
        center.setNotificationCategories([category])
    }

    // MARK: - Authorization

    static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    @discardableResult
    func refreshAuthorization() async -> UNAuthorizationStatus {
        guard let center else { authorization = .denied; return .denied }
        let status = await center.notificationSettings().authorizationStatus
        authorization = status
        return status
    }

    /// Asks for alert + sound permission (the system shows its prompt once; afterwards it
    /// just returns the stored answer), then reschedules.
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.reminder.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            granted = false
        }
        await refreshAuthorization()
        await reschedule()
        return granted
    }

    /// 系统设置 ▸ 通知 ▸ PaperDeck.
    static func openSystemNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? SharedPaths.bundleID
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Reschedule

    /// Reconciles the 14-day plan with the notification center (serialized with catch-up).
    func reschedule() async {
        await serialized { await self.rescheduleNow() }
    }

    private func rescheduleNow() async {
        guard let state = stateProvider() else { return }
        if registeredLanguage != L.lang { registerCategories() }
        guard let center else {
            updateFallback(armed: state.settings.reminderEnabled)
            return
        }
        let status = await refreshAuthorization()
        guard state.settings.reminderEnabled else {
            updateFallback(armed: false)
            await removeAllReminders(center)
            return
        }
        guard Self.isAuthorized(status) else {
            // Denied → in-app fallback. Not asked yet → wait for the setup assistant / settings.
            updateFallback(armed: status == .denied)
            return
        }
        updateFallback(armed: false)
        do {
            let now = Date()
            let plan = try await state.engine.reminderPlan(from: now)
            let requests = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(ReminderSpec.idPrefix) }
            inferSystemDeliveries(pendingIDs: Set(requests.map(\.identifier)), now: now)
            // ReminderSpec.hash covers the text only: a request still set for another reminder
            // time counts as changed, so moving 11:00 → 10:30 replaces the pending requests.
            let (hour, minute) = Self.reminderTime(state.settings)
            let pending = requests.map { r -> (id: String, hash: String) in
                let fires = (r.trigger as? UNCalendarNotificationTrigger)?.dateComponents
                let sameTime = fires?.hour == hour && fires?.minute == minute
                return (r.identifier, sameTime ? ((r.content.userInfo["h"] as? String) ?? "") : "")
            }
            let delivered = Set(await center.deliveredNotifications().map(\.request.identifier))
            let (remove, add) = ReminderComposer.diff(pending: pending, delivered: delivered, plan: plan,
                                                      lastDelivered: lastDeliveredDay)
            if !remove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: remove) }
            var fires: [String: Double] = [:]
            let removed = Set(remove)
            for r in requests where !removed.contains(r.identifier) {
                if let d = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                    fires[Self.day(of: r.identifier)] = d.timeIntervalSince1970
                }
            }
            var added = 0
            for spec in add {
                let trigger = UNCalendarNotificationTrigger(dateMatching: spec.triggerComponents(), repeats: false)
                do {
                    try await center.add(Self.request(spec: spec, trigger: trigger))
                    fires[spec.day.iso] = spec.fireDate.timeIntervalSince1970
                    added += 1
                } catch {
                    Log.reminder.error("add \(spec.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            scheduledFires = fires
            Log.reminder.info("reschedule: plan \(plan.count), removed \(remove.count), added \(added), pending \(fires.count)")
        } catch {
            Log.reminder.error("reminder plan failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A request we scheduled whose time has passed and which is no longer pending was
    /// delivered by the system (maybe while PaperDeck wasn't frontmost, so willPresent never
    /// ran). Recording it keeps catch-up and diff from ringing that day twice.
    private func inferSystemDeliveries(pendingIDs: Set<String>, now: Date) {
        for (iso, fire) in scheduledFires where fire <= now.timeIntervalSince1970 {
            guard !pendingIDs.contains(ReminderSpec.idPrefix + iso), let day = LocalDate(iso: iso) else { continue }
            if lastDeliveredDay.map({ day > $0 }) ?? true { lastDeliveredDay = day }
        }
    }

    private static func day(of requestID: String) -> String {
        String(requestID.dropFirst(ReminderSpec.idPrefix.count))
    }

    private func removeAllReminders(_ center: UNUserNotificationCenter) async {
        let ids = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(ReminderSpec.idPrefix) || $0.hasPrefix(Self.remindLaterPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
            Log.reminder.info("reminders off: removed \(ids.count) pending")
        }
        scheduledFires = [:]
    }

    // MARK: - Catch-up

    /// A missed reminder (asleep / not running at 11:00): between reminder time + 2 min and
    /// 22:00, if today's has not been delivered, deliver it now. Called by DerivedRefresher
    /// 5 s after launch, 60 s after wake and on day change.
    func catchUp() async {
        await serialized { await self.catchUpNow() }
    }

    private func catchUpNow() async {
        guard let state = stateProvider(), state.settings.reminderEnabled else { return }
        let now = Date()
        let cal = LocalDate.localGregorian
        let today = LocalDate(now, calendar: cal)
        healLastDelivered(today: today)
        guard lastDeliveredDay != today, Self.inCatchUpWindow(now: now, today: today, settings: state.settings, calendar: cal)
        else { return }
        guard let center else { await fallbackTick(); return }
        let status = await refreshAuthorization()
        guard Self.isAuthorized(status) else {
            if status == .denied { await fallbackTick() }
            return
        }
        let id = ReminderSpec.id(for: today)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        if delivered.contains(id) {
            lastDeliveredDay = today
            return
        }
        let pendingIDs = Set(await center.pendingNotificationRequests().map(\.identifier))
        inferSystemDeliveries(pendingIDs: pendingIDs, now: now)
        // Delivered by the system and already cleared from Notification Center: don't ring twice.
        if lastDeliveredDay == today { return }
        let isPending = pendingIDs.contains(id)
        if isPending { center.removePendingNotificationRequests(withIdentifiers: [id]) }
        do {
            guard let spec = try await state.engine.composeReminder(day: today, now: now) else { return }
            try await center.add(Self.request(spec: spec, trigger: nil))
            lastDeliveredDay = today
            scheduledFires[today.iso] = nil
            Log.reminder.notice("catch-up: delivered \(id, privacy: .public) (was \(isPending ? "pending" : "never scheduled", privacy: .public))")
        } catch {
            Log.reminder.error("catch-up failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A stored day after today (written under a non-Gregorian system calendar, e.g. 2569-…) is
    /// pulled back to today, so catch-up and the fallback recognise today's delivery again.
    private func healLastDelivered(today: LocalDate) {
        let stored = lastDeliveredDay
        let healed = ReminderComposer.clampedLastDelivered(stored, today: today)
        if healed != stored {
            lastDeliveredDay = healed
            Log.reminder.notice("lastDelivered \(stored?.iso ?? "-", privacy: .public) clamped to \(today.iso, privacy: .public)")
        }
    }

    private static func inCatchUpWindow(now: Date, today: LocalDate, settings: SettingsStore, calendar: Calendar) -> Bool {
        let (h, m) = reminderTime(settings)
        let start = today.date(hour: h, minute: m, calendar: calendar).addingTimeInterval(catchUpGrace)
        let end = today.date(hour: catchUpEndHour, minute: 0, calendar: calendar)
        return now >= start && now < end
    }

    private static func reminderTime(_ s: SettingsStore) -> (Int, Int) {
        (min(max(s.reminderHour, 0), 23), min(max(s.reminderMinute, 0), 59))
    }

    // MARK: - Delegate (nonisolated; Sendable values only cross to the main actor)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        await MainActor.run { self.noteDelivered(requestID: id) }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let r = Response(action: response.actionIdentifier,
                         requestID: response.notification.request.identifier,
                         url: response.notification.request.content.userInfo["url"] as? String)
        await MainActor.run { self.receive(r) }
    }

    private func noteDelivered(requestID: String) {
        guard requestID.hasPrefix(ReminderSpec.idPrefix),
              let day = LocalDate(iso: String(requestID.dropFirst(ReminderSpec.idPrefix.count))) else { return }
        if lastDeliveredDay.map({ day > $0 }) ?? true { lastDeliveredDay = day }
    }

    private func receive(_ r: Response) {
        noteDelivered(requestID: r.requestID)
        guard let state = stateProvider() else {
            // Cold launch from a click: the engine is still opening.
            queuedResponses.append(r)
            waitForState()
            return
        }
        perform(r, state: state)
    }

    private func perform(_ r: Response, state: AppState) {
        switch r.action {
        case UNNotificationDismissActionIdentifier:
            return
        case ActionID.postponeDay:
            state.skipToday()
        case ActionID.remindLater:
            Task { await self.remindLater(state: state) }
        default:
            // Default click and OPEN_LIST; agent notices carry a paper link, new reading requests
            // (MailRequestNotifier) a mail link.
            switch r.url.flatMap(URL.init(string:)).flatMap(DeepLink.init(url:)) {
            case .paper(let id)?: state.router.showPaper(id)
            case .mail(let id)?: state.router.showMail(id)
            default: state.router.showToday()
            }
        }
    }

    /// Delivers responses that arrived before the state existed. DerivedRefresher.start()
    /// calls it; a short poll covers the gap as well.
    func flushQueuedResponses() {
        guard !queuedResponses.isEmpty, let state = stateProvider() else { return }
        let items = queuedResponses
        queuedResponses.removeAll()
        for r in items { perform(r, state: state) }
    }

    private func waitForState() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            for _ in 0..<240 {                                   // up to 60 s
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.stateProvider() != nil { break }
            }
            self?.flushTask = nil
            self?.flushQueuedResponses()
        }
    }

    // MARK: - Actions

    /// REMIND_1H: today's content recomputed now, delivered in an hour.
    private func remindLater(state: AppState) async {
        let today = LocalDate(Date(), calendar: LocalDate.localGregorian)
        do {
            guard let spec = try await state.engine.composeReminder(day: today, now: Date()) else { return }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
            if let center {
                try await center.add(Self.request(spec: spec, id: Self.remindLaterPrefix + today.iso, trigger: trigger))
                Log.reminder.info("remind in 1 h scheduled")
            }
        } catch {
            Log.reminder.error("remind-1h failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// [发送测试通知]: today's reminder as it would read right now (a sample when there is
    /// nothing to list), delivered immediately.
    func sendTest() async {
        guard let state = stateProvider() else { return }
        let today = LocalDate(Date(), calendar: LocalDate.localGregorian)
        let spec = try? await state.engine.composeReminder(day: today, now: Date())
        let title = spec?.title ?? L.Pref.testTitle
        let subtitle = spec?.subtitle ?? ""
        let body = spec?.body ?? L.Pref.testBody
        guard let center else {
            await Self.osascriptNotify(title: title, subtitle: subtitle, body: body)
            return
        }
        var status = await refreshAuthorization()
        if status == .notDetermined {
            _ = await requestAuthorization()
            status = authorization
        }
        guard Self.isAuthorized(status) else {
            await Self.osascriptNotify(title: title, subtitle: subtitle, body: body)
            return
        }
        let content = Self.content(title: title, subtitle: subtitle, body: body,
                                   userInfo: ["url": DeepLink.today.url.absoluteString])
        do {
            try await center.add(UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil))
        } catch {
            Log.reminder.error("test notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-off notices (Claude finished / usage limit / a new reading request by email). Posted
    /// only when notifications are allowed; the in-app toast / inbox covers the rest. The same `id`
    /// replaces an earlier notice instead of adding a second one.
    func postNotice(id: String, title: String, body: String, url: URL?, thread: String = "agent") async {
        guard let center, Self.isAuthorized(await refreshAuthorization()) else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = thread
        if let url { c.userInfo = ["url": url.absoluteString] }
        c.sound = .default
        do { try await center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) }
        catch { Log.reminder.error("notice failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Debug deep links (paperdeck://debug/…, only with `debugURLs` on)

    func handleDebug(_ link: DeepLink) {
        guard UserDefaults.standard.bool(forKey: URLRouter.debugDefaultsKey) else {
            Log.reminder.notice("debug URL ignored (defaults write \(SharedPaths.bundleID, privacy: .public) debugURLs -bool true)")
            return
        }
        switch link {
        case .debugPending: Task { await self.logPending() }
        case .debugRemind(let seconds): Task { await self.debugRemind(in: seconds) }
        default: break
        }
    }

    private func logPending() async {
        guard let center else { Log.reminder.notice("pending: notifications unavailable"); return }
        let status = await refreshAuthorization()
        let pending = await center.pendingNotificationRequests().sorted { $0.identifier < $1.identifier }
        Log.reminder.notice("pending: \(pending.count) request(s), authorization \(status.rawValue), lastDelivered \(self.lastDeliveredDay?.iso ?? "-", privacy: .public)")
        for r in pending {
            let when: String
            if let t = r.trigger as? UNCalendarNotificationTrigger, let d = t.nextTriggerDate() { when = d.formatted() }
            else if let t = r.trigger as? UNTimeIntervalNotificationTrigger, let d = t.nextTriggerDate() { when = d.formatted() }
            else { when = "-" }
            let body = r.content.body.replacingOccurrences(of: "\n", with: " ⏎ ")
            Log.reminder.notice("pending \(r.identifier, privacy: .public) @ \(when, privacy: .public): \(r.content.title, privacy: .public) | \(r.content.subtitle, privacy: .public) | \(body, privacy: .public)")
        }
    }

    private func debugRemind(in seconds: Int) async {
        guard let state = stateProvider() else { return }
        let today = LocalDate(Date(), calendar: LocalDate.localGregorian)
        do {
            let spec = try await state.engine.composeReminder(day: today, now: Date())
            guard let spec else { Log.reminder.notice("debug remind: nothing to remind today"); return }
            guard let center else {
                try? await Task.sleep(for: .seconds(seconds))
                await Self.osascriptNotify(title: spec.title, subtitle: spec.subtitle, body: spec.body)
                return
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, seconds)), repeats: false)
            try await center.add(Self.request(spec: spec, id: "debug-remind-\(Int(Date().timeIntervalSince1970))", trigger: trigger))
            Log.reminder.notice("debug remind in \(seconds) s: \(spec.title, privacy: .public)")
        } catch {
            Log.reminder.error("debug remind failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Fallback (notifications denied / unavailable)

    /// A once-a-minute check on the main actor: at the reminder time it arms the drop
    /// panel and posts an osascript notification (argv form — no text in the script).
    private func updateFallback(armed: Bool) {
        if !armed {
            fallbackTask?.cancel()
            fallbackTask = nil
            return
        }
        guard fallbackTask == nil else { return }
        Log.reminder.notice("notifications not allowed: in-app fallback armed")
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fallbackTick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func fallbackTick() async {
        guard let state = stateProvider(), state.settings.reminderEnabled else { return }
        let now = Date()
        let cal = LocalDate.localGregorian
        let today = LocalDate(now, calendar: cal)
        healLastDelivered(today: today)
        guard lastDeliveredDay != today, fallbackCheckedDay != today else { return }
        let (h, m) = Self.reminderTime(state.settings)
        guard now >= today.date(hour: h, minute: m, calendar: cal),
              now < today.date(hour: Self.catchUpEndHour, minute: 0, calendar: cal) else { return }
        fallbackCheckedDay = today
        guard let spec = try? await state.engine.composeReminder(day: today, now: now) else { return }
        lastDeliveredDay = today
        state.router.armDropPanel(60)
        await Self.osascriptNotify(title: spec.title, subtitle: spec.subtitle, body: spec.body)
        Log.reminder.notice("fallback reminder shown for \(today.iso, privacy: .public)")
    }

    /// `/usr/bin/osascript -e 'on run argv' -e 'display notification …' -e 'end run' <title> <body> <subtitle>`.
    /// User text only ever travels as argv items.
    nonisolated static func osascriptNotify(title: String, subtitle: String, body: String) async {
        let script = [
            "on run argv",
            "display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)",
            "end run",
        ]
        var args: [String] = []
        for line in script { args += ["-e", line] }
        args += [title, body, subtitle]
        let env = ["HOME": SharedPaths.realHome.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let runner = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1))
        do {
            let r = try await runner.run(.init(executable: "/usr/bin/osascript", arguments: args, environment: env,
                                               currentDirectory: NSTemporaryDirectory(), timeout: .seconds(15)))
            if r.exitCode != 0 {
                Log.reminder.error("osascript exit \(r.exitCode): \(String(decoding: r.stderr, as: UTF8.self), privacy: .public)")
            }
        } catch {
            Log.reminder.error("osascript failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func content(title: String, subtitle: String, body: String, userInfo: [String: String]) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = subtitle
        c.body = body
        c.categoryIdentifier = ReminderSpec.categoryIdentifier
        c.threadIdentifier = ReminderSpec.threadIdentifier
        c.userInfo = userInfo
        c.sound = .default
        return c
    }

    private static func request(spec: ReminderSpec, id: String? = nil, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let c = content(title: spec.title, subtitle: spec.subtitle, body: spec.body, userInfo: spec.userInfo)
        return UNNotificationRequest(identifier: id ?? spec.id, content: c, trigger: trigger)
    }

    /// Runs reschedule / catch-up one at a time (both suspend on the notification center).
    private func serialized(_ op: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await op()
        }
        tail = task
        await task.value
    }

    var lastDeliveredDay: LocalDate? {
        get { UserDefaults.standard.string(forKey: Self.lastDeliveredKey).flatMap(LocalDate.init(iso:)) }
        set { UserDefaults.standard.set(newValue?.iso, forKey: Self.lastDeliveredKey) }
    }

    /// ISO day → fire time (epoch seconds) of the `daily-*` requests this app left pending.
    private var scheduledFires: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.scheduledKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.scheduledKey) }
    }
}
