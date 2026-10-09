import Foundation

/// A throwaway UserDefaults domain for one test, kept out of ~/Library/Preferences.
///
/// A named suite (`UserDefaults(suiteName: "pd-…")`) always leaves `~/Library/Preferences/<name>.plist`
/// behind: `removePersistentDomain` empties it, and even when the test deletes the file, cfprefsd
/// writes the empty domain back once the test process exits. So the suite name here is an absolute
/// path (CFPreferences' path domains, as in `defaults read /path/file`): cfprefsd keeps the plist at
/// `<directory>/defaults.plist`, a fresh folder under `$TMPDIR/pd-tests-defaults/`, and `drop()`
/// removes that folder.
/// The domain behaves like any suite for get / set / remove, never shares state with another test
/// and can never be the app's own domain (com.yijiang.paperdeck).
///
///     let scratch = ScratchDefaults("codex-settings")
///     defer { scratch.drop() }
struct ScratchDefaults {
    static let prefix = "pd-tests-"

    /// Every scratch domain lives under this one temporary folder.
    static let parent = FileManager.default.temporaryDirectory
        .appending(path: prefix + "defaults", directoryHint: .isDirectory)

    /// The temporary directory holding the domain's plist (removed by `drop()`).
    let directory: URL
    /// Suite name: the plist path without its extension.
    let name: String
    let defaults: UserDefaults

    init(_ tag: String) {
        _ = Self.pruneOnce
        let safeTag = tag.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        directory = Self.parent.appending(path: safeTag + "-" + UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        name = directory.appending(path: "defaults", directoryHint: .notDirectory).path
        defaults = UserDefaults(suiteName: name)!
    }

    /// Where cfprefsd keeps the domain.
    var plistURL: URL { URL(fileURLWithPath: name + ".plist") }

    /// Empties the domain and removes its directory (and with it the plist). The removal is
    /// flushed first: it reaches cfprefsd asynchronously, and if it lands after the directory is
    /// gone cfprefsd writes the empty plist back — re-creating the directory.
    func drop() {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes leftovers older than an hour (a crashed run; the rare late cfprefsd write) once
    /// per process — never a domain a test running right now could still use.
    private static let pruneOnce: Void = {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: item) }
        }
    }()
}
