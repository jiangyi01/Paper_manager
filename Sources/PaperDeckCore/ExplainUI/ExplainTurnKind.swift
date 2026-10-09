import Foundation

// What one Explain turn asks for (the first explanation, an action chip, a follow-up), the action
// chips with their keys, the panel language and the model each depth uses. Pure. Owned by the
// Explain UI lane (A2).

/// What a turn asks the model to do with the panel's capture.
package enum ExplainTurnKind: Sendable, Equatable, Hashable {
    /// The first explanation of a capture.
    case explain
    /// Action chips (LN §7.3).
    case simpler, technical, defineTerms, figure, translate
    /// A follow-up question (the user's own words, untrusted like everything else).
    case ask(String)

    /// The stored `explanation.action` code (no CHECK list; stable names).
    package var actionCode: String {
        switch self {
        case .explain: return "explain"
        case .simpler: return "simpler"
        case .technical: return "technical"
        case .defineTerms: return "terms"
        case .figure: return "figure"
        case .translate: return "translate"
        case .ask: return "ask"
        }
    }

    /// The follow-up question, if this is one.
    package var question: String? {
        if case .ask(let q) = self { return q }
        return nil
    }

    /// The kind of a stored `action` code (a follow-up keeps its stored question).
    package init?(actionCode: String, question: String?) {
        switch actionCode {
        case "explain": self = .explain
        case "simpler": self = .simpler
        case "technical": self = .technical
        case "terms": self = .defineTerms
        case "figure": self = .figure
        case "translate": self = .translate
        case "ask": self = .ask(question ?? "")
        default: return nil
        }
    }
}

/// The panel's action chips (⌘1…⌘5).
package enum ExplainChip: String, Sendable, CaseIterable {
    case simpler, technical, terms, figure, translate

    package var kind: ExplainTurnKind {
        switch self {
        case .simpler: return .simpler
        case .technical: return .technical
        case .terms: return .defineTerms
        case .figure: return .figure
        case .translate: return .translate
        }
    }

    /// The ⌘ digit.
    package var keyDigit: Character {
        switch self {
        case .simpler: return "1"
        case .technical: return "2"
        case .terms: return "3"
        case .figure: return "4"
        case .translate: return "5"
        }
    }

    /// SF Symbol.
    package var symbol: String {
        switch self {
        case .simpler: return "leaf"
        case .technical: return "graduationcap"
        case .terms: return "character.book.closed"
        case .figure: return "chart.xyaxis.line"
        case .translate: return "translate"
        }
    }

    /// The chips a capture offers: "Explain the figure" needs an image (a region, a screenshot, a
    /// dropped image, a reader box); text from Services / the clipboard / a selection has none.
    package static func available(hasImage: Bool) -> [ExplainChip] {
        allCases.filter { $0 != .figure || hasImage }
    }

    /// The chip of a ⌘-digit key, among those available.
    package static func forKey(_ c: Character, hasImage: Bool) -> ExplainChip? {
        available(hasImage: hasImage).first { $0.keyDigit == c }
    }
}

/// The answer language: `zh` is Chinese with the English terms kept (the approved default, D3).
package enum ExplainLanguageToggle {
    /// The language a new panel starts in.
    package static func initial(_ setting: AssistSettings.ExplainLanguage, ui: UILang) -> UILang {
        switch setting {
        case .zh: return .zh
        case .en: return .en
        case .ui: return ui
        }
    }

    /// EN ↔ 中 (⌘L, the header toggle).
    package static func toggled(_ l: UILang) -> UILang { l == .zh ? .en : .zh }

    /// The header toggle's labels, in order.
    package static let labels: [(UILang, String)] = [(.en, "EN"), (.zh, "中")]
}

/// Which model a turn runs: the depth's slug for the mode's provider (Quick = haiku / luna by
/// default; Thorough on request), effort `low` for Quick and `medium` for Thorough (as the prompt
/// builder sets them). Local / mock have no slug choice.
package enum ExplainModelChoice {
    package static func model(_ settings: AssistSettings, depth: AssistSettings.Depth) -> (model: String, effort: String?) {
        guard let provider = settings.mode.providerKind else {
            return (settings.mode == .local ? "on-device" : settings.mode.rawValue, nil)
        }
        return (settings.model(provider, depth), depth == .quick ? "low" : "medium")
    }
}

/// One click starts at most one turn: repeated gestures on a panel within `interval` are ignored
/// (a double-click is never two calls), and so is any gesture while local work runs.
package struct ExplainDebounce: Sendable, Equatable {
    /// Lens clicks (LN §6.2) and panel buttons.
    package static let click: TimeInterval = 0.6
    /// A box release (plan §2: 1 s).
    package static let box: TimeInterval = 1.0

    package private(set) var last: Date?

    package init(last: Date? = nil) { self.last = last }

    /// True (and remembered) when a gesture at `now` may start a turn.
    package mutating func allow(at now: Date, interval: TimeInterval = ExplainDebounce.click) -> Bool {
        if let last, now.timeIntervalSince(last) < interval, now >= last { return false }
        last = now
        return true
    }
}

/// One panel's own debounce (F9): the same button pressed again within `interval` of its previous
/// press — a double-click, a held ⌘-digit's key repeat (the window slides with every repeat) — is
/// ignored, so one press is one turn (each superseded turn would still spend a ticket, a burst slot
/// and a daily count). A different button is a new gesture and goes through.
package struct ExplainGestureDebounce: Sendable, Equatable {
    package enum Gesture: Sendable, Equatable {
        /// A chip, re-explain, the first explanation, a follow-up question.
        case run(ExplainTurnKind)
        /// [Send] / [Send Anyway] / [Continue].
        case confirm
        /// [Try Again] / Regenerate.
        case retry
    }

    package private(set) var last: Gesture?
    package private(set) var at: Date?

    package init() {}

    /// True when `g` at `now` may start a turn; every press is remembered (allowed or not).
    package mutating func allow(_ g: Gesture, at now: Date, interval: TimeInterval = ExplainDebounce.click) -> Bool {
        defer { last = g; at = now }
        guard g == last, let at, now >= at else { return true }
        return now.timeIntervalSince(at) >= interval
    }
}

/// Why a held turn waits for [Send] (`.refused(.askBeforeSend)`): Settings' "Ask before every
/// send", or a Services request (F10: the panel's own click / ⏎ is the consent).
package enum ExplainHeldFor: Sendable, Equatable {
    case setting
    case service
}
