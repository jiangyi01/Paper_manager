import CoreText
import Foundation
@preconcurrency import PDFKit
@testable import PaperDeckCore

/// Fixtures for the PDFKit gate tests: hand-written PDFs whose fonts are named, not embedded, so
/// PDFKit resolves each font from the system by name when it first reads the page.
enum PDFKitGateKit {
    static let title = "A Generated Paper About Cortical Development"
    static let quote = "the second line of the generated paper"

    /// Two US-Letter pages. Page 1 has the title (26 pt) in `fonts[0]`, then one body line per font.
    /// Page 2 has body lines and the quote. The fonts are TrueType, WinAnsi, and not embedded.
    static func pdf(fonts: [String]) -> Data {
        precondition(!fonts.isEmpty)
        var objects: [String] = ["<< /Type /Catalog /Pages 2 0 R >>"]
        let firstPage = 3 + fonts.count
        objects.append("<< /Type /Pages /Kids [\(firstPage) 0 R \(firstPage + 2) 0 R] /Count 2 >>")
        for f in fonts { objects.append("<< /Type /Font /Subtype /TrueType /BaseFont /\(f) /Encoding /WinAnsiEncoding >>") }
        let resources = fonts.indices.map { "/F\($0) \(3 + $0) 0 R" }.joined(separator: " ")
        for page in 0..<2 {
            var lines: [(font: Int, size: Int, text: String)] = []
            if page == 0 { lines.append((0, 26, title)) }
            for (i, _) in fonts.enumerated() {
                lines.append((i, 10, "Body line \(i) of page \(page + 1): neurons migrate along radial glia in the developing cortex."))
            }
            if page == 1 { lines.append((0, 10, "We note that \(quote) is here.")) }
            var content = ""
            var y = 730
            for line in lines {
                content += "BT /F\(line.font) \(line.size) Tf 54 \(y) Td (\(escape(line.text))) Tj ET\n"
                y -= line.size * 2
            }
            let contentObject = objects.count + 2
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << \(resources) >> >> "
                           + "/Contents \(contentObject) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
        }
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// PostScript names of the installed fonts that are safe to use as a PDF name (no hidden "."
    /// system fonts). Listing them doesn't load them.
    static func installedFontNames() -> [String] {
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return names.filter { !$0.hasPrefix(".") && !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }.sorted()
    }

    static func tempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pd-pdfkitgate-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Starts `body` on a new thread (not the cooperative pool: these threads may block on the gate).
    static func onThread(_ body: @escaping @Sendable () -> Void) {
        let t = Thread { body() }
        t.stackSize = 1 << 20
        t.start()
    }

    /// Polls `condition` every 10 ms until it is true or `timeout` passes; whether it became true.
    static func eventually(timeout: Duration, _ condition: @Sendable () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
    }
}

/// A PDFKit object handed to helper threads in a test. The test makes sure the threads take turns.
final class PDFKitBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe flags and counters for the gate tests.
final class GateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var finished: [String: ContinuousClock.Instant] = [:]
    private var notes: [String] = []

    func enter() { lock.withLock { active += 1; peak = max(peak, active) } }
    func leave() { lock.withLock { active -= 1 } }
    var maxActive: Int { lock.withLock { peak } }

    func finish(_ name: String) { lock.withLock { finished[name] = .now } }
    var finishedAt: [String: ContinuousClock.Instant] { lock.withLock { finished } }

    func note(_ s: String) { lock.withLock { notes.append(s) } }
    var allNotes: [String] { lock.withLock { notes } }
}
