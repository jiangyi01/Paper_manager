import Foundation
import PaperDeckCore

/// The persisted values of a defaults domain only (`persistentDomain(forName:)`) — never the
/// registered defaults, which `object(forKey:)` would also see (`setup.completed`, `library.path`
/// are registered by `SettingsStore`). Install detection must not mistake those for user data.
package struct PersistedDomain {
    private let storage: [String: Any]

    package init(_ values: [String: Any]) {
        storage = values
    }

    /// The app's own domain (read-only).
    package static func app(bundleID: String = BuildIdentity.current.bundleID) -> PersistedDomain {
        PersistedDomain(UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:])
    }

    /// A named suite's persisted values (tests, `--suite`).
    package static func suite(_ name: String) -> PersistedDomain {
        PersistedDomain(UserDefaults(suiteName: name)?.persistentDomain(forName: name) ?? [:])
    }

    package func has(_ key: String) -> Bool { storage[key] != nil }

    package func string(_ key: String) -> String? { storage[key] as? String }

    /// An integer value (a stored Bool is not an integer).
    package func int(_ key: String) -> Int? {
        guard let n = storage[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    package var values: [String: Any] { storage }
}
