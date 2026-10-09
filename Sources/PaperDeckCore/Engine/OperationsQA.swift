import Foundation

// Paper Q&A's engine operations (READING_ASSIST_PLAN §6.4 C2/C3). Owned by Slice C. `Engine.qa` is
// built unbound by `Engine.open` (Slice 0); `qaService()` binds it to this library on first use —
// launch recovery included — so every Q&A path in the app goes through it.
extension Engine {
    /// The Q&A service bound to this library (threads and messages in the database, `qa.json`,
    /// notes, the paper text cache, the privacy verdict and the reader of the prompt).
    package func qaService() async -> QAService {
        if await !qa.isBound {
            await qa.bind(QALibrary(ctx: ctx, reader: loadAssistReader, privacy: { [weak self] paperID in
                guard let self else { return .blocked }
                return try await self.assistPrivacy(paperID: paperID, hostBundleID: nil)
            }))
        }
        return qa
    }

    /// Launch recovery (answers a crash left streaming, threads without papers); idempotent.
    package func recoverQA() async {
        _ = await qaService()
    }

    /// Rewrites (or removes) `qa.json` of a paper — after its privacy flags changed, for example.
    package func syncQASidecar(paperID: String) async {
        await qaService().syncSidecar(paperID: paperID)
    }

    /// Imports the `qa.json` threads of `paperIDs` the database doesn't have (index rebuild).
    /// Returns how many threads were added.
    @discardableResult
    package func restoreQASidecars(paperIDs: [String]) async -> Int {
        let qa = await qaService()
        var added = 0
        for id in paperIDs { added += await qa.restoreSidecar(paperID: id) }
        return added
    }
}
