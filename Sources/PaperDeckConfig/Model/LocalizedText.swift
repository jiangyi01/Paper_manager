import Foundation
import PaperDeckCore

/// A user-facing text in both UI languages. Both are required, so a missing translation can't
/// compile.
package struct LocalizedText: Codable, Sendable, Equatable, Hashable {
    package var en: String
    package var zh: String

    package init(en: String, zh: String) {
        self.en = en; self.zh = zh
    }

    /// The same text in both languages (names, product words).
    package init(_ both: String) {
        self.init(en: both, zh: both)
    }

    package func callAsFunction(_ lang: UILang) -> String {
        lang == .zh ? zh : en
    }
}
