import AppKit
import PaperDeckCore

/// Why `Engine.open` failed at launch, and therefore what the launch alert may offer.
///
/// Only a library *folder* problem (Documents access denied, the volume missing) may offer another
/// folder (~/Papers) and write `library.path`. The database lives in Application Support whatever
/// the library folder is, so for a database newer than this build, an open / migration /
/// pre-migration backup failure, or app folders that can't be created, another folder can't help:
/// it would only point the app at an empty library (and the next build would open that one too).
/// Those get Quit, Retry (not for a newer database) and Show Backups / Show in Finder.
enum LibraryOpenFailure: Equatable {
    /// `LibraryPaths.ensureLayout` couldn't create or reach the library folders.
    case libraryFolder
    /// The database was upgraded by a newer PaperDeck (`DatabaseError.newerSchema`).
    case newerVersion(found: Int, supported: Int)
    /// Opening, checking, migrating or backing up the database failed (or the disk is full).
    case database(diskFull: Bool)
    /// One of the app's own folders (Application Support / Caches: the database's folder, text
    /// cache, Backups, thumbnails…) couldn't be created — another library folder can't help.
    case appData(folder: URL)
    /// The library is on an external or network disk (`/Volumes/<name>`) that isn't connected:
    /// Retry (default) once it is, or choose another folder — never a silent ~/Papers.
    case volumeMissing(volume: String)

    /// SQLite's primary result code for "database or disk is full".
    private static let sqliteFull: Int32 = 13

    /// `paths`: the paths that were opened. `LibraryPaths.ensureLayout` reports a folder it couldn't
    /// create as a bare `FileOpsError` (no path), and creates the library folders before the app's own
    /// ones; so for such an error the app folders are tried again here (`createFolder`, the same
    /// call ensureLayout makes): one that can't be created makes it `.appData`, else it was the
    /// library folder. Without `paths` a `FileOpsError` is the library folder (synthetic errors).
    static func classify(_ error: any Error, paths: AppPaths? = nil,
                         createFolder: (URL) -> Bool = LibraryOpenFailure.createFolder,
                         pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LibraryOpenFailure {
        if case .newerSchema(let found, let supported)? = error as? DatabaseError {
            return .newerVersion(found: found, supported: supported)
        }
        // `Engine.open` runs `LibraryPaths.ensureLayout` (FileOpsError only) before the database
        // opens; nothing after it throws a FileOpsError.
        if let e = error as? FileOpsError {
            if e == .diskFull { return .database(diskFull: true) }
            if let paths, let blocked = appFolders(paths).first(where: { !createFolder($0) }) {
                return .appData(folder: blocked)
            }
            if let paths, let volume = missingVolume(paths.library, exists: pathExists) {
                return .volumeMissing(volume: volume)
            }
            return .libraryFolder
        }
        if let e = error as? SQLiteError { return .database(diskFull: e.code == sqliteFull) }
        if error is DatabaseError { return .database(diskFull: false) }
        // Cocoa / POSIX errors: creating the database folder, the Backups folder, moving a corrupt file aside.
        return .database(diskFull: FileOps.classify(error) == .diskFull)
    }

    /// The folders `LibraryPaths.ensureLayout` creates for the app itself, in its order (never
    /// inside the library folder).
    static func appFolders(_ paths: AppPaths) -> [URL] {
        [paths.support, paths.textCache, paths.agentCwd, paths.jobs, paths.backups,
         paths.widget, paths.widgetThumbs, paths.caches, paths.thumbnails, paths.incoming]
    }

    /// Creates `url` (and its parents) if needed, as `ensureLayout` does; false when it can't.
    nonisolated static func createFolder(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }

    /// `/Volumes/<name>/…` whose `/Volumes/<name>` isn't there: the disk's name.
    static func missingVolume(_ library: URL, exists: (String) -> Bool) -> String? {
        let parts = library.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes", !parts[2].isEmpty else { return nil }
        return exists("/Volumes/" + parts[2]) ? nil : parts[2]
    }

    /// Only a folder problem may suggest another library folder (and write `library.path`).
    var offersAnotherLibrary: Bool { self == .libraryFolder }

    /// Short tag for the log (no paths, no counts).
    var logName: String {
        switch self {
        case .libraryFolder: "library-folder"
        case .newerVersion: "newer-schema"
        case .database(let full): full ? "database-disk-full" : "database"
        case .appData: "app-data-folder"
        case .volumeMissing: "library-volume-missing"
        }
    }

    /// The newest `pre-migration-v*-<stamp>.sqlite` copy in `backups` (what 「显示备份」 selects).
    static func newestBackup(in backups: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("pre-migration-") && $0.pathExtension == "sqlite" }
            .max { stamp($0) < stamp($1) }
    }

    /// `pre-migration-v1-20260930-101500_2.sqlite` → `20260930-101500_2` (sorts by time, not version).
    private static func stamp(_ url: URL) -> String {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 3)
        return parts.count == 4 ? String(parts[3]) : url.lastPathComponent
    }

    /// What 「显示备份」 reveals in Finder: the newest pre-migration copy, else the Backups folder,
    /// else the folder holding the database.
    static func revealTarget(backups: URL) -> URL {
        if let newest = newestBackup(in: backups) { return newest }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: backups.path, isDirectory: &isDir), isDir.boolValue { return backups }
        return backups.deletingLastPathComponent()
    }

    /// What 「在 Finder 中显示」 reveals for a folder that couldn't be created: the nearest part of
    /// its path that exists (where the user can check the permissions).
    static func existingAncestor(of folder: URL) -> URL {
        var url = folder.standardizedFileURL
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }
}

// MARK: - The launch alert

/// What the launch does when `Engine.open` fails (`AppDelegate.bootstrap`): which buttons the alert
/// has for each failure, and what each one does. Every button but 「改用 ~/Papers」 leaves
/// `library.path` alone, and that one is only offered (and only honoured) for a library folder problem.
enum LaunchAlert {
    enum Button: Equatable {
        case useAlternative     // 改用 ~/Papers (library folder); a missing disk: choose another folder
        case retry              // open again with the same paths
        case quit
        case showBackups        // reveal the newest pre-migration copy, then quit
        case showFolder         // reveal the nearest existing part of the app folder's path, then quit
    }

    /// The alert's buttons, the default first. A transient open failure gets 「重试」; a database
    /// newer than this build can't be opened by trying again.
    static func buttons(for failure: LibraryOpenFailure) -> [Button] {
        switch failure {
        case .libraryFolder: [.useAlternative, .retry, .quit]
        case .newerVersion: [.quit, .showBackups]
        case .database: [.quit, .retry, .showBackups]
        case .appData: [.quit, .retry, .showFolder]
        case .volumeMissing: [.retry, .useAlternative, .quit]
        }
    }

    /// The launch alert for `failure`, assembled once for both the real launch
    /// (`AppDelegate.askAfterOpenFailure` runs it) and `--render` (draws it), so a render can't
    /// drift from what the user sees: a library folder problem says which folder (`libraryPath`)
    /// and offers `alternative`; a newer or failed database, or app folders that can't be created,
    /// are critical and say what happened and that nothing was deleted. The buttons are
    /// `buttons(for:)`, in that order (the default first) — `button(for:failure:)` maps a click back.
    static func makeAlert(for failure: LibraryOpenFailure, libraryPath: String, alternative: String) -> NSAlert {
        let alert = NSAlert()
        if case .volumeMissing(let volume) = failure {
            alert.alertStyle = .warning
            alert.messageText = L.Onb.volumeMissingTitle(volume)
            alert.informativeText = L.Onb.volumeMissingBody(path: libraryPath, volume: volume)
            for b in buttons(for: failure) {
                alert.addButton(withTitle: b == .useAlternative ? L.Onb.chooseAnotherFolder : L.launchButton(b))
            }
            return alert
        }
        if failure.offersAnotherLibrary {
            alert.alertStyle = .warning
            alert.messageText = L.libraryUnavailableTitle
            alert.informativeText = L.libraryUnavailableBody(path: libraryPath, alt: alternative)
        } else {
            alert.alertStyle = .critical
            alert.messageText = L.databaseFailureTitle(failure)
            alert.informativeText = L.databaseFailureBody(failure)
        }
        for b in buttons(for: failure) { alert.addButton(withTitle: L.launchButton(b)) }
        return alert
    }

    /// The button `makeAlert(for: failure, …)` returned `response` for; anything else is Quit.
    static func button(for response: NSApplication.ModalResponse, failure: LibraryOpenFailure) -> Button {
        let offered = buttons(for: failure)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return offered.indices.contains(index) ? offered[index] : .quit
    }

    /// Opens the engine, asking after each failure until it opens (the engine) or the user quits
    /// (nil). Seams for the self-test: `open`, `ask` (shows the alert, returns the button clicked),
    /// `useLibrary` (writes library.path → the paths to try next), `reveal` (Finder), `log`,
    /// `chooseLibrary` (a missing disk's 「Choose Another Folder…」: an open panel; nil = cancelled,
    /// ask again).
    static func open<T>(_ start: AppPaths, alternative: URL,
                        open: (AppPaths) async throws -> T,
                        ask: (LibraryOpenFailure, AppPaths) -> Button,
                        useLibrary: (URL) -> AppPaths,
                        reveal: (URL) -> Void,
                        log: (LibraryOpenFailure, any Error) -> Void = { _, _ in },
                        classify: (any Error, AppPaths) -> LibraryOpenFailure = { LibraryOpenFailure.classify($0, paths: $1) },
                        chooseLibrary: () -> URL? = { nil })
        async -> T? {
        var paths = start
        while true {
            do {
                return try await open(paths)
            } catch {
                let failure = classify(error, paths)
                log(failure, error)
                let offered = buttons(for: failure)
                var choice = ask(failure, paths)
                if !offered.contains(choice) { choice = .quit }      // never a button this failure doesn't have
                switch choice {
                case .retry:
                    continue
                case .useAlternative:
                    if case .volumeMissing = failure {
                        guard let picked = chooseLibrary() else { continue }
                        paths = useLibrary(picked)
                    } else {
                        paths = useLibrary(alternative)
                    }
                case .showBackups:
                    reveal(LibraryOpenFailure.revealTarget(backups: paths.backups))
                    return nil
                case .showFolder:
                    if case .appData(let folder) = failure { reveal(LibraryOpenFailure.existingAncestor(of: folder)) }
                    return nil
                case .quit:
                    return nil
                }
            }
        }
    }
}
