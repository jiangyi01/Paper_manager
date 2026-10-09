import Foundation

// Paper Q&A model (DQ §6, READING_ASSIST_PLAN §4, §6.4 C2/C3). Owned by Slice C. Slice 0 created the
// minimum the frozen `QAService` signatures need; C2 adds citations, context statistics, the
// persisted fields of a message and the confirmation event.

/// How much of each paper a thread sends: the cards only, question-aware excerpts, or full text
/// (full text only for ≤ 3 papers).
package enum QAContextMode: String, Sendable, Codable, CaseIterable {
    case cards, excerpts, fullText

    /// The default for a thread over `count` papers: one paper → full text (question-aware pages
    /// once it exceeds the budget), ≤ 3 → full text, more → excerpts.
    package static func defaultMode(paperCount count: Int) -> QAContextMode { count > fullTextMaxPapers ? .excerpts : .fullText }

    /// Full text is offered for at most this many papers.
    package static let fullTextMaxPapers = 3

    /// The modes a thread over `count` papers may use.
    package static func allowed(paperCount count: Int) -> [QAContextMode] {
        count > fullTextMaxPapers ? [.cards, .excerpts] : (count > 1 ? [.cards, .excerpts, .fullText] : [.fullText])
    }
}

package struct QAOptions: Sendable, Equatable {
    /// Quick by default (`AssistSettings.qaDepth`'s default; "Thorough" is the user's per-question choice).
    package var depth: AssistSettings.Depth
    package var language: AssistSettings.AnswerLanguage
    /// The user confirmed the privacy sheet for this question (unpublished / confidential /
    /// person-sourced papers). Without it such a paper's question ends with `.needsConfirmation`.
    package var privacyAcknowledged: Bool

    package init(depth: AssistSettings.Depth = .quick, language: AssistSettings.AnswerLanguage = .auto,
                 privacyAcknowledged: Bool = false) {
        self.depth = depth; self.language = language; self.privacyAcknowledged = privacyAcknowledged
    }
}

package struct QAThread: Sendable, Equatable, Identifiable {
    package enum Scope: String, Sendable, Codable { case paper, multi }
    package var id: String
    package var scope: Scope
    package var paperIDs: [String]
    package var title: String
    package var mode: QAContextMode
    package var createdAt: Date
    package var updatedAt: Date
    package var archived: Bool
    /// The thread's answer-language choice (the EN / 中 / Auto toggle).
    package var language: AssistSettings.AnswerLanguage
    /// Stored in the library (false: created, no question asked yet).
    package var persisted: Bool

    package init(id: String = UUID().uuidString.lowercased(), paperIDs: [String], title: String,
                 mode: QAContextMode, createdAt: Date, archived: Bool = false,
                 language: AssistSettings.AnswerLanguage = .auto, persisted: Bool = false) {
        self.id = id; self.scope = paperIDs.count > 1 ? .multi : .paper; self.paperIDs = paperIDs
        self.title = title; self.mode = mode; self.createdAt = createdAt; self.updatedAt = createdAt
        self.archived = archived; self.language = language; self.persisted = persisted
    }
}

/// One citation in an answer: `[p. 7]`, `[pp. 7–9]`, `[P2 p. 5]`, or a card-only `[P2]`.
package struct QACitation: Sendable, Equatable, Hashable, Codable {
    /// Why a citation is invalid (the chip's help names it; the chip is drawn dimmed).
    package enum Problem: String, Sendable, Codable, Hashable {
        /// `[P5 p. 3]` in a question about three papers.
        case unknownPaper
        /// A page the PDF doesn't have.
        case pageMissing
        /// `[p. 5]` without a paper label in a question about several papers: which paper is unknown.
        case ambiguous
        /// A page that wasn't sent with the question (left out by the budget, a cards-only question,
        /// no text layer): the model never saw it, so the citation can't be checked.
        case notSent
    }

    /// 1-based paper label (P1…Pn); 1 in a single-paper thread. 0 while parsed without a label
    /// (`[p. 5]`): `QACitations.validate` makes it 1 when the thread has one paper, and marks it
    /// `.ambiguous` when it has several.
    package var paper: Int
    /// Physical page (the `[[p. N]]` index, 1-based); nil for a card-only citation.
    package var page: Int?
    /// Last page of a range (`pp. 7–9`).
    package var endPage: Int?
    /// The PDF's printed page label when it differs from the physical page ("1203").
    package var label: String?
    /// The paper exists in the thread and the page within its page count.
    package var valid: Bool
    /// The sentence on the cited page that best supports the claim (chosen locally, no tokens).
    package var quote: String?
    /// nil: not checked (no page text, or too little to compare); false: no sentence on the page
    /// supports the claim (the chip is drawn outlined).
    package var quoteFound: Bool?
    /// Why `valid` is false (nil while valid; also nil in answers stored before Phase 2 fixes —
    /// `QACitations.problem(of:paperCount:)` derives it then).
    package var problem: Problem?

    package init(paper: Int = 1, page: Int?, endPage: Int? = nil, label: String? = nil, valid: Bool = true,
                 quote: String? = nil, quoteFound: Bool? = nil, problem: Problem? = nil) {
        self.paper = paper; self.page = page; self.endPage = endPage; self.label = label; self.valid = valid
        self.quote = quote; self.quoteFound = quoteFound; self.problem = problem
    }
}

/// What a question sent (persisted with the answer; the "≈ 21k tokens" line and the history).
package struct QAContextStats: Sendable, Equatable, Codable {
    package var mode: QAContextMode
    package var chars: Int
    package var estimatedTokens: Int
    /// Physical pages sent, per paper (P1 first).
    package var pages: [[Int]]
    /// Pages left out by the budget, all papers together.
    package var omittedPages: Int
    /// Every paper went in full.
    package var fullText: Bool

    package init(mode: QAContextMode, chars: Int, estimatedTokens: Int, pages: [[Int]] = [], omittedPages: Int = 0,
                 fullText: Bool = false) {
        self.mode = mode; self.chars = chars; self.estimatedTokens = estimatedTokens; self.pages = pages
        self.omittedPages = omittedPages; self.fullText = fullText
    }
}

package struct QAMessage: Sendable, Equatable, Identifiable {
    package enum State: String, Sendable, Codable { case streaming, done, failed, cancelled }
    package var id: String
    package var threadID: String
    package var role: AssistTurnText.Role
    package var text: String
    package var state: State
    package var meta: AssistMeta?
    package var createdAt: Date
    /// Answers: the citations in order of appearance (validated, with their supporting sentence).
    package var citations: [QACitation]
    /// Answers: `en` / `zh`, the language the answer was asked in.
    package var language: String?
    package var depth: AssistSettings.Depth?
    /// Failed / cancelled answers: a short code (`usage_limit`, `not_logged_in`, `timeout`, …).
    package var errorKind: String?
    package var context: QAContextStats?
    /// Position in the thread (0-based; assigned by the store).
    package var ord: Int

    package init(id: String = UUID().uuidString.lowercased(), threadID: String, role: AssistTurnText.Role,
                 text: String, state: State = .done, meta: AssistMeta? = nil, createdAt: Date,
                 citations: [QACitation] = [], language: String? = nil, depth: AssistSettings.Depth? = nil,
                 errorKind: String? = nil, context: QAContextStats? = nil, ord: Int = 0) {
        self.id = id; self.threadID = threadID; self.role = role; self.text = text; self.state = state
        self.meta = meta; self.createdAt = createdAt; self.citations = citations; self.language = language
        self.depth = depth; self.errorKind = errorKind; self.context = context; self.ord = ord
    }
}

/// What one question would send (the estimate line before Send).
package struct QAEstimate: Sendable, Equatable {
    package var chars: Int
    package var estimatedTokens: Int
    /// Physical pages included (empty: cards only). Multi-paper: every paper's pages together.
    package var pages: [Int]
    /// Papers or pages left out by the budget.
    package var omitted: Int
    /// The model the question would run on (nil: assist off).
    package var model: String?
    /// The provider (`AssistMode` raw value) it would run on.
    package var provider: String?
    /// Expected answer time in seconds (the median of recent answers, or a default per model).
    package var latency: ClosedRange<Int>?
    package var mode: QAContextMode
    /// Every paper goes in full.
    package var fullText: Bool
    package var papers: Int

    package init(chars: Int, estimatedTokens: Int, pages: [Int] = [], omitted: Int = 0, model: String? = nil,
                 provider: String? = nil, latency: ClosedRange<Int>? = nil, mode: QAContextMode = .fullText,
                 fullText: Bool = false, papers: Int = 1) {
        self.chars = chars; self.estimatedTokens = estimatedTokens; self.pages = pages; self.omitted = omitted
        self.model = model; self.provider = provider; self.latency = latency; self.mode = mode
        self.fullText = fullText; self.papers = papers
    }
}

package enum QAEvent: Sendable, Equatable {
    case started(QAEstimate)
    case phase(AssistPhase)
    case delta(String)
    /// The whole answer so far (authoritative; a backend that rewrote its text).
    case replace(String)
    case completed(QAMessage)
    case failed(AssistFailure, partial: String?)
    /// A paper is unpublished / confidential / person-sourced: nothing was sent or stored; ask
    /// again with `QAOptions.privacyAcknowledged` after the user confirmed (a fresh gesture).
    case needsConfirmation([AssistPrivacy.Reason])
}

extension AssistFailure {
    /// A short code stored with a failed answer (`qa_message.error_kind`).
    package var code: String {
        switch self {
        case .refused(let v): return "refused:" + String(describing: v)
        case .usageLimit: return "usage_limit"
        case .notLoggedIn: return "not_logged_in"
        case .overloaded: return "overloaded"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .binaryMissing: return "binary_missing"
        case .unsupported: return "unsupported"
        case .invalidOutput: return "invalid_output"
        case .generic: return "generic"
        }
    }
}

// MARK: - Clicks that send (the Ask views' rules, kept here so they are testable)

/// What a click in the Ask views asks for (the App's `AskIntent`). Every intent that sends a
/// question is performed with a `ConsentTicket` the hosting view made in that click's action handler.
package enum QAIntent: Equatable, Sendable {
    /// The composer's question.
    case ask(String)
    /// The question again after a failure (the current thread's).
    case retry
    /// "Send Anyway" on the privacy confirmation: the one send the user's confirmation covers.
    case confirmPrivacy
    /// "Continue" past today's soft cap.
    case continuePastCap
    /// The question of this answer again, with the Thorough model.
    case thorough(messageID: String)
    /// The question of this answer (`messageID`; nil: the latest finished answer) again, answered
    /// in `UILang` — a one-off: the thread's language toggle stays.
    case translate(UILang, messageID: String? = nil)

    /// The gesture a ticket for this click is made with (`firstQuestion`: the thread has no message yet).
    package func gesture(firstQuestion: Bool) -> ConsentTicket.Gesture {
        switch self {
        case .ask: return firstQuestion ? .ask : .followUp
        case .retry: return .retry
        case .continuePastCap: return .capOverride
        case .confirmPrivacy, .thorough, .translate: return .action
        }
    }
}

/// A question as it was last sent from one Ask surface — what Try Again and Continue resend. Its
/// options never carry the privacy acknowledgement: a confirmation covers exactly one send
/// (Phase 2 fix QA-6), so a resend of a confirmable paper asks again.
package struct QASentQuestion: Sendable, Equatable {
    package var threadID: String?
    package var question: String
    package private(set) var options: QAOptions

    package init(threadID: String?, question: String, options: QAOptions) {
        self.threadID = threadID; self.question = question
        var o = options
        o.privacyAcknowledged = false
        self.options = o
    }
}

/// What one click sends: the question and its options. Pure (the Ask views call it from `perform`).
package enum QASendPlan {
    package struct Send: Sendable, Equatable {
        package var question: String
        package var options: QAOptions
    }

    /// The send of `intent`, or nil when there is nothing to send.
    /// - `current`: the toggles' options (Quick / Thorough, the language).
    /// - `last`: the question this surface sent last (Try Again / Continue resend it only in its own thread).
    /// - `threadID`, `messages`: the thread on screen.
    /// - `confirming`: the question and options of the privacy confirmation on screen.
    package static func send(_ intent: QAIntent, current: QAOptions, last: QASentQuestion?, threadID: String?,
                             messages: [QAMessage], confirming: (question: String, options: QAOptions)?) -> Send? {
        var options = current
        options.privacyAcknowledged = false
        switch intent {
        case .ask(let raw):
            let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? nil : Send(question: q, options: options)
        case .retry, .continuePastCap:
            // The question this surface sent, if it went to this thread; else the thread's own
            // unanswered question with the toggles' options. Never a stale confirmation.
            if let last, last.threadID == threadID,
               trailingQuestion(messages).map({ $0 == last.question }) ?? true {
                return Send(question: last.question, options: last.options)
            }
            return trailingQuestion(messages).map { Send(question: $0, options: options) }
        case .confirmPrivacy:
            guard let confirming else { return nil }
            var o = confirming.options
            o.privacyAcknowledged = true
            let q = confirming.question.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? nil : Send(question: q, options: o)
        case .thorough(let id):
            guard let q = question(answering: id, in: messages) else { return nil }
            options.depth = .thorough
            return Send(question: q, options: options)
        case .translate(let target, let id):
            let answer = id ?? messages.last { $0.role == .assistant && $0.state == .done }?.id
            guard let answer, let q = question(answering: answer, in: messages) else { return nil }
            options.language = target == .zh ? .zh : .en
            return Send(question: q, options: options)
        }
    }

    /// A question stored without an answer at the end of the thread (a refused one).
    package static func trailingQuestion(_ messages: [QAMessage]) -> String? {
        guard let last = messages.last, last.role == .user else { return nil }
        return last.text
    }

    /// The user question an answer replied to.
    package static func question(answering messageID: String, in messages: [QAMessage]) -> String? {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), messages[i].role == .assistant else { return nil }
        return messages[..<i].last { $0.role == .user }?.text
    }
}

extension AssistSettings {
    /// Papers one Ask window takes (`assist.qa.multiMax`): the Settings stepper's range and the
    /// window's clamp (Phase 2 fix QA-14; the loader's clamp and the import rule should match it).
    package static let qaMultiMaxRange: ClosedRange<Int> = 2...20
}

/// Why a Q&A operation was refused.
package enum QAError: Error, Equatable, Sendable {
    case unknownThread(String)
    case unknownMessage(String)
    /// `saveToNotes` of a question, an unfinished answer, or an answer with no text.
    case notAnAnswer(String)
    /// A `qa.json` of another schema.
    case unsupportedSidecar(String)
}
