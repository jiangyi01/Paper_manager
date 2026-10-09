import Foundation

/// Facts about the installed CLI that belong to the Mac, not to a library (§3.1: the learned
/// argv variant lives in UserDefaults `agent.claude.argvVariant` / `…argvVariantCLIVersion`).
/// Backed by a UserDefaults domain in the app, by memory in tests.
/// `@unchecked Sendable`: UserDefaults is documented thread-safe; the memory store is locked.
package final class CLIFactStore: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memory: [String: String] = [:]

    package init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private init() {
        defaults = nil
    }

    /// UserDefaults.standard (the app's own defaults domain).
    package static let standard = CLIFactStore(defaults: .standard)

    /// A private, process-local store (tests, scratch engines).
    package static func inMemory() -> CLIFactStore { CLIFactStore() }

    package func string(forKey key: String) -> String? {
        if let defaults { return defaults.string(forKey: key) }
        return lock.withLock { memory[key] }
    }

    /// nil removes the key.
    package func set(_ value: String?, forKey key: String) {
        if let defaults {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            return
        }
        lock.withLock { memory[key] = value }
    }
}
