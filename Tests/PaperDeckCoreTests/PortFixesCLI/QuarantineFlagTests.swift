import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// portability-cli-7: macOS keeps `com.apple.quarantine` on an app after Open Anyway and sets the
/// user-approved flag (0x0040) instead, so the 'Open Anyway' step is done when that bit is set —
/// not only when the attribute is gone.
@Suite("Quarantine flags")
struct QuarantineFlagTests {
    @Test func theUserApprovedBitMeansDone() {
        // Approved and launched apps (an approved download keeps 01c3; a re-approved one 03c1).
        #expect(!AppLocationFact.isQuarantined(attribute: "01c3;66f1e2a0;Safari;E5C8B4C6-0000-4000-8000-000000000001"))
        #expect(!AppLocationFact.isQuarantined(attribute: "03c1"))
        #expect(!AppLocationFact.isQuarantined(attribute: "0040;00000000;;"))
        #expect(!AppLocationFact.isQuarantined(attribute: "00C1;66f1e2a0;Archive Utility;"))   // hex is case-insensitive
    }

    @Test func notApprovedYetIsQuarantined() {
        // Downloaded, unzipped, never opened: 0083 (no 0x40).
        #expect(AppLocationFact.isQuarantined(attribute: "0083;66f1e2a0;Safari;E5C8B4C6-0000-4000-8000-000000000001"))
        #expect(AppLocationFact.isQuarantined(attribute: "0081;66f1e2a0;Archive Utility;"))
        #expect(AppLocationFact.isQuarantined(attribute: "0001"))
    }

    @Test func noAttributeOrAnUnreadableOne() {
        #expect(!AppLocationFact.isQuarantined(attribute: nil))
        // Present but unparsable (or unreadable, ""): still shown as quarantined, as before.
        #expect(AppLocationFact.isQuarantined(attribute: ""))
        #expect(AppLocationFact.isQuarantined(attribute: "zz;66f1e2a0"))
        #expect(AppLocationFact.isQuarantined(attribute: ";66f1e2a0;Safari;"))
    }

    @Test func theOpenAnywayCheckFollows() {
        let approved = AppLocationFact(location: .applications, quarantined: AppLocationFact.isQuarantined(attribute: "01c3;66f1e2a0;Safari;"))
        #expect(GuideEvaluator.evaluate(.notQuarantined, GuideSamples.facts { $0.app = .value(approved) }) == .done)
        let downloaded = AppLocationFact(location: .applications, quarantined: AppLocationFact.isQuarantined(attribute: "0083;66f1e2a0;Safari;"))
        if case .problem = GuideEvaluator.evaluate(.notQuarantined, GuideSamples.facts { $0.app = .value(downloaded) }) {} else {
            Issue.record("a download not yet approved must stay a problem")
        }
    }
}
