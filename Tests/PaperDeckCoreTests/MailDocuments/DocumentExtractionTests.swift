import Foundation
import Testing
@testable import PaperDeckCore

/// Local extraction + triage of documents and shared-file links (no AI, no network).
@Suite struct DocumentExtractionTests {
    private let calendar = MailParseFixture.chicago
    private let now = MailParseFixture.date("2026-09-29T16:00:00Z")

    private func run(_ data: Data, kind: SenderKind, criteria: ReadingCriteria = ReadingCriteria())
        throws -> (MailContent, MailExtraction, MailTriage, [String: MailItemRelevance]) {
        let content = try MIMEParser.parse(data, maxAttachmentBytes: 50 << 20)
        let x = MailExtractor.extract(content, senderKind: kind, bodyCap: 12_000)
        let (t, r) = MailHeuristics.triage(content: content, extraction: x, senderKind: kind, criteria: criteria,
                                           now: now, calendar: calendar)
        return (content, x, t, r)
    }

    /// The reported mail, synthesized: an advisor's .docx manuscript + four Safe-Links-wrapped
    /// SharePoint links and no request phrase used to land in 「无阅读需求」.
    @Test func theAdvisorsManuscriptMailIsAReadingCandidate() throws {
        let (_, x, t, r) = try run(try DocKit.advisorManuscriptEML(), kind: .advisor)
        let docs = x.candidates.filter { $0.origin == .document }
        let shares = x.candidates.filter { $0.origin == .shareLink }
        #expect(docs.count == 1 && shares.count == 4)
        #expect(x.candidates.first?.origin == .document)                    // attachments first: c1
        let d = try #require(docs.first)
        #expect(d.cand == "c1" && d.documentKind == "docx" && d.pdfState == .convertible)
        #expect(d.documentFileName == "Smith_lab_manuscript_v3.docx" && d.title == "Smith lab manuscript v3")
        #expect(shares.allSatisfy { $0.shareHost == "sharepoint.com" && $0.pdfState == .needsPDF
                && $0.urlOriginal?.contains("safelinks.protection.outlook.com") == true
                && $0.url?.hasPrefix("https://gowustl-my.sharepoint.com/") == true })
        #expect(Set(shares.compactMap(\.documentKind)) == ["docx", "pdf"])
        // The body names the links by their rows, never by URL.
        #expect(x.bodyText.contains("[c2 gowustl-my.sharepoint.com]"))
        #expect(!x.bodyText.contains("safelinks") && !x.bodyText.contains("https://"))
        // Triage: an FYI from the advisor (no phrase), kept in 待处理 — also when FYI isn't a kept kind.
        #expect(t.requestKind == .fyi && t.confidence == 0.6)
        #expect(r["c1"] == .highlighted)
        #expect(MailSyncActor.capturedState(manual: false, heuristic: t, candidates: x.candidates, senderKind: .advisor,
                                            criteria: ReadingCriteria()) == .pending)
        let strict = ReadingCriteria(keepKinds: [.advisorRequest, .journalClub])
        #expect(MailSyncActor.capturedState(manual: false, heuristic: t, candidates: x.candidates, senderKind: .advisor,
                                            criteria: strict) == .pending)
    }

    @Test func aRequestPhraseMakesItAnAdvisorRequestWithTheDocumentRequested() throws {
        let data = DocKit.eml(body: "Could you read the attached manuscript before our lab meeting on Friday?",
                              attachments: [.init(name: "draft.docx", type: DocKit.docxType, data: try DocKit.docx(paragraphs: 2))])
        let (_, x, t, r) = try run(data, kind: .advisor)
        #expect(t.requestKind == .journalClub || t.requestKind == .advisorRequest)
        #expect(t.hasReadingRequest && t.priority == .high)
        #expect(r[try #require(x.candidates.first { $0.origin == .document }).cand] == .requested)
    }

    @Test func slidesAreOpenOnlyAndAMissingBodyNeedsAPDF() throws {
        let data = DocKit.eml(from: "postdoc@wustl.edu", attachments: [.init(name: "talk.pptx", type: DocKit.pptxType, data: DocKit.zipStub())])
        let (_, x, _, _) = try run(data, kind: .person)
        let d = try #require(x.candidates.first)
        #expect(d.origin == .document && d.documentKind == "pptx" && d.pdfState == .openOnly)
        // Over the parser's attachment cap the bytes are not kept: the row needs a PDF.
        let content = try MIMEParser.parse(data, maxAttachmentBytes: 8)
        let y = MailExtractor.extract(content, senderKind: .person, bodyCap: 12_000)
        #expect(y.candidates.first?.pdfState == .needsPDF)
    }

    /// Alert services never yield document or shared-file rows (their links keep the old rules).
    @Test func alertMailIgnoresDocumentsAndShareLinks() throws {
        let data = DocKit.eml(from: "alerts@biorxiv.org", links: DocKit.sharepointLinks,
                              attachments: [.init(name: "toc.docx", type: DocKit.docxType, data: try DocKit.docx(paragraphs: 1))],
                              listID: true)
        let (_, x, _, _) = try run(data, kind: .alert)
        #expect(!x.candidates.contains { $0.origin == .document || $0.origin == .shareLink })
        #expect(x.candidates.allSatisfy { $0.pdfState != .downloadable })      // a ":b:" share link: never downloaded
    }

    @Test func spreadsheetsInlineImagesAndPlainMailStayNoRequest() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 1, count: 64))
        let data = DocKit.eml(from: "postdoc@wustl.edu", body: "Lunch on Thursday?",
                              attachments: [.init(name: "budget.xlsx", type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                                  data: DocKit.zipStub()),
                                            .init(name: "logo.png", type: "image/png", data: png, inline: true)])
        let (_, x, t, _) = try run(data, kind: .person)
        #expect(x.candidates.isEmpty && t.requestKind == .notPaper)
        #expect(MailSyncActor.capturedState(manual: false, heuristic: t, candidates: x.candidates, senderKind: .person,
                                            criteria: ReadingCriteria()) == .noRequest)
    }

    /// The user's exclude keywords still win over the document rule.
    @Test func excludeKeywordsStillDecide() throws {
        let data = DocKit.eml(subject: "Seminar flyer", body: "Seminar flyer attached.",
                              attachments: [.init(name: "flyer.docx", type: DocKit.docxType, data: try DocKit.docx(paragraphs: 1))])
        let criteria = ReadingCriteria(excludeKeywords: ["seminar"])
        let (_, x, t, _) = try run(data, kind: .person, criteria: criteria)
        #expect(t.requestKind == .notPaper)
        #expect(!MailHeuristics.keepsDocumentPending(t, candidates: x.candidates, senderKind: .person))
        #expect(MailSyncActor.capturedState(manual: false, heuristic: t, candidates: x.candidates, senderKind: .person,
                                            criteria: criteria) == .noRequest)
    }

    @Test func documentRuleIsForPeopleOnly() {
        let t = MailTriage(hasReadingRequest: false, requestKind: .fyi, summary: "s")
        let doc = [MailCandidate(cand: "c1", origin: .document)], share = [MailCandidate(cand: "c1", origin: .shareLink)]
        let link = [MailCandidate(cand: "c1", origin: .link)]
        #expect(MailHeuristics.keepsDocumentPending(t, candidates: doc, senderKind: .advisor))
        #expect(MailHeuristics.keepsDocumentPending(t, candidates: share, senderKind: .person))
        #expect(!MailHeuristics.keepsDocumentPending(t, candidates: link, senderKind: .person))
        #expect(!MailHeuristics.keepsDocumentPending(t, candidates: doc, senderKind: .alert))
        #expect(!MailHeuristics.keepsDocumentPending(t, candidates: doc, senderKind: .manual))
        // A dropped .eml is always pending anyway.
        #expect(MailSyncActor.capturedState(manual: true, heuristic: MailTriage(hasReadingRequest: false, requestKind: .notPaper, summary: ""),
                                            candidates: [], senderKind: .manual, criteria: ReadingCriteria()) == .pending)
    }

    @Test func documentTitlesFromFileNames() {
        #expect(MailExtractor.documentTitle("Lab_manuscript_v3.docx") == "Lab manuscript v3")
        #expect(MailExtractor.documentTitle("Talk.PPTX") == "Talk")
        #expect(MailExtractor.documentTitle("archive.tar.gz") == "archive.tar.gz")
        #expect(MailExtractor.documentTitle("  ") == nil && MailExtractor.documentTitle(nil) == nil)
    }
}
