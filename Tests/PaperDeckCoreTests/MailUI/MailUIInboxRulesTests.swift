import Foundation
import Testing
@testable import PaperDeckCore

/// The Mail panel's pure presentation rules (MailInboxRules): row chips and actions, links,
/// 「全部合并 (N)」, digest collapsing, badges, the email due-date hint, snooze presets, card-level
/// drop matching, drop-zone hit testing and inert text.
@Suite struct MailUIInboxRulesTests {
    private typealias R = MailInboxRules

    private static func item(_ ord: Int, origin: MailItemOrigin = .link, foundBy: MailItemFoundBy = .local,
                             title: String? = nil, ids: PaperIDs = PaperIDs(), url: String? = nil,
                             urlOriginal: String? = nil, host: String? = nil, relevance: MailItemRelevance? = nil,
                             pdf: MailPDFState = .unknown, paperID: String? = nil,
                             status: MailItemStatus = .pending) -> MailItem {
        MailItem(pk: Int64(ord + 1), ord: ord, cand: "c\(ord + 1)", origin: origin, foundBy: foundBy, title: title,
                 ids: ids, url: url, urlOriginal: urlOriginal, host: host, relevance: relevance, pdfState: pdf,
                 paperID: paperID, status: status)
    }

    private static let calendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private static func message(kind: SenderKind = .person, triage: MailTriage? = nil) -> MailMessage {
        MailMessage(accountID: "manual", internetMessageID: "<t@x>", fromAddress: "a@b.edu", senderKind: kind,
                    subject: "s", receivedAt: date(2026, 9, 29, 14), triage: triage)
    }

    // MARK: Chips

    @Test func chipsFollowStatusThenPDFState() {
        #expect(R.chip(Self.item(0, origin: .attachment, pdf: .hasPDF)) == .attachment)
        #expect(R.chip(Self.item(0, origin: .link, pdf: .hasPDF)) == .downloaded)
        #expect(R.chip(Self.item(0, pdf: .needsPDF)) == .needsPDF)
        #expect(R.chip(Self.item(0, pdf: .downloading)) == .downloading)
        #expect(R.chip(Self.item(0, pdf: .inLibrary, paperID: "p")) == .inLibrary)
        #expect(R.chip(Self.item(0, pdf: .inLibrary, paperID: "p", status: .merged)) == .merged)
        #expect(R.chip(Self.item(0, pdf: .inLibrary, paperID: "p", status: .linked)) == .inLibrary)
        #expect(R.chip(Self.item(0, pdf: .needsPDF, status: .skipped)) == .skipped)
    }

    @Test func downloadableNeedsALocallyExtractedPDFLink() {
        let arxiv = PaperIDs(arxivID: "2606.24530")
        let local = Self.item(0, ids: arxiv, url: "https://arxiv.org/abs/2606.24530", host: "arxiv.org", pdf: .unknown)
        #expect(R.chip(local) == .downloadable)
        #expect(R.chip(Self.item(0, ids: arxiv, url: "https://arxiv.org/abs/2606.24530", host: "arxiv.org", pdf: .downloadable))
            == .downloadable)
        // The model named it: never downloaded from its ids.
        #expect(R.chip(Self.item(0, foundBy: .ai, ids: arxiv, pdf: .downloadable)) == .needsPDF)
        // A paywalled landing page has no PDF source.
        #expect(R.chip(Self.item(0, url: "https://www.cell.com/cell/fulltext/S0092-8674(25)00001-1", host: "cell.com",
                                 pdf: .downloadable)) == .needsPDF)
    }

    // MARK: Actions

    @Test func rowActionsMatchTheChip() {
        let attached = R.actions(Self.item(0, origin: .attachment, pdf: .hasPDF))
        #expect(attached.contains(.merge) && attached.contains(.skip) && attached.contains(.acceptsDrop))
        #expect(!attached.contains(.dropBox) && !attached.contains(.downloadAndMerge))

        let needs = R.actions(Self.item(0, url: "https://www.nature.com/articles/x", pdf: .needsPDF))
        #expect(needs.contains(.dropBox) && needs.contains(.acceptsDrop) && needs.contains(.openLink) && needs.contains(.skip))
        #expect(!needs.contains(.merge))

        let downloadable = R.actions(Self.item(0, ids: PaperIDs(arxivID: "2606.24530"), url: "https://arxiv.org/abs/2606.24530",
                                               host: "arxiv.org", pdf: .downloadable))
        #expect(downloadable.contains(.downloadAndMerge) && downloadable.contains(.download) && downloadable.contains(.acceptsDrop))

        let inLibrary = R.actions(Self.item(0, pdf: .inLibrary, paperID: "p1"))
        #expect(inLibrary.contains(.merge) && inLibrary.contains(.openCard))
        #expect(!inLibrary.contains(.acceptsDrop) && !inLibrary.contains(.dropBox))

        let merged = R.actions(Self.item(0, pdf: .inLibrary, paperID: "p1", status: .merged))
        #expect(merged == [.openCard])

        let skipped = R.actions(Self.item(0, origin: .attachment, pdf: .hasPDF, status: .skipped))
        #expect(skipped.contains(.merge) && skipped.contains(.acceptsDrop))
        #expect(!skipped.contains(.skip) && !skipped.contains(.dropBox))

        #expect(!R.actions(Self.item(0, pdf: .downloading)).contains(.acceptsDrop))
    }

    // MARK: Links (untrusted)

    @Test func openLinkPrefersTheOriginalAndOnlyOpensWebURLs() {
        let wrapped = "https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.nature.com%2Farticles%2Fx&data=abc"
        #expect(R.linkURL(Self.item(0, url: "https://www.nature.com/articles/x", urlOriginal: wrapped))?.absoluteString == wrapped)
        #expect(R.linkURL(Self.item(0, url: "https://www.nature.com/articles/x", urlOriginal: "javascript:alert(1)"))?
            .absoluteString == "https://www.nature.com/articles/x")
        #expect(R.linkURL(Self.item(0, url: "file:///etc/passwd")) == nil)
        #expect(R.linkURL(Self.item(0, url: "data:text/html,hi")) == nil)
        #expect(R.linkURL(Self.item(0, url: "https://evil.example/\u{202E}fdp.exe")) == nil)
        #expect(R.linkURL(Self.item(0, url: "https://exa mple.org/")) == nil)
        #expect(R.linkURL(Self.item(0, origin: .attachment, ids: PaperIDs(doi: "10.1038/s41586-024-08351-7")))?
            .absoluteString == "https://doi.org/10.1038/s41586-024-08351-7")
        #expect(R.linkURL(Self.item(0, origin: .attachment, ids: PaperIDs(arxivID: "2606.24530")))?
            .absoluteString == "https://arxiv.org/abs/2606.24530")
        #expect(R.linkURL(Self.item(0, origin: .attachment)) == nil)
        #expect(R.safeWebURL("HTTPS://Example.org/a") != nil)
        #expect(R.safeWebURL("https://") == nil)
    }

    // MARK: 全部合并 (N)

    @Test func mergeAllTakesPendingTargetRowsWithAPDFSource() {
        let items = [
            Self.item(0, origin: .attachment, relevance: .requested, pdf: .hasPDF),
            Self.item(1, relevance: .requested, pdf: .needsPDF),
            Self.item(2, ids: PaperIDs(arxivID: "2606.24530"), url: "https://arxiv.org/abs/2606.24530", host: "arxiv.org",
                      relevance: .highlighted, pdf: .downloadable),
            Self.item(3, relevance: .highlighted, pdf: .inLibrary, paperID: "p"),
            Self.item(4, relevance: .highlighted, pdf: .inLibrary),                        // no paper id → nothing to link
            Self.item(5, origin: .attachment, relevance: .listed, pdf: .hasPDF),            // not a target
            Self.item(6, origin: .attachment, relevance: .requested, pdf: .inLibrary, paperID: "q", status: .merged),
        ]
        #expect(R.mergeAllItems(items).map(\.ord) == [0, 2, 3])
        #expect(R.mergeAllCount(items) == 3)
        // Nothing rated: every unrated row is a target.
        let unrated = [Self.item(0, origin: .attachment, pdf: .hasPDF), Self.item(1, origin: .attachment, pdf: .hasPDF)]
        #expect(R.mergeAllCount(unrated) == 2)
        // An all-listed digest has no targets.
        #expect(R.mergeAllCount([Self.item(0, origin: .attachment, relevance: .listed, pdf: .hasPDF)]) == 0)
    }

    // MARK: Digests

    @Test func digestsShowPickedRowsFirstAndCollapseTheRest() {
        let items = (0..<14).map { i -> MailItem in
            let rel: MailItemRelevance? = i == 9 ? .requested : (i == 3 || i == 12 ? .highlighted : .listed)
            return Self.item(i, relevance: rel, pdf: .needsPDF)
        }
        let parts = R.partition(items.reversed(), digest: true)
        #expect(parts.shown.map(\.ord) == [9, 3, 12])
        #expect(parts.rest.count == 11)
        #expect(parts.rest.map(\.ord) == parts.rest.map(\.ord).sorted())

        // Already merged rows stay visible.
        var withMerged = items
        withMerged[5].status = .merged
        #expect(R.partition(withMerged, digest: true).shown.map(\.ord) == [9, 3, 12, 5])

        // Nothing rated: the first rows, the rest behind 「其余 N 篇」 — only for long digests.
        let plain = (0..<10).map { Self.item($0, pdf: .needsPDF) }
        let p = R.partition(plain, digest: true)
        #expect(p.shown.map(\.ord) == [0, 1, 2, 3])
        #expect(p.rest.count == 6)
        #expect(R.partition(Array(plain.prefix(6)), digest: true).rest.isEmpty)
        // Not a digest: everything, in order.
        #expect(R.partition(items.reversed(), digest: false).shown.map(\.ord) == Array(0..<14))
    }

    @Test func digestAndBadgeFollowTheTriageThenTheSender() {
        let alert = Self.message(kind: .alert)
        #expect(R.isDigest(alert))
        #expect(R.requestBadge(alert) == .alert)
        #expect(R.requestBadge(Self.message(kind: .person)) == nil)
        func kind(_ k: MailRequestKind) -> MailMessage {
            Self.message(kind: .advisor, triage: MailTriage(hasReadingRequest: true, requestKind: k, summary: ""))
        }
        #expect(R.requestBadge(kind(.advisorRequest)) == .request)
        #expect(R.requestBadge(kind(.journalClub)) == .journalClub)
        #expect(R.requestBadge(kind(.fyi)) == .fyi)
        #expect(R.requestBadge(kind(.other)) == .other)
        #expect(R.requestBadge(kind(.notPaper)) == nil)
        #expect(R.isDigest(kind(.alertDigest)))
        #expect(!R.isDigest(kind(.advisorRequest)))
    }

    // MARK: Due date

    @Test func dueHintIsConfidentOnlyAboveThePopoverThreshold() {
        let due = LocalDate(year: 2026, month: 10, day: 3)
        func m(_ confidence: Double?, evidence: String? = "before Thursday's lab meeting") -> MailMessage {
            Self.message(triage: MailTriage(hasReadingRequest: true, requestKind: .advisorRequest, summary: "",
                                            dueDate: due, dueEvidence: evidence, dueConfidence: confidence))
        }
        let today = LocalDate(year: 2026, month: 9, day: 30)
        #expect(R.dueHint(m(0.9), today: today) == .init(date: due, confident: true, isPast: false,
                                                         evidence: "before Thursday's lab meeting"))
        #expect(R.dueHint(m(0.5), today: today)?.confident == false)
        #expect(R.dueHint(m(nil), today: today)?.confident == false)
        #expect(R.dueHint(m(0.9), today: LocalDate(year: 2026, month: 10, day: 4))?.isPast == true)
        #expect(R.dueHint(m(0.9), today: due)?.isPast == false)
        #expect(R.dueHint(m(0.9, evidence: "by\u{202E} Friday\n\n"), today: today)?.evidence == "by Friday")
        #expect(R.dueHint(Self.message(), today: today) == nil)
    }

    // MARK: Snooze

    @Test func snoozePresetsLandAtNineInTheMorning() {
        let wednesday = Self.date(2026, 9, 30, 10, 0)
        #expect(R.snoozeTomorrow(now: wednesday, calendar: Self.calendar) == Self.date(2026, 10, 1, 9, 0))
        #expect(R.snoozeNextMonday(now: wednesday, calendar: Self.calendar) == Self.date(2026, 10, 5, 9, 0))
        let monday = Self.date(2026, 10, 5, 7, 30)
        #expect(R.snoozeNextMonday(now: monday, calendar: Self.calendar) == Self.date(2026, 10, 12, 9, 0))
        let sunday = Self.date(2026, 10, 4, 23, 0)
        #expect(R.snoozeNextMonday(now: sunday, calendar: Self.calendar) == Self.date(2026, 10, 5, 9, 0))
        let lateNight = Self.date(2026, 12, 31, 23, 59)
        #expect(R.snoozeTomorrow(now: lateNight, calendar: Self.calendar) == Self.date(2027, 1, 1, 9, 0))
        #expect(R.validSnooze(wednesday.addingTimeInterval(120), now: wednesday))
        #expect(!R.validSnooze(wednesday.addingTimeInterval(10), now: wednesday))
        #expect(!R.validSnooze(wednesday.addingTimeInterval(-3600), now: wednesday))
    }

    // MARK: A PDF dropped on the card

    @Test func cardDropMatchesByIdentifierThenTitle() {
        let items = [
            Self.item(0, title: "Molecular and cellular dynamics of the developing human neocortex",
                      ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"), relevance: .requested, pdf: .needsPDF),
            Self.item(1, title: "Eubiota: a platform for microbial communities", ids: PaperIDs(arxivID: "2606.24530"),
                      relevance: .requested, pdf: .needsPDF),
            Self.item(2, title: "Spatial atlas of the mouse hippocampus", relevance: .highlighted, pdf: .needsPDF),
            Self.item(3, title: "Already there", ids: PaperIDs(doi: "10.1/in-lib"), pdf: .inLibrary, paperID: "p"),
        ]
        #expect(R.matchDroppedPDF(ids: PaperIDs(doi: "10.1038/S41586-024-08351-7"), title: nil, items: items,
                                  soleFallback: false)?.ord == 0)
        #expect(R.matchDroppedPDF(ids: PaperIDs(doi: "10.1101/2024.01.01.1", publishedDOI: "10.1038/s41586-024-08351-7"),
                                  title: nil, items: items, soleFallback: false)?.ord == 0)
        #expect(R.matchDroppedPDF(ids: PaperIDs(arxivID: "2606.24530v3"), title: nil, items: items, soleFallback: false)?.ord == 1)
        #expect(R.matchDroppedPDF(ids: PaperIDs(), title: "Spatial Atlas of the Mouse Hippocampus", items: items,
                                  soleFallback: false)?.ord == 2)
        // A title that matches but an identifier that says it is another work.
        #expect(R.matchDroppedPDF(ids: PaperIDs(doi: "10.9/other"),
                                  title: "Molecular and cellular dynamics of the developing human neocortex",
                                  items: items, soleFallback: false) == nil)
        // In-library rows never take a drop.
        #expect(R.matchDroppedPDF(ids: PaperIDs(doi: "10.1/in-lib"), title: nil, items: items, soleFallback: true) == nil)
        // Unrelated title, several rows waiting → no guess.
        #expect(R.matchDroppedPDF(ids: PaperIDs(), title: "Something else entirely", items: items, soleFallback: true) == nil)
    }

    @Test func cardDropFallsBackToTheOnlyWaitingRow() {
        let items = [
            Self.item(0, origin: .attachment, title: "Attached", pdf: .hasPDF),
            Self.item(1, title: "Paywalled", ids: PaperIDs(doi: "10.1016/j.cell.2025.01.001"), pdf: .needsPDF),
            Self.item(2, title: "Done", pdf: .inLibrary, paperID: "p", status: .merged),
        ]
        #expect(R.matchDroppedPDF(ids: PaperIDs(), title: "Scanned PDF without a title", items: items, soleFallback: true)?.ord == 1)
        #expect(R.matchDroppedPDF(ids: PaperIDs(), title: nil, items: items, soleFallback: false) == nil)
        // The PDF's DOI says it is not that paper.
        #expect(R.matchDroppedPDF(ids: PaperIDs(doi: "10.1038/other"), title: nil, items: items, soleFallback: true) == nil)
    }

    // MARK: Drop zones

    @Test func rowsWinOverTheirCardAndTheListClips() {
        let zones = [
            R.DropZone(id: "card:a", rect: CGRect(x: 0, y: 0, width: 800, height: 300), priority: 0),
            R.DropZone(id: "item:1", rect: CGRect(x: 10, y: 100, width: 780, height: 40), priority: 1),
            R.DropZone(id: "item:2", rect: CGRect(x: 10, y: 150, width: 780, height: 60), priority: 1),
            R.DropZone(id: "card:b", rect: CGRect(x: 0, y: 320, width: 800, height: 200), priority: 0),
            R.DropZone(id: "item:empty", rect: .zero, priority: 1),
        ]
        let clip = CGRect(x: 0, y: 0, width: 800, height: 500)
        #expect(R.pick(CGPoint(x: 50, y: 120), zones: zones, clip: clip) == "item:1")
        #expect(R.pick(CGPoint(x: 50, y: 160), zones: zones, clip: clip) == "item:2")
        #expect(R.pick(CGPoint(x: 50, y: 20), zones: zones, clip: clip) == "card:a")
        #expect(R.pick(CGPoint(x: 50, y: 400), zones: zones, clip: clip) == "card:b")
        #expect(R.pick(CGPoint(x: 50, y: 510), zones: zones, clip: clip) == nil)       // scrolled out of the list
        #expect(R.pick(CGPoint(x: 50, y: 310), zones: zones, clip: clip) == nil)       // between cards
        #expect(R.pick(CGPoint(x: 0, y: 0), zones: [zones[4]], clip: nil) == nil)
        // Equal priority → the smaller zone.
        let nested = [R.DropZone(id: "big", rect: CGRect(x: 0, y: 0, width: 100, height: 100), priority: 1),
                      R.DropZone(id: "small", rect: CGRect(x: 10, y: 10, width: 20, height: 20), priority: 1)]
        #expect(R.pick(CGPoint(x: 15, y: 15), zones: nested, clip: nil) == "small")
    }

    // MARK: Inert text

    @Test func untrustedTextIsInert() {
        #expect(R.line("  Please\u{202E} read\n\nthis\u{200B} ") == "Please read this")
        #expect(R.line(String(repeating: "a", count: 400), limit: 10).count == 10)
        #expect(R.line(nil).isEmpty)
        let body = R.text("Hi\u{0007} Yi,\n\n\n\n\n\nsee [c1]\u{202E}\tnow")
        #expect(body == "Hi Yi,\n\n\nsee [c1]\tnow")
        #expect(R.text(String(repeating: "x", count: 50), limit: 20).count == 21)
    }
}
