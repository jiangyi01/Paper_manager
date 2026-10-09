import Foundation
import Testing
import PaperDeckShared

/// Lints G2 and G3 (PORTABILITY_PLAN §6.4) over `Sources/**/*.swift`: the author's identity
/// appears only as `BuildIdentity.defaultBundleID`, and the only personal folder is the legacy
/// install's import folder (`LegacyInstall.importFolder`, today's value for an existing install).
/// No `/Users/<name>` path in any source. (The plists and scripts are checked by
/// tools/verify_portability.sh.)
@Suite("Lint: identity and personal paths", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct IdentityLintTests {
    @Test func theAuthorsIdentityIsOnlyTheDefaultBundleID() throws {
        let author = "yi" + "jiang"
        let hits = try LintRepo.grep(author)
        #expect(hits.count == 1, "\(hits.map(\.description).joined(separator: "\n"))")
        let only = try #require(hits.first)
        #expect(only.path == "Sources/PaperDeckShared/BuildIdentity.swift")
        #expect(only.text.contains("defaultBundleID"))
        #expect(only.text.contains("\"\(BuildIdentity.defaultBundleID)\""))
    }

    @Test func theOnlyPersonalFolderIsTheLegacyImportFolder() throws {
        let pattern = "Paper" + "_reading|/Users/[A-Za-z]"
        let hits = try LintRepo.grep(pattern)
        #expect(hits.count == 1, "\(hits.map(\.description).joined(separator: "\n"))")
        let only = try #require(hits.first)
        #expect(only.path == "Sources/PaperDeckConfig/Presets/LegacyInstall.swift")
        #expect(only.text.contains("importFolder"))
    }
}
