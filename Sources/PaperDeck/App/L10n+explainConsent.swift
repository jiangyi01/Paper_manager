import Foundation
import PaperDeckCore

/// Strings of Explain's consent fixes (phase-3 fixes F10): why a held turn waits for [Send]. Owned
/// by the privacy / consent fix lane; each accessor answers in both languages (Phase3FixesPrivacy
/// lint: distinct en / zh, the zh one Chinese, no institution).
extension L {
    enum ExplainConsent {
        private static var zh: Bool { L.lang == .zh }

        /// A Services request: the panel shows the selection and waits for the user's own ⏎ / click.
        static var serviceHeldHint: String {
            zh ? "这段文字是通过「服务」菜单交给 PaperDeck 的。按 ⏎ 或点「发送」之前，不会发给 AI。"
               : "This text came to PaperDeck from the Services menu. Nothing goes to the AI until you press ⏎ or click Send."
        }

        /// The detail line of the [Send] card: the setting's hint, or the Services one.
        static func heldDetail(_ held: ExplainHeldFor) -> String {
            switch held {
            case .setting: return L.Explain.askBeforeSendHint
            case .service: return serviceHeldHint
            }
        }

        /// Every worded string (the self-check: en ≠ zh, none empty).
        static var all: [String] { [serviceHeldHint, heldDetail(.setting), heldDetail(.service)] }
    }
}
