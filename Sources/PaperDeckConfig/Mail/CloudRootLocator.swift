import Foundation
import PaperDeckCore

/// Cloud storage providers PaperDeck can recognize by a root folder's name.
package enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case oneDriveBusiness, oneDrivePersonal, oneDriveShared, dropbox, googleDrive, box, iCloudDrive, other

    /// "OneDrive (work or school)", "Dropbox"… (both UI languages).
    package var title: LocalizedText {
        switch self {
        case .oneDriveBusiness: return LocalizedText(en: "OneDrive (work or school)", zh: "OneDrive（工作或学校）")
        case .oneDrivePersonal: return LocalizedText(en: "OneDrive (personal)", zh: "OneDrive（个人）")
        case .oneDriveShared: return LocalizedText(en: "OneDrive shared libraries", zh: "OneDrive 共享库")
        case .dropbox: return LocalizedText("Dropbox")
        case .googleDrive: return LocalizedText(en: "Google Drive", zh: "Google 云端硬盘")
        case .box: return LocalizedText("Box")
        case .iCloudDrive: return LocalizedText(en: "iCloud Drive", zh: "iCloud 云盘")
        case .other: return LocalizedText(en: "Other cloud folder", zh: "其他云文件夹")
        }
    }
}

/// One synced root folder (e.g. `~/Library/CloudStorage/OneDrive-Contoso`).
package struct CloudRoot: Sendable, Equatable {
    package var provider: CloudProvider
    package var name: String            // directory name
    package var url: URL
    package var displayName: String

    package init(provider: CloudProvider, name: String, url: URL, displayName: String) {
        self.provider = provider; self.name = name; self.url = url; self.displayName = displayName
    }
}

/// The ONE place that knows cloud-root folder names (lint G4). Privacy rule: it classifies root
/// names only and never lists or reads inside a provider's folder — callers list
/// `~/Library/CloudStorage` (names only) and check whether `<root>/PaperDeck Mail` exists.
package enum CloudRootLocator {
    /// The File Provider directory (`~/Library/CloudStorage`).
    package static func cloudStorage(home: URL) -> URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// Classifies the directory names of `cloudStorage` (sorted by name; hidden names skipped):
    /// `OneDrive-Personal`, `OneDrive-SharedLibraries-*`, any other `OneDrive-<tenant>` (work or
    /// school), `Dropbox*`, `GoogleDrive-<account>` (its `My Drive`), `Box-*`, anything else
    /// `.other`.
    package static func classify(names: [String], cloudStorage: URL) -> [CloudRoot] {
        names.filter { !$0.hasPrefix(".") && !$0.isEmpty }.sorted().map { classify(name: $0, cloudStorage: cloudStorage) }
    }

    static func classify(name: String, cloudStorage: URL) -> CloudRoot {
        let url = cloudStorage.appendingPathComponent(name, isDirectory: true)
        if name == "OneDrive-Personal" {
            return CloudRoot(provider: .oneDrivePersonal, name: name, url: url, displayName: "OneDrive (Personal)")
        }
        if name.hasPrefix("OneDrive-SharedLibraries") {
            return CloudRoot(provider: .oneDriveShared, name: name, url: url, displayName: "OneDrive (Shared Libraries)")
        }
        if name.hasPrefix("OneDrive-"), name.count > "OneDrive-".count {
            let tenant = String(name.dropFirst("OneDrive-".count))
            return CloudRoot(provider: .oneDriveBusiness, name: name, url: url, displayName: "OneDrive – \(tenant)")
        }
        if name == "Dropbox" || name.hasPrefix("Dropbox-") || name.hasPrefix("Dropbox ") {
            return CloudRoot(provider: .dropbox, name: name, url: url, displayName: name.replacingOccurrences(of: "-", with: " "))
        }
        if name.hasPrefix("GoogleDrive-"), name.count > "GoogleDrive-".count {
            let account = String(name.dropFirst("GoogleDrive-".count))
            return CloudRoot(provider: .googleDrive, name: name, url: url.appendingPathComponent(googleMyDrive, isDirectory: true),
                             displayName: "Google Drive (\(account))")
        }
        if name == "Box" || name.hasPrefix("Box-") {
            return CloudRoot(provider: .box, name: name, url: url, displayName: "Box")
        }
        return CloudRoot(provider: .other, name: name, url: url, displayName: name)
    }

    /// A Google Drive account folder (`GoogleDrive-<account>`) holds `My Drive` — a Google root's
    /// `url` — and other areas next to it (`Shared drives`, `Other computers`, shortcut targets).
    package static let googleMyDrive = "My Drive"
    static let googleOutsideMyDrive: Set<String> = ["Shared drives", "Other computers", ".shortcut-targets-by-id"]

    /// The account folder of a Google Drive root (`…/CloudStorage/GoogleDrive-<account>`, the parent
    /// of its My Drive); any other root's `url`.
    package static func accountFolder(_ root: CloudRoot) -> URL {
        guard root.provider == .googleDrive, root.url.lastPathComponent == googleMyDrive else { return root.url }
        return root.url.deletingLastPathComponent()
    }

    /// Where a Google Drive path as `split` gives it (a settings file's form, `PortablePath`) lies
    /// under `root`: a path in another area of the account folder (`Shared drives/…`,
    /// `Other computers/…`, shortcut targets) under the account folder; any other path is inside
    /// My Drive, which `split` leaves out (`Lab/PaperDeck Mail` → `<account>/My Drive/Lab/PaperDeck Mail`).
    /// The form every build writes, so files of earlier and later builds mean the same place.
    package static func googleFolder(_ root: CloudRoot, relative: String) -> URL {
        let first = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        let base = first.map(googleOutsideMyDrive.contains) == true ? accountFolder(root) : root.url
        return relative.isEmpty ? base : base.appendingPathComponent(relative)
    }

    /// A root name without the account address it may hold (`GoogleDrive-jane@example.com` →
    /// `GoogleDrive`): what an export without mailbox addresses stores. Such a name matches no root
    /// on the new Mac; the path goes to the only root of the same provider there, if any.
    package static func rootNameWithoutAddress(_ name: String, provider: CloudProvider) -> String {
        guard name.contains("@") else { return name }
        if let dash = name.firstIndex(of: "-") {
            let prefix = String(name[..<dash]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty, !prefix.contains("@") { return prefix }
        }
        return provider.rawValue
    }

    /// iCloud Drive's local root.
    package static func iCloudDrive(home: URL) -> CloudRoot {
        CloudRoot(provider: .iCloudDrive, name: "com~apple~CloudDocs",
                  url: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true),
                  displayName: "iCloud Drive")
    }

    /// The order a source offers roots in.
    /// - Power Automate (`m365PowerAutomate`): OneDrive work/school roots first — the one matching
    ///   the organization's `oneDriveRootHint` first among them — then other providers; OneDrive
    ///   Personal and Shared Libraries are left out (the flow's OneDrive for Business connector
    ///   can't write there). Then the last choice (`mail.cloudRoot`), then by name.
    /// - Every other source: the last choice first, then by provider (work OneDrive, personal
    ///   OneDrive, Dropbox, Google Drive, Box, iCloud Drive, shared libraries, other), then by name.
    /// An existing `<root>/PaperDeck Mail` wins in `suggestedFolder`, which knows the folders.
    package static func ranked(_ roots: [CloudRoot], for s: MailSourceID, org: OrganizationProfile,
                               lastChoice: String?) -> [CloudRoot] {
        let hint = org.mail.oneDriveRootHint?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        func matchesHint(_ r: CloudRoot) -> Bool { !hint.isEmpty && r.name.lowercased().contains(hint) }
        func isLast(_ r: CloudRoot) -> Bool { lastChoice.map { $0 == r.name } ?? false }
        let order: [CloudProvider] = [.oneDriveBusiness, .oneDrivePersonal, .dropbox, .googleDrive, .box, .iCloudDrive,
                                      .oneDriveShared, .other]
        func providerRank(_ r: CloudRoot) -> Int { order.firstIndex(of: r.provider) ?? order.count }
        if s == .m365PowerAutomate {
            let usable = roots.filter { $0.provider != .oneDrivePersonal && $0.provider != .oneDriveShared }
            return usable.sorted { a, b in
                let (ba, bb) = (a.provider == .oneDriveBusiness, b.provider == .oneDriveBusiness)
                if ba != bb { return ba }
                let (ha, hb) = (matchesHint(a), matchesHint(b))
                if ha != hb { return ha }
                let (la, lb) = (isLast(a), isLast(b))
                if la != lb { return la }
                if providerRank(a) != providerRank(b) { return providerRank(a) < providerRank(b) }
                return a.name < b.name
            }
        }
        return roots.sorted { a, b in
            let (la, lb) = (isLast(a), isLast(b))
            if la != lb { return la }
            if providerRank(a) != providerRank(b) { return providerRank(a) < providerRank(b) }
            return a.name < b.name
        }
    }

    /// The folder a new account's form starts with.
    /// - Power Automate: an existing `PaperDeck Mail` folder under a usable root (the best-ranked
    ///   one) wins; else `PaperDeck Mail` under the best work/school OneDrive root; with no such
    ///   root, the organization's fallback root (`oneDriveFallbackRootName`) — nil when it has
    ///   none, and the form shows Choose….
    /// - Folder of .eml files: an existing `PaperDeck Mail` under the best-ranked root, else nil.
    /// - Every other source: nil.
    /// `existingMailFolders` are the `<root>/PaperDeck Mail` folders the caller found to exist.
    package static func suggestedFolder(for s: MailSourceID, roots: [CloudRoot], existingMailFolders: [URL],
                                        org: OrganizationProfile, lastChoice: String?, home: URL,
                                        folderName: String = "PaperDeck Mail") -> URL? {
        guard s == .m365PowerAutomate || s == .folder else { return nil }
        let ordered = ranked(roots, for: s, org: org, lastChoice: lastChoice)
        let existing = Set(existingMailFolders.map { $0.standardizedFileURL.path })
        for root in ordered {
            let candidate = root.url.appendingPathComponent(folderName, isDirectory: true)
            if existing.contains(candidate.standardizedFileURL.path) { return candidate }
        }
        guard s == .m365PowerAutomate else { return nil }
        if let business = ordered.first(where: { $0.provider == .oneDriveBusiness }) {
            return business.url.appendingPathComponent(folderName, isDirectory: true)
        }
        guard let fallback = org.mail.oneDriveFallbackRootName, !fallback.isEmpty, !fallback.contains("/") else { return nil }
        return cloudStorage(home: home).appendingPathComponent(fallback, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The cloud root a path lies in and the path inside it: a File Provider root
    /// (`…/Library/CloudStorage/<root>/…`, whoever's home it is in), iCloud Drive
    /// (`…/Library/Mobile Documents/com~apple~CloudDocs/…`), or the legacy OneDrive app folder
    /// `~/OneDrive - <Org>/…` directly in `home`. `~` expands to `home`. Nil for anything else.
    /// A Google Drive path is inside the root's My Drive (`relative` without `My Drive/`); one
    /// elsewhere in the account folder (`Shared drives/…`) keeps its area and has the account folder
    /// as the root's `url` (`googleFolder` places it back).
    package static func split(_ path: String, home: URL) -> (root: CloudRoot, relative: String)? {
        let expanded: String
        if path == "~" { expanded = home.path }
        else if path.hasPrefix("~/") { expanded = home.path + String(path.dropFirst(1)) }
        else { expanded = path }
        guard expanded.hasPrefix("/") else { return nil }
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func url(_ upTo: Int) -> URL {
            URL(fileURLWithPath: "/" + parts[..<upTo].joined(separator: "/"), isDirectory: true)
        }
        for i in parts.indices where parts[i] == "Library" && i + 2 < parts.count {
            if parts[i + 1] == "CloudStorage" {
                let base = url(i + 2)
                var root = classify(name: parts[i + 2], cloudStorage: base)
                var rest = Array(parts[(i + 3)...])
                if root.provider == .googleDrive {
                    // Paths outside "My Drive" ("Shared drives") keep the account folder as the root.
                    if rest.first == googleMyDrive { rest.removeFirst() }
                    else { root.url = base.appendingPathComponent(root.name, isDirectory: true) }
                }
                return (root, rest.joined(separator: "/"))
            }
            if parts[i + 1] == "Mobile Documents", parts[i + 2] == "com~apple~CloudDocs" {
                let root = CloudRoot(provider: .iCloudDrive, name: "com~apple~CloudDocs", url: url(i + 3),
                                     displayName: "iCloud Drive")
                return (root, parts[(i + 3)...].joined(separator: "/"))
            }
        }
        let homeParts = home.standardizedFileURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts,
           let root = homeRoot(named: parts[homeParts.count], home: home) {
            return (root, parts[(homeParts.count + 1)...].joined(separator: "/"))
        }
        return nil
    }

    /// A sync root that lives directly in home (the legacy OneDrive app folder `~/OneDrive - <Org>`),
    /// or nil for any other name.
    package static func homeRoot(named name: String, home: URL) -> CloudRoot? {
        guard name.hasPrefix("OneDrive - "), name.count > "OneDrive - ".count, !name.contains("/") else { return nil }
        return CloudRoot(provider: .oneDriveBusiness, name: name, url: home.appendingPathComponent(name, isDirectory: true),
                         displayName: name.replacingOccurrences(of: " - ", with: " – "))
    }

    /// Today's legacy test of a Power Automate folder: a path inside a OneDrive root of
    /// `~/Library/CloudStorage` (`MailSettingsFormat.looksLikeOneDrive`).
    package static func isOneDrivePath(_ path: String) -> Bool {
        path.contains("/CloudStorage/OneDrive")
    }
}
