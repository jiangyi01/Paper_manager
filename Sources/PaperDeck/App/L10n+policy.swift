import Foundation
import PaperDeckCore

/// Strings of the per-paper AI policy (the inspector's toggles) and of the privacy reasons every
/// assist surface shows (`AssistPolicyText`). Lead-owned (Slice 0). Institution wording never
/// appears here: the organization's guidance comes from `OrgStrings` through `AssistPolicyText`.
extension L {
    enum Policy {
        private static var zh: Bool { L.lang == .zh }

        static var section: String { zh ? "AI 使用" : "AI use" }
        static var confidential: String { zh ? "未发表 / 保密" : "Unpublished / confidential" }
        static var confidentialHint: String {
            zh ? "讲解、问答和查重在把这篇论文的内容发给 AI 之前，都会先问你。"
               : "Explain, Ask and the duplicate check ask you before sending this paper's content to an AI."
        }
        static var neverAI: String { zh ? "不对这篇论文使用 AI" : "Never use AI for this paper" }
        static var neverAIHint: String {
            zh ? "讲解、问答和 AI 查重都不会使用这篇论文的内容。"
               : "Explain, Ask and the AI duplicate check never use this paper's content."
        }

        /// One line per privacy reason (`AssistPrivacy.Reason`).
        static func reason(_ r: AssistPrivacy.Reason) -> String {
            switch r {
            case .markedConfidential:
                return zh ? "你把这篇论文标记为未发表 / 保密。" : "You marked this paper unpublished / confidential."
            case .mailUnpublished:
                return zh ? "这篇论文来自邮件，可能是未发表的稿件。" : "This paper came by email and may be unpublished work."
            case .mailConfidential:
                return zh ? "这篇论文来自一封保密邮件（例如审稿邀请或在审稿件），可能是未发表的稿件。"
                          : "This paper came from a confidential email (such as a review invitation or a manuscript under review) and may be unpublished."
            case .personSourcedNoID:
                return zh ? "这篇论文来自某个人的邮件，而且没有 DOI 或 arXiv 编号。"
                          : "This paper came from a person's email and has no DOI or arXiv ID."
            case .messagingHost:
                return zh ? "所选内容来自邮件或聊天应用，可能包含别人的私人信息。"
                          : "The selection comes from a mail or chat app and may contain someone's private message."
            case .unknownBrowserPage:
                return zh ? "所选内容来自 PaperDeck 无法识别的浏览器页面（可能是网页邮箱）。没有「屏幕录制」权限时，PaperDeck 看不到窗口标题。"
                          : "The selection comes from a browser page PaperDeck can't identify (it may be webmail). Without Screen Recording, PaperDeck can't read window titles."
            }
        }

        /// The never-use-AI refusal.
        static var blocked: String {
            zh ? "这篇论文设置了「不使用 AI」，所以没有发送任何内容。" : "This paper is set to never use AI, so nothing was sent."
        }
    }
}
