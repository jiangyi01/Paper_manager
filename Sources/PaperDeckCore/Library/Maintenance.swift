import Foundation

// Launch-time maintenance (§5, §9 M6): rebuild an empty index from the sidecars, reconcile
// the DB with what is on disk (folders the user moved/renamed in Finder, missing files,
// adoptable folders), clean temporary files, purge 最近删除 after 30 days, daily backup,
// and mail retention (MAIL_DESIGN §4: bodies of handled cards and attachment copies).

package struct MaintenanceReport: Sendable, Equatable {
    package var rebuilt: RebuildReport?
    package var reconcile = ReconcileReport()
    package var removedPartials = 0
    package var removedIncoming = 0
    package var removedJobDirs = 0
    package var purged: [String] = []           // paper ids hard-deleted (30 days in 最近删除)
    package var backup: URL?                    // created today
    package var prunedBackups: [String] = []    // file names removed (keep newest 7)
    package var mail = MailRetentionReport()
    package var assist = AssistRetentionReport()
    package var errors: [String] = []
    /// Set when `Engine.start()` stopped early because the index belongs to another library
    /// (`checkLibraryIdentity`); nil otherwise.
    package var libraryMismatch: LibraryIdentityCheck?

    package init() {}
}

/// The reading assist's daily housekeeping (`Maintenance.assistRetention`).
package struct AssistRetentionReport: Sendable, Equatable {
    package var prunedExplanations = 0           // unpinned, unsaved, older than assist.explain.historyDays
    package var removedCounters = 0              // kv `assist.count.<day>.*` / `dedupe.ai.count.<day>` of earlier days
    package var prunedReaderPages = 0            // kv `reader.page.<id>` of purged papers (the reader's page memory)
    package var prunedReaderAnchors = 0          // kv `explain.anchor.<id>` of explanations no longer stored

    package init() {}
}

package struct MailRetentionReport: Sendable, Equatable {
    package var purgedBodies = 0                 // handled cards whose body/snippet were cleared
    package var removedFiles = 0                 // attachment / download copies deleted
    package var woken = 0                        // snoozed cards back in 待处理
    package var resetDownloads = 0               // rows stuck in `downloading` (a quit mid-download)

    package init() {}
}

package struct ReconcileReport: Sendable, Equatable {
    package var relocated: [String] = []        // ids whose folder/PDF was found under another name
    package var markedMissing: [String] = []    // ids now flagged `.missing`
    package var clearedMissing: [String] = []   // ids whose file is back
    /// Ids inserted from folders no row points at: card.json + PDF (single-paper rebuild), or
    /// a bare `_Inbox/<sha8>/` PDF left by an import interrupted before its insert (re-committed).
    package var adopted: [String] = []
    package var skipped: [String] = []          // "<folder>: <reason>"

    package init() {}
}

package struct Maintenance: Sendable {
    package static let incomingMaxAge: TimeInterval = 24 * 3600
    package static let failedJobMaxAge: TimeInterval = 7 * 86_400
    package static let backupsKept = 7
    package static let backupPrefix = "library-"

    package let engine: Engine
    /// Moves a folder to the Trash (injectable so tests never touch the real Trash).
    package var trash: @Sendable (URL) -> Bool
    /// Wall clock for file ages — file modification dates are wall-clock, unlike the
    /// engine's (injectable) planning clock.
    package var fileClock: @Sendable () -> Date

    package init(engine: Engine, trash: @escaping @Sendable (URL) -> Bool = { FileOps.trash($0) },
                 fileClock: @escaping @Sendable () -> Date = Date.init) {
        self.engine = engine; self.trash = trash; self.fileClock = fileClock
    }

    /// Everything `Engine.start()` runs before resuming work. Never throws; failures of
    /// one step are logged and reported, and the next step still runs.
    package func onLaunch() async -> MaintenanceReport {
        var report = MaintenanceReport()
        let launchedAt = fileClock()
        func record(_ step: String, _ error: any Error) {
            report.errors.append("\(step): \(error)")
            Log.storage.error("maintenance \(step, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }

        do {
            if try await engine.db.allPapers().isEmpty, await hasSidecars() {
                report.rebuilt = try await engine.rebuildFromSidecars()
            }
        } catch { record("rebuild", error) }

        do { report.reconcile = try await reconcile() } catch { record("reconcile", error) }

        let cleaned = await cleanTemporaryFiles(partialsBefore: launchedAt)
        report.removedPartials = cleaned.partials
        report.removedIncoming = cleaned.incoming
        report.removedJobDirs = cleaned.jobs

        do { report.purged = try await engine.purgeExpired(trash: trash) } catch { record("purge", error) }

        do {
            let backup = try await dailyBackup()
            report.backup = backup.created
            report.prunedBackups = backup.pruned
        } catch { record("backup", error) }

        do { report.mail = try await mailRetention(atLaunch: true) } catch { record("mail retention", error) }

        do { report.assist = try await assistRetention() } catch { record("assist retention", error) }

        Log.storage.notice("""
            maintenance: rebuilt=\(report.rebuilt != nil) relocated=\(report.reconcile.relocated.count) \
            missing=\(report.reconcile.markedMissing.count) adopted=\(report.reconcile.adopted.count) \
            partials=\(report.removedPartials) purged=\(report.purged.count)
            """)
        return report
    }

    // MARK: Reconcile

    /// Makes the DB agree with Papers/: a live paper whose PDF is gone is looked for under
    /// its folder (renamed PDF) and among folders no row points at (matched by card.json id —
    /// the user moved/renamed it in Finder); if found, `folder`/`pdf_name` are fixed, else it
    /// is flagged `.missing` (cleared again when the file reappears). Unreferenced folders
    /// with card.json + PDF whose id/sha are unknown are adopted (single-paper rebuild).
    /// A bare `_Inbox/<sha8>/` with one PDF that hashes to its name and matches no row is an
    /// import a crash interrupted between moving the copy there and inserting its row: it is
    /// committed now through the normal intake path (`IntakeActor.recoverInterruptedCommit`).
    @discardableResult
    package func reconcile() async throws -> ReconcileReport {
        let engine = self.engine
        let papers = try await engine.db.allPapers()
        let library = engine.paths.library, papersRoot = engine.paths.papers
        let facts = papers.map { PaperFact(pk: $0.pk, id: $0.id, folder: $0.folder, pdfName: $0.pdfName,
                                           live: $0.isLive, missingFlag: $0.flags.contains(.missing)) }
        let probe = await BlockingIO.run { ReconcileProbe.run(facts: facts, library: library, papersRoot: papersRoot) }

        var report = ReconcileReport()
        var fixes: [Int64: (folder: String, pdfName: String, previousFolder: String)] = [:]
        var setMissing: [Int64: Bool] = [:]
        var unclaimed = probe.unknownByID
        for fact in facts where fact.live {
            if probe.present.contains(fact.pk) {
                if fact.missingFlag { setMissing[fact.pk] = false; report.clearedMissing.append(fact.id) }
                continue
            }
            if let renamed = probe.renamedPDF[fact.pk] {
                fixes[fact.pk] = (fact.folder, renamed, fact.folder)
                report.relocated.append(fact.id)
            } else if let found = unclaimed.removeValue(forKey: fact.id.lowercased()), let pdf = found.pdfName {
                fixes[fact.pk] = (found.relativeFolder, pdf, fact.folder)
                report.relocated.append(fact.id)
            } else if !fact.missingFlag {
                setMissing[fact.pk] = true
                report.markedMissing.append(fact.id)
                continue
            } else {
                continue
            }
            if fact.missingFlag { setMissing[fact.pk] = false }
        }

        let knownIDs = Set(papers.map { $0.id.lowercased() })
        let knownSHAs = Set(papers.map { $0.sha256.lowercased() })
        let adoptable = unclaimed.values
            .filter { $0.pdfName != nil && !knownIDs.contains($0.sidecar.id.lowercased())
                && !knownSHAs.contains($0.sidecar.sha256.lowercased()) }
            .sorted { $0.relativeFolder < $1.relativeFolder }
        for c in unclaimed.values where c.pdfName == nil {
            report.skipped.append("\(c.relativeFolder): card.json without a PDF")
        }

        let manifestURL = engine.paths.libraryManifest
        let manifest = (try? await BlockingIO.run { try SidecarWriter.readManifest(at: manifestURL) }) ?? nil
        let now = engine.ctx.now()
        let fixesList = fixes.map { (pk: $0.key, folder: $0.value.folder, pdfName: $0.value.pdfName, previous: $0.value.previousFolder) }
        let missingList = setMissing.map { (pk: $0.key, missing: $0.value) }
        let outcome = try await engine.db.transaction { db -> (changed: [Int64], adopted: [SidecarRestore.Inserted], skipped: [String]) in
            var changed: [Int64] = []
            for fix in fixesList {
                guard let p = try db.paper(pk: fix.pk), p.isLive, p.folder == fix.previous else { continue }
                try db.modifyPaper(pk: fix.pk, now: now) { row in
                    row.folder = fix.folder
                    row.pdfName = fix.pdfName
                }
                changed.append(fix.pk)
            }
            for m in missingList {
                guard let p = try db.paper(pk: m.pk), p.isLive, p.flags.contains(.missing) != m.missing else { continue }
                try db.modifyPaper(pk: m.pk, now: now) { row in
                    if m.missing { row.flags.insert(.missing) } else { row.flags.remove(.missing) }
                }
                if !changed.contains(m.pk) { changed.append(m.pk) }
            }
            var adopted: [SidecarRestore.Inserted] = []
            var skipped: [String] = []
            if !adoptable.isEmpty {
                var categories: [String: Int64] = [:]
                for c in try db.categories() { categories[SidecarRestore.categoryKey(c.name)] = c.pk }
                if let manifest {
                    // Categories the card names but the DB lost come back with their manifest details.
                    let wanted = Set(adoptable.compactMap { $0.sidecar.category.name.map(SidecarRestore.categoryKey) })
                    for entry in manifest.categoryModels(fallbackDate: now)
                    where wanted.contains(SidecarRestore.categoryKey(entry.name)) && categories[SidecarRestore.categoryKey(entry.name)] == nil {
                        categories[SidecarRestore.categoryKey(entry.name)] = try db.insertCategory(entry).pk
                    }
                }
                for c in adoptable {
                    do {
                        let saved = try SidecarRestore.insert(c, db: db, categories: &categories, now: now)
                        adopted.append(.init(pk: saved.pk, id: saved.id))
                    } catch let e as SQLiteError where e.isConstraintViolation {
                        skipped.append("\(c.relativeFolder): \(e.message)")
                    }
                }
            }
            return (changed, adopted, skipped)
        }
        report.adopted = outcome.adopted.map(\.id)
        report.skipped += outcome.skipped
        for pk in outcome.changed { await engine.ctx.syncSidecar(pk: pk) }
        if !outcome.adopted.isEmpty {
            _ = await SidecarRestore.indexFullText(engine, outcome.adopted)
            await engine.ctx.writeManifest()
        }

        let bare = probe.bareInbox
        let interrupted = await BlockingIO.run {
            bare.filter { c in
                guard let sha = try? FileOps.sha256(of: c.folder.appendingPathComponent(c.pdfName)) else { return false }
                return c.folder.lastPathComponent.lowercased().hasPrefix(String(sha.prefix(8))) && !knownSHAs.contains(sha)
            }
        }
        for c in interrupted {
            if let id = await engine.intake.recoverInterruptedCommit(folder: c.folder, pdfName: c.pdfName) {
                report.adopted.append(id)
            }
        }
        return report
    }

    // MARK: Mail retention

    /// Leftover attachment folders (no card — e.g. a quit between storing a capture's PDFs and
    /// inserting its row) are only removed once they are this old.
    package static let mailOrphanMinAge: TimeInterval = 86_400

    /// Mail housekeeping — at launch (`onLaunch`) and once per local day (the sync loop, through
    /// `MailSyncActor.Housekeeping`): snoozed cards whose time came go back to 待处理; cards
    /// handled (merged / dismissed / no request) more than `mail.retentionDays` ago lose their
    /// body and snippet (subject, sender, link and items stay for provenance) and their
    /// attachment copies, as do attachment folders of cards that no longer exist;
    /// `retentionDays ≤ 0` keeps everything. Only files under `AppPaths.mailFiles` are ever
    /// deleted, never those of an open card (pending / snoozed — re-checked inside the
    /// transaction, so a card reopened meanwhile keeps them) or of a row being merged. At
    /// launch, rows left `downloading` by a quit become `downloadable` again.
    /// Once a day (launch and the sync loop's daily pass): explanations past
    /// `assist.explain.historyDays` (pinned and saved-to-notes rows stay), and the daily assist /
    /// duplicate-judge counter rows of earlier days (only today's count is ever read), the reader
    /// anchors of explanations no longer stored, and the reader's page memory of papers purged
    /// since (Recently Deleted keeps its pages).
    @discardableResult
    package func assistRetention() async throws -> AssistRetentionReport {
        var report = AssistRetentionReport()
        report.prunedExplanations = try await engine.pruneExplanationsByRetention()
        // The reader anchors of the explanations just pruned (or deleted from the history) go too (R-UI-7).
        report.prunedReaderAnchors = await engine.pruneExplanationReaderAnchors()
        let today = LocalDate.today(now: engine.ctx.now(), calendar: engine.ctx.calendar)
        var stale: [String] = []
        for prefix in [AssistDailyCounter.assistPrefix, AssistDailyCounter.dedupeJudgePrefix] {
            let rows = try await engine.db.kvRows(prefix: prefix + ".")
            stale += rows.keys.filter { Self.isEarlierCounterDay($0, prefix: prefix, today: today) }
        }
        if !stale.isEmpty { try await engine.db.removeCounterKVs(stale.sorted()) }
        report.removedCounters = stale.count
        report.prunedReaderPages = await engine.pruneReaderPages()
        return report
    }

    /// `<prefix>.<yyyy-mm-dd>[.<provider>]` with a day before `today` (a malformed key is kept).
    package static func isEarlierCounterDay(_ key: String, prefix: String, today: LocalDate) -> Bool {
        guard key.hasPrefix(prefix + ".") else { return false }
        let day = key.dropFirst(prefix.count + 1).prefix(10)
        guard day.count == 10, let parsed = LocalDate(iso: String(day)) else { return false }
        return parsed < today
    }

    @discardableResult
    package func mailRetention(atLaunch: Bool = false) async throws -> MailRetentionReport {
        var report = MailRetentionReport()
        let db = engine.db
        let now = engine.ctx.now()
        report.woken = try await db.wakeSnoozedMail(now: now)
        if atLaunch { report.resetDownloads = try await resetStuckDownloads(now: now) }
        let days = engine.loadMailSettings().retentionDays
        guard days > 0 else { return report }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        report.purgedBodies = try await db.purgeMailBodies(handledBefore: cutoff, now: now)

        // Attachment copies of handled cards past the retention period.
        let handledStates: Set<MailState> = [.merged, .dismissed, .noRequest]
        let handled = try await db.mailMessages(states: handledStates, limit: 100_000)
            .filter { ($0.handledAt ?? $0.updatedAt) < cutoff }
        let root = engine.paths.mailFiles
        // Only cards that still have something on disk: a row with a copy, or their folder.
        let withCopies = Set(try await db.mailItems(messagePKs: handled.map(\.pk)).filter { $0.value.contains { $0.pdfPath != nil } }.keys)
        let byID = handled.map { (pk: $0.pk, id: $0.id) }
        let pks = await BlockingIO.run {
            byID.filter { m in
                withCopies.contains(m.pk) || (MailAttachmentFiles.isMessageFolderName(m.id)
                    && FileManager.default.fileExists(atPath: root.appendingPathComponent(m.id, isDirectory: true).path))
            }.map(\.pk)
        }
        if !pks.isEmpty {
            // Decided on the current rows: still handled and past the cutoff, no row in a merge.
            let (paths, folders) = try await db.transaction { db -> ([String], [String]) in
                var paths: [String] = []
                var folders: [String] = []
                for pk in pks {
                    guard let m = try db.mailMessage(pk: pk), handledStates.contains(m.state),
                          (m.handledAt ?? m.updatedAt) < cutoff else { continue }
                    let items = try db.mailItems(messagePK: pk)
                    if items.contains(where: { MailMergeInFlight.shared.contains($0.id) }) { continue }
                    for var item in items {
                        guard let path = item.pdfPath else { continue }
                        paths.append(path)
                        item.pdfPath = nil
                        if item.pdfState == .hasPDF { item.pdfState = .needsPDF }
                        try db.upsertMailItem(item, now: now)
                    }
                    folders.append(m.id)
                }
                return (paths, folders)
            }
            report.removedFiles = await BlockingIO.run {
                let existing = paths.filter { rel in MailAttachmentFiles.url(rel, root: root).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
                MailAttachmentFiles.remove(paths, root: root)
                // Their folders (e.g. a copy whose row was deleted) go too.
                for id in folders { MailAttachmentFiles.removeFolder(messageID: id, root: root) }
                return existing.count
            }
        }
        report.removedFiles += try await removeOrphanMailFolders(root: root)
        if report.purgedBodies > 0 || report.removedFiles > 0 {
            Log.storage.notice("mail retention: \(report.purgedBodies) bodies purged, \(report.removedFiles) copies removed")
        }
        return report
    }

    /// Message folders under `mailFiles` whose card is gone, older than `mailOrphanMinAge`.
    private func removeOrphanMailFolders(root: URL) async throws -> Int {
        let minAge = Self.mailOrphanMinAge
        let clock = fileClock()
        let names = await BlockingIO.run { () -> [String] in
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { url -> String? in
                guard MailAttachmentFiles.isMessageFolderName(url.lastPathComponent),
                      let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      v.isDirectory == true, let modified = v.contentModificationDate,
                      clock.timeIntervalSince(modified) >= minAge else { return nil }
                return url.lastPathComponent
            }
        }
        var orphans: [String] = []
        for name in names {
            if try await engine.db.mailMessage(id: name) == nil { orphans.append(name) }
        }
        guard !orphans.isEmpty else { return 0 }
        let gone = orphans
        return await BlockingIO.run {
            gone.reduce(0) { $0 + (MailAttachmentFiles.removeFolder(messageID: $1, root: root) ? 1 : 0) }
        }
    }

    /// Rows in `downloading` (nothing downloads at launch) → `downloadable`.
    private func resetStuckDownloads(now: Date) async throws -> Int {
        let db = engine.db
        let open = try await db.mailMessages(states: [.pending, .snoozed], limit: 100_000)
        guard !open.isEmpty else { return 0 }
        let stuck = try await db.mailItems(messagePKs: open.map(\.pk)).values.flatMap { $0 }
            .filter { $0.pdfState == .downloading }
        guard !stuck.isEmpty else { return 0 }
        return try await db.transaction { db -> Int in
            var n = 0
            for item in stuck {
                guard var row = try db.mailItem(id: item.id), row.pdfState == .downloading else { continue }
                row.pdfState = .downloadable
                try db.upsertMailItem(row, now: now)
                n += 1
            }
            return n
        }
    }

    // MARK: Temporary files

    /// `.partial` files older than this launch (a pending "same work" choice doesn't survive
    /// a restart) — except those an import is working on right now (`InFlightPartials`) —,
    /// `caches/incoming/*` older than 24 h, job folders older than 7 days.
    package func cleanTemporaryFiles(partialsBefore: Date) async -> (partials: Int, incoming: Int, jobs: Int) {
        let paths = engine.paths
        let now = fileClock()
        return await BlockingIO.run {
            (TempSweep.remove(in: paths.partial, olderThan: partialsBefore, keep: InFlightPartials.shared.contains),
             TempSweep.remove(in: paths.incoming, olderThan: now.addingTimeInterval(-Maintenance.incomingMaxAge)),
             TempSweep.remove(in: paths.jobs, olderThan: now.addingTimeInterval(-Maintenance.failedJobMaxAge)))
        }
    }

    // MARK: Backups

    /// `Backups/library-YYYY-MM-DD.sqlite` once per local day (VACUUM INTO), keeping the newest 7.
    package func dailyBackup() async throws -> (created: URL?, pruned: [String]) {
        let day = LocalDate(engine.ctx.now(), calendar: engine.ctx.calendar)
        let url = engine.paths.backups.appendingPathComponent("\(Self.backupPrefix)\(day.iso).sqlite")
        var created: URL?
        let exists = await BlockingIO.run { PaperOpsSupport.itemExists(url) }
        if !exists {
            try await engine.db.vacuumInto(url)
            created = url
        }
        return (created, await pruneBackups())
    }

    /// 立即备份: a timestamped snapshot next to the daily ones (same retention).
    @discardableResult
    package func backupNow() async throws -> URL {
        let now = engine.ctx.now()
        let day = LocalDate(now, calendar: engine.ctx.calendar)
        let c = engine.ctx.calendar.dateComponents([.hour, .minute, .second], from: now)
        let stamp = String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let dir = engine.paths.backups
        let base = "\(Self.backupPrefix)\(day.iso)-\(stamp)"
        let url = await BlockingIO.run { () -> URL in
            var candidate = dir.appendingPathComponent(base + ".sqlite")
            var n = 2
            while PaperOpsSupport.itemExists(candidate) {
                candidate = dir.appendingPathComponent("\(base)_\(n).sqlite")
                n += 1
            }
            return candidate
        }
        try await engine.db.vacuumInto(url)
        _ = await pruneBackups()
        return url
    }

    private func pruneBackups() async -> [String] {
        let dir = engine.paths.backups
        return await BlockingIO.run {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix(Maintenance.backupPrefix) && $0.hasSuffix(".sqlite") }
                .sorted(by: >)                                     // ISO dates: newest first
            var removed: [String] = []
            for name in names.dropFirst(Maintenance.backupsKept) {
                if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { removed.append(name) }
            }
            return removed
        }
    }

    private func hasSidecars() async -> Bool {
        let roots = [engine.paths.papers, engine.paths.inbox, engine.paths.recentlyDeleted]
        return await BlockingIO.run {
            roots.contains { root in
                ReconcileProbe.subfolders(root).contains {
                    PaperOpsSupport.itemExists($0.appendingPathComponent(CardSidecar.fileName))
                }
            }
        }
    }
}

extension Engine {
    /// Launch maintenance with the real Trash (`Engine.start()` runs `onLaunch()`).
    package var maintenance: Maintenance { Maintenance(engine: self) }
}

// MARK: - Private helpers

private struct PaperFact: Sendable {
    var pk: Int64
    var id: String
    var folder: String
    var pdfName: String
    var live: Bool
    var missingFlag: Bool
}

/// One blocking pass over Papers/ (directory listings + the card.json of unreferenced folders).
private struct ReconcileProbe: Sendable {
    var present: Set<Int64> = []                          // live papers whose PDF exists
    var renamedPDF: [Int64: String] = [:]                 // folder exists, PDF renamed inside it
    var unknownByID: [String: SidecarRestore.Candidate] = [:]   // unreferenced folders with a card.json
    var bareInbox: [BareInboxFolder] = []                 // unreferenced `_Inbox/<sha8>` with one PDF, no card.json

    static func run(facts: [PaperFact], library: URL, papersRoot: URL) -> ReconcileProbe {
        var probe = ReconcileProbe()
        for fact in facts where fact.live {
            let folder = LibraryPaths.folderURL(forRelative: fact.folder, library: library)
            if PaperOpsSupport.itemExists(folder.appendingPathComponent(fact.pdfName)) {
                probe.present.insert(fact.pk)
            } else {
                let pdfs = SidecarRestore.pdfNames(in: folder)
                if pdfs.count == 1 { probe.renamedPDF[fact.pk] = pdfs[0] }
            }
        }
        let known = Set(facts.map { $0.folder.precomposedStringWithCanonicalMapping.lowercased() })
        let inbox = papersRoot.appendingPathComponent("_Inbox", isDirectory: true)
        let folders = subfolders(papersRoot).filter { $0.lastPathComponent != "_Inbox" } + subfolders(inbox)
        for folder in folders {
            let relative = OpsFiles.relative(folder, library: library)
            guard !known.contains(relative.precomposedStringWithCanonicalMapping.lowercased()) else { continue }
            let file = folder.appendingPathComponent(CardSidecar.fileName)
            if !PaperOpsSupport.itemExists(file), folder.deletingLastPathComponent().lastPathComponent == inbox.lastPathComponent,
               isInboxFolderName(folder.lastPathComponent) {
                let pdfs = SidecarRestore.pdfNames(in: folder)
                if pdfs.count == 1 { probe.bareInbox.append(BareInboxFolder(folder: folder, pdfName: pdfs[0])) }
                continue
            }
            guard let data = try? Data(contentsOf: file), let sidecar = try? CardSidecar.decoded(from: data) else { continue }
            let key = sidecar.id.lowercased()
            guard probe.unknownByID[key] == nil else { continue }
            probe.unknownByID[key] = SidecarRestore.Candidate(
                relativeFolder: relative, sidecar: sidecar, inRecentlyDeleted: false,
                pdfName: SidecarRestore.resolvePDF(in: folder, preferred: [sidecar.pdf, FileNamer.pdfName(forFolder: folder.lastPathComponent)]),
                folderDate: (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return probe
    }

    /// `FileNamer.inboxFolderName` for a hash (`5f31a23c`), possibly with a `_2` collision suffix.
    static func isInboxFolderName(_ name: String) -> Bool {
        name.range(of: #"^[0-9a-f]{8}(_[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Visible, non-package subdirectories, sorted by name.
    static func subfolders(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private struct BareInboxFolder: Sendable {
    var folder: URL
    var pdfName: String
}

private enum TempSweep {
    /// Removes direct children of `dir` last modified before `cutoff`, except those `keep`
    /// names. Returns how many.
    static func remove(in dir: URL, olderThan cutoff: Date, keep: (URL) -> Bool = { _ in false }) -> Int {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [])) ?? []
        var removed = 0
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard modified <= cutoff, !keep(item) else { continue }
            if (try? fm.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}
