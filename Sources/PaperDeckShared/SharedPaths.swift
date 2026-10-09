import Foundation

/// Filesystem locations shared by the app and the sandboxed widget.
///
/// Inside the widget sandbox `NSHomeDirectory()` points into the container, so
/// the real home comes from the passwd database. The widget's sandbox has a
/// read-only temporary exception for `widgetDirectory`.
public enum SharedPaths {
    public static var bundleID: String { BuildIdentity.current.bundleID }
    public static var widgetBundleID: String { BuildIdentity.current.widgetBundleID }

    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var supportDirectory: URL {
        realHome.appendingPathComponent("Library/Application Support/PaperDeck", isDirectory: true)
    }

    public static var widgetDirectory: URL {
        supportDirectory.appendingPathComponent("widget", isDirectory: true)
    }

    public static var widgetSnapshotURL: URL {
        widgetDirectory.appendingPathComponent("snapshot.json")
    }
}
