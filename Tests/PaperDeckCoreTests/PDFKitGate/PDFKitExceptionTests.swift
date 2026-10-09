import Foundation
@preconcurrency import PDFKit
import Testing
@testable import PaperDeckCore

/// R-PDFKIT-2: PDFKit's "nil NSFont" NSException in the title read is caught (the font-run title
/// is skipped) instead of aborting the process. The race behind it can't be forced on demand, so a
/// page that throws the same exception stands in for it.
@Suite struct PDFKitExceptionTests {
    /// The reason PDFKit's exception carries (crash reports, Oct 2026).
    static let pdfKitReason = "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: NSFont)"

    /// A page whose `attributedString` throws like PDFKit's does under the race.
    final class ThrowingPage: PDFPage {
        override var attributedString: NSAttributedString? {
            NSException(name: .invalidArgumentException, reason: PDFKitExceptionTests.pdfKitReason).raise()
            return nil
        }
    }

    @Test func aCaughtExceptionKeepsItsNameAndReason() {
        let result = ObjCException.catching { () -> Int in
            NSException(name: .invalidArgumentException, reason: Self.pdfKitReason).raise()
            return 1
        }
        #expect(result == .failure(CaughtObjCException(name: NSExceptionName.invalidArgumentException.rawValue, reason: Self.pdfKitReason)))
    }

    @Test func aNormalCallPassesItsValueThrough() {
        #expect(ObjCException.catching { 42 } == .success(42))
        #expect(ObjCException.catching { () -> String? in nil } == .success(nil))
    }

    /// The title read survives the exception, gives no title, and leaves the gate free for the
    /// next caller on another thread.
    @Test func theTitleReadSurvivesPDFKitThrowing() throws {
        let before = TitleHeuristic.exceptionsCaughtOnThisThread
        #expect(TitleHeuristic.attributedText(of: ThrowingPage()) == nil)
        #expect(TitleHeuristic.title(of: ThrowingPage()) == nil)
        #expect(PDFKitGate.shared.run { TitleHeuristic.title(of: ThrowingPage()) } == nil)
        #expect(!PDFKitGate.shared.isHeldByCurrentThread)
        // Counted per thread, so the stress test's workers can tell they saw none.
        #expect(TitleHeuristic.exceptionsCaughtOnThisThread == before + 3)

        let entered = DispatchSemaphore(value: 0)
        PDFKitGateKit.onThread {
            PDFKitGate.shared.run { }
            entered.signal()
        }
        #expect(entered.wait(timeout: .now() + 20) == .success, "the gate stayed held after a caught exception")

        // A real page still reads normally afterwards.
        let fonts = Array(PDFKitGateKit.installedFontNames().prefix(2))
        try #require(!fonts.isEmpty)
        let doc = try #require(GatedPDFDocument(data: PDFKitGateKit.pdf(fonts: fonts)))
        #expect(doc.with { $0.page(at: 0).flatMap(TitleHeuristic.title(of:)) } == PDFKitGateKit.title)
    }

    /// The title heuristic reads the attributed string in one place, through the catcher, and the
    /// gate and the autorelease pool stay outside the catch.
    @Test(.enabled(if: LintRepo.hasSources)) func theAttributedStringIsReadOnlyThroughTheCatcher() throws {
        let source = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/PDF/TitleHeuristic.swift"), encoding: .utf8)
        let code = PDFKitGateLintTests.code(source)
        #expect(code.components(separatedBy: ".attributedString").count == 2, "attributedString read more than once")
        #expect(code.contains("switch ObjCException.catching({ page.attributedString }) {"))
        #expect(code.contains("guard let attributed = attributedText(of: page), attributed.length > 0 else { return nil }"))
        let shim = try String(contentsOf: LintRepo.url("Sources/PaperDeckObjCSupport/PDCatchException.m"), encoding: .utf8)
        #expect(shim.contains("@catch (NSException *exception) {\n        return exception;"))
        #expect(!shim.contains("@throw"))
    }
}
