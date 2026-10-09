import Foundation

// Per-paper AI policy and the privacy inputs every assist surface checks (READING_ASSIST_PLAN §2,
// §5). Lead-owned (Slice 0). The inspector's toggles call `setPaperPolicy`; Explain, Q&A and the
// duplicate judge call `assistPrivacy(paperID:hostBundleID:)` before building a request.
extension Engine {
    /// The paper's policy (nil: neither flag). Deleted papers too (read-only display).
    package func paperPolicy(paperID: String) async throws -> PaperPolicy? {
        guard let paper = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        return try await db.paperPolicy(paperPK: paper.pk)
    }

    /// Sets the inspector's "Unpublished / confidential" and "Never use AI" flags of a live paper.
    /// Returns the stored policy (nil when both are off: the row is removed).
    @discardableResult
    package func setPaperPolicy(paperID: String, confidential: Bool, neverAI: Bool,
                                setBy: PaperPolicy.SetBy = .user) async throws -> PaperPolicy? {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let policy = PaperPolicy(confidential: confidential, neverAI: neverAI, setBy: setBy, setAt: ctx.now())
        try await db.setPaperPolicy(paperPK: pk, policy)
        await ctx.syncSidecar(pk: pk)                   // card.json `policy` (omitted when both are off)
        await syncQASidecar(paperID: paperID)          // qa.json leaves the folder of a confidential / never-AI paper
        return policy.isEmpty ? nil : try await db.paperPolicy(paperPK: pk)
    }

    /// The pure inputs of `AssistPrivacy.verdict` for one paper: its policy, its `ai_note` and one
    /// summary per email it came from (a person's email: advisor, person, a dropped .eml).
    package func privacyInputs(paperID: String) async throws -> (policy: PaperPolicy?, aiNote: String?,
                                                                 provenance: [PaperSourceSummary]) {
        guard let paper = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        let policy = try await db.paperPolicy(paperPK: paper.pk)
        let sources = try await db.paperSources(paperPK: paper.pk)
        let identified = paper.ids.doi != nil || paper.ids.arxivID != nil || paper.ids.publishedDOI != nil
        var summaries: [PaperSourceSummary] = []
        for source in sources {
            var kind: SenderKind?
            if let id = source.mailMessageID, let m = try await db.mailMessage(id: id) { kind = m.senderKind }
            else if let mid = source.internetMessageID, let m = try await db.mailMessage(internetMessageID: mid) { kind = m.senderKind }
            // A purged or unknown message counts as a person's: the stricter reading.
            let person = kind.map { $0 != .alert } ?? true
            summaries.append(PaperSourceSummary(personSourced: person, identified: identified))
        }
        return (policy, paper.aiNote, summaries)
    }

    /// `AssistPrivacy.verdict` for a paper, as captured from `hostBundleID` (nil: inside PaperDeck).
    package func assistPrivacy(paperID: String, hostBundleID: String?) async throws -> AssistPrivacy.Verdict {
        let inputs = try await privacyInputs(paperID: paperID)
        return AssistPrivacy.verdict(policy: inputs.policy, aiNote: inputs.aiNote, provenance: inputs.provenance,
                                     hostBundleID: hostBundleID)
    }
}
