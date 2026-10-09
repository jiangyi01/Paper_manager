import AppKit
import PaperDeckCore

/// System notifications that invalidate time-derived state (§6.5 重排触发): wake from
/// sleep, midnight, a manual clock change, a time-zone change, and app activation.
///
/// Every observer uses `queue: .main`, so the handlers run on the main thread and can be
/// entered with `MainActor.assumeIsolated` (an observer without a queue would call a
/// MainActor-inferred closure from a background thread and trap).
final class SystemEvents {
    enum Kind: String, CaseIterable, Sendable {
        case wake, dayChanged, clockChanged, timeZoneChanged, becameActive
    }

    private var handlers: [Kind: [() -> Void]] = [:]
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init() {}

    /// Registers a callback (runs on the main actor); several subscribers per kind are fine.
    func on(_ kind: Kind, perform handler: @escaping () -> Void) {
        handlers[kind, default: []].append(handler)
    }

    /// Idempotent.
    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        observe(workspace, NSWorkspace.didWakeNotification, .wake)
        observe(center, .NSCalendarDayChanged, .dayChanged)
        observe(center, .NSSystemClockDidChange, .clockChanged)
        observe(center, .NSSystemTimeZoneDidChange, .timeZoneChanged)
        observe(center, NSApplication.didBecomeActiveNotification, .becameActive)
    }

    func stop() {
        for t in tokens { t.center.removeObserver(t.token) }
        tokens.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ kind: Kind) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(kind) }
        }
        tokens.append((center, token))
    }

    private func fire(_ kind: Kind) {
        if kind != .becameActive { Log.app.info("system event: \(kind.rawValue, privacy: .public)") }
        // TimeZone.current is cached per process; drop the cache before anyone recomputes "today".
        if kind == .timeZoneChanged { NSTimeZone.resetSystemTimeZone() }
        for handler in handlers[kind] ?? [] { handler() }
    }
}
