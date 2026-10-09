import Darwin
import Foundation
@preconcurrency import PDFKit

/// The one gate all of PaperDeck's own PDFKit work goes through: one thread at a time,
/// process-wide. That covers opening, reading, drawing and releasing documents off the main actor,
/// plus the reader's text calls on its window's document.
///
/// Why: PDFKit resolves a PDF's fonts through process-wide state that isn't thread-safe. While one
/// thread builds `PDFPage.attributedString` (the title heuristic), another thread can open, read
/// (`string`), draw (a thumbnail) or release a different document. PDFKit's
/// `-[NSFont fontWithSize:]` can then return nil, and PDFKit throws "object cannot be nil (key:
/// NSFont)". That NSException is uncaught and kills the process. A lock around the title heuristic
/// alone wasn't enough because the other paths stayed outside it. The race shows most often with
/// fonts the process hasn't used yet, and drawing a page (a thumbnail) at the same time is the
/// strongest trigger. `PDFKitGateStressTests` reproduces it.
///
/// Not covered: a reader window's PDFView draws and tracks selections on PDFKit's own threads,
/// outside this gate.
///
/// - Re-entrant: gated helpers nest (the extractor calls the title heuristic inside its own gate;
///   the reader runs the quote finder inside one).
/// - Fair: hand-off is first come, first served, so a long import can't starve the reader's find.
/// - Each `run` drains its own autorelease pool before it lets go, so PDFKit's temporaries are
///   freed inside the gate.
/// - Holders take it for one step (a page, a title, a thumbnail), never across an `await`: bodies
///   are synchronous.
/// - A holder never waits for the main thread, so the main actor may take it too. It then waits at
///   most one step.
package final class PDFKitGate: @unchecked Sendable {
    package static let shared = PDFKitGate()

    private let mutex: UnsafeMutablePointer<pthread_mutex_t>
    /// The owner's nesting depth (read and written only while holding `mutex`).
    private var depth = 0
    private let stats = NSLock()
    private var owner: pthread_t?
    private var inside = 0
    private var peak = 0
    private var entries = 0

    package init() {
        mutex = .allocate(capacity: 1)
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE)
        pthread_mutexattr_setpolicy_np(&attr, PTHREAD_MUTEX_POLICY_FAIRSHARE_NP)
        let status = pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
        precondition(status == 0, "PDFKitGate: pthread_mutex_init failed (\(status))")
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    /// Runs `body` holding the gate, inside its own autorelease pool. Nested calls on the same
    /// thread go straight in.
    package func run<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        depth += 1
        if depth == 1 { stats.withLock { owner = pthread_self(); inside += 1; peak = max(peak, inside); entries += 1 } }
        defer {
            if depth == 1 { stats.withLock { owner = nil; inside -= 1 } }
            depth -= 1
            pthread_mutex_unlock(mutex)
        }
        return try autoreleasepool { try body() }
    }

    /// Whether the calling thread holds the gate.
    package var isHeldByCurrentThread: Bool {
        stats.withLock { owner.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
    }

    /// The most threads ever inside at once since the last `resetPeak()` (always 1 while it holds).
    package var maxInside: Int { stats.withLock { peak } }
    package func resetPeak() { stats.withLock { peak = inside } }
    /// Outermost entries so far (nested calls don't count).
    package var entryCount: Int { stats.withLock { entries } }
}

/// A `PDFDocument` that one task owns. It is opened, used and released inside `PDFKitGate`. Every
/// use is a `with { }` call, one step at a time (a page, the title, the thumbnail), so other PDFKit
/// work can run between steps. Don't let the document or its pages escape a `with` body. Not for
/// a window's document: a view draws that one on the main thread.
package final class GatedPDFDocument: @unchecked Sendable {
    /// Set until `deinit`, which releases it inside the gate.
    private var document: PDFDocument?
    private let gate: PDFKitGate

    /// Opens the file; nil when PDFKit can't read it.
    package convenience init?(url: URL, gate: PDFKitGate = .shared) {
        guard let document = gate.run({ PDFDocument(url: url) }) else { return nil }
        self.init(document, gate: gate)
    }

    /// Opens the bytes; nil when PDFKit can't read them.
    package convenience init?(data: Data, gate: PDFKitGate = .shared) {
        guard let document = gate.run({ PDFDocument(data: data) }) else { return nil }
        self.init(document, gate: gate)
    }

    private init(_ document: PDFDocument, gate: PDFKitGate) {
        self.document = document
        self.gate = gate
    }

    /// Runs `body` with the document, holding the gate.
    package func with<T>(_ body: (PDFDocument) throws -> T) rethrows -> T {
        try gate.run {
            guard let document else { preconditionFailure("GatedPDFDocument used after release") }
            return try body(document)
        }
    }

    deinit {
        gate.run { document = nil }
    }
}
