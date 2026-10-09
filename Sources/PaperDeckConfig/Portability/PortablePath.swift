import Foundation
import PaperDeckCore

/// A path as it travels in a settings file: inside a cloud root (by provider and root name),
/// relative to home, or absolute. Storage keeps absolute paths as today; this is only used to
/// export and import (PORTABILITY_PLAN §2.8, §2.10).
package enum PortablePath: Codable, Sendable, Equatable {
    case home(String)
    case cloud(provider: CloudProvider, root: String, relative: String)
    case absolute(String)

    /// Where an imported path points on this Mac.
    package enum Resolution: Sendable, Equatable {
        /// The same place: home-relative, absolute, or the same cloud root name.
        case exact(URL)
        /// The only root of the same provider on this Mac (another tenant / account name).
        case sameProvider(URL)
        /// No such root here: the user chooses later.
        case unresolved
    }

    /// Cloud roots first (`CloudRootLocator.split`), then home-relative, else absolute. `~` paths
    /// count as home-relative.
    package static func encode(_ absolutePath: String, home: URL, roots: [CloudRoot]) -> PortablePath {
        if let (root, relative) = CloudRootLocator.split(absolutePath, home: home) {
            return .cloud(provider: root.provider, root: root.name, relative: relative)
        }
        let path = absolutePath.hasPrefix("~/") ? home.path + String(absolutePath.dropFirst(1)) : absolutePath
        let base = home.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) { return .home(String(path.dropFirst(prefix.count))) }
        if path == base { return .home("") }
        return .absolute(path)
    }

    /// The path on this Mac: home-relative under `home`; absolute as is; a cloud path under the
    /// root of the same name, else under the only root of the same provider (iCloud Drive: always
    /// this Mac's), else unresolved.
    package func resolve(home: URL, roots: [CloudRoot]) -> Resolution {
        func under(_ base: URL, _ relative: String) -> URL {
            relative.isEmpty ? base : base.appendingPathComponent(relative)
        }
        switch self {
        case .home(let relative): return .exact(under(home, relative))
        case .absolute(let path): return .exact(URL(fileURLWithPath: path))
        case .cloud(let provider, let root, let relative):
            if provider == .iCloudDrive { return .exact(under(CloudRootLocator.iCloudDrive(home: home).url, relative)) }
            if let same = roots.first(where: { $0.name == root }) { return .exact(under(same.url, relative)) }
            if let legacy = CloudRootLocator.homeRoot(named: root, home: home),
               FileManager.default.fileExists(atPath: legacy.url.path) {
                return .exact(under(legacy.url, relative))            // the legacy app folder in home
            }
            let sameProvider = roots.filter { $0.provider == provider }
            if sameProvider.count == 1 { return .sameProvider(under(sameProvider[0].url, relative)) }
            return .unresolved
        }
    }
}
