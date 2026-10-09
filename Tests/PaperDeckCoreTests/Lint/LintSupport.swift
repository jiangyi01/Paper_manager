import Foundation

/// The repository as the lint suites see it: the root is found from this file's own path
/// (`Tests/PaperDeckCoreTests/Lint/LintSupport.swift` → three folders up), so the suites read the
/// sources they were compiled from, wherever the checkout lives. Read-only.
enum LintRepo {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Lint
        .deletingLastPathComponent()   // PaperDeckCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    static func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// One matching line: `path` is repo-relative (`Sources/…`), `line` 1-based.
    struct Hit: CustomStringConvertible, Equatable {
        var path: String
        var line: Int
        var text: String
        var description: String { "\(path):\(line): \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// Every `.swift` file under `folder` (repo-relative), sorted.
    static func swiftFiles(under folder: String) -> [String] {
        let base = url(folder).standardizedFileURL
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let depth = base.pathComponents.count
        var out: [String] = []
        for case let file as URL in e where file.pathExtension == "swift" {
            out.append(([folder] + file.standardizedFileURL.pathComponents.dropFirst(depth)).joined(separator: "/"))
        }
        return out.sorted()
    }

    /// The lines of the Swift files under `folder` that match `pattern` (ICU regex).
    static func grep(_ pattern: String, caseInsensitive: Bool = false, under folder: String = "Sources") throws -> [Hit] {
        let regex = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        var hits: [Hit] = []
        for path in swiftFiles(under: folder) {
            guard let text = try? String(contentsOf: url(path), encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    hits.append(Hit(path: path, line: i + 1, text: line))
                }
            }
        }
        return hits
    }

    /// Whether the sources are where `#filePath` says (a relocated test bundle skips the lints).
    static var hasSources: Bool {
        FileManager.default.fileExists(atPath: url("Sources/PaperDeckConfig/Presets/OrganizationPresets.swift").path)
    }
}
