import Foundation

// The Mail inbox read model (MAIL_DESIGN Part A §3): one consistent snapshot for the sidebar
// badge, the segmented inbox (待处理 · 稍后 · 已处理 · 已忽略 · 无阅读需求), the detail inspector,
// Settings ▸ Mail (account statuses, today's triage usage) and the menu / panel / reminder lines.

/// The inbox's segmented filter.
package enum MailInboxFilter: String, Sendable, CaseIterable, Identifiable {
    case pending        // 待处理
    case snoozed        // 稍后
    case handled        // 已处理 (merged)
    case dismissed      // 已忽略
    case noRequest      // 无阅读需求

    package var id: String { rawValue }

    package var state: MailState {
        switch self {
        case .pending: return .pending
        case .snoozed: return .snoozed
        case .handled: return .merged
        case .dismissed: return .dismissed
        case .noRequest: return .noRequest
        }
    }

    package init(_ state: MailState) {
        switch state {
        case .pending: self = .pending
        case .snoozed: self = .snoozed
        case .merged: self = .handled
        case .dismissed: self = .dismissed
        case .noRequest: self = .noRequest
        }
    }

    /// How many cards a snapshot loads for this filter (newest first).
    package var snapshotLimit: Int {
        switch self {
        case .pending, .snoozed: return 500
        case .handled, .dismissed, .noRequest: return 200
        }
    }
}

/// One email card: the message, its paper rows and what the card shows about them.
package struct MailCard: Sendable, Equatable, Identifiable {
    package var message: MailMessage
    package var items: [MailItem]                  // ord order
    package var rule: SenderRule?                  // the sender rule (nil for unmatched manual drops)
    package var account: MailAccount?              // nil for manual drops / removed accounts
    /// Open rows that still need a PDF from the user (「还差 N 篇需要 PDF」); `listed` alert rows are not counted.
    package var needsPDFCount: Int
    /// Open rows that can be merged / linked right now (PDF attached, downloadable, or already in the library).
    package var readyCount: Int
    /// The triage state to show: `running` while the lane is working on this message.
    package var displayTriageState: MailTriageState
    /// The stored email has a body. Inbox snapshots (`Engine.mailSnapshot`) carry no bodies
    /// (`message.bodyText` nil): load the card with `Engine.mailCard(id:)` to show it. False for
    /// an empty or purged (`message.bodyPurged`) body.
    package var hasBody: Bool

    package var id: String { message.id }
    package var filter: MailInboxFilter { MailInboxFilter(message.state) }
    /// 「让 AI 分析」 is offered (not on a dismissed or merged card: reopen it first).
    package var canRequestAI: Bool {
        [.awaitingConsent, .failed, .held, .none].contains(message.triageState) && !message.bodyPurged
            && message.triageSource != .ai && rule?.aiPolicy != .never
            && message.state != .dismissed && message.state != .merged
    }

    /// `hasBody` nil: whether `message` carries a non-empty body.
    package init(message: MailMessage, items: [MailItem], rule: SenderRule?, account: MailAccount?,
                 runningTriagePK: Int64? = nil, hasBody: Bool? = nil) {
        self.message = message
        self.hasBody = hasBody ?? (!message.bodyPurged && !(message.bodyText ?? "").isEmpty)
        self.items = items.sorted { ($0.ord, $0.pk) < ($1.ord, $1.pk) }
        self.rule = rule
        self.account = account
        let relevant = items.filter { $0.isOpen && $0.relevance != .listed }
        // Slides to export and shared files wait for the user's PDF too; a stored Word document is
        // ready (it converts on its row's button).
        self.needsPDFCount = relevant.filter { $0.pdfState == .needsPDF || $0.pdfState == .openOnly }.count
        self.readyCount = relevant.filter { [.hasPDF, .downloadable, .inLibrary, .convertible].contains($0.pdfState) }.count
        if runningTriagePK == message.pk, [.queued, .limited, .needsLogin].contains(message.triageState) {
            self.displayTriageState = .running
        } else {
            self.displayTriageState = message.triageState
        }
    }
}

package struct MailCounts: Sendable, Equatable {
    package var pending: Int                       // cards in 待处理 (sidebar badge)
    package var requests: Int                      // … of them reading requests from people (red badge)
    package var awaitingConsent: Int               // open cards offering 「让 AI 分析」
    package var needsPDF: Int                      // Σ rows needing a PDF over pending cards
    package var snoozed: Int

    package init(pending: Int = 0, requests: Int = 0, awaitingConsent: Int = 0, needsPDF: Int = 0, snoozed: Int = 0) {
        self.pending = pending; self.requests = requests; self.awaitingConsent = awaitingConsent
        self.needsPDF = needsPDF; self.snoozed = snoozed
    }
}

package struct MailSnapshot: Sendable, Equatable {
    package let groups: [MailInboxFilter: [MailCard]]   // newest received first
    package let counts: MailCounts
    package let accounts: [MailAccountSyncInfo]          // Settings order
    package let triageUsage: MailTriageUsage
    package let triageQueued: Int                         // lane jobs waiting (all providers)
    package let enabled: Bool                             // Settings ▸ Mail master switch
    package let aiMode: MailSettings.AIMode
    package let generatedAt: Date
    private let index: [String: MailCard]

    package init(groups: [MailInboxFilter: [MailCard]], counts: MailCounts, accounts: [MailAccountSyncInfo],
                 triageUsage: MailTriageUsage, triageQueued: Int, enabled: Bool, aiMode: MailSettings.AIMode,
                 generatedAt: Date) {
        self.groups = groups; self.counts = counts; self.accounts = accounts; self.triageUsage = triageUsage
        self.triageQueued = triageQueued; self.enabled = enabled; self.aiMode = aiMode; self.generatedAt = generatedAt
        var index: [String: MailCard] = [:]
        for cards in groups.values { for c in cards where index[c.id] == nil { index[c.id] = c } }
        self.index = index
    }

    package func cards(_ filter: MailInboxFilter) -> [MailCard] { groups[filter] ?? [] }
    package func card(id: String) -> MailCard? { index[id.lowercased()] }
    package var isEmpty: Bool { index.isEmpty }

    /// Last known status per account id (the ones checked so far).
    package var accountStatuses: [String: MailSourceStatus] {
        var out: [String: MailSourceStatus] = [:]
        for a in accounts { if let s = a.status { out[a.id] = s } }
        return out
    }

    /// Same content: `generatedAt` (the read time) and the derived `index` are not compared, so
    /// a periodic refresh that read the same inbox does not invalidate the views.
    package static func == (a: MailSnapshot, b: MailSnapshot) -> Bool {
        a.counts == b.counts && a.triageQueued == b.triageQueued && a.enabled == b.enabled && a.aiMode == b.aiMode
            && a.triageUsage == b.triageUsage && a.accounts == b.accounts && a.groups == b.groups
    }
}

extension Engine {
    /// The whole inbox from one DB read (messages per filter, their rows, the badge counts),
    /// plus the sync actor's account statuses (in the UI language) and today's triage usage.
    /// Cards carry no bodies (`message.bodyText` nil, `MailCard.hasBody` says whether there is
    /// one): a periodic refresh neither reads nor compares them — `mailCard(id:)` has the body.
    package func mailSnapshot() async throws -> MailSnapshot {
        let settings = loadMailSettings()
        let lang = await ctx.settings().lang
        typealias Head = (message: MailMessage, hasBody: Bool)
        let read = try await db.transaction { db -> ([MailInboxFilter: [Head]], [Int64: [MailItem]], (pending: Int, requests: Int)) in
            var byFilter: [MailInboxFilter: [Head]] = [:]
            var pks: [Int64] = []
            for f in MailInboxFilter.allCases {
                let list = try db.mailMessageHeads(states: [f.state], limit: f.snapshotLimit)
                byFilter[f] = list
                pks += list.map(\.message.pk)
            }
            return (byFilter, try db.mailItems(messagePKs: pks), try db.mailCounts())
        }
        let lane = await agents.triageStatus()
        let accounts = await mail.accountSyncInfo(lang: lang)
        let usage = await mailTriage.usage()
        var groups: [MailInboxFilter: [MailCard]] = [:]
        for (filter, heads) in read.0 {
            groups[filter] = heads.map { head in
                let m = head.message
                return MailCard(message: MailMachineText.localized(m, lang),
                                items: MailMachineText.localized(read.1[m.pk] ?? [], lang), rule: settings.rule(id: m.ruleID),
                                account: settings.account(id: m.accountID), runningTriagePK: lane.runningMessagePK,
                                hasBody: head.hasBody)
            }
        }
        let pending = groups[.pending] ?? []
        let open = pending + (groups[.snoozed] ?? [])
        let counts = MailCounts(pending: read.2.pending, requests: read.2.requests,
                                awaitingConsent: open.filter { $0.message.triageState == .awaitingConsent }.count,
                                needsPDF: pending.reduce(0) { $0 + $1.needsPDFCount },
                                snoozed: groups[.snoozed]?.count ?? 0)
        return MailSnapshot(groups: groups, counts: counts, accounts: accounts, triageUsage: usage,
                            triageQueued: lane.queued, enabled: settings.enabled, aiMode: settings.aiMode,
                            generatedAt: ctx.now())
    }

    /// One card by message id (detail inspector, deep link `paperdeck://mail/<id>`), with its full body.
    package func mailCard(id: String) async throws -> MailCard? {
        let settings = loadMailSettings()
        guard let m = try await db.mailMessage(id: id) else { return nil }
        let items = try await db.mailItems(messagePK: m.pk)
        let lane = await agents.triageStatus()
        let lang = await ctx.settings().lang
        return MailCard(message: MailMachineText.localized(m, lang), items: MailMachineText.localized(items, lang),
                        rule: settings.rule(id: m.ruleID),
                        account: settings.account(id: m.accountID), runningTriagePK: lane.runningMessagePK)
    }
}

// MARK: - Stored machine text in the current language

/// Texts PaperDeck itself wrote into a card while it was captured, triaged or merged — download
/// errors of its rows (incl. why an email merge's import failed), triage notes (「今日 AI 分拣已达
/// 上限…」), the local rules' summary of an alert digest — are stored in the UI language of that
/// moment. `localized` shows them in the
/// current language: a known text (en or zh, numbers included) is worded again; anything else
/// (an AI summary, a sentence quoted from the email) is left alone.
package enum MailMachineText {
    /// The message with its triage note and (local-rules) summary in `lang`.
    package static func localized(_ m: MailMessage, _ lang: UILang) -> MailMessage {
        var out = m
        if let e = m.triageError { out.triageError = localized(e, lang) }
        if m.triageSource == .heuristic, var t = m.triage {
            let s = localized(t.summary, lang)
            if s != t.summary {
                t.summary = s
                out.triage = t
            }
        }
        return out
    }

    /// An account row with its status text in `lang` (the pipeline's own texts) — for a copy read
    /// earlier; `MailSyncActor.accountSyncInfo(lang:)` already words every status in the language
    /// asked, the transports' texts included.
    package static func localized(_ info: MailAccountSyncInfo, _ lang: UILang) -> MailAccountSyncInfo {
        guard let status = info.status else { return info }
        var out = info
        switch status {
        case .ready(let d): out.status = .ready(detail: localized(d, lang))
        case .needsSetup(let m): out.status = .needsSetup(localized(m, lang))
        case .authFailed(let m): out.status = .authFailed(localized(m, lang))
        case .unavailable(let m): out.status = .unavailable(localized(m, lang))
        }
        return out
    }

    /// The rows with their download errors in `lang`.
    package static func localized(_ items: [MailItem], _ lang: UILang) -> [MailItem] {
        guard items.contains(where: { $0.downloadError != nil }) else { return items }
        return items.map { item in
            guard let e = item.downloadError else { return item }
            var out = item
            out.downloadError = localized(e, lang)
            return out
        }
    }

    /// One stored machine text in `lang`; unknown text unchanged.
    package static func localized(_ text: String, _ lang: UILang) -> String {
        if let render = fixed[text] { return render(lang) }
        let from: UILang = text.unicodeScalars.contains(where: isCJK) ? .zh : .en
        guard from != lang else { return text }
        for t in templates {
            if let numbers = t.match(text, from) { return t.render(lang, numbers) }
        }
        return text
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(u.value) || (0x4E00...0x9FFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value)
    }

    /// Texts without numbers, by their en and zh wording.
    private static let fixed: [String: @Sendable (UILang) -> String] = {
        var producers: [@Sendable (UILang) -> String] = [
            { MailSyncText.attachmentNotStored($0) }, { MailSyncText.bodyPurged($0) },
            { MailSyncText.aiUnavailable($0) }, { MailSyncText.usageLimited(nil, $0) },
            { MailSyncText.needsLogin($0) }, { MailSyncText.fetchFailed($0) }, { MailSyncText.syncFailed($0) },
            { MailSyncText.triageFailed(.timeout, $0) }, { MailSyncText.triageFailed(.overloaded, $0) },
            { MailSyncText.triageFailed(.invalidOutput(""), $0) }, { MailSyncText.triageFailed(.generic(""), $0) },
            { MailPDFFetcher.Rejection.notPDF.message($0, capMB: 1) },
            { MailPDFFetcher.Rejection.incomplete.message($0, capMB: 1) },
            { MailPDFFetcher.Rejection.writeFailed.message($0, capMB: 1) },
            // Documents (Word / slides) and their conversion.
            { MailSyncText.documentNotStored($0) },
            { MailPDFFetcher.Rejection.notPDF.documentMessage($0, capMB: 1) },
            { MailPDFFetcher.Rejection.incomplete.documentMessage($0, capMB: 1) },
            { DocumentConversionError.unsupported.message($0) }, { DocumentConversionError.encrypted.message($0) },
            { DocumentConversionError.unreadable.message($0) }, { DocumentConversionError.empty.message($0) },
            { DocumentConversionError.tooLarge.message($0) }, { DocumentConversionError.renderFailed.message($0) },
            { MailOpsText.documentMissing($0) },
            { MailOpsText.noPDFLink($0) }, { MailOpsText.notPDF($0) }, { MailOpsText.biorxivBlocked($0) },
            { MailOpsText.downloadFailed(status: nil, $0) }, { MailOpsText.importFailed($0) },
            { MailOpsText.privateAddress($0) }, { MailOpsText.notAutomatic($0) },
            { MailOpsText.inRecentlyDeleted($0) }, { MailOpsText.restoreFailed($0) },
            { MailHeuristics.noRequestSummary($0) }, { MailHeuristics.alertSummary(total: 1, highlighted: 0, lang: $0) },
            // Why an email merge's import failed (`ImportItemResult.Outcome.failureReason`, stored
            // as the row's download error by OperationsMail.mergeFiles).
            { IntakeText.reasonNotPDFLink($0) }, { IntakeText.reasonBlocked($0) }, { IntakeText.reasonLinkNotPDF($0) },
            { IntakeText.reasonNotPDF($0) }, { IntakeText.reasonAborted($0) }, { IntakeText.reasonLibraryWrite($0) },
            { IntakeText.downloadFailed(status: nil, $0) },
        ]
        let fileErrors: [FileOpsError] = [.notPDF, .sourceMissing, .permissionDenied, .diskFull,
                                          .hashMismatch(expected: "", actual: ""), .timeout, .destinationExists,
                                          .libraryUnavailable, .io("")]
        for e in fileErrors {            // commit failures word these too (or reasonLibraryWrite)
            producers.append { IntakeText.reason(for: e, $0) }
        }
        for wanted in AIProviderKind.allCases {
            producers.append { MailTriageRoute.modeOff(wanted: wanted).heldText($0) ?? "" }
            for mode in [AgentMode.off, .mock, .claude, .codex] {
                producers.append { MailTriageRoute.providerNotActive(wanted: wanted, mode: mode).heldText($0) ?? "" }
            }
        }
        var out: [String: @Sendable (UILang) -> String] = [:]
        for p in producers {
            for lang in [UILang.en, .zh] {
                let text = p(lang)
                if !text.isEmpty, out[text] == nil { out[text] = p }
            }
        }
        return out
    }()

    /// Texts with numbers: each wording is split around its numbers.
    private struct Template: Sendable {
        let render: @Sendable (UILang, [Int]) -> String
        /// Per language: the literal pieces between the numbers and which number each slot is.
        let parts: [UILang: (pieces: [String], order: [Int])]

        init(arity: Int, _ render: @escaping @Sendable (UILang, [Int]) -> String) {
            self.render = render
            let sentinels = (0..<arity).map { 913_570_001 + $0 * 1_111 }
            var parts: [UILang: (pieces: [String], order: [Int])] = [:]
            for lang in [UILang.en, .zh] {
                var rest = render(lang, sentinels)
                var pieces: [String] = []
                var order: [Int] = []
                while let (i, r) = sentinels.enumerated()
                    .compactMap({ i, n in rest.range(of: String(n)).map { (i, $0) } })
                    .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                    pieces.append(String(rest[..<r.lowerBound]))
                    order.append(i)
                    rest = String(rest[r.upperBound...])
                }
                pieces.append(rest)
                parts[lang] = (pieces, order)
            }
            self.parts = parts
        }

        /// The numbers when `text` is this template's wording in `lang`.
        func match(_ text: String, _ lang: UILang) -> [Int]? {
            guard let (pieces, order) = parts[lang], !order.isEmpty else { return nil }
            var numbers = [Int](repeating: 0, count: order.count)
            var rest = Substring(text)
            for (k, piece) in pieces.enumerated() {
                guard rest.hasPrefix(piece) else { return nil }
                rest = rest.dropFirst(piece.count)
                guard k < order.count else { break }
                let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
                guard !digits.isEmpty, digits.count <= 9, let n = Int(digits) else { return nil }
                numbers[order[k]] = n
                rest = rest.dropFirst(digits.count)
            }
            return rest.isEmpty ? numbers : nil
        }
    }

    private static let templates: [Template] = [
        Template(arity: 2) { MailSyncText.dailyCapReached(used: $1[0], limit: $1[1], $0) },
        Template(arity: 1) { IntakeText.downloadFailed(status: $1[0], $0) },
        Template(arity: 2) { MailPDFFetcher.Rejection.tooLarge(sizeBytes: $1[0] * 1_048_576).message($0, capMB: $1[1]) },
        Template(arity: 2) {
            MailPDFFetcher.Rejection.tooLarge(sizeBytes: $1[0] * 1_048_576).documentMessage($0, capMB: $1[1])
        },
        Template(arity: 1) { MailOpsText.downloadFailed(status: $1[0], $0) },
        Template(arity: 1) { MailHeuristics.containsPapersSummary($1[0], $0) },
        // Alert digests: "1 paper" is worded apart from "N papers".
        Template(arity: 2) { MailHeuristics.alertSummary(total: $1[0], highlighted: $1[1], lang: $0) },
        Template(arity: 1) { MailHeuristics.alertSummary(total: $1[0], highlighted: 0, lang: $0) },
        Template(arity: 1) { MailHeuristics.alertSummary(total: 1, highlighted: $1[0], lang: $0) },
    ]
}
