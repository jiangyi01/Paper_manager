import CoreGraphics
import Foundation

// Explain's models (LN §9.1). Owned by Slice A. Slice 0 created the part the frozen
// `ExplainCoordinator.begin(capture:ticket:)` signature needs; A3 adds the paper match's contract
// shape (`PaperMatch.confidence` / `MatchSource`), the turn's kind / language / level, the reader
// anchor, and the paper context (`ExplainContext`, PaperContextBuilder.swift).

/// Where an explanation's input came from (the `explanation.source` CHECK list, frozen in
/// SchemaAssist.swift: a new case needs ('assist', 2)).
package enum ExplainSource: String, Sendable, Codable, CaseIterable {
    case services, clipboard, screenshot, region, lens, reader, drop
}

/// One thing to explain: exact text (Services, the clipboard, the reader) or an image (a region,
/// a screenshot, a dropped image), with where it was captured.
package struct ExplainCapture: Sendable, Equatable {
    package var source: ExplainSource
    package var text: String?
    package var image: AssistImage?
    /// The frontmost app's bundle id at capture (privacy: mail / chat hosts ask first).
    package var hostBundleID: String?
    /// The window's title, used locally to locate the paper; never sent raw.
    package var windowTitle: String?
    /// The built-in reader's exact anchor (paper, physical page, rect): the paper is known.
    package var readerAnchor: ReaderAnchor?
    /// A click (not a box): `image` is the band around it and only what is under the click is
    /// explained (`ExplainFocusResolver`).
    package var focus: ExplainFocus?
    /// Who was on screen under the capture (every window showing part of it, PaperDeck's own
    /// readers and their papers, where copied text came from): the privacy check's input only —
    /// never sent, never stored (`CaptureSurroundings`, F1 / F2 of the phase-3 fixes).
    package var surroundings: CaptureSurroundings?
    /// The full-resolution crop of a screen capture, for local OCR and the click's paragraph only
    /// (`image` is what may be sent, already downscaled); dropped with the panel, never sent.
    package var ocrImage: CGImage?

    package init(source: ExplainSource, text: String? = nil, image: AssistImage? = nil, hostBundleID: String? = nil,
                 windowTitle: String? = nil, readerAnchor: ReaderAnchor? = nil, focus: ExplainFocus? = nil,
                 surroundings: CaptureSurroundings? = nil, ocrImage: CGImage? = nil) {
        self.source = source; self.text = text; self.image = image
        self.hostBundleID = hostBundleID; self.windowTitle = windowTitle; self.readerAnchor = readerAnchor
        self.focus = focus; self.surroundings = surroundings; self.ocrImage = ocrImage
    }
}

/// How a capture was matched to a library paper (stored as `explanation.match_via`, free text).
package enum MatchSource: String, Sendable, Codable, CaseIterable {
    /// The built-in reader: exact paper and page.
    case reader
    /// A DOI or arXiv id in the window title (a browser tab, an arXiv file name).
    case identifier
    /// The window title names the paper's PDF (its canonical or original file name).
    case fileName
    /// The window title matches the paper's title.
    case windowTitle
    /// The OCR / selected text was found in the paper's cached full text.
    case text
    /// A paper opened from PaperDeck moments ago (a tie-breaker, never evidence on its own).
    case recentOpen
    /// The user picked it in the panel.
    case user
}

/// Which library paper a capture shows (nil from the locator: none matched).
package struct PaperMatch: Sendable, Equatable {
    /// The A1 name of `MatchSource` (stored rows and their tests use it).
    package typealias Via = MatchSource

    package var paperID: String
    /// Physical, 1-based (what `[[p. N]]` counts); nil when only the paper is known.
    package var page: Int?
    /// 0…1: how sure the locator is (1 = the reader's exact anchor).
    package var confidence: Double
    package var via: MatchSource

    package init(paperID: String, page: Int? = nil, confidence: Double, via: MatchSource) {
        self.paperID = paperID; self.page = page; self.confidence = min(max(confidence, 0), 1); self.via = via
    }

    /// The A1 initializer (same fields; `score` is the confidence).
    package init(paperID: String, page: Int? = nil, via: MatchSource, score: Double) {
        self.init(paperID: paperID, page: page, confidence: score, via: via)
    }

    /// The A1 name of `confidence`.
    package var score: Double { confidence }
}

/// The located paper's context for a turn in its flat A1 form (title / venue line + the text
/// around the capture), already within the budget. `ExplainContext` is the structured form.
package struct PaperContext: Sendable, Equatable {
    package var paperID: String
    package var meta: String
    package var context: String

    package init(paperID: String, meta: String, context: String) {
        self.paperID = paperID; self.meta = meta; self.context = context
    }
}

/// What one Explain turn asks for (the panel's buttons, LN §7.3; the `<task kind=…>` line and the
/// stored `explanation.action`).
package enum ExplainKind: Sendable, Equatable, Hashable {
    /// Explain the selection (a passage; with an image and no text, the figure).
    case explain
    /// Again, more simply.
    case simpler
    /// Again, more technically.
    case technical
    /// Define the key terms.
    case terms
    /// Explain the figure / table / chart.
    case figure
    /// Explain the equation.
    case equation
    /// Translate the selection into the answer language.
    case translate
    /// A follow-up question about the selection (the panel's field).
    case ask(String)

    /// The stored `explanation.action`.
    package var code: String {
        switch self {
        case .explain: return "explain"
        case .simpler: return "simpler"
        case .technical: return "technical"
        case .terms: return "terms"
        case .figure: return "figure"
        case .equation: return "equation"
        case .translate: return "translate"
        case .ask: return "ask"
        }
    }

    /// The follow-up question, if any.
    package var question: String? {
        if case .ask(let q) = self { return q }
        return nil
    }
}

/// The answer's language: Simplified Chinese keeping each key term's English original on first
/// use (the approved default, D3), or English. Settings' `.ui` resolves to one of them.
package enum ExplainLanguage: String, Sendable, Codable, CaseIterable {
    case zh, en

    /// `assist.explain.lang` with `ui` resolved against the UI language.
    package static func resolve(_ setting: AssistSettings.ExplainLanguage, ui: UILang) -> ExplainLanguage {
        switch setting {
        case .zh: return .zh
        case .en: return .en
        case .ui: return ui == .zh ? .zh : .en
        }
    }

    /// The stored `explanation.lang`.
    package var uiLang: UILang { self == .zh ? .zh : .en }
}

/// How much the explanation assumes (`assist.explain.level`).
package typealias ExplainLevel = AssistSettings.Level

/// One stored explanation (`explanation` row). Excerpts are kept to `maxExcerpt` characters.
package struct ExplanationRecord: Sendable, Equatable, Identifiable {
    package static let maxExcerpt = 2_000
    package var id: String
    package var paperID: String?
    package var threadID: String
    package var turn: Int
    package var source: ExplainSource
    package var action: String
    package var lang: UILang
    package var page: Int?
    package var excerpt: String?
    package var question: String?
    package var answer: String
    package var hadImage: Bool
    package var meta: AssistMeta
    package var pinned: Bool
    package var savedToNotesAt: Date?
    package var createdAt: Date
    /// How the paper was located (nil: unmatched, or picked by the user).
    package var matchVia: PaperMatch.Via?
    package var matchScore: Double?
    /// A small capture thumbnail next to the library (optional; never the full capture).
    package var thumbPath: String?

    package init(id: String = UUID().uuidString.lowercased(), paperID: String?, threadID: String, turn: Int = 0,
                 source: ExplainSource, action: String, lang: UILang, page: Int? = nil, excerpt: String?,
                 question: String? = nil, answer: String, hadImage: Bool = false, meta: AssistMeta,
                 pinned: Bool = false, savedToNotesAt: Date? = nil, createdAt: Date,
                 matchVia: PaperMatch.Via? = nil, matchScore: Double? = nil, thumbPath: String? = nil) {
        self.id = id; self.paperID = paperID; self.threadID = threadID; self.turn = turn; self.source = source
        self.action = action; self.lang = lang; self.page = page; self.excerpt = excerpt.map { String($0.prefix(Self.maxExcerpt)) }
        self.question = question; self.answer = answer; self.hadImage = hadImage; self.meta = meta
        self.pinned = pinned; self.savedToNotesAt = savedToNotesAt; self.createdAt = createdAt
        self.matchVia = matchVia; self.matchScore = matchScore; self.thumbPath = thumbPath
    }
}

/// Where a stored explanation points back to: the paper, its page and a quote to highlight there
/// (the history's page chip → `ReaderRouting.open(paperID:page:highlight:)`).
package struct ExplanationAnchor: Sendable, Equatable {
    package var paperID: String
    package var page: Int?
    /// The excerpt's first sentence (≤ `highlightLimit` characters), nil without one.
    package var highlight: String?

    package static let highlightLimit = 200

    package init(paperID: String, page: Int?, highlight: String?) {
        self.paperID = paperID; self.page = page; self.highlight = highlight
    }
}
