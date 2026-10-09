import Foundation

/// Writes `card.json` + `notes.md` per paper and `.paperdeck-library.json`, coalesced:
/// the first `schedule` starts a 1 s window, later schedules in the window replace the
/// pending value for that paper, and everything pending is written when it closes.
/// Rules (§5): writes are atomic, unchanged bytes are not rewritten, and directories are
/// NEVER created — if a paper folder (or the library root) is gone the write is skipped
/// and logged. Callers must resolve `folderURL` in the same Database call that renames
/// folders, and call `flush()` before quitting.
///
/// A batch runs outside the Database, so a folder can move (最近删除, restore, refiling, the
/// Trash) while its card is being written. New bytes are therefore staged in
/// `Papers/_Inbox/.partial` and renamed into the folder in one step: the folder gets the
/// whole file or nothing, and no temp file is stranded inside a folder that moved away.
package actor SidecarWriter {
    package struct Stats: Sendable, Equatable {
        package var cardWrites = 0
        package var notesWrites = 0
        package var manifestWrites = 0
        package var unchanged = 0              // files skipped because their bytes were identical
        package var skippedMissingFolder = 0
        package var failures = 0

        package init() {}

        fileprivate mutating func add(_ o: Stats) {
            cardWrites += o.cardWrites; notesWrites += o.notesWrites; manifestWrites += o.manifestWrites
            unchanged += o.unchanged; skippedMissingFolder += o.skippedMissingFolder; failures += o.failures
        }
    }

    /// Result of scanning a papers root for sidecars (index rebuild, Maintenance).
    package struct Scan: Sendable {
        package var entries: [(folder: URL, sidecar: CardSidecar)] = []
        package var unreadable: [(folder: URL, reason: String)] = []
        package var missingSidecar: [URL] = []   // folders without card.json (orphan candidates)
    }

    private struct PendingCard: Sendable {
        var sidecar: CardSidecar
        var folder: URL
    }

    private let manifestURL: URL
    /// Same-volume folder outside every paper folder where new bytes are written before the
    /// rename (swept at launch); nil → Foundation's atomic write next to the target.
    private let stagingURL: URL?
    private let delay: Duration
    private var pendingCards: [String: PendingCard] = [:]
    private var pendingManifest: LibraryManifest?
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var lastBatch: Task<Void, Never>?
    private var stats = Stats()

    package init(manifestURL: URL, stagingURL: URL? = nil, delay: Duration = .seconds(1)) {
        self.manifestURL = manifestURL
        self.stagingURL = stagingURL
        self.delay = delay
    }

    package init(paths: AppPaths, delay: Duration = .seconds(1)) {
        self.init(manifestURL: paths.libraryManifest, stagingURL: paths.partial, delay: delay)
    }

    package var statistics: Stats { stats }
    package var hasPendingWrites: Bool { !pendingCards.isEmpty || pendingManifest != nil }

    /// Queues `sidecar` for `<folderURL>/card.json` (and notes.md); the latest call per
    /// paper id within the window wins.
    package func schedule(_ sidecar: CardSidecar, folderURL: URL) {
        pendingCards[sidecar.id] = PendingCard(sidecar: sidecar, folder: folderURL)
        armTimer()
    }

    /// Drops the pending card write of a paper whose row is gone (永久删除, purge), so a
    /// folder that takes over its old path never receives the deleted paper's card.json.
    package func discard(paperID: String) {
        pendingCards[paperID] = nil
    }

    /// Queues the library manifest (coalesced like card writes).
    package func writeManifest(_ manifest: LibraryManifest) {
        pendingManifest = manifest
        armTimer()
    }

    /// Writes everything pending now and waits for all earlier batches to finish.
    package func flush() async {
        timer?.cancel()
        timer = nil
        await drain()
    }

    // MARK: - Coalescing

    private func armTimer() {
        guard timer == nil else { return }
        timerGeneration += 1
        let generation = timerGeneration
        let delay = self.delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.timerFired(generation)
        }
    }

    private func timerFired(_ generation: Int) async {
        guard generation == timerGeneration, timer != nil else { return }
        timer = nil
        await drain()
    }

    /// Batches run strictly one after another so a later snapshot never lands before an
    /// earlier one, even though the actor is reentrant while a batch is on disk.
    private func drain() async {
        let cards = pendingCards.values.sorted { $0.sidecar.id < $1.sidecar.id }
        let manifest = pendingManifest
        pendingCards = [:]
        pendingManifest = nil
        let previous = lastBatch
        let manifestURL = self.manifestURL, stagingURL = self.stagingURL
        let batch = Task {
            await previous?.value
            guard !cards.isEmpty || manifest != nil else { return }
            let outcome = await BlockingIO.run {
                Self.write(cards: cards, manifest: manifest, manifestURL: manifestURL, staging: stagingURL)
            }
            self.stats.add(outcome)
        }
        lastBatch = batch
        await batch.value
    }

    private static func write(cards: [PendingCard], manifest: LibraryManifest?, manifestURL: URL, staging: URL?) -> Stats {
        var s = Stats()
        for job in cards {
            guard isDirectory(job.folder) else {
                s.skippedMissingFolder += 1
                Log.storage.notice("card.json skipped, folder missing: \(job.folder.lastPathComponent, privacy: .public)")
                continue
            }
            do {
                let card = try job.sidecar.encoded()
                if try writeIfChanged(card, to: job.folder.appendingPathComponent(CardSidecar.fileName), staging: staging) {
                    s.cardWrites += 1
                } else {
                    s.unchanged += 1
                }
                let notes = Data(notesMarkdown(for: job.sidecar).utf8)
                if try writeIfChanged(notes, to: job.folder.appendingPathComponent(CardSidecar.notesFileName),
                                      staging: staging) {
                    s.notesWrites += 1
                } else {
                    s.unchanged += 1
                }
            } catch let error where FileOps.classify(error) == .sourceMissing || !isDirectory(job.folder) {
                // Moved or trashed mid-write; its new location gets its own (later) write.
                s.skippedMissingFolder += 1
                Log.storage.notice("card.json skipped, folder moved while writing: \(job.folder.lastPathComponent, privacy: .public)")
            } catch {
                s.failures += 1
                Log.storage.error("card.json write failed in \(job.folder.lastPathComponent, privacy: .public): \(FileOps.classify(error).description, privacy: .public)")
            }
        }
        if let manifest {
            if !isDirectory(manifestURL.deletingLastPathComponent()) {
                s.skippedMissingFolder += 1
                Log.storage.notice("library manifest skipped, library root missing")
            } else {
                do {
                    if try writeIfChanged(try manifest.encoded(), to: manifestURL, staging: staging) {
                        s.manifestWrites += 1
                    } else {
                        s.unchanged += 1
                    }
                } catch {
                    s.failures += 1
                    Log.storage.error("library manifest write failed: \(FileOps.classify(error).description, privacy: .public)")
                }
            }
        }
        return s
    }

    /// Atomic write unless the file already holds exactly these bytes. The bytes go to a temp
    /// file in `staging` and rename(2) moves it into place, so the target folder gets the whole
    /// file or nothing; a folder gone by then fails the rename (it is never created) and the
    /// temp file is removed. Without a usable staging folder, or across volumes, `.atomic` is
    /// used: its temp file sits next to the target and would stay behind in a folder that
    /// moves mid-write.
    private static func writeIfChanged(_ data: Data, to url: URL, staging: URL?) throws -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        if let staging, isDirectory(staging) {
            let temp = staging.appendingPathComponent(".sidecar-\(UUID().uuidString).tmp")
            let staged = (try? data.write(to: temp)) != nil
            if staged, rename(temp.path, url.path) == 0 { return true }
            let code = staged ? errno : 0
            try? FileManager.default.removeItem(at: temp)
            // Staging failed or crossed volumes: `.atomic` below. Anything else (ENOENT: the
            // folder moved away) is the caller's to classify.
            if staged, code != EXDEV { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - notes.md

    /// One-way Markdown rendering of the card for people browsing the folder in Finder
    /// or other tools; the app never reads it back (v1).
    ///
    /// Every card / metadata string is untrusted model or API output, so it is rendered inert
    /// (`markdownText`): Markdown metacharacters are escaped, HTML is entity-escaped and bare
    /// URLs are defanged, so no viewer turns it into images, links or HTML. The only links are
    /// allow-listed resource URLs (`CardSanitizer.allowedURL`), emitted as `<https://…>`
    /// autolinks. The user's own notes are theirs and stay verbatim.
    package static func notesMarkdown(for sidecar: CardSidecar) -> String {
        func oneLine(_ s: String) -> String {
            s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        func inert(_ s: String) -> String { markdownText(oneLine(s)) }
        /// Mid-line fragment (byline parts): inline escapes only — a DOI's "10." isn't a list.
        func inline(_ s: String) -> String { markdownText(oneLine(s), atLineStart: false) }
        let card = sidecar.ai.card
        var out = ["<!-- Generated by PaperDeck. Edit notes inside the app. -->", ""]
        func section(_ title: String, _ body: String?) {
            guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return }
            let lines = body.split(whereSeparator: \.isNewline).map { markdownText($0.trimmingCharacters(in: .whitespaces)) }
            out += ["## \(title)", "", lines.joined(separator: "\n"), ""]
        }
        func bullets(_ title: String, _ items: [String]) {
            let lines = items.filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            out += ["## \(title)", ""] + lines.map { "- \($0)" } + [""]
        }

        let title = inert(sidecar.meta.title)
        out += ["# \(title.isEmpty ? FileNamer.fallbackName : title)", ""]
        var byline: [String] = []
        let authors = sidecar.meta.authors.map(inline).filter { !$0.isEmpty }
        if !authors.isEmpty {
            byline.append(authors.count > 3 ? authors.prefix(3).joined(separator: ", ") + " et al." : authors.joined(separator: ", "))
        }
        if let venue = sidecar.meta.venue.map(inline), !venue.isEmpty { byline.append(venue) }
        if let year = sidecar.meta.year { byline.append(String(year)) }
        if let doi = sidecar.ids.doi { byline.append("doi:" + inline(doi)) } else if let arxiv = sidecar.ids.arxiv { byline.append("arXiv:" + inline(arxiv)) }
        if !byline.isEmpty { out += [blockSafe(byline.joined(separator: " · ")), ""] }

        section("TL;DR", sidecar.ai.tldr ?? card?.tldr)
        if let card {
            section("Summary", card.summary)
            bullets("Key contributions", card.contributions.map(inert))
            section("Method", card.method)
            bullets("Results", card.results.map(inert))
            bullets("Limitations", card.limitations.map { inert($0.text) + ($0.source == .inferred ? " (inferred)" : "") })
            bullets("Key terms", card.keyTerms.map { "**\(inert($0.term))**: \(inert($0.definition))" })
            bullets("Data & code", card.resources.map { r in
                let link = autolink(r.url)
                return [inert(r.name), r.identifier.map { "(\(inert($0)))" }, link].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            })
        }

        out += ["## My notes", ""]
        let notes = sidecar.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += [notes, ""] }
        return out.joined(separator: "\n")
    }

    /// Untrusted text as inert Markdown: backslash-escapes the characters that start emphasis,
    /// code, links and images (`\ ` * _ [ ] ! |`, a leading `#`, `>`, `+`, `-`, `=` or `1.`),
    /// entity-escapes `<` / `>` (no raw HTML, no `<…>` autolinks) and defangs bare URLs
    /// (`https\://`, `www\.`) so GFM-style renderers do not auto-link them. Renders as the
    /// original text.
    package static func markdownText(_ s: String, atLineStart: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\", "`", "*", "_", "[", "]", "!", "|", "~": out.append("\\"); out.append(ch)
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        // Bare URL / domain autolinks (GFM extended autolinks: scheme://, www.).
        out = out.replacingOccurrences(of: "://", with: "\\://")
        out = out.replacingOccurrences(of: #"(?i)\b(www)\."#, with: "$1\\\\.", options: .regularExpression)
        return atLineStart ? blockSafe(out) : out
    }

    /// Neutralizes block syntax at the start of a line: heading, list, numbered list, setext rule.
    static func blockSafe(_ line: String) -> String {
        var out = line
        if let first = out.first, "#+-=".contains(first) {
            out = "\\" + out
        } else if let r = out.range(of: #"^\d+(?=[.)])"#, options: .regularExpression) {
            out.insert("\\", at: r.upperBound)
        }
        return out
    }

    /// `<url>` for an allow-listed https URL that is safe inside an autolink, else nil.
    static func autolink(_ url: String?) -> String? {
        guard let ok = CardSanitizer.allowedURL(url.map(JSONValue.string)),
              !ok.contains(where: { c in
                  c == "<" || c == ">" || c.isWhitespace || c.unicodeScalars.contains { u in u.properties.generalCategory == .control }
              })
        else { return nil }
        return "<\(ok)>"
    }

    // MARK: - Rebuild support

    /// Decodes every `card.json` directly under `papersRoot` and under `papersRoot/_Inbox`
    /// (hidden folders such as `.partial` are skipped). Works for `.recently-deleted` too.
    /// Unreadable sidecars are reported, not thrown; folders without one are listed.
    package static func scanSidecars(papersRoot: URL) async -> Scan {
        await BlockingIO.run { scanBlocking(papersRoot) }
    }

    /// nil when the library has no manifest yet.
    package static func readManifest(at url: URL) throws -> LibraryManifest? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if FileOps.classify(error) == .sourceMissing { return nil }
            throw FileOps.classify(error)
        }
        return try LibraryManifest.decoded(from: data)
    }

    private static func scanBlocking(_ root: URL) -> Scan {
        var scan = Scan()
        for folder in candidateFolders(root) {
            let file = folder.appendingPathComponent(CardSidecar.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else {
                scan.missingSidecar.append(folder)
                continue
            }
            do {
                let sidecar = try CardSidecar.decoded(from: Data(contentsOf: file))
                scan.entries.append((folder: folder, sidecar: sidecar))
            } catch {
                let reason = describe(error)
                scan.unreadable.append((folder: folder, reason: reason))
                Log.storage.error("unreadable card.json in \(folder.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
            }
        }
        return scan
    }

    private static func candidateFolders(_ root: URL) -> [URL] {
        func subfolders(_ dir: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
            return items.filter {
                let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var result: [URL] = []
        for folder in subfolders(root) {
            if folder.lastPathComponent == "_Inbox" {
                result += subfolders(folder)
            } else {
                result.append(folder)
            }
        }
        return result
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let ctx): return ctx.debugDescription
        case DecodingError.keyNotFound(let key, _): return "missing key \(key.stringValue)"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "bad value at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
        default: return FileOps.classify(error).description
        }
    }
}
