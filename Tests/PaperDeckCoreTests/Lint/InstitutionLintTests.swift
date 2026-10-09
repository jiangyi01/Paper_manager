import Foundation
import Testing

/// Lint G1 (PORTABILITY_PLAN §2.1 rule 3, §6.4): institution literals live only in the institution
/// preset (`Sources/PaperDeckConfig/Presets/OrganizationPresets.swift`). Code anywhere else names
/// the legacy preset `OrganizationPresets.legacyInstallPreset` and words institution text through
/// `OrgStrings`. Tests and their fixtures are exempt (the synthetic legacy domain, golden copies).
@Suite("Lint: institution literals", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct InstitutionLintTests {
    /// G1's pattern, spelled in pieces so no source line (not even a comment quoting it) matches.
    static let pattern = ["wash" + "u", "wus" + "tl", "washing" + "ton ?university"].joined(separator: "|")
    static let allowed: Set<String> = ["Sources/PaperDeckConfig/Presets/OrganizationPresets.swift"]

    @Test func noInstitutionLiteralOutsideTheInstitutionPreset() throws {
        let hits = try LintRepo.grep(Self.pattern, caseInsensitive: true).filter { !Self.allowed.contains($0.path) }
        #expect(hits.isEmpty, "institution literals outside OrganizationPresets.swift:\n\(hits.map(\.description).joined(separator: "\n"))")
    }

    /// The scan really sees the sources: the preset itself holds the literals.
    @Test func theScanFindsThePresetItself() throws {
        let hits = try LintRepo.grep(Self.pattern, caseInsensitive: true)
        #expect(hits.contains { Self.allowed.contains($0.path) })
        #expect(LintRepo.swiftFiles(under: "Sources").count > 100)
    }

    /// Lint G4 (§2.1 rule 4): logic that recognises cloud-root folder names lives only in
    /// `CloudRootLocator` (and the institution preset's root-name hint).
    @Test func cloudRootNameLogicLivesInCloudRootLocator() throws {
        let one = "One" + "Drive"
        let pattern = ["CloudStorage/\(one)", #"hasPrefix\(""# + one, #"contains\(""# + one, "\(one)-Personal", "\(one)-SharedLibraries"]
            .joined(separator: "|")
        let allowed: Set<String> = ["Sources/PaperDeckConfig/Mail/CloudRootLocator.swift",
                                    "Sources/PaperDeckConfig/Presets/OrganizationPresets.swift"]
        let hits = try LintRepo.grep(pattern).filter { !allowed.contains($0.path) }
        #expect(hits.isEmpty, "cloud-root name checks outside CloudRootLocator:\n\(hits.map(\.description).joined(separator: "\n"))")
    }
}
