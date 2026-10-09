import Foundation
import PaperDeckCore

/// The field-dependent UI texts (PORTABILITY_PLAN §2.7): today's sentences with the field's
/// example in the slot. For `lifeSciencesCompBio` they are today's texts word for word.
package enum FieldStrings {
    /// Settings ▸ Library ▸ Edit Description… hint.
    package static func describeHint(_ f: FieldPreset, _ l: UILang) -> String {
        example(f.categoryDescriptionExample, l)
    }

    /// The sidebar's category-description placeholder.
    package static func categoryDescriptionPlaceholder(_ f: FieldPreset, _ l: UILang) -> String {
        example(f.categoryPlaceholderExample, l)
    }

    /// Settings ▸ Mail ▸ Instructions for the AI, with the field's example.
    package static func customInstructionsHint(_ f: FieldPreset, _ l: UILang) -> String {
        l == .zh
            ? "随每次 AI 分拣请求一起发送（「仅本地规则」时不发送），并标明是你的偏好。例如：「" + f.customInstructionsExample.zh + "」。"
            : "Sent with every AI triage request (never in local-rules-only mode), marked as your own preferences. Example: “" + f.customInstructionsExample.en + "”"
    }

    /// The IMAP forms' alerts tip.
    package static func alertsTip(_ f: FieldPreset, _ l: UILang) -> String {
        f.alertsTip(l)
    }

    private static func example(_ t: LocalizedText, _ l: UILang) -> String {
        l == .zh ? "例如：" + t.zh : "e.g. " + t.en
    }
}
