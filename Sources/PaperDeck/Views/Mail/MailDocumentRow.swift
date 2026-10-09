import AppKit
import Observation
import SwiftUI
import PaperDeckCore

// Document attachments and cloud share links in an email card (the lab-manuscript fix):
//
//     [Document]    Smith_lab_manuscript_v3.docx              [Convert to PDF & Add] [Open]  Skip
//                   Word manuscript attached · docx · 7.2 MB
//                   ⓘ Figures may not convert — open the original if needed
//                   🔒 Possibly unpublished — confirm before AI reading
//     [Needs export] Lab_meeting.pptx               [Open] ┆ Export as PDF and drop it here ┆  Skip
//     [Shared link] Shared Word document · SharePoint  [Open Link] ┆ Download it, then drop the PDF here ┆
//
// Display rules only (`MailDocumentInfo`, pure — `--selftest app-rules` checks them); which rows
// exist and what the engine does with them is Core's. File names and URLs are untrusted mail
// text: clipped inert lines, never Markdown; links open only through `MailInboxRules.linkURL`.

/// What a document / share-link row says about its file (Core's fields: `documentFileName`,
/// `documentKind`, `pdfBytes` = the original's size, `shareHost` = the service's key).
enum MailDocumentInfo {
    /// The kind of an attached document, from its file extension.
    enum Kind: String, CaseIterable, Sendable {
        case word, richText, openDocument, pages, powerPoint, keynote, excel, numbers, other
    }

    /// Extensions per kind (lowercased, no dot).
    static func kind(ext: String?) -> Kind {
        switch (ext ?? "").lowercased() {
        case "docx", "doc", "docm", "dotx", "dot": return .word
        case "rtf", "rtfd": return .richText
        case "odt", "ott": return .openDocument
        case "pages": return .pages
        case "pptx", "ppt", "pptm", "ppsx", "pps", "potx", "odp": return .powerPoint
        case "key": return .keynote
        case "xlsx", "xls", "xlsm": return .excel
        case "numbers": return .numbers
        default: return .other
        }
    }

    /// The row's file name (`documentFileName`), else its title — clipped, inert.
    static func fileName(_ item: MailItem) -> String? {
        for raw in [item.documentFileName, item.title] {
            let name = MailInboxRules.line(raw, limit: 200)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Lowercased extension (`docx`): Core's `documentKind`, else the file name's. Letters and
    /// digits only, at most 8 — anything else is no extension.
    static func ext(_ item: MailItem) -> String? {
        for raw in [item.documentKind, item.documentFileName.map { ($0 as NSString).pathExtension }] {
            guard let e = raw?.lowercased(), !e.isEmpty, e.count <= 8,
                  e.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { continue }
            return e
        }
        return nil
    }

    // MARK: Share links

    /// The file-sharing service of a share row (display names; Core decides what a share link is).
    enum Provider: String, CaseIterable, Sendable {
        case sharePoint, oneDrive, box, googleDrive, dropbox, iCloud

        /// From Core's `MailItem.shareHost` key ("sharepoint.com", "drive.google.com"…); nil otherwise.
        init?(key: String?) {
            switch key?.lowercased() {
            case "sharepoint.com": self = .sharePoint
            case "onedrive.live.com": self = .oneDrive
            case "box.com": self = .box
            case "drive.google.com", "docs.google.com": self = .googleDrive
            case "dropbox.com": self = .dropbox
            case "icloud.com": self = .iCloud
            default: return nil
            }
        }

        /// Brand names, the same in both languages.
        var name: String {
            switch self {
            case .sharePoint: return "SharePoint"
            case .oneDrive: return "OneDrive"
            case .box: return "Box"
            case .googleDrive: return "Google Drive"
            case .dropbox: return "Dropbox"
            case .iCloud: return "iCloud Drive"
            }
        }
    }

    /// What a share link points at: Core's `documentKind` when the URL told it, else the URL's own
    /// hints (SharePoint / OneDrive `/:f:/` folders and `/:w:/` codes, Google Docs paths, a file
    /// name in the last path segment).
    enum SharedKind: String, CaseIterable, Sendable {
        case word, powerPoint, excel, pdf, folder, googleDoc, googleSlides, googleSheet, file
    }

    static func sharedKind(ext: String) -> SharedKind? {
        if ext.lowercased() == "pdf" { return .pdf }
        switch kind(ext: ext) {
        case .word, .richText, .openDocument, .pages: return .word
        case .powerPoint, .keynote: return .powerPoint
        case .excel, .numbers: return .excel
        case .other: return nil
        }
    }

    static func sharedKind(_ item: MailItem) -> SharedKind {
        if let e = ext(item), let k = sharedKind(ext: e) { return k }
        return sharedKind(url: shareURL(item), provider: Provider(key: item.shareHost))
    }

    static func sharedKind(url: URL?, provider: Provider?) -> SharedKind {
        guard let url else { return .file }
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map { $0.lowercased() }
        switch provider {
        case .sharePoint?, .oneDrive?:
            // https://tenant-my.sharepoint.com/:w:/g/personal/… (w Word, p PowerPoint, x Excel, b PDF, f folder)
            switch parts.first {
            case ":w:": return .word
            case ":p:": return .powerPoint
            case ":x:": return .excel
            case ":b:": return .pdf
            case ":f:": return .folder
            default: break
            }
        case .googleDrive?:
            if host == "docs.google.com" {
                switch parts.first {
                case "document": return .googleDoc
                case "presentation": return .googleSlides
                case "spreadsheets": return .googleSheet
                default: break
                }
            }
        case .box?, .dropbox?, .iCloud?, nil:
            break
        }
        if parts.contains("folders") || parts.contains("folder") { return .folder }
        if let name = urlFileName(url), let k = sharedKind(ext: (name as NSString).pathExtension) { return k }
        return .file
    }

    /// A file name in a share URL's last path segment (`…/Manuscript_v3.docx?dl=0`), clipped and inert.
    static func urlFileName(_ url: URL?) -> String? {
        guard let last = url?.lastPathComponent, last != "/", !last.isEmpty,
              sharedKind(ext: (last as NSString).pathExtension) != nil else { return nil }
        let name = MailInboxRules.line(last.removingPercentEncoding ?? last, limit: 120)
        return name.isEmpty ? nil : name
    }

    /// The share row's own URL for display: the unwrapped one (Safe Links removed by Core).
    static func shareURL(_ item: MailItem) -> URL? {
        MailInboxRules.safeWebURL(item.url) ?? MailInboxRules.safeWebURL(item.urlOriginal)
    }

    /// 「共享的 Word 文档 · SharePoint」.
    static func shareDescription(_ item: MailItem) -> String {
        L.Mail.sharedDocument(sharedKind(item), provider: Provider(key: item.shareHost))
    }

    /// The row's title line: its title (a link text, a file name), a file name in the URL, else
    /// 「共享的 Word 文档 · SharePoint」.
    static func shareTitle(_ item: MailItem) -> String {
        let stored = MailInboxRules.line(item.title, limit: 240)
        if !stored.isEmpty { return stored }
        if let name = urlFileName(shareURL(item)) { return name }
        return shareDescription(item)
    }

    /// The meta line under a share row's title: 「共享的 Word 文档 · SharePoint · host」 when the
    /// title is a name, else just the host.
    static func shareMeta(_ item: MailItem) -> String? {
        let host = MailInboxRules.line(shareURL(item)?.host ?? item.host, limit: 60)
        var parts: [String] = []
        if shareTitle(item) != shareDescription(item) { parts.append(shareDescription(item)) }
        if !host.isEmpty { parts.append(host) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Documents

    /// 「附件：Word 稿件 · docx · 7.2 MB」 / "Word manuscript attached · docx · 7.2 MB".
    static func documentMeta(_ item: MailItem) -> String {
        let e = ext(item)
        var parts = [L.Mail.documentAttached(kind(ext: e))]
        if let e { parts.append(e) }
        if let n = item.pdfBytes, n > 0 { parts.append(L.bytes(n)) }
        return parts.joined(separator: " · ")
    }

    /// A merged document row whose original was stored: the merge put it next to the PDF in the
    /// paper folder (`<name>.source.<ext>`; a stored original has its `documentSHA256`).
    static func keptOriginal(_ item: MailItem) -> Bool {
        item.origin == .document && item.status == .merged && item.documentSHA256 != nil
    }

    /// Rows this file draws: an attached document, or a cloud share link.
    static func isDocument(_ item: MailItem) -> Bool { item.origin == .document }
    static func isShareLink(_ item: MailItem) -> Bool { item.origin == .shareLink }

    /// The email's documents are held as possibly unpublished (a person's, an advisor's or a
    /// dropped email, or confidential mail) — the same rule as the merge's AI hold.
    static func possiblyUnpublished(_ message: MailMessage) -> Bool {
        [.advisor, .person, .manual].contains(message.senderKind) || MailHeuristics.isConfidential(message)
    }

    /// The drop box's caption for this row: export it (a document — slides, a failed conversion, a
    /// file too large to store), download it (a share link), else the downloaded PDF.
    static func dropCaption(_ item: MailItem, chip: MailInboxRules.ItemChip) -> String {
        if chip == .shareLink { return L.Mail.dropShared }
        if chip == .openOnly || chip == .convertible || isDocument(item) { return L.Mail.dropExported }
        return L.Mail.dropHere
    }

    /// The drop box's tooltip: how to get that PDF (nil: the caption says it all).
    static func dropDetail(_ item: MailItem, chip: MailInboxRules.ItemChip) -> String? {
        if chip == .shareLink { return L.Mail.dropSharedHelp }
        if chip == .openOnly || chip == .convertible || isDocument(item) { return L.Mail.dropExportedHelp }
        return nil
    }
}

// MARK: - Conversion progress

/// Rows being converted right now (「正在本机转换为 PDF…」): the conversion is one engine call, so
/// its progress is app state, not a stored PDF state. Main actor; observed by the rows.
@MainActor @Observable
final class MailDocumentActivity {
    static let shared = MailDocumentActivity()
    private(set) var converting: Set<String> = []

    func begin(_ itemID: String) { converting.insert(itemID) }
    func end(_ itemID: String) { converting.remove(itemID) }
    func isConverting(_ itemID: String) -> Bool { converting.contains(itemID) }
}

// MARK: - Opening the stored original

/// 「打开」 on a document row opens the stored attachment in its own app — only a regular file of
/// a document type, inside the mail attachment folder (never a symlink out of it, an app, a
/// script or a web page), marked as downloaded (quarantine) so Word / Pages open it with their
/// usual caution for files from the internet.
nonisolated enum MailDocumentOpen {
    /// Document types `Open` hands to their app.
    static let openableExtensions: Set<String> = [
        "docx", "doc", "rtf", "odt", "pages", "pptx", "ppt", "key", "xlsx", "xls", "numbers",
    ]

    static func mayOpen(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL, openableExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePath),
              openableExtensions.contains(resolved.pathExtension.lowercased()) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return true
    }

    /// Adds a quarantine record when the file has none (the attachment came from email).
    @discardableResult
    static func markDownloaded(_ url: URL) -> Bool {
        var target = url
        if let values = try? target.resourceValues(forKeys: [.quarantinePropertiesKey]), values.quarantineProperties != nil {
            return true
        }
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "PaperDeck",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Row notes

/// The lines under a document / share row's title: conversion progress, what conversion may lose,
/// the possibly-unpublished hold, sign-in for share links, and the original a merged row kept.
struct MailDocumentNotes: View {
    let card: MailCard
    let item: MailItem
    let chip: MailInboxRules.ItemChip
    let converting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if converting {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(L.Mail.converting)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tint)
                }
                .accessibilityElement(children: .combine)
            }
            if item.status == .pending {
                if chip == .convertible {
                    note(L.Mail.figuresNote, symbol: "photo.badge.exclamationmark")
                } else if chip == .shareLink {
                    note(L.Mail.signInNeeded, symbol: "person.badge.key")
                }
                if MailDocumentInfo.isDocument(item), MailDocumentInfo.possiblyUnpublished(card.message) {
                    note(ImportAnnotation.unpublishedHoldText(L.lang), symbol: "lock.shield")
                }
            } else if MailDocumentInfo.keptOriginal(item) {
                note(L.Mail.keptOriginal(MailDocumentInfo.ext(item)), symbol: "doc.on.doc")
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}
