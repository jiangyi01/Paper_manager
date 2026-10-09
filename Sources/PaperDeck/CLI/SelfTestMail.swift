import Foundation
import PaperDeckCore

/// `--selftest mail --root R --fixtures DIR [--agent mock|off] [--senders SPEC] [--network on]`:
/// imports every `.eml` of DIR through the engine (manual-drop path), runs the mock AI triage
/// (consent given for every card that asks), prints the cards and counts, merges one stored PDF
/// attachment and verifies its provenance (DB + card.json), then re-imports (idempotent).
/// Settings ▸ Mail are the self-test's own (alert presets + `--senders`), never the user's; no
/// mail server, offline by default, zero quota (the agent is the mock unless explicitly real).
enum SelfTestMail {
    static func run(_ args: CLIArgs, _ base: SelfTest.Options) async -> Int32 {
        var o = base
        o.network = args.value("--network") == "on"           // offline unless asked (deterministic)
        guard args.has("--fixtures") else {
            return CLIRunner.fail("--selftest mail needs --fixtures DIR (a folder of .eml files)")
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: o.fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "eml" }
            .filter { o.only == nil || $0.lastPathComponent == o.only }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return CLIRunner.fail("no .eml files in \(o.fixtures.path)") }
        let mail = MailSettings(enabled: false, senders: MailCLI.senderRules(args.value("--senders")) + SenderRule.presets,
                                aiMode: o.agent == .off ? .heuristicOnly : .ai)
        do {
            let engine = try await SelfTest.openEngine(o, mail: mail)
            if o.agent.providerKind != nil, let n = o.maxRuns { engine.runBudget.setLimit(n) }
            await engine.start()
            var ok = try await importAndTriage(engine, files: files, o)
            ok = try await mergeOne(engine, o) && ok
            ok = try await reimport(engine, files: files) && ok
            await engine.shutdown()
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            return ok ? 0 : 1
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    // MARK: Import + triage

    static func importAndTriage(_ engine: Engine, files: [URL], _ o: SelfTest.Options) async throws -> Bool {
        var ok = true
        let t0 = Date()
        let ids = await engine.mail.importEML(files)
        await engine.mail.waitUntilIdle()
        CLIRunner.line(["check": "import", "files": files.count, "emails": ids.count,
                        "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        if ids.count != files.count { ok = false }

        var snap = try await engine.mailSnapshot()
        for card in allCards(snap) { printCard(card, phase: "captured") }

        // Mock AI triage: give consent on every card that asks (the 「让 AI 分析」 click).
        guard o.agent != .off else {
            CLIRunner.line(["check": "triage", "skipped": "agent off (local rules only)"])
            return ok
        }
        var requested = 0
        for card in allCards(snap) where card.canRequestAI {
            do {
                _ = try await engine.requestMailAI(messageID: card.id)
                requested += 1
            } catch let e as MailTriageError {
                CLIRunner.line(["card": card.id, "requestAI": e.message(.en)])
            }
        }
        let deadline = Date().addingTimeInterval(o.agent.providerKind != nil ? 600 : 90)
        while Date() < deadline {
            snap = try await engine.mailSnapshot()
            let busy = allCards(snap).filter { [.queued, .running].contains($0.displayTriageState) }
            if busy.isEmpty { break }
            if engine.runBudget.isExhausted { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        await engine.mailTriage.waitForVerification()
        await engine.mail.waitUntilIdle()
        snap = try await engine.mailSnapshot()
        var done = 0, failed = 0, waiting = 0
        for card in allCards(snap) {
            printCard(card, phase: "triaged")
            switch card.message.triageState {
            case .done: done += 1
            case .failed: failed += 1
            case .queued, .running, .held, .limited, .needsLogin: waiting += 1
            default: break
            }
        }
        let c = snap.counts
        CLIRunner.line(["check": "triage", "requested": requested, "done": done, "failed": failed, "waiting": waiting,
                        "usage": "\(snap.triageUsage.used)/\(snap.triageUsage.limit)"])
        CLIRunner.line(["counts": ["pending": c.pending, "requests": c.requests, "awaitingConsent": c.awaitingConsent,
                                   "needsPDF": c.needsPDF, "snoozed": c.snoozed] as [String: Any],
                        "filters": Dictionary(uniqueKeysWithValues: MailInboxFilter.allCases.map { ($0.rawValue, snap.cards($0).count) })])
        if o.agent == .mock, failed > 0 || waiting > 0 { ok = false }
        return ok
    }

    // MARK: Merge one attachment + provenance

    static func mergeOne(_ engine: Engine, _ o: SelfTest.Options) async throws -> Bool {
        let snap = try await engine.mailSnapshot()
        guard let (card, item) = allCards(snap).lazy.compactMap({ card in
            card.items.first { $0.origin == .attachment && $0.pdfState == .hasPDF && $0.status == .pending }.map { (card, $0) }
        }).first else {
            CLIRunner.line(["check": "merge", "skipped": "no stored PDF attachment among the fixtures"])
            return true
        }
        let settings = await engine.ctx.settings()
        let today = LocalDate.today(now: engine.ctx.now(), calendar: engine.ctx.calendar)
        var options = MailMergeOptions.suggested(for: card.message, rule: card.rule, settings: settings, today: today)
        options.readWithAI = false                          // the merge check needs no AI card
        guard let paperID = try await engine.mergeMailItem(itemID: item.id, options: options) else {
            CLIRunner.line(["check": "merge", "error": "merge returned no paper"])
            return false
        }
        await engine.enrich.waitUntilIdle()
        await engine.ctx.sidecars.flush()
        guard let paper = try await engine.db.paper(id: paperID) else {
            CLIRunner.line(["check": "merge", "error": "paper \(paperID) not in the library"])
            return false
        }
        let sources = try await engine.db.paperSources(paperPK: paper.pk)
        let dbOK = sources.contains { $0.mailMessageID == card.message.id && $0.internetMessageID == card.message.internetMessageID }
        let row = try await engine.db.mailItem(id: item.id)
        let rowOK = row.map { [.merged, .linked].contains($0.status) && $0.paperID == paperID } ?? false
        let sidecar = engine.ctx.folderURL(paper).appendingPathComponent(CardSidecar.fileName)
        let sidecarOK = Self.sidecarHasProvenance(sidecar, messageID: card.message.id)
        let wantHigh = options.priority == .high
        let priorityOK = !wantHigh || paper.priority == .high
        CLIRunner.line(["check": "merge", "email": String(card.message.subject.prefix(60)), "paper": String(paper.title.prefix(60)),
                        "priority": String(describing: paper.priority), "deadline": paper.deadline?.iso,
                        "provenanceDB": dbOK, "provenanceCardJSON": sidecarOK, "row": row?.status.rawValue,
                        "cardState": try await engine.db.mailMessage(id: card.id)?.state.rawValue])
        return dbOK && rowOK && sidecarOK && priorityOK
    }

    static func sidecarHasProvenance(_ url: URL, messageID: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["provenance"] as? [[String: Any]] else { return false }
        return entries.contains { ($0["mailMessageID"] as? String) == messageID }
    }

    // MARK: Idempotency

    static func reimport(_ engine: Engine, files: [URL]) async throws -> Bool {
        let before = allCards(try await engine.mailSnapshot()).map(\.id).sorted()
        let again = await engine.mail.importEML(files)
        await engine.mail.waitUntilIdle()
        let after = allCards(try await engine.mailSnapshot()).map(\.id).sorted()
        let same = before == after && Set(again).isSubset(of: Set(before))
        CLIRunner.line(["check": "reimport", "cards": after.count, "unchanged": same])
        return same
    }

    // MARK: Output

    static func allCards(_ snap: MailSnapshot) -> [MailCard] {
        MailInboxFilter.allCases.flatMap { snap.cards($0) }
    }

    static func printCard(_ card: MailCard, phase: String) {
        let m = card.message
        CLIRunner.line([
            "phase": phase, "card": m.id, "from": m.fromAddress, "kind": m.senderKind.rawValue,
            "subject": String(m.subject.prefix(60)), "state": m.state.rawValue,
            "triage": card.displayTriageState.rawValue, "source": m.triageSource?.rawValue,
            "request": m.triage?.requestKind.rawValue, "summary": m.triage.map { String($0.summary.prefix(100)) },
            "due": m.triage?.dueDate?.iso, "rows": card.items.map { "\($0.cand):\($0.origin.rawValue)/\($0.pdfState.rawValue)/\($0.relevance?.rawValue ?? "-")" },
            "needsPDF": card.needsPDFCount, "canRequestAI": card.canRequestAI,
        ])
    }
}
