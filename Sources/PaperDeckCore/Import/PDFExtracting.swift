import Foundation

/// What the import pipeline needs from PDF extraction, so tests can substitute a fake.
/// Implementations must not block the caller's executor (PDFExtractor runs on BlockingIO)
/// and throw `PDFExtractor.ExtractError` (`.notPDF`, `.unreadable`, `.fileUnavailable`).
package protocol PDFExtracting: Sendable {
    func extract(url: URL, fileName: String) async throws -> ExtractedPDF
}

extension PDFExtractor: PDFExtracting {}
