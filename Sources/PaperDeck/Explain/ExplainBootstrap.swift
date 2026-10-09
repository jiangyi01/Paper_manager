import AppKit
import PaperDeckCore

/// What AppDelegate installs for Explain (the Services provider, the coordinator, the shortcut).
/// While `ExplainCoordinator.isAvailable` is false nothing is installed: no shortcut is registered,
/// no Services provider is set, and the app behaves exactly as before. Owned by the Explain UI lane.
enum ExplainBootstrap {
    /// The coordinator the menus, the reader and the Services provider call (nil until installed).
    private(set) static var coordinator: ExplainCoordinator?
    private static var services: ExplainServiceProvider?

    /// As early as possible at launch (`applicationDidFinishLaunching`, before the library opens):
    /// the Services provider exists, so a Services call that cold-launched the app is queued until
    /// `install` (like the app's pending opens).
    static func installServices() {
        guard ExplainCoordinator.isAvailable, services == nil else { return }
        let provider = ExplainServiceProvider(coordinator: nil)
        services = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    /// Called once by AppDelegate after `buildUI`.
    static func install(_ state: AppState) {
        guard ExplainCoordinator.isAvailable else { return }
        installServices()
        let coordinator = ExplainCoordinator(state: state)
        self.coordinator = coordinator
        coordinator.registerHotKey()
        services?.attach(coordinator)
    }

    /// The shared switch (`assist.mode`) changed: the shortcut is registered while it is on and
    /// released while it is off.
    static func assistModeChanged() {
        coordinator?.registerHotKey()
    }

    /// Settings changed the shortcut: register it again (returns the new status).
    @discardableResult
    static func shortcutChanged() -> HotKeyRegistration? {
        guard let coordinator else { return nil }
        coordinator.registerHotKey()
        return coordinator.hotKeyStatus
    }

    /// Quit: the panels close (their sessions end) and the shortcut is released.
    static func shutdown() {
        coordinator?.closeAll()
        coordinator?.unregisterHotKey()
    }
}
