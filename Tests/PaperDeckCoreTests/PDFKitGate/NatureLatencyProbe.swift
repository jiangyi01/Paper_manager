import Foundation
import Testing
@testable import PaperDeckCore

/// Timing probe for the 35 MB Nature fixture, printed as `PROBE …` lines: the extraction alone,
/// the extraction while a reader find runs over the same file (both now take turns at
/// `PDFKitGate`), and a whole import (commit, then the pipeline idle). Prints medians and asserts
/// only success. Opt-in like the other probes:
/// `PAPERDECK_PERF_PROBES=1 ./test.sh -j 4 --filter NatureLatencyProbe`. Skipped without the fixture.
@Suite(.serialized) struct NatureLatencyProbe {
    static let file = NSHomeDirectory() + "/Library/Caches/PaperDeck-dev/fixtures/s41586-024-08351-7.pdf"
    static let enabled = RDPerf.probes && FileManager.default.fileExists(atPath: file)

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }

    @Test(.enabled(if: NatureLatencyProbe.enabled, "a timing probe: PAPERDECK_PERF_PROBES=1")) func extractionAlone() async throws {
        let url = URL(fileURLWithPath: Self.file)
        _ = try await PDFExtractor().extract(url: url, fileName: "nature.pdf")       // warm-up
        var runs: [Double] = []
        for _ in 0..<5 {
            let t = ContinuousClock.now
            let x = try await PDFExtractor().extract(url: url, fileName: "nature.pdf")
            runs.append(Self.ms(ContinuousClock.now - t))
            #expect(x.pageCount == 49)
        }
        print("PROBE extraction-alone ms median=\(Self.median(runs)) runs=\(runs.map { Int($0) })")
    }

    @Test(.enabled(if: NatureLatencyProbe.enabled, "a timing probe: PAPERDECK_PERF_PROBES=1")) func extractionWhileAFindRuns() async throws {
        let url = URL(fileURLWithPath: Self.file)
        let data = try Data(contentsOf: url)
        var runs: [Double] = []
        var finds: [Double] = []
        for _ in 0..<5 {
            let findStart = ContinuousClock.now
            let find = Task.detached { () -> Double in
                var n = 0
                for await b in ReaderFindSearch.search("e", data: data, limit: 5000) { n += b.matches.count }
                _ = n
                return NatureLatencyProbe.ms(ContinuousClock.now - findStart)
            }
            let t = ContinuousClock.now
            _ = try await PDFExtractor().extract(url: url, fileName: "nature.pdf")
            runs.append(Self.ms(ContinuousClock.now - t))
            finds.append(await find.value)
        }
        print("PROBE extraction-with-find ms median=\(Self.median(runs)) runs=\(runs.map { Int($0) }) find-ms median=\(Self.median(finds))")
    }

    @Test(.enabled(if: NatureLatencyProbe.enabled, "a timing probe: PAPERDECK_PERF_PROBES=1")) func wholeImport() async throws {
        var commits: [Double] = []
        var idles: [Double] = []
        for _ in 0..<4 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-probe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let settings = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: .off,
                                          autoReadNewPapers: false, importMode: .copy, metadataLookup: false)
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
                loadSettings: { settings }, fetcher: nil, claude: MockAgentProvider(), codex: MockAgentProvider(),
                sidecarDelay: .milliseconds(10), cliFacts: .inMemory(), loadMailSettings: { MailSettings() },
                mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()]))
            let t = ContinuousClock.now
            let summary = await engine.intake.ingest([.file(URL(fileURLWithPath: Self.file))], options: ImportOptions(origin: .drop))
            commits.append(Self.ms(ContinuousClock.now - t))
            await engine.enrich.waitUntilIdle()
            idles.append(Self.ms(ContinuousClock.now - t))
            #expect(summary.added.count == 1)
            await engine.enrich.shutdown()
            await engine.ctx.sidecars.flush()
            await engine.db.close()
        }
        print("PROBE import commit-ms median=\(Self.median(commits)) runs=\(commits.map { Int($0) }) idle-ms median=\(Self.median(idles)) runs=\(idles.map { Int($0) })")
    }
}
