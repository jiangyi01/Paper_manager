import Foundation

/// The name of the sync app a path's folder belongs to, for wording only ("make sure Dropbox is
/// running"). Derived from the path's shape, never from a list of institutions or tenants: a
/// File Provider root `…/Library/CloudStorage/<App>-<account>/…` names its app before the first
/// "-" (or space), and iCloud Drive lives under `…/Library/Mobile Documents/`. Recognizing and
/// ranking cloud roots for the mail sources is `CloudRootLocator`'s job (PaperDeckConfig); this
/// only labels a path the engine already has. Never touches the file system.
package enum CloudPathHint {
    /// "OneDrive", "Dropbox", "Google Drive", "Box", "iCloud Drive"… or nil for a local path.
    package static func providerName(forPath path: String) -> String? {
        let components = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        for i in components.indices.dropLast() where components[i] == "Library" {
            let next = components.index(after: i)
            if components[next] == "Mobile Documents" { return "iCloud Drive" }
            guard components[next] == "CloudStorage" else { continue }
            let rootIndex = components.index(after: next)
            guard rootIndex < components.endIndex else { return nil }
            return appName(ofRoot: String(components[rootIndex]))
        }
        return nil
    }

    /// The leading word of a File Provider root's name ("Dropbox (Personal)" → "Dropbox").
    static func appName(ofRoot root: String) -> String? {
        let head = String(root.prefix { $0.isLetter })
        guard head.count >= 2 else { return nil }
        // File Provider roots join an app's words ("GoogleDrive-…"): a capital after a word of at
        // least four letters starts a new word; short prefixes stay joined ("OneDrive", "iCloud").
        var out = "", word = 0
        for c in head {
            if c.isUppercase, word >= 4, out.last?.isLowercase == true {
                out.append(" ")
                word = 0
            }
            out.append(c)
            word += 1
        }
        return out
    }
}
