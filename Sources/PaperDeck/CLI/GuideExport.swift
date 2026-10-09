import Foundation
import PaperDeckCore
import PaperDeckConfig

/// `--guide-export DIR [--lang en|zh]`: the Help Center topics as Markdown — the blocks pasted
/// between the `<!-- BEGIN GENERATED: troubleshooting <lang> -->` markers of docs/TROUBLESHOOTING.md
/// (`TROUBLESHOOTING.generated.<lang>.md`) and every topic (`GUIDE.generated.<lang>.md`).
/// Pure: reads only the built-in catalog; writes only into DIR.
enum GuideExport {
    static func run(_ a: CLIArgs) -> Int32 {
        guard let dir = a.positional.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }) else {
            return CLIRunner.fail("--guide-export DIR [--lang en|zh]")
        }
        let langs: [UILang]
        if let raw = a.value("--lang") {
            guard let l = UILang(rawValue: raw) else { return CLIRunner.fail("--lang must be en or zh") }
            langs = [l]
        } else {
            langs = [.en, .zh]
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let topics = GuideCatalog.topics
            if topics.isEmpty { FileHandle.standardError.write(Data("note: the guide catalog is empty in this build\n".utf8)) }
            for lang in langs {
                let trouble = dir.appendingPathComponent("TROUBLESHOOTING.generated.\(lang.rawValue).md")
                try Data(GuideMarkdown.troubleshooting(lang: lang, topics: topics).utf8).write(to: trouble, options: .atomic)
                let all = dir.appendingPathComponent("GUIDE.generated.\(lang.rawValue).md")
                try Data(GuideMarkdown.render(topics, lang: lang).utf8).write(to: all, options: .atomic)
                CLIRunner.line(["lang": lang.rawValue, "troubleshooting": trouble.path, "guide": all.path,
                                "topics": topics.count, "troubleshootingTopics": topics.count(where: { $0.kind == .troubleshoot })])
            }
            return 0
        } catch {
            return CLIRunner.fail("--guide-export: \(error.localizedDescription)")
        }
    }
}
