import Foundation
import PaperDeckShared

/// File-sharing services whose links in a person's email become `shareLink` rows (a manuscript
/// on SharePoint / OneDrive, Box, Google Drive / Docs, Dropbox, iCloud Drive). Raw values are the
/// provider keys stored in `MailItem.shareHost`.
package enum MailShareProvider: String, Sendable, CaseIterable, Equatable {
    case sharepoint = "sharepoint.com"          // SharePoint and OneDrive for work or school (*-my.sharepoint.com)
    case onedrive = "onedrive.live.com"         // OneDrive (personal) and 1drv.ms short links
    case box = "box.com"
    case googleDrive = "drive.google.com"
    case googleDocs = "docs.google.com"
    case dropbox = "dropbox.com"
    case icloud = "icloud.com"

    /// The service's name as the UI shows it.
    package func name(_ lang: UILang) -> String {
        switch self {
        case .sharepoint: return "SharePoint / OneDrive"
        case .onedrive: return "OneDrive"
        case .box: return "Box"
        case .googleDrive: return "Google Drive"
        case .googleDocs: return lang == .zh ? "Google 文档" : "Google Docs"
        case .dropbox: return "Dropbox"
        case .icloud: return lang == .zh ? "iCloud 云盘" : "iCloud Drive"
        }
    }

    /// The service of a `shareLink` row (nil for other rows or an unknown key).
    package static func of(_ item: MailItem) -> MailShareProvider? {
        guard item.origin == .shareLink else { return nil }
        return item.shareHost.flatMap(MailShareProvider.init(rawValue:))
    }

    /// `name` of a row's service.
    package static func name(for item: MailItem, _ lang: UILang) -> String? { of(item)?.name(lang) }
}

/// Recognizes a link to a shared file — after Safe Links / Proofpoint unwrapping — and tells
/// which service it is and, when the URL says so, what kind of file. Pure string work: nothing
/// is fetched (these links need the user's sign-in; PaperDeck never downloads them).
///
/// Only links that point at a file or folder count: a service's home page, a SharePoint site page,
/// an app-store "Get OneDrive" link or a signature's intranet link does not. Spreadsheets, forms,
/// videos, images and OneNote notebooks are not reading material and never count.
package enum ShareLinks {
    package struct Match: Sendable, Equatable {
        package var provider: MailShareProvider
        /// "docx" / "pptx" / "pdf" / a `DocumentKind` raw value, when the URL tells.
        package var documentKind: String?
        /// The file's name when the URL carries one ("Manuscript draft.docx"), else nil.
        package var fileName: String?
    }

    private static let spreadsheetExtensions: Set<String> = ["xlsx", "xls", "xlsm", "xlsb", "csv", "numbers", "ods", "tsv"]
    /// SharePoint / OneDrive sharing-link type letters ("/:w:/…"): Word, PowerPoint, PDF / other
    /// binary file, folder, any file, text. Excel (x), video (v), image (i), OneNote (o) don't count.
    private static let accepted: [Character: String?] = ["w": "docx", "p": "pptx", "b": "pdf", "f": nil, "u": nil, "t": nil]

    package static func match(_ url: URL) -> Match? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else { return nil }
        let host = PaperLinkClassifier.displayHost(rawHost)
        let path = url.path
        let lower = path.lowercased()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        // The file a link names, in its path or an `id=` / `file=` / `sourcedoc=` parameter.
        let named = [path, query["id"] ?? "", query["file"] ?? "", query["sourcedoc"] ?? ""]
            .map { ($0.removingPercentEncoding ?? $0) }
        if named.contains(where: { spreadsheetExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            return nil
        }
        let fileName = named.lazy.compactMap(documentFileName).first
        let kindFromName = named.lazy.compactMap { DocumentKind.kind(ofPath: $0) }.first

        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if within("sharepoint.com") {
            if let letter = typeLetter(lower) {
                guard let kind = accepted[letter] else { return nil }
                return Match(provider: .sharepoint, documentKind: kind ?? kindFromName, fileName: fileName)
            }
            if lower.contains("/_layouts/15/stream.aspx") { return nil }              // a meeting recording
            let fileish = ["/_layouts/15/doc.aspx", "/_layouts/15/doc2.aspx", "/_layouts/15/wopiframe",
                           "/_layouts/15/guestaccess.aspx", "/_layouts/15/download.aspx", "/_layouts/15/onedrive.aspx",
                           "/shared documents/", "/documents/", "/personal/"]
            let isFile = fileish.contains { lower.contains($0) } || kindFromName != nil
                || (host.hasSuffix("-my.sharepoint.com") && lower.count > 1)
            guard isFile, !lower.contains("/sitepages/") else { return nil }
            return Match(provider: .sharepoint, documentKind: kindFromName, fileName: fileName)
        }
        if host == "1drv.ms" {
            guard lower.count > 1 else { return nil }
            if let letter = typeLetter(lower, shortLink: true) {
                guard let kind = accepted[letter] else { return nil }
                return Match(provider: .onedrive, documentKind: kind ?? kindFromName, fileName: fileName)
            }
            return Match(provider: .onedrive, documentKind: kindFromName, fileName: fileName)
        }
        if within("onedrive.live.com") {
            let keys = ["resid", "cid", "id", "redeem", "authkey"]
            let prefixes = ["/redir", "/view.aspx", "/edit.aspx", "/embed", "/download", "/personal/"]
            guard keys.contains(where: { query[$0] != nil }) || prefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return Match(provider: .onedrive, documentKind: kindFromName, fileName: fileName)
        }
        if within("box.com") {
            let prefixes = ["/s/", "/file/", "/folder/", "/v/", "/shared/static/"]
            guard prefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return Match(provider: .box, documentKind: kindFromName, fileName: fileName)
        }
        if host == "drive.google.com" {
            let isFile = lower.hasPrefix("/file/d/") || lower.hasPrefix("/open") || lower.hasPrefix("/uc")
                || lower.hasPrefix("/drive/folders/") || (lower.hasPrefix("/drive/") && lower.contains("/folders/"))
            guard isFile else { return nil }
            return Match(provider: .googleDrive, documentKind: kindFromName, fileName: fileName)
        }
        if host == "docs.google.com" {
            guard lower.hasPrefix("/document/") || lower.hasPrefix("/presentation/") || lower.hasPrefix("/file/d/") else {
                return nil                                       // spreadsheets, forms, drawings
            }
            return Match(provider: .googleDocs, documentKind: kindFromName, fileName: fileName)
        }
        if within("dropbox.com") || within("dropboxusercontent.com") {
            let prefixes = ["/s/", "/scl/", "/sh/", "/l/", "/t/", "/cd/"]
            guard prefixes.contains(where: { lower.hasPrefix($0) }) || within("dropboxusercontent.com") && lower.count > 1 else {
                return nil
            }
            return Match(provider: .dropbox, documentKind: kindFromName, fileName: fileName)
        }
        if within("icloud.com") {
            let prefixes = ["/iclouddrive/", "/keynote/", "/pages/", "/attachment/"]
            guard prefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
            return Match(provider: .icloud, documentKind: kindFromName, fileName: fileName)
        }
        return nil
    }

    /// Any link to one of the services (a file or not) — what the classifier must never treat as
    /// a downloadable PDF link.
    package static func isShareService(_ host: String) -> Bool {
        let h = PaperLinkClassifier.displayHost(host)
        let domains = ["sharepoint.com", "onedrive.live.com", "1drv.ms", "box.com", "drive.google.com", "docs.google.com",
                       "dropbox.com", "dropboxusercontent.com", "icloud.com"]
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// "/:w:/g/personal/…" → "w"; for 1drv.ms short links "/w/s!…" → "w".
    private static func typeLetter(_ lowerPath: String, shortLink: Bool = false) -> Character? {
        let chars = Array(lowerPath)
        if shortLink {
            guard chars.count >= 3, chars[0] == "/", chars[1].isLetter, chars[2] == "/" else { return nil }
            return chars[1]
        }
        guard chars.count >= 4, chars[0] == "/", chars[1] == ":", chars[2].isLetter, chars[3] == ":" else { return nil }
        return chars[2]
    }

    /// The last path component when it is a document or PDF file name.
    private static func documentFileName(_ s: String) -> String? {
        let last = (s as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last.count <= 200, DocumentKind.kind(ofPath: last) != nil else { return nil }
        return last
    }
}
