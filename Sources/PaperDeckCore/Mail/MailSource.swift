import Foundation

// Transport contract. Two phases so "only allowlisted senders ever get their body read"
// is structural: phase 1 lists headers, the engine filters them locally with SenderMatcher,
// and only then asks for phase 2 (full message) of the allowlisted ones.

package enum MailSourceStatus: Sendable, Equatable {
    case ready(detail: String)                  // e.g. "3 new files", "Signed in as me@gmail.com"
    case needsSetup(String)                     // folder missing, no password in Keychain…
    case authFailed(String)                     // IMAP LOGIN rejected (app password revoked?)
    case unavailable(String)                    // network down, folder offline, server error
}

/// A source status worded at display time: the same facts in either UI language, so Settings ▸
/// Mail ▸ Accounts follows a language switch without asking the transport again (an IMAP
/// sign-in) or rebuilding it.
package struct MailLocalizedStatus: Sendable {
    package let render: @Sendable (UILang) -> MailSourceStatus
    package init(_ render: @escaping @Sendable (UILang) -> MailSourceStatus) { self.render = render }
    /// A status whose text does not depend on the language (or is already worded).
    package static func fixed(_ status: MailSourceStatus) -> MailLocalizedStatus { MailLocalizedStatus { _ in status } }
}

/// What `MailSource.deferral` kept listable: the cursor to save, and the refs a retry-list cap
/// dropped (never listed again by themselves).
package struct MailDeferral: Sendable, Equatable {
    package var cursor: MailCursor
    package var dropped: [String]
    package init(cursor: MailCursor, dropped: [String] = []) { self.cursor = cursor; self.dropped = dropped }
}

/// Opaque resume point per account (IMAP: UIDVALIDITY + last UID; folder: processed-file ledger key).
package struct MailCursor: Codable, Sendable, Equatable {
    package var value: String
    package init(_ value: String) { self.value = value }
}

/// Phase-1 record: headers only.
package struct MailHeader: Sendable, Equatable {
    package var ref: String                     // transport ref to fetch the full message
    package var internetMessageID: String?      // normalized "<…>" lowercased, when present
    package var fromAddress: String             // address part, lowercased
    package var fromName: String?
    package var senderAddress: String?          // Sender: header when different
    package var subject: String
    package var receivedAt: Date
    package var sizeBytes: Int?
    package var hasAttachments: Bool?
    package var authResults: String?            // raw Authentication-Results header (DKIM/DMARC)

    package init(ref: String, internetMessageID: String?, fromAddress: String, fromName: String?,
                 senderAddress: String? = nil, subject: String, receivedAt: Date, sizeBytes: Int? = nil,
                 hasAttachments: Bool? = nil, authResults: String? = nil) {
        self.ref = ref; self.internetMessageID = internetMessageID; self.fromAddress = fromAddress
        self.fromName = fromName; self.senderAddress = senderAddress; self.subject = subject
        self.receivedAt = receivedAt; self.sizeBytes = sizeBytes; self.hasAttachments = hasAttachments
        self.authResults = authResults
    }
}

package struct MailHeaderPage: Sendable, Equatable {
    package var headers: [MailHeader]
    package var nextCursor: MailCursor?         // persist only after the batch was committed
    package var hasMore: Bool
    /// Files in the source that were read and are not RFC 822 messages (folder source: an
    /// HTML-only Power Automate export, an empty file…); nil when the transport can't tell.
    package var notEmailFiles: Int?
    /// Which files those are, as the source's hashed names (folder: `FolderLedger.key`), so the
    /// engine can tell the ones the user chose to ignore from new ones; nil when the transport
    /// can't tell (then `notEmailFiles` counts them all).
    package var notEmailKeys: Set<String>?
    package init(headers: [MailHeader], nextCursor: MailCursor?, hasMore: Bool, notEmailFiles: Int? = nil,
                 notEmailKeys: Set<String>? = nil) {
        self.headers = headers; self.nextCursor = nextCursor; self.hasMore = hasMore
        self.notEmailFiles = notEmailFiles
        self.notEmailKeys = notEmailKeys
    }
}

/// An attachment part of a parsed message.
package struct MailAttachment: Sendable, Equatable {
    package var filename: String?
    package var contentType: String             // lowercased MIME type
    package var isInline: Bool
    package var data: Data?                     // decoded bytes (nil when too large / not fetched)
    package var sizeBytes: Int
    package init(filename: String?, contentType: String, isInline: Bool, data: Data?, sizeBytes: Int) {
        self.filename = filename; self.contentType = contentType; self.isInline = isInline
        self.data = data; self.sizeBytes = sizeBytes
    }

    package var looksLikePDF: Bool {
        contentType == "application/pdf" || (filename?.lowercased().hasSuffix(".pdf") ?? false)
    }
}

/// Phase-2 record: a fully parsed message (from IMAP BODY.PEEK[] or an .eml file).
package struct MailContent: Sendable, Equatable {
    package var header: MailHeader
    package var plainText: String?              // text/plain part (decoded)
    package var html: String?                   // text/html part (decoded)
    package var attachments: [MailAttachment]
    package var headers: [String: String]       // selected raw headers (lowercased names)
    package init(header: MailHeader, plainText: String?, html: String?, attachments: [MailAttachment],
                 headers: [String: String] = [:]) {
        self.header = header; self.plainText = plainText; self.html = html
        self.attachments = attachments; self.headers = headers
    }
}

package protocol MailSource: Sendable {
    var accountID: String { get }
    func status() async -> MailSourceStatus
    /// `status()`, renderable in either UI language (default: the text `status()` returns).
    func localizedStatus() async -> MailLocalizedStatus
    /// Headers of messages newer than `since` (or within the account's lookback when nil).
    func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage
    /// Full message for an allowlisted header. Must be read-only (IMAP: EXAMINE + BODY.PEEK).
    func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent
    /// Optional post-capture hook (folder source may delete processed files when configured).
    func didCapture(_ header: MailHeader) async
    /// The cursor to save when some listed (allowlisted) messages could not be fetched yet:
    /// `refs` must come back from a later `listHeaders(since:)` that starts at the returned
    /// cursor (folder: their ledger entries are dropped, so the files are new again; IMAP: their
    /// UIDs ride along in the cursor's retry list). Nil when the transport can't keep a message
    /// listable — the engine then gives the message up after its fetch attempts, as before.
    func deferring(_ refs: [String], in cursor: MailCursor) async -> MailCursor?
    /// `deferring`, plus the refs it could not keep listable (a cap on the cursor's retry list
    /// was reached): the engine counts them on the account instead of dropping them silently.
    func deferral(_ refs: [String], in cursor: MailCursor) async -> MailDeferral?
    /// The account's stored cursor, before the first `status()` of a sync pass (folder: which
    /// files are known not to be emails, so the status counts real messages only).
    func prime(cursor: MailCursor?) async
    /// The cursor a re-list of the account's look-back starts from (「立即同步」 after messages were
    /// skipped, a sender list that grew): like starting without a cursor — the whole look-back is
    /// listed again — except that `cursor`'s retry list stays listable, deferred messages older
    /// than the look-back included (IMAP: its retry UIDs; folder: its retry keys). Nil (the
    /// default, and without a look-back): the engine starts without a cursor.
    func relisting(_ cursor: MailCursor) async -> MailCursor?
}

package extension MailSource {
    func localizedStatus() async -> MailLocalizedStatus { .fixed(await status()) }
    func didCapture(_ header: MailHeader) async {}
    func deferring(_ refs: [String], in cursor: MailCursor) async -> MailCursor? { nil }
    func deferral(_ refs: [String], in cursor: MailCursor) async -> MailDeferral? {
        await deferring(refs, in: cursor).map { MailDeferral(cursor: $0) }
    }
    func prime(cursor: MailCursor?) async {}
    func relisting(_ cursor: MailCursor) async -> MailCursor? { nil }
}

/// Secret storage for account credentials (IMAP app passwords). The production
/// implementation uses the app's own login-keychain items; tests use an in-memory store.
package protocol MailSecretStore: Sendable {
    func secret(for key: String) async -> String?
    func setSecret(_ value: String?, for key: String) async throws
}

/// A candidate paper found by local extraction (before it becomes a MailItem row).
package struct MailCandidate: Sendable, Equatable {
    package var cand: String                    // "c1"…
    package var origin: MailItemOrigin
    package var title: String?
    package var authors: [String]
    package var ids: PaperIDs
    package var url: String?                    // unwrapped
    package var urlOriginal: String?
    package var host: String?
    package var attachmentIndex: Int?           // index into MailContent.attachments for PDFs
    package var pdfState: MailPDFState          // local guess: hasPDF / downloadable / needsPDF / unknown
    package var snippet: String?                // alert entry snippet / anchor text context
    package var venue: String?                  // alert byline ("Nature Neuroscience"), when known
    package var year: Int?
    /// `document` candidates: the attachment's lowercase extension ("docx"…); `shareLink`: when the URL tells.
    package var documentKind: String?
    /// `document` candidates: the attachment's (sanitized) file name.
    package var documentFileName: String?
    /// `shareLink` candidates: the service (`MailShareProvider` raw value).
    package var shareHost: String?

    package init(cand: String, origin: MailItemOrigin, title: String? = nil, authors: [String] = [],
                 ids: PaperIDs = PaperIDs(), url: String? = nil, urlOriginal: String? = nil, host: String? = nil,
                 attachmentIndex: Int? = nil, pdfState: MailPDFState = .unknown, snippet: String? = nil,
                 venue: String? = nil, year: Int? = nil, documentKind: String? = nil, documentFileName: String? = nil,
                 shareHost: String? = nil) {
        self.cand = cand; self.origin = origin; self.title = title; self.authors = authors; self.ids = ids
        self.url = url; self.urlOriginal = urlOriginal; self.host = host; self.attachmentIndex = attachmentIndex
        self.pdfState = pdfState; self.snippet = snippet; self.venue = venue; self.year = year
        self.documentKind = documentKind; self.documentFileName = documentFileName; self.shareHost = shareHost
    }
}

/// Output of local extraction for one message.
package struct MailExtraction: Sendable, Equatable {
    package var bodyText: String                // sanitized text with [cN] link markers, capped
    package var snippet: String
    package var candidates: [MailCandidate]
    package var isForwarded: Bool
    /// The first lines (`MailHeuristics.leadingLines`) of the quoted history or forwarded section
    /// the body cut off, nil when nothing was cut. Read by the capture's confidentiality guard
    /// only (`MailHeuristics.isConfidential(_:extraction:)`) — never stored, never sent to an AI.
    package var historyHead: String?
    package init(bodyText: String, snippet: String, candidates: [MailCandidate], isForwarded: Bool = false,
                 historyHead: String? = nil) {
        self.bodyText = bodyText; self.snippet = snippet; self.candidates = candidates; self.isForwarded = isForwarded
        self.historyHead = historyHead
    }
}
