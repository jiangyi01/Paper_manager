import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperDeckCore

/// Shared helpers of the Explain A3 suites: the synthetic OCR line fixtures (`Fixtures/explain/`),
/// a scratch engine with mock providers only, papers with cached + indexed text, and images drawn
/// in memory with CoreText (never a screenshot).
enum ExplainKit {
    struct Fixture {
        var name: String
        var note: String
        var imageSize: CGSize
        var expect: RegionKind
        var lines: [OCRLine]

        /// The fixture's lines through the fallback layout (columns, paragraphs).
        var result: OCRResult { OCRPostProcess.assemble(lines, imageSize: imageSize) }
    }

    static let fixtureNames = ["prose", "two_column", "equation", "inline_math_light", "inline_math_dense", "chart", "table",
                               "chinese", "figure_caption", "low_confidence", "unreadable", "empty"]

    static func fixture(_ name: String) throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/explain"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let size = try #require(json["imageSize"] as? [Double])
        let raw = try #require(json["lines"] as? [[String: Any]])
        let lines = try raw.map { d -> OCRLine in
            let b = try #require(d["b"] as? [Double])
            return OCRLine(text: try #require(d["t"] as? String), box: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]),
                           confidence: try #require(d["c"] as? Double))
        }
        return Fixture(name: name, note: json["note"] as? String ?? "", imageSize: CGSize(width: size[0], height: size[1]),
                       expect: try #require(RegionKind(rawValue: json["expect"] as? String ?? "")), lines: lines)
    }

    static func layoutPages(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/pdf"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\u{0C}")
    }

    // MARK: Engine

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_790_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    static func engine(_ clock: Box = Box()) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-explain-a3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { EngineSettings(metadataLookup: false) }, now: { clock.now }, fetcher: nil,
            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            sidecarDelay: .milliseconds(10), cliFacts: .inMemory(), loadMailSettings: { MailSettings() },
            mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()]))
        return (engine, root)
    }

    /// A live paper with `pages` cached (form feeds between pages) and full-text indexed.
    @discardableResult
    static func paper(_ engine: Engine, title: String, pages: [String] = [], authors: [String] = ["Ada Lovelace"],
                      year: Int? = 2026, venue: String? = nil, abstract: String? = nil, ids: PaperIDs = PaperIDs(),
                      pdfName: String? = nil, originalName: String? = nil, aiNote: String? = nil) async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder), withIntermediateDirectories: true)
        let name = pdfName ?? "\(sha.prefix(8)).pdf"
        let p = Paper(id: id, sha256: sha, fileSize: 1000, ids: ids, title: title, titleRank: .font, authors: authors,
                      year: year, venue: venue, abstract: abstract, pageCount: max(pages.count, 1), charCount: 10,
                      folder: folder, pdfName: name, originalName: originalName ?? name, stage: .ready, aiNote: aiNote,
                      addedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let saved = try await engine.db.insertPaper(p)
        if !pages.isEmpty {
            let text = pages.joined(separator: "\u{0C}")
            try engine.ctx.texts.save(text, id: saved.id)
            try await engine.db.indexFullText(pk: saved.pk, text: text)
        }
        return saved
    }

    // MARK: OCR-style noise

    /// `text` as a screen OCR might return it: ligatures for fi / fl, every `every`-th letter
    /// swapped for a look-alike, and the lines re-broken with hyphens. Deterministic.
    static func perturb(_ text: String, every: Int = 33) -> String {
        let lookalike: [Character: Character] = ["l": "1", "o": "0", "e": "c", "a": "o", "n": "m", "i": "l", "t": "f", "s": "5"]
        var out = ""
        var letters = 0
        for ch in text.replacingOccurrences(of: "fi", with: "\u{FB01}").replacingOccurrences(of: "fl", with: "\u{FB02}") {
            if ch.isLetter {
                letters += 1
                if letters % every == 0, let swap = lookalike[ch] { out.append(swap); continue }
            }
            out.append(ch)
        }
        // Re-break into ~50-character lines, hyphenating inside long words.
        var lines: [String] = []
        var current = ""
        for word in out.split(separator: " ") {
            if current.count + word.count > 50, word.count > 6 {
                let cut = word.index(word.startIndex, offsetBy: word.count / 2)
                lines.append(current + " " + word[..<cut] + "-")
                current = String(word[cut...])
            } else if current.count + word.count > 50 {
                lines.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " " + word
            }
        }
        lines.append(current)
        return lines.joined(separator: "\n")
    }

    // MARK: Images (CoreText, in memory)

    /// White canvas with `lines` of black text (top to bottom), `scale` × points.
    static func render(_ lines: [String], width: Int, height: Int, fontSize: CGFloat = 28, font: String = "Helvetica",
                       lineGap: CGFloat = 1.5) -> CGImage? {
        guard let ctx = canvas(width, height) else { return nil }
        let f = CTFontCreateWithName(font as CFString, fontSize, nil)
        var y = CGFloat(height) - fontSize * 1.4
        for line in lines {
            let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                                                            CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
            ctx.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(ct, ctx)
            y -= fontSize * lineGap
        }
        return ctx.makeImage()
    }

    /// Bars of a chart (no text at all).
    static func bars(width: Int = 480, height: Int = 320) -> CGImage? {
        guard let ctx = canvas(width, height) else { return nil }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1))
        for (i, h) in [120, 240, 180, 60].enumerated() { ctx.fill(CGRect(x: 40 + i * 100, y: 30, width: 60, height: h)) }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 28, width: 420, height: 2))
        return ctx.makeImage()
    }

    /// A flat colour (a protected window or a sleeping display).
    static func flat(width: Int, height: Int, gray: CGFloat = 0) -> CGImage? {
        guard let ctx = canvas(width, height, fill: gray) else { return nil }
        return ctx.makeImage()
    }

    /// Random pixels: incompressible (forces the JPEG path).
    static func noise(width: Int, height: Int, seed: UInt64 = 7) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var s = seed
        for i in 0..<(width * height * 4) {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            px[i] = UInt8(truncatingIfNeeded: s >> 33)
        }
        return ctx.makeImage()
    }

    private static func canvas(_ w: Int, _ h: Int, fill: CGFloat = 1) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: fill, green: fill, blue: fill, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    /// A fake capturer: preflight answers `granted`; counts every call (tests prove the flow never
    /// asks for permission on its own and never freezes without it).
    final class FakeCapturer: ScreenCapturing, @unchecked Sendable {
        private let lock = NSLock()
        let granted: Bool
        let screens: FrozenScreens
        let failure: CaptureError?
        private(set) var preflights = 0
        private(set) var requests = 0
        private(set) var freezes: [[CGWindowID]] = []

        init(granted: Bool, screens: FrozenScreens = FrozenScreens(displays: []), failure: CaptureError? = nil) {
            self.granted = granted; self.screens = screens; self.failure = failure
        }

        func preflight() -> Bool { lock.withLock { preflights += 1 }; return granted }
        func request() async -> Bool { lock.withLock { requests += 1 }; return granted }
        func freeze(excludingWindowIDs ids: [CGWindowID]) async throws -> FrozenScreens {
            lock.withLock { freezes.append(ids) }
            if let failure { throw failure }
            return screens
        }
        var counts: (preflights: Int, requests: Int, freezes: Int) { lock.withLock { (preflights, requests, freezes.count) } }
    }

    /// A still whose pixel (x, y) encodes its own coordinates (R = x mod 256, G = y mod 256), so a
    /// crop's origin can be read back.
    static func coordinateImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // CGContext memory is top row first.
                let i = (y * width + x) * 4
                px[i] = UInt8(x % 256); px[i + 1] = UInt8(y % 256); px[i + 2] = 0
            }
        }
        return ctx.makeImage()
    }

    /// The top-left pixel of `image` as (R, G).
    static func topLeft(_ image: CGImage) -> (Int, Int)? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let one = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let d = ctx.data else { return nil }
        let px = d.bindMemory(to: UInt8.self, capacity: 4)
        return (Int(px[0]), Int(px[1]))
    }
}
