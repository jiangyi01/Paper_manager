import Foundation
import PaperDeckCore

/// Strings of the library's layout and density pass (one notice at a time, compact cards, the
/// Today rows' step disclosure). Every name sits in `L.Library`.
extension L {
    enum Library {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Notices (one at a time)

        /// The pager's help and VoiceOver hint.
        static var nextNotice: String { zh ? "下一条提示" : "Next Notice" }
        /// The pager's VoiceOver label: `Notice 1 of 3`.
        static func noticePosition(_ index: Int, _ count: Int) -> String {
            zh ? "第 \(index) 条提示，共 \(count) 条" : "Notice \(index) of \(count)"
        }
        /// The ⋯ menu holding a notice's other actions.
        static var moreActions: String { zh ? "更多操作" : "More Actions" }

        // MARK: Today rows

        /// The disclosure of an upcoming paper's open steps: `3 steps` / `3 个步骤`.
        static func showSteps(_ count: Int) -> String {
            zh ? "\(count) 个步骤" : (count == 1 ? "1 step" : "\(count) steps")
        }
        static var hideSteps: String { zh ? "收起步骤" : "Hide Steps" }
        static func stepsA11y(_ count: Int, expanded: Bool) -> String {
            if zh { return expanded ? "收起 \(count) 个未完成步骤" : "显示 \(count) 个未完成步骤" }
            return expanded ? "Hide \(count) open steps" : "Show \(count) open steps"
        }
    }
}
