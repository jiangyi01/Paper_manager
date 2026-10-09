import Foundation

/// What changed in the library, emitted after a DB transaction commits.
package enum LibraryChange: Sendable, Equatable {
    case paper(pk: Int64)            // row fields, checklist or tags of one paper
    case papersBulk                  // many papers (import batch, skip-day, rebuild)
    case categories
    case jobs
    case settings
    case mail(pk: Int64)             // one captured email: its row, items or triage state
    case mailBulk                    // many emails (sync batch, retention purge, clear all mail data)
}

/// Fan-out broadcaster: every subscriber gets its own AsyncStream.
/// Thread-safe; `send` never blocks.
package final class ChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    package init() {}

    package func subscribe() -> AsyncStream<LibraryChange> {
        let id = UUID()
        let (stream, cont) = AsyncStream<LibraryChange>.makeStream(bufferingPolicy: .bufferingNewest(256))
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
        }
        lock.lock(); continuations[id] = cont; lock.unlock()
        return stream
    }

    package func send(_ change: LibraryChange) {
        lock.lock(); let conts = Array(continuations.values); lock.unlock()
        for c in conts { c.yield(change) }
    }
}
