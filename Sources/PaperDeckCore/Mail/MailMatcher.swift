import Foundation

/// Anywhere-drop matching (MAIL_DESIGN §3 "Anywhere-drop matching"): when a paper reaches
/// [ready] — whatever brought it in (the floating panel, Finder, a merge from another email) —
/// email items that are still waiting for that PDF (`needs_pdf` / `downloadable`, pending, on
/// an open card) are satisfied by it:
///
/// - Exact DOI (both bioRxiv prefixes, also via `published_doi`) or arXiv id → linked right
///   away (status `linked`, `paperID`, a `paper_source` row), the card's state is settled, and
///   one toast per card: 「已匹配邮件请求：<subject> [查看] [撤销]」 (`Engine.undoMailLink`).
///   A card that a merge is working on right now — checked before the link is written, so the
///   merge finishing meanwhile cannot slip a toast in — links silently; rows a merge already
///   linked are left alone (the write re-checks every row).
/// - Title only (`TitleSimilarity` ≥ 0.92 plus a matching first-author surname or year, and
///   no conflicting ids) → nothing changes; a toast offers 「关联」 (`Toast.Action.linkMailItem`).
///
/// Nothing here reads or logs message bodies; subjects only appear in toasts (clipped, inert).
package enum MailMatcher {
    package static let titleThreshold = 0.92
    /// Title-only suggestions per paper (one toast each).
    package static let maxTitleSuggestions = 3

    /// Test seams for interleavings with a merge (nil in production): `beforeCapture` runs after
    /// the waiting rows were read and before the in-flight check, `afterLink` after the write.
    package struct Probe: Sendable {
        package var beforeCapture: (@Sendable (_ messageID: String) async -> Void)?
        package var afterLink: (@Sendable (_ messageID: String) async -> Void)?
        package init(beforeCapture: (@Sendable (_ messageID: String) async -> Void)? = nil,
                     afterLink: (@Sendable (_ messageID: String) async -> Void)? = nil) {
            self.beforeCapture = beforeCapture; self.afterLink = afterLink
        }
    }

    /// Entry point (EnrichActor after [ready] and after a metadata refresh that changed ids).
    /// Never throws; failures are logged.
    package static func paperReady(pk: Int64, ctx: EngineContext, probe: Probe? = nil) async {
        let db = ctx.db
        guard let paper = try? await db.paper(pk: pk), paper.isLive else { return }
        let lang = (await ctx.settings()).lang

        // 1. Exact identifier matches.
        var exact: [String: MailItem] = [:]
        for doi in [paper.ids.doi, paper.ids.publishedDOI].compactMap({ $0 }) {
            for item in (try? await db.mailItems(doi: doi)) ?? [] { exact[item.id] = item }
        }
        if let arxiv = paper.ids.arxivID {
            for item in (try? await db.mailItems(arxivID: arxiv)) ?? [] { exact[item.id] = item }
        }
        let owner = ObjectIdentifier(db)
        let waiting = exact.values.filter { isWaiting($0) && !MailLinkUndoLedger.shared.declined($0.id, paper.id, owner: owner) }
            .sorted { ($0.messagePK, $0.ord) < ($1.messagePK, $1.ord) }
        var byMessage: [Int64: [MailItem]] = [:]
        for item in waiting { byMessage[item.messagePK, default: []].append(item) }
        for (messagePK, items) in byMessage.sorted(by: { $0.key < $1.key }) {
            guard let message = try? await db.mailMessage(pk: messagePK), message.isOpen else { continue }
            await probe?.beforeCapture?(message.id)
            // A card being merged right now links its other rows silently (the user is on it).
            // Taken before the write: if that merge ends meanwhile, its own sibling-linking already
            // ran — the write below then finds those rows linked and changes nothing.
            let merging = MailMergeInFlight.shared.containsMessage(message.id)
            let result: MailItemLinker.LinkResult
            do {
                result = try await MailItemLinker.link(itemIDs: items.map(\.id), messagePK: messagePK, to: paper,
                                                       status: .linked, annotation: nil, userAction: false,
                                                       onlyWaiting: true, ctx: ctx)
            } catch {
                Log.importer.error("mail match: linking to \(pk) failed (\(String(describing: type(of: error)), privacy: .public))")
                continue
            }
            await probe?.afterLink?(message.id)
            guard !result.linked.isEmpty else { continue }
            Log.importer.info("mail match: linked \(result.linked.count) email item(s) to paper \(pk)")
            if !merging, result.linked.contains(where: { isRequestLike($0, message) }) {
                let token = MailLinkUndoLedger.shared.put(result, paper: paper, owner: owner, now: ctx.now())
                ctx.events.send(.toast(Toast(kind: .success, message: MatcherText.matched(message.subject, lang),
                                             buttons: [.init(title: MatcherText.view(lang), action: .openMail(id: message.id)),
                                                       .init(title: MatcherText.undo(lang), action: .undoMailLink(token: token))])))
            }
        }

        // 2. Title-only suggestions (never applied without the user's 「关联」).
        guard let open = try? await db.openMailItemsNeedingPDF() else { return }
        var suggested = 0
        var messages: [Int64: MailMessage?] = [:]
        for item in open where suggested < maxTitleSuggestions && exact[item.id] == nil && isWaiting(item)
            && !MailLinkUndoLedger.shared.declined(item.id, paper.id, owner: owner) && titleMatches(item: item, paper: paper) {
            if messages[item.messagePK] == nil { messages[item.messagePK] = try? await db.mailMessage(pk: item.messagePK) }
            guard let message = messages[item.messagePK] ?? nil, message.isOpen, isRequestLike(item, message) else { continue }
            suggested += 1
            ctx.events.send(.toast(Toast(kind: .info, message: MatcherText.mayMatch(message.subject, title: paper.title, lang),
                                         buttons: [
                                            .init(title: MatcherText.link(lang), action: .linkMailItem(itemID: item.id, paperID: paper.id)),
                                            .init(title: MatcherText.view(lang), action: .openMail(id: message.id)),
                                         ])))
        }
    }

    /// Pending, waiting for a PDF, and not being merged by an operation right now.
    static func isWaiting(_ item: MailItem) -> Bool {
        item.status == .pending && (item.pdfState == .needsPDF || item.pdfState == .downloadable)
            && !MailMergeInFlight.shared.contains(item.id)
    }

    /// Worth a toast: something the email asked for / highlighted, or anything a person sent.
    static func isRequestLike(_ item: MailItem, _ message: MailMessage) -> Bool {
        item.relevance != .listed || message.senderKind != .alert
    }

    /// Title-only match: ≥ `titleThreshold`, corroborated by the first author's surname or the
    /// year, and no identifier that says it is a different work.
    package static func titleMatches(item: MailItem, paper: Paper) -> Bool {
        guard let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Exact matching already compared these; both present means they differ.
        if item.ids.doi != nil, paper.ids.doi != nil || paper.ids.publishedDOI != nil { return false }
        if item.ids.arxivID != nil, paper.ids.arxivID != nil { return false }
        guard TitleSimilarity.score(title, paper.title) >= titleThreshold else { return false }
        if let y = item.year, let py = paper.year, y == py { return true }
        return authorsOverlap(item.authors, paper.authors)
    }

    /// The first listed author's surname appears among the paper's authors' surnames.
    static func authorsOverlap(_ a: [String], _ b: [String]) -> Bool {
        guard let first = a.first.flatMap(surname) else { return false }
        return b.compactMap(surname).contains(first)
    }

    /// "Wang, Li" → "wang"; "Li Wang" → "wang"; "Kriegstein AR" → "kriegstein" (diacritics folded).
    static func surname(_ name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if let comma = folded.firstIndex(of: ",") {
            let s = folded[..<comma].trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }
        let words = folded.split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return nil }
        // "Kriegstein AR": trailing initials (all-caps ≤ 3 letters in the original) are not the surname.
        let original = name.split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
        if words.count > 1, let last = original.last, last.count <= 3, last == last.uppercased(),
           last.allSatisfy(\.isLetter) {
            return words.first
        }
        return words.last
    }
}

// MARK: - Linking items to a paper (shared by the matcher and the merge operations)

enum MailItemLinker {
    /// What one `link` call changed (the matcher's undo record is built from it).
    struct LinkResult: Sendable {
        var before: MailMessage             // the card right before the write
        var message: MailMessage            // … and after it (settled)
        var prior: [MailItem]               // the rows this call linked, as they were
        var linked: [MailItem]              // … and as stored now
        var sourceAdded: Bool               // the paper had no provenance row for this email yet
    }

    /// Links items of one message to `paper` in one transaction: each item gets `status`
    /// (merged / linked), the paper's id, `in_library`, no attachment path and no download
    /// error; the paper gets the message's provenance row (when `annotation` is nil — merges
    /// pass the provenance through the import instead and give it here only for links); the
    /// message's state is settled (`MailMergeState.settle`). Then the paper's card.json is
    /// refreshed and the items' attachment copies are deleted. `onlyWaiting` (the matcher):
    /// rows are re-checked inside the transaction — only those of an open card still pending,
    /// waiting for a PDF and not being merged are linked; when none is left nothing is written.
    @discardableResult
    static func link(itemIDs: [String], messagePK: Int64, to paper: Paper, status: MailItemStatus,
                     annotation: ImportAnnotation?, userAction: Bool, onlyWaiting: Bool = false,
                     ctx: EngineContext) async throws -> LinkResult {
        let now = ctx.now()
        let files = ctx.paths.mailFiles
        if let annotation {
            try await IntakeActor.link(paper.pk, annotation: annotation, ctx: ctx)
        }
        let ids = Set(itemIDs.map { $0.lowercased() })
        let (result, removed) = try await ctx.db.transaction { db -> (LinkResult, [String]) in
            guard let message = try db.mailMessage(pk: messagePK) else {
                throw MailOperationError.messageNotFound(String(messagePK))
            }
            var removed: [String] = []
            var prior: [MailItem] = []
            var linked: [MailItem] = []
            for var item in try db.mailItems(messagePK: messagePK) where ids.contains(item.id.lowercased()) {
                if onlyWaiting, !message.isOpen || !MailMatcher.isWaiting(item) { continue }
                prior.append(item)
                if let path = item.pdfPath { removed.append(path) }
                item.status = status
                item.paperID = paper.id
                item.pdfState = .inLibrary
                item.pdfPath = nil
                item.downloadError = nil
                linked.append(try db.upsertMailItem(item, now: now))
            }
            if onlyWaiting, linked.isEmpty {
                return (LinkResult(before: message, message: message, prior: [], linked: [], sourceAdded: false), [])
            }
            var sourceAdded = false
            if annotation == nil {
                let key = Database.clean(message.internetMessageID)?.lowercased()
                sourceAdded = !(try db.paperSources(paperPK: paper.pk)).contains {
                    Database.clean($0.internetMessageID)?.lowercased() == key
                }
                try db.insertPaperSource(paperPK: paper.pk, PaperProvenance.email(message, addedAt: now))
            }
            let items = try db.mailItems(messagePK: messagePK)
            let settled = try db.modifyMailMessage(pk: messagePK, now: now) { m in
                guard userAction || m.isOpen else { return }                      // automation never reopens a card
                MailMergeState.settle(&m, items: items, now: now, userAction: userAction)
            }
            return (LinkResult(before: message, message: settled, prior: prior, linked: linked,
                               sourceAdded: sourceAdded), removed)
        }
        if onlyWaiting, result.linked.isEmpty { return result }
        await ctx.syncSidecar(pk: paper.pk)
        if !removed.isEmpty { await BlockingIO.run { MailAttachmentFiles.remove(removed, root: files) } }
        return result
    }
}

/// Email items an operation is merging right now (between marking and the final item
/// update) — the matcher leaves them alone so a merge never races its own auto-link — and the
/// cards they belong to (the matcher links their other rows without a toast).
final class MailMergeInFlight: @unchecked Sendable {
    static let shared = MailMergeInFlight()
    private let lock = NSLock()
    private var ids: [String: Int] = [:]

    func insert(_ id: String) { lock.withLock { ids[id.lowercased(), default: 0] += 1 } }
    func remove(_ id: String) {
        lock.withLock {
            let key = id.lowercased()
            if let n = ids[key], n > 1 { ids[key] = n - 1 } else { ids[key] = nil }
        }
    }
    func contains(_ id: String) -> Bool { lock.withLock { ids[id.lowercased()] != nil } }

    /// By message uuid (pks repeat across libraries, e.g. parallel test engines).
    func insertMessage(_ id: String) { insert("message:" + id) }
    func removeMessage(_ id: String) { remove("message:" + id) }
    func containsMessage(_ id: String) -> Bool { contains("message:" + id) }
}

/// Attachment / download copies under `AppPaths.mailFiles` (paths relative to it).
enum MailAttachmentFiles {
    /// The absolute URL of a stored relative path, nil when it would leave `root`.
    static func url(_ relative: String, root: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let url = root.appendingPathComponent(relative)
        guard LibraryPaths.relativePath(of: url, root: root) != nil else { return nil }
        return url
    }

    /// A message's folder name: its lowercase uuid (nothing else is ever created under `root`).
    static func isMessageFolderName(_ name: String) -> Bool { MailPDFFetcher.isSafeID(name) }

    /// Deletes `root/<messageID>/` (only a uuid-named folder directly under `root`). Blocking.
    @discardableResult
    static func removeFolder(messageID: String, root: URL) -> Bool {
        guard isMessageFolderName(messageID) else { return false }
        let dir = root.appendingPathComponent(messageID, isDirectory: true)
        guard LibraryPaths.relativePath(of: dir, root: root) != nil,
              FileManager.default.fileExists(atPath: dir.path) else { return false }
        return (try? FileManager.default.removeItem(at: dir)) != nil
    }

    /// Deletes the files and then their folders when left empty (never `root` itself). Blocking.
    static func remove(_ relatives: [String], root: URL) {
        let fm = FileManager.default
        for relative in relatives {
            guard let url = url(relative, root: root) else { continue }
            try? fm.removeItem(at: url)
            var dir = url.deletingLastPathComponent()
            while dir.standardizedFileURL.path != root.standardizedFileURL.path,
                  LibraryPaths.relativePath(of: dir, root: root) != nil,
                  (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
    }
}

extension PaperProvenance {
    /// Provenance of a paper that came from (or was linked to) `m`.
    package static func email(_ m: MailMessage, addedAt: Date) -> PaperProvenance {
        PaperProvenance(kind: "email", mailMessageID: m.id, internetMessageID: m.internetMessageID,
                        fromAddress: m.fromAddress, fromName: m.fromName, subject: m.subject,
                        receivedAt: m.receivedAt, webLink: m.webLink, requestKind: m.triage?.requestKind,
                        summary: m.triage?.summary, dueHint: m.triage?.dueDate, addedAt: addedAt)
    }
}

/// zh/en strings of the matcher's toasts (subjects are untrusted: one line, clipped).
enum MatcherText {
    static func t(_ l: UILang, _ zh: String, _ en: String) -> String { l == .zh ? zh : en }

    static func matched(_ subject: String, _ l: UILang) -> String {
        t(l, "已匹配邮件请求：\(MailInertText.clip(subject))", "Matched an email request: \(MailInertText.clip(subject))")
    }
    static func mayMatch(_ subject: String, title: String, _ l: UILang) -> String {
        t(l, "可能匹配邮件请求：\(MailInertText.clip(subject)) · \(MailInertText.clip(title, 40))",
          "May match an email request: \(MailInertText.clip(subject)) · \(MailInertText.clip(title, 40))")
    }
    static func view(_ l: UILang) -> String { t(l, "查看", "View") }
    static func undo(_ l: UILang) -> String { t(l, "撤销", "Undo") }
    static func link(_ l: UILang) -> String { t(l, "关联", "Link") }
}

/// Shared cleaning of untrusted mail text for UI strings.
enum MailInertText {
    /// One line without control / bidi / zero-width characters, at most `limit` characters.
    static func clip(_ s: String, _ limit: Int = 60) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isInvisible($0) }))
        let flat = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F: return true      // controls (tab/newline kept)
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return true   // zero-width, bidi
        default: return false
        }
    }
}
