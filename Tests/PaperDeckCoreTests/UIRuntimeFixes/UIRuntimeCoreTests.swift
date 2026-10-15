import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

/// The Core / Config halves of the ui-runtime fixes (hunt wave 1, lens ui-runtime). The app halves
/// are `UIRuntimeWiringLintTests` and `--selftest app-rules` (`SelfTestAppRulesUI.swift`).
@Suite("UI runtime fixes: rules")
struct UIRuntimeCoreTests {
    // MARK: ui-runtime-2 — a rewritten card thumbnail is a new URL

    @Test func thumbnailURLsAreVersionedByTheFile() async throws {
        try await OpsTestKit.run { env in
            let paper = try await OpsTestKit.addPaper(env, title: "Preprint")
            let thumbs = env.engine.ctx.thumbs
            try thumbs.save(cardJPEG: OpsTestKit.jpeg(), id: paper.id)
            let file = thumbs.cardURL(for: paper.id)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                                                  ofItemAtPath: file.path)
            let first = try #require(try await env.engine.librarySnapshot().row(id: paper.id)?.thumbnailURL)
            // Unchanged file: the same URL (the card's cache keeps hitting).
            #expect(try await env.engine.librarySnapshot().row(id: paper.id)?.thumbnailURL == first)
            #expect(ThumbnailStore.unversioned(first) == file)

            // Replace (keep checklist) / a merge / Undo: the same path, a new file.
            try thumbs.save(cardJPEG: OpsTestKit.jpeg(width: 560, height: 200), id: paper.id)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_007)],
                                                  ofItemAtPath: file.path)
            let second = try #require(try await env.engine.librarySnapshot().row(id: paper.id)?.thumbnailURL)
            #expect(second != first, "a rewritten thumbnail must come with a new URL")
            #expect(ThumbnailStore.unversioned(second) == file)
        }
    }

    @Test func aVersionedURLStillNamesItsFile() {
        let file = URL(fileURLWithPath: "/tmp/Application Support/PaperDeck caches/thumbs/ab-c%d@2x.jpg")
        let v = ThumbnailStore.versioned(file, version: ThumbnailStore.version(modified: Date(timeIntervalSince1970: 12.5), size: 42))
        #expect(v.fragment == "v=12500000-42")
        #expect(v.path == file.path)
        #expect(ThumbnailStore.unversioned(v) == file)
        #expect(ThumbnailStore.versioned(file, version: "1-1") != ThumbnailStore.versioned(file, version: "1-2"))
    }

    // MARK: ui-runtime-3 — skipped / undownloadable emails are no "server isn't reachable"

    private func info(status: MailSourceStatus?, failures: Int = 0, synced: Bool = true, skipped: Int = 0,
                      hint: String? = nil, undownloadable: Int = 0, enabled: Bool = true) -> MailAccountSyncInfo {
        MailAccountSyncInfo(id: "a", displayName: "Lab", kind: .imap, enabled: enabled, status: status,
                            lastSuccessAt: synced ? Date(timeIntervalSince1970: 1_800_000_000) : nil,
                            consecutiveFailures: failures, undownloadable: undownloadable, skipped: skipped, skippedHint: hint)
    }

    private func ready(_ i: MailAccountSyncInfo) -> CheckState {
        let fact = MailAccountFact(id: "a", source: .imapGmail, info: i)
        return GuideEvaluator.evaluate(.mailAccountReady(nil), GuideSamples.facts { $0.mail = MailFact(enabled: true, accounts: [fact]) })
    }

    private func isProblem(_ s: CheckState) -> Bool {
        if case .problem = s { return true }
        return false
    }

    @Test func anAccountThatSyncsWithSkippedEmailsIsReady() {
        let hint = MailSyncText.skippedByCap(2, lookbackDays: 14, .en)
        let skipped = info(status: .unavailable("Signed in · " + hint), skipped: 2, hint: hint)
        #expect(ready(skipped) == .done)
        // Paused (not syncing): the status keeps the suffix, the pass still got through.
        #expect(ready(info(status: .unavailable("Signed in · " + hint), skipped: 2, hint: hint, enabled: false)) == .done)
        // Emails it couldn't download: still reachable.
        let undownloadable = info(status: .unavailable("Signed in · " + MailSyncText.undownloadable(1, .en)), undownloadable: 1)
        #expect(ready(undownloadable) == .done)
        #expect(MailNoticePolicy.reachable(undownloadable))
    }

    @Test func aFailingServerIsStillAProblem() {
        #expect(isProblem(ready(info(status: .unavailable("Couldn't connect"), failures: 1))))
        #expect(isProblem(ready(info(status: .unavailable("Couldn't connect"), synced: false))))
        #expect(isProblem(ready(info(status: .authFailed("LOGIN rejected")))))
        #expect(!MailNoticePolicy.reachable(info(status: .needsSetup("no password"))))
        #expect(ready(info(status: nil, synced: false)) == .todo)
    }

    // MARK: ui-runtime-4 — the Paper menu's commands

    private func paper(_ status: PaperStatus = .toRead, deleted: Bool = false) -> Paper {
        Paper(sha256: String(repeating: "a", count: 64), fileSize: 1, title: "P", folder: "Papers/p", pdfName: "p.pdf",
              originalName: "p.pdf", status: status, deletedAt: deleted ? Date() : nil)
    }

    private func ctx(_ papers: [Paper], key: Bool = true, editing: Bool = false, papersView: Bool = true,
                     aiOff: Bool = false) -> PaperCommandContext {
        PaperCommandContext(libraryIsKey: key, editingText: editing, listsPapers: papersView, papers: papers, aiOff: aiOff)
    }

    @Test func everyCommandRunsOnASelectedLivePaper() {
        for command in PaperCommand.allCases {
            #expect(PaperCommandRules.isEnabled(command, ctx([paper()])), "\(command)")
        }
    }

    @Test func theKeysStayTheTextsWhileEditingAndOutsideTheLibrary() {
        for command in PaperCommand.allCases {
            #expect(!PaperCommandRules.isEnabled(command, ctx([paper()], editing: true)), "\(command) while typing")
            #expect(!PaperCommandRules.isEnabled(command, ctx([paper()], key: false)), "\(command) in another window")
            #expect(!PaperCommandRules.isEnabled(command, ctx([], key: true)), "\(command) with nothing selected")
            #expect(!PaperCommandRules.isEnabled(command, ctx([paper()], papersView: false)), "\(command) in the Mail inbox")
        }
    }

    @Test func recentlyDeletedOnlyShowsInFinder() {
        for command in PaperCommand.allCases {
            #expect(PaperCommandRules.isEnabled(command, ctx([paper(deleted: true)])) == (command == .revealInFinder), "\(command)")
        }
    }

    @Test func selectionDependentCommands() {
        let many = (0..<(PaperCommandRules.openLimit + 1)).map { _ in paper() }
        #expect(!PaperCommandRules.isEnabled(.openPDF, ctx(many)))
        #expect(!PaperCommandRules.isEnabled(.openInPreview, ctx(many)))
        #expect(PaperCommandRules.isEnabled(.moveToTrash, ctx(many)))
        #expect(!PaperCommandRules.isEnabled(.postponeDay, ctx([paper(.done)])))
        #expect(PaperCommandRules.isEnabled(.postponeDay, ctx([paper(.done), paper()])))
        // AI reading off: one paper's Read with AI is off (as its context menu); a selection asks first.
        #expect(!PaperCommandRules.isEnabled(.readWithAI, ctx([paper()], aiOff: true)))
        #expect(PaperCommandRules.isEnabled(.readWithAI, ctx([paper(), paper()], aiOff: true)))
        #expect(PaperCommandRules.marksRead([paper(.done), paper(.reading)]))
        #expect(!PaperCommandRules.marksRead([paper(.done), paper(.done)]))
        #expect(PaperCommand.priorityHigh.priority == .high && PaperCommand.priorityLow.priority == .low)
        #expect(PaperCommand.openPDF.priority == nil)
    }

    // MARK: ui-runtime-5 — edits still waiting for their debounce are written at quit

    @MainActor final class Written {
        var items: [String] = []
    }

    @MainActor @Test func pendingSavesAreFlushedOnceAndInOrder() async {
        let pending = PendingSaves()
        let written = Written()
        pending.set("b") { written.items.append("b-old") }
        pending.set("b") { written.items.append("b-new") }     // only the newest text of an editor
        pending.set("a") { written.items.append("a") }
        pending.set("c") { written.items.append("c") }
        pending.clear("c")                                     // saved meanwhile
        #expect(pending.count == 2)
        await pending.flushAll()
        #expect(written.items == ["a", "b-new"])
        #expect(pending.isEmpty)
        await pending.flushAll()
        #expect(written.items == ["a", "b-new"], "nothing runs twice")
    }

    @MainActor @Test func aSaveRegisteredDuringTheFlushIsWrittenToo() async {
        let pending = PendingSaves()
        let written = Written()
        pending.set("a") {
            written.items.append("a")
            pending.set("late") { written.items.append("late") }
        }
        await pending.flushAll()
        #expect(written.items == ["a", "late"])
        #expect(pending.isEmpty)
    }
}
