import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

/// Portability fix round, app side (verifier findings F6, F10). The app target's own fixes
/// (F2, F5, F7–F9, F11) are checked by `--selftest onboarding` and `--selftest settings`, which
/// can reach the app's types; these suites cover the scripts, the docs and the guide content.
/// Read-only over the repository (`LintRepo`); skipped when the sources aren't next to the tests.

/// F6: build_app.sh's warning about callback-style APIs in the MainActor app target must not fire
/// on the intended nonisolated wrapper (a permanent false alarm hides real ones), yet still fire
/// on an unmarked call.
@Suite("Callback-API check (build_app.sh)")
struct CallbackAPICheckTests {
    static let script = LintRepo.url("tools/check_callback_apis.sh")
    static var present: Bool { LintRepo.hasSources && FileManager.default.isExecutableFile(atPath: script.path) }

    static func run(_ dir: String? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + (dir.map { [$0] } ?? [])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    static func scratch(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-callback-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("Probe.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test(.enabled(if: present, "tools/check_callback_apis.sh isn't next to the tests"))
    func theAppTargetHasNoUnmarkedCallbackAPI() throws {
        let r = try Self.run()
        #expect(r.status == 0 && r.out.isEmpty, "unexpected hits:\n\(r.out)")
    }

    @Test(.enabled(if: present, "tools/check_callback_apis.sh isn't next to the tests"))
    func anUnmarkedCallIsReportedAndAMarkedOneIsNot() throws {
        let dir = try Self.scratch([
            "WidgetCenter.shared.getCurrentConfigurations { result in",
            "center.getNotificationSettings { s in   // pd-callback-ok: wrapped",
            "NotificationCenter.default.addObserver(forName: n, object: nil, queue: nil) { _ in }",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try Self.run(dir.path)
        #expect(r.status == 1)
        #expect(r.out.contains("Probe.swift:1:") && r.out.contains("Probe.swift:3:"))
        #expect(!r.out.contains("Probe.swift:2:"))
        let clean = try Self.scratch(["WidgetCenter.shared.getCurrentConfigurations { r in   // pd-callback-ok"])
        defer { try? FileManager.default.removeItem(at: clean) }
        #expect(try Self.run(clean.path).status == 0)
    }

    @Test(.enabled(if: present, "tools/check_callback_apis.sh isn't next to the tests"))
    func buildAppRunsTheCheck() throws {
        let build = try String(contentsOf: LintRepo.url("build_app.sh"), encoding: .utf8)
        #expect(build.contains("tools/check_callback_apis.sh Sources/PaperDeck"))
        // The old inline grep (which matched the wrapper itself) is gone.
        #expect(!build.contains("grep -rnE 'getNotificationSettings"))
    }
}

/// F10: the docs say what the UI does.
@Suite("Docs match the setup window and the move guide")
struct PortFixesDocsTests {
    static func doc(_ path: String) -> String? { try? String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static var present: Bool { doc("docs/USER_GUIDE.md") != nil && doc("README.md") != nil && doc("docs/guides/MOVE_TO_ANOTHER_MAC.md") != nil }

    /// The line(s) of `doc` from the first line containing `start` up to (not including) the next
    /// numbered or bulleted item.
    static func item(_ doc: String, startingWith start: String) -> String? {
        let lines = doc.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(start) }) else { return nil }
        var out = [lines[i]]
        for l in lines[(i + 1)...] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.first?.isNumber == true || t.hasPrefix("- ") || t.hasPrefix("#") { break }
            out.append(l)
        }
        return out.joined(separator: "\n")
    }

    /// Whether every needle occurs in `text`, in this order.
    static func inOrder(_ text: String, _ needles: [String]) -> Bool {
        var from = text.startIndex
        for n in needles {
            guard let r = text.range(of: n, options: [.caseInsensitive], range: from..<text.endIndex) else { return false }
            from = r.upperBound
        }
        return true
    }

    @Test(.enabled(if: present, "docs aren't next to the sources"))
    func theLibraryStepOffersTheHomeFolderOnlyWithICloud() throws {
        // The setup window shows the ~/PaperDeck card only when Documents syncs with iCloud.
        let en = try #require(Self.item(Self.doc("docs/USER_GUIDE.md")!, startingWith: "**Library.**"))
        #expect(en.contains("~/PaperDeck when Documents is in iCloud"), "\(en)")
        #expect(!en.contains("home folder (~/PaperDeck)"))
        let zh = try #require(Self.item(Self.doc("README.md")!, startingWith: "**论文库**"))
        #expect(zh.contains("iCloud") && zh.contains("~/PaperDeck"), "\(zh)")
        #expect(!zh.contains("个人文件夹（~/PaperDeck）、"))
    }

    @Test(.enabled(if: present, "docs aren't next to the sources"))
    func theOldMacExportsBeforeQuittingThenCopies() throws {
        // Export needs the app running: export → quit → copy.
        let guide = Self.doc("docs/guides/MOVE_TO_ANOTHER_MAC.md")!
        let old = try #require(guide.components(separatedBy: "## On the new Mac").first)
        #expect(Self.inOrder(old, ["Export your settings", "Quit PaperDeck", "Copy the library folder"]), "\(old)")
        let user = try #require(Self.item(Self.doc("docs/USER_GUIDE.md")!, startingWith: "**Old Mac:**"))
        #expect(Self.inOrder(user, ["Export Settings", "quit PaperDeck", "copy the library folder"]), "\(user)")
        let readme = try #require(Self.doc("README.md")!.components(separatedBy: "\n").first { $0.contains("**换一台 Mac**") })
        #expect(Self.inOrder(readme, ["导出设置", "退出 PaperDeck", "复制"]), "\(readme)")
    }

    @Test func theMoveTutorialsOldMacStepExportsBeforeQuitting() throws {
        let topic = try #require(GuideCatalog.topic(.moveToNewMac))
        let step = try #require(topic.steps.first { $0.id == "old-mac" })
        #expect(Self.inOrder(step.text.en, ["Export your settings", "quit PaperDeck", "copy the library folder"]), "\(step.text.en)")
        #expect(Self.inOrder(step.text.zh, ["导出设置", "退出", "复制"]), "\(step.text.zh)")
    }
}
