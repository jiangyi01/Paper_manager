import Foundation

/// Something the user handed us: a drop, "Open With", a folder import, a link.
package enum IntakeItem: Sendable, Equatable {
    case file(URL)                               // file or folder URL (Finder, Open With, NSOpenPanel)
    case promised(URL)                           // file promise already materialized in caches/incoming
    case pdfData(Data, suggestedName: String)    // raw PDF bytes (e.g. Preview sidebar pages)
    case remote(URL)                             // http(s) link → download
}

package enum ImportOrigin: String, Sendable {
    case drop, openWith, menuBar, folderImport, setupAssistant, cli
    /// Merged from an email card (attachment copy, downloaded link, PDF dropped on a mail row).
    /// Always copies — the source is never moved to the Trash, whatever the import mode says.
    case mail
}

/// How a batch gets DDLs.
package enum BatchScheduling: Sendable, Equatable {
    case automatic          // ≤ 10 papers: normal place(); > 10 or setup import: sequentialLow
    case sequentialLow      // priority low, placed one after another in queue order
    case unscheduled        // schedule_mode none
}

/// Whether new papers get AI jobs.
package enum BatchAIPolicy: Sendable, Equatable {
    case automatic          // settings (agent.mode + autoRead); > 3 papers in one batch → held for confirmation
    case queueAll
    case hold
    case skip
    /// A job for every paper whatever auto-read says (like `queueAll`), created held so the
    /// batch dialog asks first (like `hold`) — 「全部合并」 of more than 3 papers with AI reading.
    case queueHeld
}

/// What an import does when the file turns out to be a paper the library already has.
package enum SameWorkPolicy: Sendable, Equatable {
    /// Exact duplicate → 「已在库中」 toast; same work (DOI/arXiv) → park the copy and ask
    /// 「替换并保留清单 / 忽略」 (the normal drop behaviour).
    case prompt
    /// Link instead: the annotation (provenance, and priority / DDL / category / notes when
    /// given) is applied to the existing paper and the new copy is discarded — no replace toast.
    case link
}

/// Per-file extras of an import (email merges): applied to the new paper before `place()`
/// (priority) and inside the insert transaction (provenance, pinned DDL, category, notes).
package struct ImportAnnotation: Sendable, Equatable {
    /// Stored as a `paper_source` row (mirrored into card.json "provenance").
    package var provenance: PaperProvenance?
    /// Priority of the new paper, set before it is placed (nil → the batch's default). On a
    /// linked existing paper it is written only when given.
    package var priority: Priority?
    /// DDL pinned by the user's merge choice (mode pinned, origin user).
    package var pinnedDeadline: LocalDate?
    /// Category name (created as a user category when missing); on a linked paper only when
    /// it has no category yet.
    package var category: String?
    /// Written to the notes only when they are empty.
    package var notesPrefill: String?
    package var sameWorkPolicy: SameWorkPolicy
    /// Overrides `ImportOptions.ai` for this file.
    package var aiPolicy: BatchAIPolicy?
    /// `AgentQueue.enqueue(priority:)` of the paper's reading job (1 = read first: advisor requests).
    package var aiPriority: Int
    /// A PDF from a person's / advisor's / manually imported email, or from any confidential email
    /// (`MailHeuristics.isConfidential`: an editor's invitation from an alert domain too) —
    /// attachment, link, a file dropped on the row, an auto-merge download: when the paper ends up
    /// with no DOI / arXiv id, its AI job is created held with `unpublishedHoldNote` (institutional
    /// IP guidance — confirm before AI reading).
    package var holdAIUnlessIdentified: Bool
    /// The file turns out to be a paper in 最近删除: intake leaves that paper alone — no
    /// provenance row, no annotation, no 「已在最近删除中」 toast — and reports it as a duplicate;
    /// the caller decides (an email merge restores it on the user's click, the sync's auto-merge
    /// leaves its row waiting).
    package var leaveDeletedAlone: Bool
    /// The email's titles may not go to the metadata services (`MailSyncActor.mayLookUpTitles`:
    /// confidential mail, or a person's / advisor's / dropped / alert-domain non-list email before
    /// 「让 AI 分析」): a new paper is flagged `titleLookupHeld` — enrichment looks up its
    /// identifiers only, never its title — until the user asks (`Engine.lookUpMetadataOnline`).
    package var identifierLookupsOnly: Bool

    package init(provenance: PaperProvenance? = nil, priority: Priority? = nil, pinnedDeadline: LocalDate? = nil,
                 category: String? = nil, notesPrefill: String? = nil, sameWorkPolicy: SameWorkPolicy = .prompt,
                 aiPolicy: BatchAIPolicy? = nil, aiPriority: Int = 0, holdAIUnlessIdentified: Bool = false,
                 leaveDeletedAlone: Bool = false, identifierLookupsOnly: Bool = false) {
        self.provenance = provenance; self.priority = priority; self.pinnedDeadline = pinnedDeadline
        self.category = category; self.notesPrefill = notesPrefill; self.sameWorkPolicy = sameWorkPolicy
        self.aiPolicy = aiPolicy; self.aiPriority = aiPriority; self.holdAIUnlessIdentified = holdAIUnlessIdentified
        self.leaveDeletedAlone = leaveDeletedAlone; self.identifierLookupsOnly = identifierLookupsOnly
    }

    /// `paper.aiNote` of a job held by `holdAIUnlessIdentified` (a code; `unpublishedHoldText` is the UI text).
    package static let unpublishedHoldNote = "mail_unpublished"

    /// 「可能是未发表稿件 · 解读前请确认」 / "Possibly unpublished — confirm before AI reading".
    package static func unpublishedHoldText(_ lang: UILang) -> String {
        lang == .zh ? "可能是未发表稿件 · 解读前请确认" : "Possibly unpublished — confirm before AI reading"
    }
}

package struct ImportOptions: Sendable, Equatable {
    package var origin: ImportOrigin
    package var scheduling: BatchScheduling
    package var ai: BatchAIPolicy
    /// Per-file extras keyed by the URL of the item (`.file` / `.promised` / `.remote`), or of a
    /// file inside a dropped folder. File URLs are compared standardized.
    package var annotations: [URL: ImportAnnotation]

    package init(origin: ImportOrigin, scheduling: BatchScheduling = .automatic, ai: BatchAIPolicy = .automatic,
                 annotations: [URL: ImportAnnotation] = [:]) {
        self.origin = origin; self.scheduling = scheduling; self.ai = ai; self.annotations = annotations
    }

    /// The annotation for `url` (standardized for file URLs).
    package func annotation(for url: URL?) -> ImportAnnotation? {
        guard let url, !annotations.isEmpty else { return nil }
        if let hit = annotations[url] { return hit }
        let key = Self.key(url)
        return annotations.first { Self.key($0.key) == key }?.value
    }

    static func key(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.resolvingSymlinksInPath().path : url.absoluteString
    }
}

/// What happened to one item of a batch (`ImportBatchSummary.items`), so a caller (an email
/// merge) knows which paper it produced or linked.
package struct ImportItemResult: Sendable, Equatable {
    package enum Outcome: Sendable, Equatable {
        case added(paperID: String)
        /// Exact bytes already in the library (live or in 最近删除).
        case duplicate(paperID: String)
        /// Same DOI / arXiv work: with `SameWorkPolicy.prompt` the copy waits for the user's
        /// replace/ignore answer; with `.link` it was linked and discarded.
        case sameWork(existingPaperID: String)
        case rejected(reason: String)            // not a PDF, not a PDF link…
        case failed(reason: String)              // unreadable source, disk full, download failed…

        /// The paper the item ended up as (added or already there).
        package var paperID: String? {
            switch self {
            case .added(let id), .duplicate(let id), .sameWork(let id): return id
            case .rejected, .failed: return nil
            }
        }

        package var failureReason: String? {
            switch self {
            case .rejected(let r), .failed(let r): return r
            default: return nil
            }
        }
    }

    /// The item's URL (the file inside a folder for folder drops; nil for raw PDF data).
    package var source: URL?
    package var outcome: Outcome
    /// With `SameWorkPolicy.link`: the annotation was applied to the existing paper.
    package var linked: Bool

    package init(source: URL?, outcome: Outcome, linked: Bool = false) {
        self.source = source; self.outcome = outcome; self.linked = linked
    }
}
