import Darwin
import Foundation

/// Health of the library root (§3.6). `ubiquitous` is usable but warned about:
/// the root sits in iCloud/OneDrive, so files may be evicted to placeholders.
package enum LibraryStatus: String, Sendable, Equatable, CaseIterable {
    case ok, missing, denied, readOnly, ubiquitous

    package var isUsable: Bool { self == .ok || self == .ubiquitous }
}

package enum LibraryPaths {
    /// Probes `root` by listing it (TCC denials show up as EPERM here) and creating and
    /// removing a hidden temp file. Denied is reported only for access failures, never
    /// silently replaced by a fallback location (§3.6).
    package static func status(of root: URL) -> LibraryStatus {
        var st = stat()
        let statErr = root.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return EINVAL }
            return stat(p, &st) == 0 ? 0 : errno
        }
        if statErr != 0 { return statErr == EPERM || statErr == EACCES ? .denied : .missing }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .missing }

        let listable = root.withUnsafeFileSystemRepresentation { p -> Int32 in
            guard let p else { return EINVAL }
            guard let dir = opendir(p) else { return errno }
            defer { closedir(dir) }
            errno = 0
            return readdir(dir) == nil && errno != 0 ? errno : 0
        }
        if listable != 0 { return listable == EPERM || listable == EACCES ? .denied : .missing }

        let probe = root.appendingPathComponent(".paperdeck-probe-\(UUID().uuidString)")
        let writable = probe.withUnsafeFileSystemRepresentation { p -> Bool in
            guard let p else { return false }
            let fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return false }
            close(fd)
            unlink(p)
            return true
        }
        if !writable { return .readOnly }
        return FileOps.isUbiquitous(root) ? .ubiquitous : .ok
    }

    /// Creates the full on-disk layout (§5). The library root's parent must exist — a
    /// missing volume or folder is never recreated as an empty local directory — while
    /// the app-owned support and cache trees are created with intermediates. Caches are
    /// excluded from backups. Idempotent.
    package static func ensureLayout(paths: AppPaths) throws {
        try FileOps.createFolder(paths.library)
        for dir in [paths.papers, paths.inbox, paths.partial, paths.recentlyDeleted] {
            try FileOps.createFolder(dir)
        }
        let owned = [paths.support, paths.textCache, paths.agentCwd, paths.jobs, paths.backups,
                     paths.widget, paths.widgetThumbs, paths.caches, paths.thumbnails, paths.incoming]
        for dir in owned {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { throw FileOps.classify(error) }
        }
        for dir in [paths.caches, paths.thumbnails, paths.incoming] {
            excludeFromBackup(dir)
        }
    }

    /// Absolute folder of a paper (`Paper.folder` is relative to the library root).
    package static func folderURL(forRelative folder: String, library: URL) -> URL {
        library.appendingPathComponent(folder, isDirectory: true)
    }

    /// `url` relative to `root` ("Papers/2024_Wang_…"), nil if it is not inside `root`.
    /// Tolerates /var ↔ /private/var style differences and other resolvable symlinks.
    package static func relativePath(of url: URL, root: URL) -> String? {
        func components(_ u: URL) -> [String] {
            let c = u.standardizedFileURL.pathComponents
            if c.count > 2, c[1] == "private", ["var", "tmp", "etc"].contains(c[2]) { return [c[0]] + c.dropFirst(2) }
            return c
        }
        for (a, b) in [(components(url), components(root)),
                       (components(url.resolvingSymlinksInPath()), components(root.resolvingSymlinksInPath()))] {
            guard a.count > b.count, Array(a.prefix(b.count)) == b else { continue }
            return a.dropFirst(b.count).joined(separator: "/")
        }
        return nil
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try u.setResourceValues(values) }
        catch { Log.storage.info("isExcludedFromBackup failed for \(url.lastPathComponent, privacy: .public)") }
    }
}
