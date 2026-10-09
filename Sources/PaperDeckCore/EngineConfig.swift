import Foundation
import PaperDeckShared

/// All on-disk locations. Production uses the real folders; `--root R` (self-tests)
/// redirects everything under R so the real library is never touched.
package struct AppPaths: Sendable, Equatable {
    package var library: URL        // user-visible root, e.g. ~/Documents/PaperDeck
    package var support: URL        // ~/Library/Application Support/PaperDeck (DB, text cache, agent cwd)
    package var caches: URL         // ~/Library/Caches/PaperDeck (thumbnails, incoming)
    package var widget: URL         // support/widget (read by the sandboxed widget)

    package init(library: URL, support: URL, caches: URL, widget: URL) {
        self.library = library; self.support = support; self.caches = caches; self.widget = widget
    }

    package static func production(library: URL? = nil) -> AppPaths {
        let home = SharedPaths.realHome
        return AppPaths(
            library: library ?? home.appendingPathComponent("Documents/PaperDeck", isDirectory: true),
            support: SharedPaths.supportDirectory,
            caches: home.appendingPathComponent("Library/Caches/PaperDeck", isDirectory: true),
            widget: SharedPaths.widgetDirectory
        )
    }

    package static func rooted(at root: URL) -> AppPaths {
        AppPaths(
            library: root.appendingPathComponent("Library", isDirectory: true),
            support: root.appendingPathComponent("Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true),
            widget: root.appendingPathComponent("Support/widget", isDirectory: true)
        )
    }

    // Derived locations
    package var papers: URL { library.appendingPathComponent("Papers", isDirectory: true) }
    package var inbox: URL { papers.appendingPathComponent("_Inbox", isDirectory: true) }
    package var partial: URL { inbox.appendingPathComponent(".partial", isDirectory: true) }
    package var recentlyDeleted: URL { library.appendingPathComponent(".recently-deleted", isDirectory: true) }
    package var libraryManifest: URL { library.appendingPathComponent(".paperdeck-library.json") }
    package var database: URL { support.appendingPathComponent("library.sqlite") }
    package var textCache: URL { support.appendingPathComponent("text", isDirectory: true) }
    package var agentCwd: URL { support.appendingPathComponent("agent-cwd", isDirectory: true) }
    package var jobs: URL { support.appendingPathComponent("jobs", isDirectory: true) }
    package var backups: URL { support.appendingPathComponent("Backups", isDirectory: true) }
    package var thumbnails: URL { caches.appendingPathComponent("thumbs", isDirectory: true) }
    package var incoming: URL { caches.appendingPathComponent("incoming", isDirectory: true) }
    package var widgetThumbs: URL { widget.appendingPathComponent("thumbs", isDirectory: true) }
    /// Attachments / downloaded PDFs of captured emails (support/mail/files/<message-id>/…).
    package var mailFiles: URL { support.appendingPathComponent("mail/files", isDirectory: true) }
}
