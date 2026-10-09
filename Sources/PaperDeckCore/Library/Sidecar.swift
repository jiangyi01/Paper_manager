import Foundation

/// The per-paper `card.json` (§5): enough to rebuild the paper's rows if library.sqlite
/// is lost. Keys and nesting follow the §5 schema; a few extra keys make the rebuild
/// lossless (`fileSize`, `meta.charCount`, `state.aiNote`/`aiSeen`, `checklist[].ord`,
/// `ai.tldr`). Nil values are written as explicit `null`s so the shape is stable.
/// Decoding is lenient per field — a bad date or unknown enum value falls back to a
/// default instead of losing the paper — but `id`, `sha256` and a known `schema` are required.
/// An optional `provenance` array (emails the paper came from or was linked to) is written
/// only when non-empty, so cards of other papers keep their exact bytes; the schema id stays
/// `paperdeck.card/1` (older readers ignore the key). The reading assist adds four such optional
/// keys (READING_ASSIST_PLAN §5): `policy` (the inspector's "Unpublished / confidential" and "Never
/// use AI"), `readingCycles` (earlier readings, "Re-read the earlier one"), `distinctFrom` (ids
/// of papers the user said are not the same work as this one) and `relatedTo` (those of them kept
/// linked as related — a correction, a comment — with the relation) — each written only when non-empty.
package struct CardSidecar: Codable, Sendable, Equatable {
    package static let schemaPrefix = "paperdeck.card/"
    package static let schemaVersion = 1
    package static let schemaID = "paperdeck.card/1"
    package static let fileName = "card.json"
    package static let notesFileName = "notes.md"

    package struct IDs: Codable, Sendable, Equatable {
        package var doi: String?
        package var arxiv: String?
        package var arxivVersion: Int?
        package var pii: String?
        package var publishedDoi: String?

        package init(doi: String? = nil, arxiv: String? = nil, arxivVersion: Int? = nil,
                     pii: String? = nil, publishedDoi: String? = nil) {
            self.doi = doi; self.arxiv = arxiv; self.arxivVersion = arxivVersion
            self.pii = pii; self.publishedDoi = publishedDoi
        }
    }

    package struct Meta: Codable, Sendable, Equatable {
        package var title: String
        package var titleRank: TitleRank
        package var authors: [String]
        package var year: Int?
        package var venue: String?
        package var abstract: String?
        package var source: MetaSource
        package var userEdited: Bool
        package var pageCount: Int?
        package var charCount: Int?

        package init(title: String, titleRank: TitleRank = .filename, authors: [String] = [], year: Int? = nil,
                     venue: String? = nil, abstract: String? = nil, source: MetaSource = .none,
                     userEdited: Bool = false, pageCount: Int? = nil, charCount: Int? = nil) {
            self.title = title; self.titleRank = titleRank; self.authors = authors; self.year = year
            self.venue = venue; self.abstract = abstract; self.source = source; self.userEdited = userEdited
            self.pageCount = pageCount; self.charCount = charCount
        }
    }

    package struct Reading: Codable, Sendable, Equatable {
        package var status: PaperStatus
        package var priority: Priority
        package var deadline: LocalDate?
        package var scheduleMode: ScheduleMode
        package var deadlineOrigin: DeadlineOrigin
        package var queueRank: Int
        package var placementFloor: LocalDate?
        package var provisional: Bool
        package var estMinutes: Int?
        package var estSource: EstSource
        package var openedAt: Date?
        package var doneAt: Date?
        package var deletedAt: Date?

        package init(status: PaperStatus = .toRead, priority: Priority = .normal, deadline: LocalDate? = nil,
                     scheduleMode: ScheduleMode = .auto, deadlineOrigin: DeadlineOrigin = .place, queueRank: Int = 0,
                     placementFloor: LocalDate? = nil, provisional: Bool = true, estMinutes: Int? = nil,
                     estSource: EstSource = .heuristic, openedAt: Date? = nil, doneAt: Date? = nil,
                     deletedAt: Date? = nil) {
            self.status = status; self.priority = priority; self.deadline = deadline
            self.scheduleMode = scheduleMode; self.deadlineOrigin = deadlineOrigin; self.queueRank = queueRank
            self.placementFloor = placementFloor; self.provisional = provisional; self.estMinutes = estMinutes
            self.estSource = estSource; self.openedAt = openedAt; self.doneAt = doneAt; self.deletedAt = deletedAt
        }
    }

    package struct State: Codable, Sendable, Equatable {
        package var stage: PaperStage
        package var flags: PaperFlags
        package var nameFinal: Bool
        package var needsReview: Bool
        package var textQuality: TextQuality?
        package var aiState: AIState
        package var aiNote: String?
        package var aiSeen: Bool

        package init(stage: PaperStage = .committed, flags: PaperFlags = [], nameFinal: Bool = false,
                     needsReview: Bool = false, textQuality: TextQuality? = nil, aiState: AIState = .none,
                     aiNote: String? = nil, aiSeen: Bool = true) {
            self.stage = stage; self.flags = flags; self.nameFinal = nameFinal; self.needsReview = needsReview
            self.textQuality = textQuality; self.aiState = aiState; self.aiNote = aiNote; self.aiSeen = aiSeen
        }
    }

    /// A checklist row. `ord` is optional on the wire (absent in the §5 example → array position).
    package struct ChecklistEntry: Codable, Sendable, Equatable {
        package var id: String
        package var ord: Double?
        package var text: String
        package var section: String?
        package var page: Int?
        package var minutes: Int
        package var kind: ChecklistKind
        package var origin: ItemOrigin
        package var userEdited: Bool
        package var doneAt: Date?

        package init(_ item: ChecklistItem) {
            id = item.id; ord = item.ord; text = item.text; section = item.section; page = item.page
            minutes = item.minutes; kind = item.kind; origin = item.origin; userEdited = item.userEdited
            doneAt = item.doneAt
        }

        package func model(fallbackOrd: Double) -> ChecklistItem {
            ChecklistItem(id: id, ord: ord ?? fallbackOrd, text: text, section: section, page: page,
                          minutes: minutes, kind: kind, origin: origin, userEdited: userEdited, doneAt: doneAt)
        }
    }

    package struct CategoryRef: Codable, Sendable, Equatable {
        package var name: String?
        package var userSet: Bool
        package init(name: String? = nil, userSet: Bool = false) { self.name = name; self.userSet = userSet }
    }

    package struct AI: Codable, Sendable, Equatable {
        package var provider: String?
        package var model: String?
        package var cardVersion: Int?
        package var generatedAt: Date?
        package var card: ReadingCard?
        package var tldr: String?

        package init(provider: String? = nil, model: String? = nil, cardVersion: Int? = nil,
                     generatedAt: Date? = nil, card: ReadingCard? = nil, tldr: String? = nil) {
            self.provider = provider; self.model = model; self.cardVersion = cardVersion
            self.generatedAt = generatedAt; self.card = card; self.tldr = tldr
        }
    }

    /// One `paper_source` row (`PaperProvenance`) on the wire: explicit nulls, ISO dates,
    /// lenient per field. `addedAt` falls back to `receivedAt` (then the epoch) so a hand-edited
    /// entry still rebuilds deterministically.
    package struct ProvenanceEntry: Codable, Sendable, Equatable {
        package var kind: String
        package var mailMessageID: String?
        package var internetMessageID: String?
        package var fromAddress: String?
        package var fromName: String?
        package var subject: String?
        package var receivedAt: Date?
        package var webLink: String?
        package var requestKind: String?
        package var summary: String?
        package var dueHint: LocalDate?
        package var addedAt: Date?
        /// The email's original document kept in the paper folder (a converted .docx), by file
        /// name; the key is written only when set, so other cards keep their exact bytes.
        package var document: String?

        package init(_ p: PaperProvenance) {
            kind = p.kind; mailMessageID = p.mailMessageID; internetMessageID = p.internetMessageID
            fromAddress = p.fromAddress; fromName = p.fromName; subject = p.subject; receivedAt = p.receivedAt
            webLink = p.webLink; requestKind = p.requestKind?.rawValue; summary = p.summary; dueHint = p.dueHint
            addedAt = p.addedAt; document = p.document
        }

        package var model: PaperProvenance {
            PaperProvenance(kind: kind.isEmpty ? "email" : kind, mailMessageID: mailMessageID,
                            internetMessageID: internetMessageID, fromAddress: fromAddress, fromName: fromName,
                            subject: subject, receivedAt: receivedAt, webLink: webLink,
                            requestKind: requestKind.flatMap(MailRequestKind.init(rawValue:)), summary: summary,
                            dueHint: dueHint, addedAt: addedAt ?? receivedAt ?? Date(timeIntervalSince1970: 0),
                            document: CardSidecar.safeDocumentName(document))
        }
    }

    /// `paper_policy` on the wire (only when a flag is on).
    package struct PolicyEntry: Codable, Sendable, Equatable {
        package var confidential: Bool
        package var neverAI: Bool
        package var setBy: PaperPolicy.SetBy
        package var setAt: Date?

        package init(_ p: PaperPolicy) {
            confidential = p.confidential; neverAI = p.neverAI; setBy = p.setBy; setAt = p.setAt
        }

        /// nil when neither flag is on (nothing to restore).
        package func model(fallbackDate: Date) -> PaperPolicy? {
            let p = PaperPolicy(confidential: confidential, neverAI: neverAI, setBy: setBy, setAt: setAt ?? fallbackDate)
            return p.isEmpty ? nil : p
        }
    }

    /// A `dup_pair` kept linked as related, on the wire: the partner's id and how the two relate
    /// (`dup_pair.relation`: "correction", "comment", "supplement", …).
    package struct RelatedEntry: Codable, Sendable, Hashable {
        package var id: String
        package var relation: String?

        package init(id: String, relation: String?) { self.id = id; self.relation = relation }
    }

    /// How `Database.dupPairPartnerIDs` hands a related partner to `init(…distinctFrom:)` next to
    /// the plain ids: `related:<relation>:<id>` (paper ids are UUIDs, relations `DupRelation` raw
    /// values — neither holds a colon).
    package static func relatedPartnerEntry(id: String, relation: String?) -> String {
        "related:\(relation ?? ""):\(id.lowercased())"
    }

    /// The related partner a `relatedPartnerEntry` names; nil for a plain id.
    package static func relatedPartner(_ entry: String) -> RelatedEntry? {
        guard entry.hasPrefix("related:") else { return nil }
        let rest = entry.dropFirst("related:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let relation = String(rest[..<colon]), id = String(rest[rest.index(after: colon)...]).lowercased()
        guard !id.isEmpty else { return nil }
        return RelatedEntry(id: id, relation: relation.isEmpty ? nil : relation)
    }

    /// One `reading_cycle` row on the wire.
    package struct CycleEntry: Codable, Sendable, Equatable {
        package var n: Int
        package var startedAt: Date?
        package var doneAt: Date?
        package var reason: String?

        package init(_ c: ReadingCycle) { n = c.n; startedAt = c.startedAt; doneAt = c.doneAt; reason = c.reason }

        package func model(fallbackDate: Date) -> ReadingCycle {
            ReadingCycle(n: n, startedAt: startedAt ?? fallbackDate, doneAt: doneAt, reason: reason)
        }
    }

    /// What a rebuild inserts: the paper (pk 0, folder given by the caller, categoryPK
    /// unresolved — look up `categoryName`), its checklist and tags, the AI provenance and
    /// the email provenance (`paper_source` rows), its AI policy, reading cycles and the ids of
    /// papers it is distinct from or related to (`dup_pair`, restored once both papers exist).
    package struct Models: Sendable, Equatable {
        package var paper: Paper
        package var checklist: [ChecklistItem]
        package var categoryName: String?
        package var tags: [Tag]
        package var aiProvider: String?
        package var aiModel: String?
        package var aiGeneratedAt: Date?
        package var provenance: [PaperProvenance] = []
        package var policy: PaperPolicy?
        package var readingCycles: [ReadingCycle] = []
        package var distinctFrom: [String] = []
        /// Those of `distinctFrom` kept linked as related, with the relation.
        package var relatedTo: [RelatedEntry] = []
    }

    package var schema: String
    package var id: String
    package var sha256: String
    package var fileSize: Int64?
    package var addedAt: Date?
    package var updatedAt: Date?
    package var pdf: String
    package var originalName: String
    package var ids: IDs
    package var meta: Meta
    package var reading: Reading
    package var state: State
    package var checklist: [ChecklistEntry]
    package var category: CategoryRef
    package var tags: [Tag]
    package var notes: String
    package var ai: AI
    /// Emails the paper came from / was linked to, oldest first (empty → key omitted).
    package var provenance: [ProvenanceEntry]
    /// The user's AI policy for the paper (nil → key omitted).
    package var policy: PolicyEntry?
    /// Readings by number (empty → key omitted).
    package var readingCycles: [CycleEntry]
    /// Lowercased ids of papers the user kept as distinct works, sorted (empty → key omitted).
    package var distinctFrom: [String]
    /// Those of them kept linked as related, with the relation, by id (empty → key omitted).
    package var relatedTo: [RelatedEntry]

    /// Snapshot of a paper and its related rows. Checklist is stored in `ord` order and
    /// tags by name so unchanged papers serialize to identical bytes. `distinctFrom` takes
    /// `Database.dupPairPartnerIDs`: partner ids, and `relatedPartnerEntry`s for related pairs.
    package init(paper: Paper, checklist: [ChecklistItem], categoryName: String?, tags: [Tag],
                 aiProvider: String?, aiModel: String?, aiGeneratedAt: Date? = nil,
                 provenance: [PaperProvenance] = [], policy: PaperPolicy? = nil, readingCycles: [ReadingCycle] = [],
                 distinctFrom: [String] = []) {
        schema = Self.schemaID
        id = paper.id
        sha256 = paper.sha256
        fileSize = paper.fileSize
        addedAt = paper.addedAt
        updatedAt = paper.updatedAt
        pdf = paper.pdfName
        originalName = paper.originalName
        ids = IDs(doi: paper.ids.doi, arxiv: paper.ids.arxivID, arxivVersion: paper.ids.arxivVersion,
                  pii: paper.ids.pii, publishedDoi: paper.ids.publishedDOI)
        meta = Meta(title: paper.title, titleRank: paper.titleRank, authors: paper.authors, year: paper.year,
                    venue: paper.venue, abstract: paper.abstract, source: paper.metaSource,
                    userEdited: paper.metaUserEdited, pageCount: paper.pageCount, charCount: paper.charCount)
        reading = Reading(status: paper.status, priority: paper.priority, deadline: paper.deadline,
                          scheduleMode: paper.scheduleMode, deadlineOrigin: paper.deadlineOrigin,
                          queueRank: paper.queueRank, placementFloor: paper.placementFloor,
                          provisional: paper.provisional, estMinutes: paper.estMinutes, estSource: paper.estSource,
                          openedAt: paper.openedAt, doneAt: paper.doneAt, deletedAt: paper.deletedAt)
        state = State(stage: paper.stage, flags: paper.flags, nameFinal: paper.nameFinal,
                      needsReview: paper.needsReview, textQuality: paper.textQuality, aiState: paper.aiState,
                      aiNote: paper.aiNote, aiSeen: paper.aiSeen)
        self.checklist = checklist.enumerated()
            .sorted { ($0.element.ord, $0.offset) < ($1.element.ord, $1.offset) }
            .map { ChecklistEntry($0.element) }
        category = CategoryRef(name: categoryName, userSet: paper.categoryUserSet)
        self.tags = tags.sorted { ($0.name, $0.origin.rawValue) < ($1.name, $1.origin.rawValue) }
        notes = paper.notes
        ai = AI(provider: aiProvider, model: aiModel, cardVersion: paper.cardVersion, generatedAt: aiGeneratedAt,
                card: paper.card, tldr: paper.tldr)
        self.provenance = provenance.map(ProvenanceEntry.init)
        self.policy = policy.flatMap { $0.isEmpty ? nil : PolicyEntry($0) }
        self.readingCycles = readingCycles.sorted { $0.n < $1.n }.map(CycleEntry.init)
        var partners: [String] = [], related: [RelatedEntry] = []
        for entry in distinctFrom {
            if let r = Self.relatedPartner(entry) {
                related.append(r)
                partners.append(r.id)
            } else {
                partners.append(entry)
            }
        }
        self.distinctFrom = Array(Set(partners.map { $0.lowercased() })).sorted()
        self.relatedTo = Array(Set(related)).sorted { ($0.id, $0.relation ?? "") < ($1.id, $1.relation ?? "") }
    }

    /// Copies every sidecar field onto `paper`, leaving `pk`, `folder` and `categoryPK`
    /// (DB-local facts) untouched. Missing timestamps keep the paper's current values.
    package func apply(to paper: inout Paper) {
        paper.id = id
        paper.sha256 = sha256
        if let fileSize { paper.fileSize = fileSize }
        paper.ids = PaperIDs(doi: ids.doi, arxivID: ids.arxiv, arxivVersion: ids.arxivVersion,
                             pii: ids.pii, publishedDOI: ids.publishedDoi)
        paper.title = displayTitle
        paper.titleRank = meta.titleRank
        paper.authors = meta.authors
        paper.year = meta.year
        paper.venue = meta.venue
        paper.abstract = meta.abstract
        paper.metaSource = meta.source
        paper.metaUserEdited = meta.userEdited
        paper.pageCount = meta.pageCount
        paper.charCount = meta.charCount
        paper.flags = state.flags
        if !pdf.isEmpty { paper.pdfName = pdf }
        paper.originalName = originalName
        paper.nameFinal = state.nameFinal
        paper.stage = state.stage
        paper.status = reading.status
        paper.priority = reading.priority
        paper.deadline = reading.deadline
        paper.scheduleMode = reading.scheduleMode
        paper.deadlineOrigin = reading.deadlineOrigin
        paper.queueRank = reading.queueRank
        paper.placementFloor = reading.placementFloor
        paper.provisional = reading.provisional
        paper.estMinutes = reading.estMinutes
        paper.estSource = reading.estSource
        paper.categoryUserSet = category.userSet
        paper.needsReview = state.needsReview
        paper.tldr = ai.tldr
        paper.card = ai.card
        paper.cardVersion = ai.cardVersion
        paper.textQuality = state.textQuality
        paper.aiState = state.aiState
        paper.aiNote = state.aiNote
        paper.aiSeen = state.aiSeen
        paper.notes = notes
        if let addedAt { paper.addedAt = addedAt }
        if let updatedAt { paper.updatedAt = updatedAt }
        paper.openedAt = reading.openedAt
        paper.doneAt = reading.doneAt
        paper.deletedAt = reading.deletedAt
    }

    /// Rows for an index rebuild. `folder` is the paper folder relative to the library
    /// root (where this card.json was found); `fallbackDate` stands in for unreadable
    /// timestamps so rebuilds stay deterministic.
    package func toModels(folder: String, fallbackDate: Date = Date(timeIntervalSince1970: 0)) -> Models {
        let folderName = (folder as NSString).lastPathComponent
        var paper = Paper(id: id, sha256: sha256, fileSize: fileSize ?? 0, title: displayTitle, folder: folder,
                          pdfName: pdf.isEmpty ? FileNamer.pdfName(forFolder: folderName) : pdf,
                          originalName: originalName,
                          addedAt: addedAt ?? updatedAt ?? fallbackDate, updatedAt: updatedAt ?? addedAt ?? fallbackDate)
        apply(to: &paper)
        let items = checklist.enumerated().map { $0.element.model(fallbackOrd: Double($0.offset + 1)) }
        let stamp = paper.updatedAt
        var seenCycles = Set<Int>()
        let cycles = readingCycles.filter { $0.n > 0 && seenCycles.insert($0.n).inserted }.map { $0.model(fallbackDate: stamp) }
        return Models(paper: paper, checklist: items, categoryName: category.name, tags: tags,
                      aiProvider: ai.provider, aiModel: ai.model, aiGeneratedAt: ai.generatedAt,
                      provenance: provenance.map(\.model), policy: policy?.model(fallbackDate: stamp),
                      readingCycles: cycles,
                      distinctFrom: distinctFrom.map { $0.lowercased() }.filter { !$0.isEmpty && $0 != id.lowercased() },
                      relatedTo: relatedTo.map { RelatedEntry(id: $0.id.lowercased(), relation: $0.relation) }
                          .filter { !$0.id.isEmpty && $0.id != id.lowercased() })
    }

    /// A kept original's file name as card.json may name it: one plain file name inside the paper
    /// folder (no path, not hidden, no control characters); anything else reads as nil.
    package static func safeDocumentName(_ name: String?) -> String? {
        guard let n = name, !n.isEmpty, n.count <= 255, !n.hasPrefix("."), !n.contains("/"), !n.contains("\\"),
              !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return n
    }

    private var displayTitle: String {
        if !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return meta.title }
        let stem = (originalName as NSString).deletingPathExtension
        return stem.isEmpty ? FileNamer.fallbackName : stem
    }

    // MARK: - Serialization

    /// sortedKeys + prettyPrinted; dates are ISO-8601 UTC strings (written by the types
    /// themselves, so any encoder produces the same shape).
    package static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(SidecarDate.format(date))
        }
        return enc
    }

    package func encoded() throws -> Data {
        var data = try Self.makeEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    package static func decoded(from data: Data) throws -> CardSidecar {
        try JSONDecoder().decode(CardSidecar.self, from: data)
    }

    // MARK: - Codable

    private enum Keys: String, CodingKey {
        case schema, id, sha256, fileSize, addedAt, updatedAt, pdf, originalName
        case ids, meta, reading, state, checklist, category, tags, notes, ai, provenance
        case policy, readingCycles, distinctFrom, relatedTo
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let schema = try c.decode(String.self, forKey: .schema)
        guard schema.hasPrefix(Self.schemaPrefix), let version = Int(schema.dropFirst(Self.schemaPrefix.count)) else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c, debugDescription: "Not a PaperDeck card: \(schema)")
        }
        guard version <= Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schema, in: c,
                                                   debugDescription: "card.json schema \(version) is newer than supported")
        }
        self.schema = schema
        id = try c.decode(String.self, forKey: .id)
        sha256 = try c.decode(String.self, forKey: .sha256)
        guard !id.isEmpty, !sha256.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Empty id or sha256")
        }
        fileSize = c.lenient(Int64.self, .fileSize)
        addedAt = c.lenientDate(.addedAt)
        updatedAt = c.lenientDate(.updatedAt)
        pdf = c.lenient(String.self, .pdf) ?? ""
        originalName = c.lenient(String.self, .originalName) ?? ""
        ids = c.lenient(IDs.self, .ids) ?? IDs()
        meta = c.lenient(Meta.self, .meta) ?? Meta(title: "")
        reading = c.lenient(Reading.self, .reading) ?? Reading()
        state = c.lenient(State.self, .state) ?? State()
        checklist = c.lenientArray(ChecklistEntry.self, .checklist)
        category = c.lenient(CategoryRef.self, .category) ?? CategoryRef()
        tags = c.lenientArray(Tag.self, .tags)
        notes = c.lenient(String.self, .notes) ?? ""
        ai = c.lenient(AI.self, .ai) ?? AI()
        provenance = c.lenientArray(ProvenanceEntry.self, .provenance)
        policy = c.lenient(PolicyEntry.self, .policy)
        readingCycles = c.lenientArray(CycleEntry.self, .readingCycles)
        distinctFrom = c.lenientArray(String.self, .distinctFrom)
        relatedTo = c.lenientArray(RelatedEntry.self, .relatedTo)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(sha256, forKey: .sha256)
        try c.put(fileSize, .fileSize)
        try c.putDate(addedAt, .addedAt)
        try c.putDate(updatedAt, .updatedAt)
        try c.encode(pdf, forKey: .pdf)
        try c.encode(originalName, forKey: .originalName)
        try c.encode(ids, forKey: .ids)
        try c.encode(meta, forKey: .meta)
        try c.encode(reading, forKey: .reading)
        try c.encode(state, forKey: .state)
        try c.encode(checklist, forKey: .checklist)
        try c.encode(category, forKey: .category)
        try c.encode(tags, forKey: .tags)
        try c.encode(notes, forKey: .notes)
        try c.encode(ai, forKey: .ai)
        if !provenance.isEmpty { try c.encode(provenance, forKey: .provenance) }
        if let policy, policy.confidential || policy.neverAI { try c.encode(policy, forKey: .policy) }
        if !readingCycles.isEmpty { try c.encode(readingCycles, forKey: .readingCycles) }
        if !distinctFrom.isEmpty { try c.encode(distinctFrom, forKey: .distinctFrom) }
        if !relatedTo.isEmpty { try c.encode(relatedTo, forKey: .relatedTo) }
    }
}

extension CardSidecar.PolicyEntry {
    private enum Keys: String, CodingKey { case confidential, neverAI, setBy, setAt }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        confidential = c.lenient(Bool.self, .confidential) ?? false
        neverAI = c.lenient(Bool.self, .neverAI) ?? false
        setBy = c.lenientRaw(.setBy, default: PaperPolicy.SetBy.rebuild)
        setAt = c.lenientDate(.setAt)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(confidential, forKey: .confidential); try c.encode(neverAI, forKey: .neverAI)
        try c.encode(setBy.rawValue, forKey: .setBy); try c.putDate(setAt, .setAt)
    }
}

extension CardSidecar.CycleEntry {
    private enum Keys: String, CodingKey { case n, startedAt, doneAt, reason }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        n = try c.decode(Int.self, forKey: .n)
        startedAt = c.lenientDate(.startedAt)
        doneAt = c.lenientDate(.doneAt)
        reason = c.lenient(String.self, .reason)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(n, forKey: .n); try c.putDate(startedAt, .startedAt)
        try c.putDate(doneAt, .doneAt); try c.put(reason, .reason)
    }
}

// MARK: - Nested Codable (explicit nulls on encode, per-field fallbacks on decode)

extension CardSidecar.IDs {
    private enum Keys: String, CodingKey { case doi, arxiv, arxivVersion, pii, publishedDoi }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(doi: c.lenient(String.self, .doi), arxiv: c.lenient(String.self, .arxiv),
                  arxivVersion: c.lenient(Int.self, .arxivVersion), pii: c.lenient(String.self, .pii),
                  publishedDoi: c.lenient(String.self, .publishedDoi))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.put(doi, .doi); try c.put(arxiv, .arxiv); try c.put(arxivVersion, .arxivVersion)
        try c.put(pii, .pii); try c.put(publishedDoi, .publishedDoi)
    }
}

extension CardSidecar.Meta {
    private enum Keys: String, CodingKey {
        case title, titleRank, authors, year, venue, abstract, source, userEdited, pageCount, charCount
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(title: c.lenient(String.self, .title) ?? "",
                  titleRank: c.lenientRaw(.titleRank, default: TitleRank.filename),
                  authors: c.lenientArray(String.self, .authors),
                  year: c.lenient(Int.self, .year), venue: c.lenient(String.self, .venue),
                  abstract: c.lenient(String.self, .abstract),
                  source: c.lenientRaw(.source, default: MetaSource.none),
                  userEdited: c.lenient(Bool.self, .userEdited) ?? false,
                  pageCount: c.lenient(Int.self, .pageCount), charCount: c.lenient(Int.self, .charCount))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(title, forKey: .title); try c.encode(titleRank.rawValue, forKey: .titleRank)
        try c.encode(authors, forKey: .authors); try c.put(year, .year); try c.put(venue, .venue)
        try c.put(abstract, .abstract); try c.encode(source.rawValue, forKey: .source)
        try c.encode(userEdited, forKey: .userEdited); try c.put(pageCount, .pageCount)
        try c.put(charCount, .charCount)
    }
}

extension CardSidecar.Reading {
    private enum Keys: String, CodingKey {
        case status, priority, deadline, scheduleMode, deadlineOrigin, queueRank, placementFloor
        case provisional, estMinutes, estSource, openedAt, doneAt, deletedAt
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(status: c.lenientRaw(.status, default: PaperStatus.toRead),
                  priority: c.lenientRaw(.priority, default: Priority.normal),
                  deadline: c.lenientLocalDate(.deadline),
                  scheduleMode: c.lenientRaw(.scheduleMode, default: ScheduleMode.auto),
                  deadlineOrigin: c.lenientRaw(.deadlineOrigin, default: DeadlineOrigin.place),
                  queueRank: c.lenient(Int.self, .queueRank) ?? 0,
                  placementFloor: c.lenientLocalDate(.placementFloor),
                  provisional: c.lenient(Bool.self, .provisional) ?? true,
                  estMinutes: c.lenient(Int.self, .estMinutes),
                  estSource: c.lenientRaw(.estSource, default: EstSource.heuristic),
                  openedAt: c.lenientDate(.openedAt), doneAt: c.lenientDate(.doneAt),
                  deletedAt: c.lenientDate(.deletedAt))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(status.rawValue, forKey: .status); try c.encode(priority.rawValue, forKey: .priority)
        try c.put(deadline?.iso, .deadline); try c.encode(scheduleMode.rawValue, forKey: .scheduleMode)
        try c.encode(deadlineOrigin.rawValue, forKey: .deadlineOrigin); try c.encode(queueRank, forKey: .queueRank)
        try c.put(placementFloor?.iso, .placementFloor); try c.encode(provisional, forKey: .provisional)
        try c.put(estMinutes, .estMinutes); try c.encode(estSource.rawValue, forKey: .estSource)
        try c.putDate(openedAt, .openedAt); try c.putDate(doneAt, .doneAt); try c.putDate(deletedAt, .deletedAt)
    }
}

extension CardSidecar.State {
    private enum Keys: String, CodingKey {
        case stage, flags, nameFinal, needsReview, textQuality, aiState, aiNote, aiSeen
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(stage: c.lenientRaw(.stage, default: PaperStage.committed),
                  flags: PaperFlags(rawValue: c.lenient(Int.self, .flags) ?? 0),
                  nameFinal: c.lenient(Bool.self, .nameFinal) ?? false,
                  needsReview: c.lenient(Bool.self, .needsReview) ?? false,
                  textQuality: c.lenient(String.self, .textQuality).flatMap(TextQuality.init(rawValue:)),
                  aiState: c.lenientRaw(.aiState, default: AIState.none),
                  aiNote: c.lenient(String.self, .aiNote),
                  aiSeen: c.lenient(Bool.self, .aiSeen) ?? true)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(stage.rawValue, forKey: .stage); try c.encode(flags.rawValue, forKey: .flags)
        try c.encode(nameFinal, forKey: .nameFinal); try c.encode(needsReview, forKey: .needsReview)
        try c.put(textQuality?.rawValue, .textQuality); try c.encode(aiState.rawValue, forKey: .aiState)
        try c.put(aiNote, .aiNote); try c.encode(aiSeen, forKey: .aiSeen)
    }
}

extension CardSidecar.ChecklistEntry {
    private enum Keys: String, CodingKey {
        case id, ord, text, section, page, minutes, kind, origin, userEdited, doneAt
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        ord = c.lenient(Double.self, .ord)
        section = c.lenient(String.self, .section)
        page = c.lenient(Int.self, .page)
        minutes = c.lenient(Int.self, .minutes) ?? 0
        kind = c.lenientRaw(.kind, default: ChecklistKind.other)
        origin = c.lenientRaw(.origin, default: ItemOrigin.heuristic)
        userEdited = c.lenient(Bool.self, .userEdited) ?? false
        doneAt = c.lenientDate(.doneAt)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.put(ord, .ord); try c.encode(text, forKey: .text)
        try c.put(section, .section); try c.put(page, .page); try c.encode(minutes, forKey: .minutes)
        try c.encode(kind.rawValue, forKey: .kind); try c.encode(origin.rawValue, forKey: .origin)
        try c.encode(userEdited, forKey: .userEdited); try c.putDate(doneAt, .doneAt)
    }
}

extension CardSidecar.CategoryRef {
    private enum Keys: String, CodingKey { case name, userSet }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(name: c.lenient(String.self, .name), userSet: c.lenient(Bool.self, .userSet) ?? false)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.put(name, .name); try c.encode(userSet, forKey: .userSet)
    }
}

extension CardSidecar.AI {
    private enum Keys: String, CodingKey { case provider, model, cardVersion, generatedAt, card, tldr }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(provider: c.lenient(String.self, .provider), model: c.lenient(String.self, .model),
                  cardVersion: c.lenient(Int.self, .cardVersion), generatedAt: c.lenientDate(.generatedAt),
                  card: c.lenient(ReadingCard.self, .card), tldr: c.lenient(String.self, .tldr))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.put(provider, .provider); try c.put(model, .model); try c.put(cardVersion, .cardVersion)
        try c.putDate(generatedAt, .generatedAt); try c.put(card, .card); try c.put(tldr, .tldr)
    }
}

extension CardSidecar.ProvenanceEntry {
    private enum Keys: String, CodingKey {
        case kind, mailMessageID, internetMessageID, fromAddress, fromName, subject, receivedAt, webLink
        case requestKind, summary, dueHint, addedAt, document
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.lenient(String.self, .kind) ?? "email"
        mailMessageID = c.lenient(String.self, .mailMessageID)
        internetMessageID = c.lenient(String.self, .internetMessageID)
        fromAddress = c.lenient(String.self, .fromAddress)
        fromName = c.lenient(String.self, .fromName)
        subject = c.lenient(String.self, .subject)
        receivedAt = c.lenientDate(.receivedAt)
        webLink = c.lenient(String.self, .webLink)
        requestKind = c.lenient(String.self, .requestKind)
        summary = c.lenient(String.self, .summary)
        dueHint = c.lenientLocalDate(.dueHint)
        addedAt = c.lenientDate(.addedAt)
        document = c.lenient(String.self, .document)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind); try c.put(mailMessageID, .mailMessageID)
        try c.put(internetMessageID, .internetMessageID); try c.put(fromAddress, .fromAddress)
        try c.put(fromName, .fromName); try c.put(subject, .subject); try c.putDate(receivedAt, .receivedAt)
        try c.put(webLink, .webLink); try c.put(requestKind, .requestKind); try c.put(summary, .summary)
        try c.put(dueHint?.iso, .dueHint); try c.putDate(addedAt, .addedAt)
        if let document { try c.encode(document, forKey: .document) }
    }
}

// MARK: - Library manifest

/// `.paperdeck-library.json` at the library root: the library-wide facts a rebuild
/// needs besides the card.json files (categories incl. description/hue, skip days).
/// `categories[].createdAt` is an addition to §5 so rebuilds keep it.
package struct LibraryManifest: Codable, Sendable, Equatable {
    package static let currentFormat = 1
    package static let fileName = ".paperdeck-library.json"

    package struct CategoryEntry: Codable, Sendable, Equatable {
        package var name: String
        package var description: String?
        package var hue: Int
        package var origin: CategoryOrigin
        package var acknowledged: Bool
        package var createdAt: Date?

        package init(name: String, description: String?, hue: Int, origin: CategoryOrigin,
                     acknowledged: Bool, createdAt: Date?) {
            self.name = name; self.description = description; self.hue = hue; self.origin = origin
            self.acknowledged = acknowledged; self.createdAt = createdAt
        }

        package init(_ category: PaperCategory) {
            self.init(name: category.name, description: category.description, hue: category.hue,
                      origin: category.origin, acknowledged: category.acknowledged, createdAt: category.createdAt)
        }

        private enum Keys: String, CodingKey { case name, description, hue, origin, acknowledged, createdAt }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = try c.decode(String.self, forKey: .name)
            description = c.lenient(String.self, .description)
            hue = c.lenient(Int.self, .hue) ?? 0
            origin = c.lenientRaw(.origin, default: CategoryOrigin.user)
            acknowledged = c.lenient(Bool.self, .acknowledged) ?? true
            createdAt = c.lenientDate(.createdAt)
        }

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .name); try c.put(description, .description)
            try c.encode(hue, forKey: .hue); try c.encode(origin.rawValue, forKey: .origin)
            try c.encode(acknowledged, forKey: .acknowledged); try c.putDate(createdAt, .createdAt)
        }
    }

    package var libraryID: String
    package var format: Int
    package var categories: [CategoryEntry]
    package var skipDays: [LocalDate]           // ascending, unique
    package var updatedAt: Date?

    package init(libraryID: String, categories: [PaperCategory], skipDays: Set<LocalDate>, updatedAt: Date = Date()) {
        self.libraryID = libraryID
        format = Self.currentFormat
        self.categories = categories.map(CategoryEntry.init)
        self.skipDays = skipDays.sorted()
        self.updatedAt = updatedAt
    }

    package var skipDaySet: Set<LocalDate> { Set(skipDays) }

    /// Categories for a rebuild (pk 0); missing creation dates become `fallbackDate`.
    package func categoryModels(fallbackDate: Date = Date(timeIntervalSince1970: 0)) -> [PaperCategory] {
        categories.map {
            PaperCategory(name: $0.name, description: $0.description, hue: $0.hue, origin: $0.origin,
                     acknowledged: $0.acknowledged, createdAt: $0.createdAt ?? fallbackDate)
        }
    }

    package func encoded() throws -> Data {
        var data = try CardSidecar.makeEncoder().encode(self)
        data.append(0x0A)
        return data
    }

    package static func decoded(from data: Data) throws -> LibraryManifest {
        try JSONDecoder().decode(LibraryManifest.self, from: data)
    }

    private enum Keys: String, CodingKey { case libraryID, format, categories, skipDays, updatedAt }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        libraryID = try c.decode(String.self, forKey: .libraryID)
        format = c.lenient(Int.self, .format) ?? Self.currentFormat
        guard format <= Self.currentFormat else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c,
                                                   debugDescription: "Library format \(format) is newer than supported")
        }
        categories = c.lenientArray(CategoryEntry.self, .categories)
        skipDays = Array(Set(c.lenientArray(String.self, .skipDays).compactMap(LocalDate.init(iso:)))).sorted()
        updatedAt = c.lenientDate(.updatedAt)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(libraryID, forKey: .libraryID); try c.encode(format, forKey: .format)
        try c.encode(categories, forKey: .categories); try c.encode(skipDays.map(\.iso), forKey: .skipDays)
        try c.putDate(updatedAt, .updatedAt)
    }
}

// MARK: - Helpers

/// ISO-8601 UTC timestamps: whole seconds when exact ("2026-09-30T10:42:00Z"),
/// otherwise millisecond precision. Parsing also accepts offsets and any fraction length,
/// and rounds to the millisecond like `Database.date(fromTimestamp:)`, so a rebuilt row
/// holds the same instant as the original.
private enum SidecarDate {
    static func format(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (secs, ms) = totalMs.quotientAndRemainder(dividingBy: 1000)
        let (s, m) = ms < 0 ? (secs - 1, ms + 1000) : (secs, ms)
        let base = Date(timeIntervalSince1970: TimeInterval(s)).formatted(.iso8601)   // "…Z"
        guard m != 0 else { return base }
        return String(base.dropLast()) + String(format: ".%03lldZ", m)
    }

    static func parse(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard let t = s.firstIndex(of: "T") else { return nil }
        var fraction = 0.0
        var plain = s
        if let dot = s[t...].firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix(while: \.isNumber)
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            plain = String(s[..<dot]) + String(s[s.index(after: dot)...].dropFirst(digits.count))
        }
        guard let base = try? Date(plain, strategy: .iso8601) else { return nil }
        let totalMs = (base.timeIntervalSince1970 * 1000).rounded() + (fraction * 1000).rounded()
        return Date(timeIntervalSince1970: totalMs / 1000)
    }
}

fileprivate extension KeyedDecodingContainer {
    /// nil when missing, null or of the wrong type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lenientRaw<E: RawRepresentable>(_ key: Key, default fallback: E) -> E where E.RawValue: Decodable {
        lenient(E.RawValue.self, key).flatMap(E.init(rawValue:)) ?? fallback
    }

    func lenientDate(_ key: Key) -> Date? {
        lenient(String.self, key).flatMap(SidecarDate.parse)
    }

    func lenientLocalDate(_ key: Key) -> LocalDate? {
        lenient(String.self, key).flatMap(LocalDate.init(iso:))
    }

    /// Elements that fail to decode are dropped, not the whole array.
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (lenient([SidecarLenient<T>].self, key) ?? []).compactMap(\.value)
    }
}

fileprivate extension KeyedEncodingContainer {
    mutating func put<T: Encodable>(_ value: T?, _ key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    mutating func putDate(_ date: Date?, _ key: Key) throws {
        try put(date.map(SidecarDate.format), key)
    }
}

private struct SidecarLenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
