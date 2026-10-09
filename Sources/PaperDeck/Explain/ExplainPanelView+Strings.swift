import Foundation
import PaperDeckCore

/// Strings of the capture / panel fixes (fix-capture-ux): what is sent, the paper match and its
/// correction, the overlay's "nothing legible" notice. Each accessor answers in both languages
/// (`Phase3FixesUX` lint: distinct en / zh, the zh one Chinese).
extension L {
    enum ExplainUX {
        private static var zh: Bool { L.lang == .zh }

        // MARK: What is sent (F3)

        /// Under the thumbnail when the image goes with the request.
        static var willBeSent: String { zh ? "将发送的就是这张图" : "This is what will be sent" }
        /// Under the thumbnail when only the text goes.
        static var textOnlySent: String {
            zh ? "只发送下面的文字，图片留在本机" : "Only the text below is sent; the image stays on this Mac"
        }

        // MARK: The paper match (CUX-6)

        static func matched(_ title: String) -> String { zh ? "已匹配：\(title)" : "Matched: \(title)" }
        static func chosen(_ title: String) -> String { zh ? "你选择的：\(title)" : "You chose: \(title)" }
        static var unmatched: String { zh ? "未匹配到库中的论文" : "Not matched to a library paper" }
        static var change: String { zh ? "更换…" : "Change…" }
        static var choose: String { zh ? "选择…" : "Choose…" }
        static var notThisPaper: String { zh ? "不是这篇" : "Not this paper" }
        static var notThisPaperHelp: String {
            zh ? "不使用这篇论文重新讲解；这条讲解也不再归到它名下" : "Explain again without this paper; the explanation is no longer filed under it"
        }
        static var changeHelp: String {
            zh ? "选出屏幕上真正的论文，用它重新讲解" : "Pick the paper that is really on screen and explain again with it"
        }
        static var choosePaperTitle: String { zh ? "这是哪篇论文？" : "Which paper is this?" }
        static var searchPapers: String { zh ? "搜索你的论文库" : "Search your library" }
        static var noPapersFound: String { zh ? "没有匹配的论文" : "No paper matches" }
        static var useAndExplain: String { zh ? "用这篇论文重新讲解" : "Explain again with this paper" }

        // MARK: The overlay (CUX-8)

        static var nothingLegible: String {
            zh ? "这里没有可读的内容（空白区域或受保护的窗口），未发送任何内容。" : "Nothing legible here (a blank area or a protected window). Nothing was sent."
        }

        /// Every string (the strings self-test and the lint read them).
        static var all: [String] {
            [willBeSent, textOnlySent, matched("X"), chosen("X"), unmatched, change, choose, notThisPaper, notThisPaperHelp,
             changeHelp, choosePaperTitle, searchPapers, noPapersFound, useAndExplain, nothingLegible]
        }
    }
}
