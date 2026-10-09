import Foundation
import PaperDeckCore

/// Settings ▸ Library ▸ Change… : what the next launch does before opening the engine
/// (`library.pendingAction`, JSON).
package struct LibraryPendingAction: Codable, Sendable, Equatable {
    package enum Kind: String, Codable, Sendable {
        case openExisting, startNew
    }

    package var kind: Kind
    package var path: String
    package var previousPath: String?

    package static let key = "library.pendingAction"

    package init(kind: Kind, path: String, previousPath: String?) {
        self.kind = kind; self.path = path; self.previousPath = previousPath
    }

    package static func load(_ d: UserDefaults) -> LibraryPendingAction? {
        guard let s = d.string(forKey: key), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LibraryPendingAction.self, from: data)
    }

    package func save(_ d: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        d.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    package static func clear(_ d: UserDefaults) {
        d.removeObject(forKey: key)
    }
}
