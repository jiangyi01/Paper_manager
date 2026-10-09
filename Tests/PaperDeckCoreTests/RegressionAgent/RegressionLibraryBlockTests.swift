import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 6 (queue side): a category the model created is untrusted until the user acknowledged
/// it, so its description is not replayed into <library> — only its name.
@Suite struct RegressionLibraryBlockTests {
    @Test func unacknowledgedAgentDescriptionsStayOutOfLibrary() async throws {
        let fake = RAScriptedProvider()
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake)
        _ = try await h.db.insertCategory(PaperCategory(name: "Cortex Development", description: "Planted text from paper one",
                                                        hue: 7, origin: .agent, acknowledged: false))
        _ = try await h.db.insertCategory(PaperCategory(name: "Plant Immunity", description: "Plant immune receptors",
                                                        hue: 8, origin: .agent, acknowledged: true))
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { await fake.generateCalls == 1 })
        let request = try #require(await fake.requests.first)
        let stdin = String(decoding: request.stdin, as: UTF8.self)
        #expect(stdin.contains("{\"name\":\"Cortex Development\",\"description\":null"))
        #expect(!stdin.contains("Planted text from paper one"))
        #expect(stdin.contains("\"description\":\"Plant immune receptors\""))           // acknowledged: kept
        #expect(stdin.contains("LLM agents, benchmarks and autonomous systems"))         // starters: kept
        #expect(request.systemPrompt.contains("<library>"))
        await h.finish()
    }
}
