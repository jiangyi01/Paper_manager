import Foundation

// Undo of the matcher's automatic links (「已匹配邮件请求：… [查看] [撤销]」): the toast carries
// `Toast.Action.undoMailLink(token:)`; `Engine.undoMailLink(token:)` (OperationsMail) puts the
// rows back to how they were — pending, waiting for a PDF — when nothing touched them since,
// removes the provenance row the link added, and reopens the card when the link completed it.
// Records live in memory per engine (like 今天跳过's undo) for `MailLinkUndo.lifetime`.

/// What one automatic link changed (enough to put it back).
struct MailLinkUndo: Sendable {
    /// The "not touched since" checks make a late undo safe, so the window is generous.
    static let lifetime: TimeInterval = 10 * 60

    var owner: ObjectIdentifier
    var expiresAt: Date
    var messagePK: Int64
    var internetMessageID: String
    var paperPK: Int64
    var paperID: String
    /// The rows as they were before the link, with the `updatedAt` the link gave them.
    var rows: [(prior: MailItem, linkedAt: Date)]
    /// The link added the paper's `paper_source` row for this email (else it was there already).
    var sourceAdded: Bool
    /// The card before the link, when the link completed it (`merged`), plus what the link left
    /// (`linkedHandledAt`, `linkedUserTouched` — a card changed since is not reopened); nil otherwise.
    var reopen: (state: MailState, snoozedUntil: Date?, handledAt: Date?, linkedHandledAt: Date?, linkedUserTouched: Bool)?
}

/// Undo records and the (item, paper) pairs the user undid — the matcher does not link or
/// suggest those again while the app runs. Records are scoped to the engine that made them
/// (its database actor), expiry follows that engine's clock.
final class MailLinkUndoLedger: @unchecked Sendable {
    static let shared = MailLinkUndoLedger()
    private static let maxRecords = 64
    private static let maxDeclined = 2_000

    private let lock = NSLock()
    private var records: [String: MailLinkUndo] = [:]
    private var order: [String] = []
    private var declinedPairs: [ObjectIdentifier: Set<String>] = [:]

    /// Records an automatic link; returns the token for `Toast.Action.undoMailLink`.
    func put(_ result: MailItemLinker.LinkResult, paper: Paper, owner: ObjectIdentifier, now: Date) -> String {
        let token = UUID().uuidString.lowercased()
        let linkedAt = Dictionary(result.linked.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        let completed = result.before.state != .merged && result.message.state == .merged
        let record = MailLinkUndo(
            owner: owner, expiresAt: now.addingTimeInterval(MailLinkUndo.lifetime), messagePK: result.message.pk,
            internetMessageID: result.message.internetMessageID, paperPK: paper.pk, paperID: paper.id,
            rows: result.prior.compactMap { p in linkedAt[p.id].map { (p, $0) } }, sourceAdded: result.sourceAdded,
            reopen: completed ? (result.before.state, result.before.snoozedUntil, result.before.handledAt,
                                 result.message.handledAt, result.message.userTouched) : nil)
        lock.withLock {
            prune(owner: owner, now: now)
            records[token] = record
            order.append(token)
            while order.count > Self.maxRecords { records[order.removeFirst()] = nil }
        }
        return token
    }

    /// Removes and returns a live record of `owner`; nil when unknown, used or expired.
    func take(_ token: String, owner: ObjectIdentifier, now: Date) -> MailLinkUndo? {
        lock.withLock {
            prune(owner: owner, now: now)
            guard let r = records[token], r.owner == owner else { return nil }
            records[token] = nil
            order.removeAll { $0 == token }
            return r
        }
    }

    func decline(itemIDs: [String], paperID: String, owner: ObjectIdentifier) {
        lock.withLock {
            var set = declinedPairs[owner] ?? []
            if set.count > Self.maxDeclined { set.removeAll() }
            for id in itemIDs { set.insert(Self.pair(id, paperID)) }
            declinedPairs[owner] = set
        }
    }

    func declined(_ itemID: String, _ paperID: String, owner: ObjectIdentifier) -> Bool {
        lock.withLock { declinedPairs[owner]?.contains(Self.pair(itemID, paperID)) ?? false }
    }

    private static func pair(_ itemID: String, _ paperID: String) -> String {
        itemID.lowercased() + "|" + paperID.lowercased()
    }

    private func prune(owner: ObjectIdentifier, now: Date) {
        let expired = records.filter { $0.value.owner == owner && $0.value.expiresAt < now }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { records[key] = nil }
        order.removeAll { expired.contains($0) }
    }
}

extension Database {
    /// Removes one email's provenance row from a paper (the undo of an automatic link).
    /// Emits `.paper(pk:)`. Idempotent.
    func deletePaperSource(paperPK: Int64, internetMessageID: String) throws {
        try write {
            try db.run("DELETE FROM paper_source WHERE paper_pk = ? AND internet_message_id = ?",
                       [.integer(paperPK), .string(Database.clean(internetMessageID))])
            if db.changes > 0 { note(.paper(pk: paperPK)) }
        }
    }
}
