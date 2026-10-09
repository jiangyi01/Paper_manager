import Foundation
import PaperDeckCore

/// `--selftest dedupe [--lang en|zh]`: the duplicate check's app-side rules, pure — every
/// `L.Dedupe` string worded in both languages (and distinct), no institution literal, the
/// review toasts' buttons (never "keep new" for a supplement or a paper in Recently Deleted),
/// which toasts stay until handled, and the decision sheet's choice → engine choice mapping.
/// No engine, no library, nothing spawned, nothing stored. Owned by Slice B.
enum SelfTestDedupe {
    static func run(_ args: CLIArgs) -> Int32 {
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let previous = LangStore.shared.lang
        defer { LangStore.shared.lang = previous }

        var ok = true
        func check(_ name: String, _ pass: Bool, _ extra: [String: Any?] = [:]) {
            var line: [String: Any?] = ["check": name, "ok": pass]
            line.merge(extra) { a, _ in a }
            CLIRunner.line(line)
            if !pass { ok = false }
        }

        // 1. Strings: both languages, all distinct between them, none empty, no institution literal.
        LangStore.shared.lang = .en
        let en = L.Dedupe.all
        LangStore.shared.lang = .zh
        let zh = L.Dedupe.all
        LangStore.shared.lang = lang
        let same = zip(en, zh).filter { $0 == $1 }.map(\.0)
        check("strings: en and zh differ", en.count == zh.count && same.isEmpty, ["same": same])
        check("strings: none empty", !(en + zh).contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let institution = ["wash" + "u", "wus" + "tl", "washing" + "ton university"]
        check("strings: no institution literal",
              !(en + zh).contains { s in institution.contains { s.lowercased().contains($0) } })

        // 2. Review toasts: [Review…] first; one quick answer that never throws the library's version away.
        func review(_ relation: DupRelation, parked: Bool = true) -> DupReview {
            DupReview(newPaperID: parked ? nil : "n", existingPaperID: "e", band: .certain, score: 1, createdAt: Date(),
                      newPaperPK: parked ? nil : 2, existingPaperPK: 1, relation: relation, pendingID: parked ? "p" : nil)
        }
        func actions(_ r: DupReview, live: Bool = true) -> [Toast.Action] {
            DupExplainer.reviewToast(r, newTitle: "N", existingTitle: "E", existingIsLive: live, lang: lang).buttons.map(\.action)
        }
        let newer = review(.newerVersion)
        check("toast: a newer version offers Keep New",
              actions(newer) == [.openDuplicateReview(id: newer.id), .replaceKeepingChecklist(pendingID: "p")])
        let supplement = review(.supplement)
        check("toast: a supplement is never offered as a replacement",
              actions(supplement) == [.openDuplicateReview(id: supplement.id), .ignorePending(pendingID: "p")])
        let copy = review(.sameVersion)
        check("toast: the same version offers Skip", actions(copy).last == .ignorePending(pendingID: "p"))
        check("toast: a paper in Recently Deleted gets the sheet only",
              actions(newer, live: false) == [.openDuplicateReview(id: newer.id)])
        let reviewToast = DupExplainer.reviewToast(newer, newTitle: "N", existingTitle: "E", existingIsLive: true, lang: lang)
        check("toast: a review toast stays until handled", reviewToast.requiresAttention && reviewToast.isSticky)
        let undo = Toast(kind: .success, message: "m", buttons: [.init(title: L.Dedupe.undo, action: .undo(token: "t"))])
        check("toast: the result's Undo expires on its own", !undo.requiresAttention && ToastJanitor.grace(for: undo) == .seconds(12))

        // 3. The sheet's choice → the engine's choice.
        let today = LocalDate.today()
        let detail = DupReviewDetail(review: review(.newerVersion), new: DupSideSummary(title: "N"),
                                     existing: DupSideSummary(title: "E", status: .done),
                                     explanation: DupExplanation(headline: "h"),
                                     choices: [.keepNew, .rereadEarlier, .skip], defaultChoice: .keepNew,
                                     canRegenerateChecklist: true)
        let model = DuplicateSheetModel(fixture: detail, today: today)
        check("sheet: the default is preselected, nothing else", model.choice == .keepNew && model.dupChoice == .keepNew(reread: false))
        model.moveBackToRead = true
        check("sheet: keep new + back to To Read", model.dupChoice == .keepNew(reread: true))
        model.choice = .rereadEarlier
        model.checklist = .uncheckAll
        model.deadline = .date
        model.deadlineDate = today.adding(days: 3).date(hour: 12, minute: 0)
        check("sheet: re-read with a picked date",
              model.dupChoice == .rereadEarlier(checklist: .uncheckAll, deadline: .date(today.adding(days: 3)), useNewFile: false))
        model.deadline = .none
        model.useNewFile = true
        check("sheet: re-read, no deadline, the new file",
              model.dupChoice == .rereadEarlier(checklist: .uncheckAll, deadline: .unscheduled, useNewFile: true))
        let related = DuplicateSheetModel(fixture: DupReviewDetail(review: review(.correction), new: DupSideSummary(title: "N"),
                                                                   existing: DupSideSummary(title: "E"),
                                                                   explanation: DupExplanation(headline: "h"),
                                                                   choices: [.keepBoth, .skip], defaultChoice: .keepBoth,
                                                                   canRegenerateChecklist: false), today: today)
        check("sheet: a correction is kept linked as related", related.dupChoice == .keepBoth(linkAsRelated: true))
        check("sheet: a queue of one shows no counter", related.position == nil)
        let queued = DuplicateSheetModel(fixture: detail, queueCount: 3, today: today)
        check("sheet: a queue shows 1 of 3", queued.position.map { $0 == (1, 3) } == true)

        // 4. B3: the batch review's presets never pick a choice a row doesn't offer.
        let rowA = DupBatchRow(detail: detail)                         // keepNew / rereadEarlier / skip
        let rowB = DupBatchRow(detail: DupReviewDetail(review: review(.correction), new: DupSideSummary(title: "N"),
                                                       existing: DupSideSummary(title: "E"),
                                                       explanation: DupExplanation(headline: "h"),
                                                       choices: [.keepBoth, .skip], defaultChoice: .keepBoth,
                                                       canRegenerateChecklist: false))
        let both = DupBatch.applying(.keepBoth, to: [rowA, rowB])
        check("batch: keep both only where offered", both[0].choice == .keepNew && both[1].choice == .keepBoth
              && both.allSatisfy { $0.detail.choices.contains($0.choice) })
        let skipped = DupBatch.applying(.skip, to: [rowA, rowB])
        check("batch: skip all overrides both rows", skipped.map(\.choice) == [.skip, .skip] && skipped.allSatisfy(\.isOverridden))
        check("batch: suggested clears every override", DupBatch.applying(.suggested, to: skipped).allSatisfy { !$0.isOverridden })
        check("batch: a related row is kept linked", rowB.dupChoice == .keepBoth(linkAsRelated: true))
        // Phase 2 fix B3-2: a preset equal to a row's suggestion is still the user's pick, so an [Ask AI]
        // answer that moves the suggestion doesn't move what [Apply] does.
        let pinned = DupBatch.applying(.keepNew, to: [rowA])[0]          // rowA suggests Keep New already
        var moved = rowA.detail
        moved.defaultChoice = .skip
        check("batch: a preset equal to the suggestion survives an AI answer",
              pinned.override == .keepNew && pinned.refreshed(with: moved).choice == .keepNew
                  && rowA.refreshed(with: moved).choice == .skip)
        let fixture = DuplicateBatchModel(fixture: [rowA, rowB])
        fixture.set(.rereadEarlier, for: rowA.id)
        fixture.set(.attachSupplement, for: rowB.id)                 // not offered: ignored
        check("batch: per-row override", fixture.items.map(\.choice)
              == [.rereadEarlier(checklist: .keepProgress, deadline: .auto, useNewFile: false), .keepBoth(linkAsRelated: true)]
              && fixture.changedCount == 1)

        // 5. B3: [Ask AI] — hidden while off or pointless, a reason when private, the cost when offered.
        let status = { (b: DupJudgeBlock?) in DupJudgeStatus(block: b, usedToday: 1, dailyCap: 10) }
        check("judge: hidden while switched off / Explain & Ask off / certain",
              [DupJudgeBlock.switchedOff, .assistOff, .dedupeOff, .certain, .removedPaper, .reviewClosed]
                .allSatisfy { DuplicateSheetModel.phase(status($0)) == .hidden })
        check("judge: a private paper says why", {
            if case .blocked(let why) = DuplicateSheetModel.phase(status(.privateExisting)) { return !why.isEmpty }
            return false
        }())
        check("judge: offered with today's count", DuplicateSheetModel.phase(status(nil)) == .ready(status(nil)))
        let unsure = DupAIVerdict(verdict: .different, confidence: 0.5, reason: "", bandBefore: .likely, bandAfter: .likely,
                                  provider: "mock", model: "m", at: Date())
        check("judge: an unsure answer says nothing moved", DupVerdictLine.note(unsure) == L.Dedupe.judgeUnsure)

        // 6. B3: the email popover's default never replaces or re-reads on a weak match.
        let done = Paper(pk: 1, sha256: "e", fileSize: 1, ids: PaperIDs(), title: "E", folder: "Papers/E", pdfName: "E.pdf",
                         originalName: "e.pdf", status: .done)
        let weak = MailDupRules.choices(existing: done, band: .possible, relation: .newerVersion, newerSide: .new, identity: false)
        check("mail: a possible match adds separately by default", weak.default == .addSeparately)
        let strong = MailDupRules.choices(existing: done, band: .likely, relation: .newerVersion, newerSide: .new, identity: false)
        check("mail: a newer version of a likely match is used", strong.default == .useThisVersion && strong.choices.count == 4)
        let identical = MailDupRules.choices(existing: done, band: .certain, relation: .sameVersion, newerSide: nil, identity: true)
        check("mail: an identifier match can't be a separate paper", !identical.choices.contains(.addSeparately) && identical.default == .reread)

        CLIRunner.line(["selftest": "dedupe", "lang": lang.rawValue, "ok": ok])
        return ok ? 0 : 1
    }
}
