import Foundation

/// One paper in the library — mirrors a row of the `paper` table.
/// `pk` is the SQLite primary key (also the FTS rowid); `id` is the stable UUID
/// used in card.json, deep links and the widget snapshot.
package struct Paper: Sendable, Identifiable, Equatable {
    package var pk: Int64
    package var id: String                     // lowercase UUID
    package var sha256: String                 // of the original bytes; identity for dedupe
    package var fileSize: Int64
    package var ids: PaperIDs

    // Bibliographic header
    package var title: String
    package var titleRank: TitleRank
    package var authors: [String]
    package var year: Int?
    package var venue: String?
    package var abstract: String?
    package var metaSource: MetaSource
    package var metaUserEdited: Bool

    // File facts
    package var pageCount: Int?
    package var charCount: Int?
    package var flags: PaperFlags
    package var folder: String                 // relative to the library root, e.g. "Papers/2024_Wang_…"
    package var pdfName: String                // file name inside `folder`
    package var originalName: String           // name of the dropped file
    package var nameFinal: Bool                // folder renamed from canonical metadata

    // Pipeline + reading state
    package var stage: PaperStage
    package var status: PaperStatus
    package var priority: Priority
    package var deadline: LocalDate?
    package var scheduleMode: ScheduleMode
    package var deadlineOrigin: DeadlineOrigin
    package var queueRank: Int
    package var placementFloor: LocalDate?
    package var provisional: Bool              // ≈DDL from the heuristic estimate, may be re-placed once
    package var estMinutes: Int?
    package var estSource: EstSource

    // Organization
    package var categoryPK: Int64?
    package var categoryUserSet: Bool
    package var needsReview: Bool

    // AI
    package var tldr: String?
    package var card: ReadingCard?
    package var cardVersion: Int?
    package var textQuality: TextQuality?
    package var aiState: AIState
    package var aiNote: String?
    package var aiSeen: Bool

    package var notes: String
    package var addedAt: Date
    package var updatedAt: Date
    package var openedAt: Date?
    package var doneAt: Date?
    package var deletedAt: Date?

    package init(
        pk: Int64 = 0, id: String = UUID().uuidString.lowercased(), sha256: String, fileSize: Int64,
        ids: PaperIDs = PaperIDs(), title: String, titleRank: TitleRank = .filename, authors: [String] = [],
        year: Int? = nil, venue: String? = nil, abstract: String? = nil, metaSource: MetaSource = .none,
        metaUserEdited: Bool = false, pageCount: Int? = nil, charCount: Int? = nil, flags: PaperFlags = [],
        folder: String, pdfName: String, originalName: String, nameFinal: Bool = false,
        stage: PaperStage = .committed, status: PaperStatus = .toRead, priority: Priority = .normal,
        deadline: LocalDate? = nil, scheduleMode: ScheduleMode = .auto, deadlineOrigin: DeadlineOrigin = .place,
        queueRank: Int = 0, placementFloor: LocalDate? = nil, provisional: Bool = true,
        estMinutes: Int? = nil, estSource: EstSource = .heuristic,
        categoryPK: Int64? = nil, categoryUserSet: Bool = false, needsReview: Bool = false,
        tldr: String? = nil, card: ReadingCard? = nil, cardVersion: Int? = nil, textQuality: TextQuality? = nil,
        aiState: AIState = .none, aiNote: String? = nil, aiSeen: Bool = true, notes: String = "",
        addedAt: Date = Date(), updatedAt: Date = Date(), openedAt: Date? = nil, doneAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.pk = pk; self.id = id; self.sha256 = sha256; self.fileSize = fileSize; self.ids = ids
        self.title = title; self.titleRank = titleRank; self.authors = authors; self.year = year
        self.venue = venue; self.abstract = abstract; self.metaSource = metaSource
        self.metaUserEdited = metaUserEdited; self.pageCount = pageCount; self.charCount = charCount
        self.flags = flags; self.folder = folder; self.pdfName = pdfName; self.originalName = originalName
        self.nameFinal = nameFinal; self.stage = stage; self.status = status; self.priority = priority
        self.deadline = deadline; self.scheduleMode = scheduleMode; self.deadlineOrigin = deadlineOrigin
        self.queueRank = queueRank; self.placementFloor = placementFloor; self.provisional = provisional
        self.estMinutes = estMinutes; self.estSource = estSource; self.categoryPK = categoryPK
        self.categoryUserSet = categoryUserSet; self.needsReview = needsReview; self.tldr = tldr
        self.card = card; self.cardVersion = cardVersion; self.textQuality = textQuality
        self.aiState = aiState; self.aiNote = aiNote; self.aiSeen = aiSeen; self.notes = notes
        self.addedAt = addedAt; self.updatedAt = updatedAt; self.openedAt = openedAt
        self.doneAt = doneAt; self.deletedAt = deletedAt
    }

    package var isDeleted: Bool { deletedAt != nil }
    package var isLive: Bool { deletedAt == nil }

    /// Path of the PDF relative to the library root.
    package var relativePDFPath: String { folder + "/" + pdfName }
}
