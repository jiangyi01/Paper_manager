import Foundation
import PaperDeckCore

/// What PaperDeck would do with one parsed email, computed locally with the same Core steps as
/// a capture (`MailExtractor` → `MailHeuristics` → rows → initial triage state) and the exact
/// triage stdin `MailTriageCoordinator` builds (`MailTriageSchema.stdin`, before metadata
/// lookups enrich the rows). Pure: no network, no spawn, nothing stored. Used by
/// `--mail-dry-run` and Settings ▸ Mail ▸ 「显示发送给 AI 的内容示例」.
nonisolated enum MailTriagePreview {
    nonisolated struct Result: Sendable {
        var rule: SenderRule?
        var kind: SenderKind
        var extraction: MailExtraction
        var heuristic: MailTriage
        var items: [MailItem]
        /// State when an account sync captures it (allowlisted senders only).
        var syncedState: MailState
        /// State when the user drops / imports the file (always pending).
        var droppedState: MailState
        var syncedTriage: MailTriageState
        var droppedTriage: MailTriageState
        var stdin: Data
        var provider: AIProviderKind
        var model: String
        var route: MailTriageRoute

        var stdinText: String { String(decoding: stdin, as: UTF8.self) }
    }

    /// First-page information of a stored PDF attachment (what the triage `<attachments>` block carries).
    nonisolated struct Page: Sendable, Equatable {
        var title: String?
        var ids: PaperIDs = PaperIDs()
        var text: String
    }

    /// - `stored`: attachment indexes that were stored as PDFs (`has_pdf`); `rejected`: why the
    ///   others were not. Indexes in neither follow the parsed data (bytes present → `has_pdf`).
    /// - `pages`: first-page information of stored attachments by index.
    static func run(content: MailContent, rule: SenderRule?, settings: MailSettings, engineSettings: EngineSettings,
                    categories: [String], frequentTags: [String], now: Date, calendar: Calendar,
                    stored: Set<Int> = [], rejected: [Int: MailPDFFetcher.Rejection] = [:],
                    pages: [Int: Page] = [:]) -> Result {
        let lang = engineSettings.lang
        let kind: SenderKind = rule.map { $0.kind == .manual ? .person : $0.kind } ?? .manual
        let criteria = settings.criteria
        let extraction = MailExtractor.extract(content, senderKind: kind, bodyCap: MailExtractor.defaultBodyCap)
        let (heuristic, relevance) = MailHeuristics.triage(content: content, extraction: extraction, senderKind: kind,
                                                           criteria: criteria, now: now, calendar: calendar, lang: lang,
                                                           dateOrder: settings.dateOrder)
        let capMB = max(1, settings.maxAttachmentMB)
        var items: [MailItem] = []
        var attachments: [MailTriageSchema.Attachment] = []
        for (i, c) in extraction.candidates.enumerated() {
            // Document and shared-file candidates keep their state (convertible / open-only / needs a
            // PDF) and file facts; only PDF attachments take the branch below.
            var item = MailItem(pk: Int64(i + 1), ord: i + 1, cand: c.cand, origin: c.origin, foundBy: .local,
                                title: c.title, authors: c.authors, ids: c.ids, url: c.url, urlOriginal: c.urlOriginal,
                                host: c.host, relevance: relevance[c.cand] ?? .listed, pdfState: c.pdfState,
                                createdAt: now, updatedAt: now, documentFileName: c.documentFileName,
                                documentKind: c.documentKind, shareHost: c.shareHost)
            if c.origin == .attachment, let index = c.attachmentIndex, content.attachments.indices.contains(index) {
                let attachment = content.attachments[index]
                if let why = rejected[index] {
                    item.pdfState = .needsPDF
                    item.downloadError = why.message(lang, capMB: capMB)
                } else if stored.contains(index) || attachment.data != nil {
                    item.pdfState = .hasPDF
                } else {
                    item.pdfState = .needsPDF
                }
                item.pdfBytes = Int64(attachment.sizeBytes)
                if item.title == nil { item.title = attachmentTitle(attachment.filename) }
                // Post-processing reads the stored PDF's first page before triage: ids + a local title.
                if item.pdfState == .hasPDF, let page = pages[index] {
                    item.ids = item.ids.merged(with: page.ids)
                    if let t = page.title { item.title = t; item.metaSource = .pdf }
                }
                if item.pdfState == .hasPDF, attachments.count < MailTriageSchema.maxAttachments {
                    let page = pages[index]
                    attachments.append(MailTriageSchema.Attachment(ref: item.cand, title: item.title ?? page?.title,
                                                                   abstract: page.flatMap { $0.text.isEmpty ? nil : $0.text }))
                }
            } else if item.pdfState == .unknown {
                item.pdfState = MailPDFFetcher.availability(ids: item.ids, url: item.url, host: item.host)
            }
            items.append(item)
        }

        // The capture's own rule (a person's / advisor's document or shared-file mail stays pending).
        let synced = MailSyncActor.capturedState(manual: false, heuristic: heuristic, candidates: extraction.candidates,
                                                 senderKind: kind, criteria: criteria)
        // As the capture decides it: a failed DMARC / DKIM check never auto-triages, an alert /
        // always rule auto-triages mailing-list mail only, and confidential mail (reviewer
        // invitations, manuscript / submission systems) never (MailSyncActor passes the same facts).
        let authState = MIMEParser.authState(content.header.authResults ?? content.headers["authentication-results"])
        let bulk = Self.isBulk(content.headers)
        let confidential = MailHeuristics.isConfidential(content, bodyText: extraction.bodyText)
        let syncedTriage = MailTriageCoordinator.initialState(senderKind: kind, rule: rule,
                                                              candidates: extraction.candidates.count, settings: settings,
                                                              authState: authState, isBulk: bulk, confidential: confidential)

        // The stored message, as MailTriageCoordinator.buildJob reads it back.
        let message = MailMessage(accountID: "dry-run", internetMessageID: content.header.internetMessageID ?? "<dry-run>",
                                  fromAddress: content.header.fromAddress.lowercased(), fromName: content.header.fromName,
                                  ruleID: rule?.id, senderKind: kind, subject: content.header.subject,
                                  receivedAt: content.header.receivedAt,
                                  snippet: extraction.snippet.isEmpty ? nil : extraction.snippet,
                                  bodyText: extraction.bodyText, state: synced, triage: heuristic)
        let body = message.bodyText ?? ""
        let forwarded = body.hasPrefix(MailExtractor.forwardedLabel + "\n")
            || body.contains("\n" + MailExtractor.forwardedLabel + "\n")
        let stored = MailExtraction(bodyText: body, snippet: message.snippet ?? "", candidates: [], isForwarded: forwarded)
        let stdin = MailTriageSchema.stdin(message: message, extraction: stored, candidates: items, criteria: criteria,
                                           categories: categories, frequentTags: frequentTags, attachments: attachments,
                                           bodyCap: settings.triageBodyCap, calendar: calendar)
        let provider = settings.triageProvider ?? engineSettings.selectedProvider
        let request = MailTriageSchema.request(stdin: stdin, provider: provider, settings: settings)
        return Result(rule: rule, kind: kind, extraction: extraction, heuristic: heuristic, items: items,
                      syncedState: synced, droppedState: .pending, syncedTriage: syncedTriage,
                      droppedTriage: MailTriageCoordinator.initialState(senderKind: kind, rule: rule,
                                                                        candidates: extraction.candidates.count,
                                                                        settings: settings, authState: authState,
                                                                        isBulk: bulk, confidential: confidential),
                      stdin: stdin, provider: provider, model: request.model,
                      route: MailTriageRoute.of(provider: settings.triageProvider, settings: engineSettings))
    }

    /// Mailing-list mail (the only mail an alert / always rule may auto-triage), decided by the
    /// capture's own rule (`MailSyncActor.isBulk`) so the preview never differs from a real sync.
    /// `headers`: `MailContent.headers` (lowercased names).
    static func isBulk(_ headers: [String: String]) -> Bool {
        MailSyncActor.isBulk(headers)       // the capture's own rule (one implementation)
    }

    /// `neocortex_dynamics.pdf` → `neocortex dynamics` (the capture's fallback row title).
    static func attachmentTitle(_ filename: String?) -> String? {
        guard var name = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        name = name.replacingOccurrences(of: "_", with: " ")
        name = CardSanitizer.clean(name)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    // MARK: Sample (Settings ▸ Mail ▸ 显示发送给 AI 的内容示例)

    /// A made-up advisor email (attachment + a bioRxiv link + a phone number and another
    /// address that the redaction removes) run through the real pipeline with the user's settings.
    static func sample(settings: MailSettings, engineSettings: EngineSettings, categories: [String],
                       frequentTags: [String], now: Date = Date(), calendar: Calendar = .current) -> Result {
        let header = MailHeader(ref: "sample", internetMessageID: "<sample-request@paperdeck.local>",
                                fromAddress: "advisor@university.edu", fromName: "Prof. A. Advisor",
                                subject: "Paper for Thursday's lab meeting", receivedAt: now)
        let text = """
        Hi,

        Please read the attached paper before Thursday's lab meeting and be ready to present Fig. 2. \
        The companion preprint is here: https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2

        If anything is unclear, call me at +1 (314) 555-0199 or email the lab manager at lab.manager@university.edu.

        Thanks,
        A.

        --
        Prof. A. Advisor
        Department of Neuroscience · Phone (314) 555-0123
        """
        let attachment = MailAttachment(filename: "Molecular_and_cellular_dynamics_of_the_developing_human_neocortex.pdf",
                                        contentType: "application/pdf", isInline: false, data: nil, sizeBytes: 4_200_000)
        let content = MailContent(header: header, plainText: text, html: nil, attachments: [attachment])
        let rule = SenderRule(id: "sample-advisor", pattern: "advisor@university.edu", label: "Prof. A. Advisor", kind: .advisor)
        var s = settings
        if !s.senders.contains(where: { $0.id == rule.id }) { s.senders.append(rule) }
        let page = Page(title: "Molecular and cellular dynamics of the developing human neocortex",
                        text: "Abstract — the first page of an attached PDF (up to 2,000 characters) is sent here.")
        return run(content: content, rule: rule, settings: s, engineSettings: engineSettings, categories: categories,
                   frequentTags: frequentTags, now: now, calendar: calendar, stored: [0], pages: [0: page])
    }
}
