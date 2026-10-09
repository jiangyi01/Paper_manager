import Foundation

// Persisted mail models (migration 2). Raw values are stored in SQLite — never change them.
// Design: docs/MAIL_DESIGN.md (Part A §1–§3; the user-decision block at the top wins).

/// Who sent a captured message, from the matching sender rule.
package enum SenderKind: String, Codable, Sendable, CaseIterable {
    case advisor        // advisor / PI — requests default to high priority
    case person         // collaborator or other person
    case alert          // journal / preprint alert, TOC, newsletter (public content)
    case manual         // dropped / imported .eml by the user (explicit intent, no rule)
}

/// Lifecycle of an email card in the Mail inbox.
package enum MailState: String, Codable, Sendable, CaseIterable {
    case pending, snoozed, merged, dismissed
    case noRequest = "no_request"      // triage found no paper-reading need (still visible under a filter)
}

/// AI triage progress for one message (separate lane from paper AI jobs).
package enum MailTriageState: String, Codable, Sendable, CaseIterable {
    case none           // not triaged by AI (heuristic result may exist)
    case awaitingConsent = "awaiting_consent"   // person sender: user must click 「让 AI 分析」
    case held           // agent.mode off / daily cap reached
    case queued, running, done, failed, skipped, limited
    case needsLogin = "needs_login"
}

package enum MailTriageSource: String, Codable, Sendable {
    case ai, heuristic
}

package enum MailRequestKind: String, Codable, Sendable, CaseIterable {
    case advisorRequest = "advisor_request"   // someone asks the user to read/present something
    case journalClub = "journal_club"
    case alertDigest = "alert_digest"         // alert/TOC listing several papers
    case fyi                                   // shared for information
    case other
    case notPaper = "not_paper"               // no paper-reading content
}

/// Where a candidate paper was found in the message.
///
/// `document` and `shareLink` came after the mail schema's CHECK list was frozen: the database
/// stores them as `attachment` / `link` plus the exact value in `mail_item.origin_ext`
/// (`Database+Mail`), so an older build reads such a row as an attachment / link that needs a PDF.
/// Decoding is lenient: an unknown value (a newer build's) reads as `link`.
package enum MailItemOrigin: String, Codable, Sendable, CaseIterable {
    case attachment     // PDF attached to the email
    case link           // URL in the body (arXiv, DOI, publisher, PDF link…)
    case identifier     // bare DOI / arXiv id in the text
    case citation       // title/authors only (e.g. from the AI), no link
    case alertEntry = "alert_entry"   // parsed entry of an alert digest
    case document       // Word / RTF / ODT / slides attachment (a manuscript, a draft) — `MailItem.documentKind`
    case shareLink = "share_link"     // SharePoint / OneDrive / Box / Google Drive / Dropbox link (sign-in needed)

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MailItemOrigin(rawValue: raw) ?? .link
    }

    /// The value the frozen `mail_item.origin` CHECK list accepts (the exact one goes to `origin_ext`).
    package var storedBase: MailItemOrigin {
        switch self {
        case .document: return .attachment
        case .shareLink: return .link
        default: return self
        }
    }
}

package enum MailItemFoundBy: String, Codable, Sendable {
    case local, ai, user
}

/// Whether we have (or can get) the PDF for a candidate.
///
/// `convertible` and `openOnly` are stored as `needs_pdf` plus the exact value in
/// `mail_item.pdf_state_ext` (the CHECK list is frozen), so an older build shows such a row as
/// waiting for a PDF. Decoding is lenient: an unknown value reads as `unknown`.
package enum MailPDFState: String, Codable, Sendable, CaseIterable {
    case unknown
    case hasPDF = "has_pdf"            // attachment or downloaded file is stored locally
    case downloadable                   // known open PDF URL (arXiv, direct .pdf, bioRxiv try-once)
    case downloading
    case needsPDF = "needs_pdf"         // user must download it and drop it on the row's drop box
    case inLibrary = "in_library"       // already a paper in the library (paperID set)
    case convertible                    // stored Word / RTF / ODT original: 「转换为 PDF 并合并」 converts it on this Mac
    case openOnly = "open_only"         // stored slides / Pages original: open it, export a PDF, drop it on the row

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MailPDFState(rawValue: raw) ?? .unknown
    }

    /// The value the frozen `mail_item.pdf_state` CHECK list accepts (the exact one goes to `pdf_state_ext`).
    package var storedBase: MailPDFState {
        switch self {
        case .convertible, .openOnly: return .needsPDF
        default: return self
        }
    }

    /// Waiting for a PDF the user brings (a drop on the row, or an import the matcher links).
    package var waitsForPDF: Bool {
        self == .needsPDF || self == .downloadable || self == .convertible || self == .openOnly
    }
}

package enum MailItemStatus: String, Codable, Sendable {
    case pending        // waiting for the user
    case merged         // imported into the library from this email
    case linked         // the paper already existed; provenance attached
    case skipped        // user chose not to add it
}

/// How strongly the email asks for this paper.
package enum MailItemRelevance: String, Codable, Sendable {
    case requested      // explicitly asked to read/present
    case highlighted    // recommended / relevant to the user's interests
    case listed         // just listed (e.g. other entries of an alert)
}

/// DKIM/DMARC result parsed from Authentication-Results headers when available.
package enum MailAuthState: String, Codable, Sendable {
    case pass, fail, unknown
}

/// One captured email (row of `mail_message`).
package struct MailMessage: Sendable, Identifiable, Equatable {
    package var pk: Int64
    package var id: String                      // lowercase UUID (paperdeck://mail/<id>)
    package var accountID: String               // MailAccount.id, or "manual" for dropped .eml
    package var sourceRef: String?              // transport id: IMAP "<mailbox>:<uidvalidity>:<uid>", folder file name…
    package var internetMessageID: String       // normalized Message-ID (dedupe key across sources)
    package var fromAddress: String             // lowercased address part only
    package var fromName: String?
    package var ruleID: String?                 // matched SenderRule.id (nil for manual drops)
    package var senderKind: SenderKind
    package var authState: MailAuthState
    package var subject: String
    package var receivedAt: Date
    package var webLink: String?                // "open in Outlook/Gmail on the web" when known
    package var snippet: String?                // ≤ 255 chars, sanitized
    package var bodyText: String?               // sanitized plain text, capped (URLs keep [cN] markers)
    package var bodyPurged: Bool                // retention removed body/snippet
    package var state: MailState
    package var userTouched: Bool               // AI may never change state after a user action
    package var snoozedUntil: Date?
    package var triageState: MailTriageState
    package var triageSource: MailTriageSource?
    package var triage: MailTriage?             // sanitized result (AI or heuristic)
    package var triageAttempt: Int
    package var triageNotBefore: Date?
    package var triageError: String?
    package var triageProvider: String?         // "claude" | "codex" | "mock"
    package var triageModel: String?
    package var triageMs: Int?
    package var triageInputTokens: Int?
    package var triageOutputTokens: Int?
    package var triageStdinBytes: Int?
    /// 「让 AI 分析」 was clicked for this email (the per-email consent): its AI triage may run while
    /// the sender's policy is `ask`, but only on `triageConsentProvider` — the provider the
    /// card named when the user agreed. Written by `MailTriageCoordinator.requestAI` only;
    /// cleared when the consent no longer applies (another provider, a dismissed card).
    package var triageConsented: Bool
    package var triageConsentProvider: String?  // AIProviderKind raw value ("claude" | "codex")
    /// Mailing-list mail (`MailSyncActor.isBulk`: List-Id / List-Unsubscribe) — an alert service's
    /// digest. False for an alert-domain message that isn't (an editor's or a person's own mail
    /// from a journal's domain): its titles wait for 「让 AI 分析」 like a person's
    /// (`MailSyncActor.mayLookUpTitles`). Nil for messages captured before this was recorded.
    package var isBulk: Bool?
    package var seen: Bool
    package var createdAt: Date
    package var updatedAt: Date
    package var handledAt: Date?

    package init(pk: Int64 = 0, id: String = UUID().uuidString.lowercased(), accountID: String,
                 sourceRef: String? = nil, internetMessageID: String, fromAddress: String, fromName: String? = nil,
                 ruleID: String? = nil, senderKind: SenderKind, authState: MailAuthState = .unknown,
                 subject: String, receivedAt: Date, webLink: String? = nil, snippet: String? = nil,
                 bodyText: String? = nil, bodyPurged: Bool = false, state: MailState = .pending,
                 userTouched: Bool = false, snoozedUntil: Date? = nil, triageState: MailTriageState = .none,
                 triageSource: MailTriageSource? = nil, triage: MailTriage? = nil, triageAttempt: Int = 0,
                 triageNotBefore: Date? = nil, triageError: String? = nil, triageProvider: String? = nil,
                 triageModel: String? = nil, triageMs: Int? = nil, triageInputTokens: Int? = nil,
                 triageOutputTokens: Int? = nil, triageStdinBytes: Int? = nil, seen: Bool = false,
                 createdAt: Date = Date(), updatedAt: Date = Date(), handledAt: Date? = nil,
                 triageConsented: Bool = false, triageConsentProvider: String? = nil, isBulk: Bool? = nil) {
        self.pk = pk; self.id = id; self.accountID = accountID; self.sourceRef = sourceRef
        self.internetMessageID = internetMessageID; self.fromAddress = fromAddress; self.fromName = fromName
        self.ruleID = ruleID; self.senderKind = senderKind; self.authState = authState; self.subject = subject
        self.receivedAt = receivedAt; self.webLink = webLink; self.snippet = snippet; self.bodyText = bodyText
        self.bodyPurged = bodyPurged; self.state = state; self.userTouched = userTouched
        self.snoozedUntil = snoozedUntil; self.triageState = triageState; self.triageSource = triageSource
        self.triage = triage; self.triageAttempt = triageAttempt; self.triageNotBefore = triageNotBefore
        self.triageError = triageError; self.triageProvider = triageProvider; self.triageModel = triageModel
        self.triageMs = triageMs; self.triageInputTokens = triageInputTokens
        self.triageOutputTokens = triageOutputTokens; self.triageStdinBytes = triageStdinBytes
        self.seen = seen; self.createdAt = createdAt; self.updatedAt = updatedAt; self.handledAt = handledAt
        self.triageConsented = triageConsented; self.triageConsentProvider = triageConsentProvider
        self.isBulk = isBulk
    }

    package var isOpen: Bool { state == .pending || state == .snoozed }
}

/// Sanitized triage result (stored as JSON in `mail_message.triage_json`).
package struct MailTriage: Codable, Sendable, Equatable {
    package var hasReadingRequest: Bool
    package var requestKind: MailRequestKind
    package var summary: String                 // ≤ 2 plain sentences (English)
    package var requester: String?
    package var dueDate: LocalDate?             // only with evidence; applied only on the user's merge
    package var dueEvidence: String?            // verbatim phrase from the email
    package var dueConfidence: Double?          // 0…1
    package var priority: Priority              // high only for person/advisor senders
    package var confidence: Double              // overall: is this a reading request? (0…1)

    package init(hasReadingRequest: Bool, requestKind: MailRequestKind, summary: String, requester: String? = nil,
                 dueDate: LocalDate? = nil, dueEvidence: String? = nil, dueConfidence: Double? = nil,
                 priority: Priority = .normal, confidence: Double = 0.5) {
        self.hasReadingRequest = hasReadingRequest; self.requestKind = requestKind; self.summary = summary
        self.requester = requester; self.dueDate = dueDate; self.dueEvidence = dueEvidence
        self.dueConfidence = dueConfidence; self.priority = priority; self.confidence = confidence
    }
}

/// A candidate paper inside a message (row of `mail_item`).
package struct MailItem: Sendable, Identifiable, Equatable {
    package var pk: Int64
    package var id: String                      // lowercase UUID
    package var messagePK: Int64
    package var ord: Int
    package var cand: String                    // "c1", "c2"… — the id the AI references
    package var origin: MailItemOrigin
    package var foundBy: MailItemFoundBy
    package var title: String?
    package var authors: [String]
    package var venue: String?
    package var year: Int?
    package var ids: PaperIDs                   // doi / arXiv / pii (reuse library identity rules)
    package var url: String?                    // unwrapped canonical URL (identification only)
    package var urlOriginal: String?            // as in the mail (Safe Links etc.) — used for 「打开链接」
    package var host: String?
    package var metaSource: MetaSource
    package var relevance: MailItemRelevance?
    package var why: String?
    package var confidence: Double?
    package var pdfState: MailPDFState
    package var pdfPath: String?                // relative to AppPaths.mailFiles
    package var pdfSHA256: String?
    package var pdfBytes: Int64?
    package var downloadError: String?
    package var paperID: String?                // soft ref to paper.id once merged/linked/in library
    package var status: MailItemStatus
    package var createdAt: Date
    package var updatedAt: Date
    /// `document` rows: the attachment's original file name (sanitized), e.g. "Lab_manuscript_v3.docx".
    package var documentFileName: String?
    /// `document` rows: the lowercase extension ("docx", "doc", "rtf", "odt" → `convertible`; "pptx", "ppt",
    /// "key", "pages", "odp" → `openOnly`). `shareLink` rows: only when the URL tells ("docx", "pptx", "pdf").
    package var documentKind: String?
    /// `shareLink` rows: the file-sharing service (`MailShareProvider` raw value, e.g. "sharepoint.com").
    package var shareHost: String?
    /// `document` rows: the stored original, relative to `AppPaths.mailFiles` (`<message-id>/<n>.<ext>`);
    /// nil when it was not stored (too large, sender rule) or after the merge / retention removed it.
    package var documentPath: String?
    /// SHA-256 of the stored original (a document converted before links instead of converting again).
    package var documentSHA256: String?

    package init(pk: Int64 = 0, id: String = UUID().uuidString.lowercased(), messagePK: Int64 = 0, ord: Int,
                 cand: String, origin: MailItemOrigin, foundBy: MailItemFoundBy = .local, title: String? = nil,
                 authors: [String] = [], venue: String? = nil, year: Int? = nil, ids: PaperIDs = PaperIDs(),
                 url: String? = nil, urlOriginal: String? = nil, host: String? = nil, metaSource: MetaSource = .none,
                 relevance: MailItemRelevance? = nil, why: String? = nil, confidence: Double? = nil,
                 pdfState: MailPDFState = .unknown, pdfPath: String? = nil, pdfSHA256: String? = nil,
                 pdfBytes: Int64? = nil, downloadError: String? = nil, paperID: String? = nil,
                 status: MailItemStatus = .pending, createdAt: Date = Date(), updatedAt: Date = Date(),
                 documentFileName: String? = nil, documentKind: String? = nil, shareHost: String? = nil,
                 documentPath: String? = nil, documentSHA256: String? = nil) {
        self.pk = pk; self.id = id; self.messagePK = messagePK; self.ord = ord; self.cand = cand
        self.origin = origin; self.foundBy = foundBy; self.title = title; self.authors = authors
        self.venue = venue; self.year = year; self.ids = ids; self.url = url; self.urlOriginal = urlOriginal
        self.host = host; self.metaSource = metaSource; self.relevance = relevance; self.why = why
        self.confidence = confidence; self.pdfState = pdfState; self.pdfPath = pdfPath
        self.pdfSHA256 = pdfSHA256; self.pdfBytes = pdfBytes; self.downloadError = downloadError
        self.paperID = paperID; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.documentFileName = documentFileName; self.documentKind = documentKind; self.shareHost = shareHost
        self.documentPath = documentPath; self.documentSHA256 = documentSHA256
    }

    package var isOpen: Bool { status == .pending }
}

/// Provenance of a library paper that came from an email (row of `paper_source`,
/// mirrored into card.json as an optional "provenance" array).
package struct PaperProvenance: Codable, Sendable, Equatable {
    package var kind: String                    // "email"
    package var mailMessageID: String?
    package var internetMessageID: String?
    package var fromAddress: String?
    package var fromName: String?
    package var subject: String?
    package var receivedAt: Date?
    package var webLink: String?
    package var requestKind: MailRequestKind?
    package var summary: String?
    package var dueHint: LocalDate?
    package var addedAt: Date
    /// The email's original document (a .docx the paper was converted from), kept next to the PDF in
    /// the paper folder under this file name ("<pdf stem>.source.docx"); nil for everything else.
    package var document: String?

    package init(kind: String = "email", mailMessageID: String? = nil, internetMessageID: String? = nil,
                 fromAddress: String? = nil, fromName: String? = nil, subject: String? = nil,
                 receivedAt: Date? = nil, webLink: String? = nil, requestKind: MailRequestKind? = nil,
                 summary: String? = nil, dueHint: LocalDate? = nil, addedAt: Date = Date(), document: String? = nil) {
        self.kind = kind; self.mailMessageID = mailMessageID; self.internetMessageID = internetMessageID
        self.fromAddress = fromAddress; self.fromName = fromName; self.subject = subject
        self.receivedAt = receivedAt; self.webLink = webLink; self.requestKind = requestKind
        self.summary = summary; self.dueHint = dueHint; self.addedAt = addedAt; self.document = document
    }
}
