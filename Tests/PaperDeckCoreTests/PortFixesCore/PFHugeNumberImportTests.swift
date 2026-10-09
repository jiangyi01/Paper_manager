import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Portability verification (pf2) regression #1: a settings file whose number does not fit in an
/// `Int` (e.g. `"mail.triageDailyMax": 1e300`) trapped in `Int(Double)` while the import sheet or
/// `--import-settings --dry-run` described the value. Describing must never trap.
@Suite struct PFHugeNumberImportTests {
    @Test func describingAnOutOfRangeNumberDoesNotTrap() {
        #expect(SettingsTransferValues.describe(json: .number(1e300)) == String(1e300))
        #expect(SettingsTransferValues.describe(json: .number(-1e300)) == String(-1e300))
        #expect(SettingsTransferValues.describe(json: .number(.infinity)) == String(Double.infinity))
    }

    @Test func integralNumbersStillPrintAsIntegers() {
        #expect(SettingsTransferValues.describe(json: .number(30)) == "30")
        #expect(SettingsTransferValues.describe(json: .number(2.5)) == "2.5")
    }
}
