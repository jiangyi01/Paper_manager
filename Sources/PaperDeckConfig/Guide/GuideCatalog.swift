import Foundation
import PaperDeckCore

/// Every Help Center topic (content: `GuideContent`, S4). W0: empty.
package enum GuideCatalog {
    package static var topics: [GuideTopic] {
        GuideContent.tour + GuideContent.tutorials + GuideContent.mail + GuideContent.troubleshooting
    }

    package static func topic(_ id: GuideTopicID) -> GuideTopic? {
        topics.first { $0.id == id }
    }
}
