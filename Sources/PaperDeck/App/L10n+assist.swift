import Foundation
import PaperDeckCore

/// Strings shared by the assist surfaces (Settings ▸ Explain & Ask, the consent and confidential
/// sheets, banners, the quota footer). Owned by Slice A (the Explain UI lane); the Lead added the
/// shared switch's words when Ask shipped ahead of Explain. Every name sits in `L.Assist`.
extension L {
    enum Assist {
        private static var zh: Bool { L.lang == .zh }

        /// Settings tab title.
        static var tab: String { zh ? "讲解与问答" : "Explain & Ask" }

        // MARK: The shared switch (`assist.mode`)

        static var switchTitle: String { zh ? "打开讲解与问答" : "Turn on Explain & Ask" }
        static var switchOff: String {
            zh ? "已关闭：不会把任何问题或论文发给 AI。" : "Off: no question or paper is ever sent to an AI."
        }
        static func switchOn(_ provider: String) -> String {
            zh ? "已打开：只有在你按「提问」时，问题才会发给 \(provider)，每次计一次订阅额度。"
               : "On: a question goes to \(provider) only when you press Ask, one request on your subscription each time."
        }
        /// The same once Explain ships (`ExplainCoordinator.isAvailable`): a question or an explanation.
        static func switchOnWithExplain(_ provider: String) -> String {
            zh ? "已打开：只有在你按「提问」或亲手触发讲解时，内容才会发给 \(provider)，每次计一次订阅额度。"
               : "On: a question or an explanation goes to \(provider) only when you press Ask or trigger Explain yourself, one request on your subscription each time."
        }
        static var providerPicker: String { zh ? "回答来自" : "Answers from" }
        static var switchFooter: String {
            zh ? "与「AI 解读」（设置 ▸ AI 解读）互相独立。打开开关本身不会发送任何内容。标为「不对这篇论文使用 AI」的论文永不发送；可能未发表或保密的论文要你确认后才发送。"
               : "Separate from AI Reading (Settings ▸ AI Reading). Turning this on sends nothing by itself. "
                 + "A paper marked “Never use AI for this paper” is never sent; one that may be unpublished or "
                 + "confidential is sent only after you confirm."
        }

        /// Every worded string (en ≠ zh, none empty, no institution literal): `--selftest qa`.
        static var all: [String] {
            [tab, switchTitle, switchOff, switchOn("Claude"), switchOnWithExplain("Claude"), providerPicker, switchFooter]
        }
    }
}
