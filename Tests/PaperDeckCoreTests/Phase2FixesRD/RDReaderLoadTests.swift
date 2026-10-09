import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PaperDeckCore

/// Phase 2 fix RD-3: the reader opens a PDF off the main actor — a coordinated read with a time
/// limit (an iCloud / OneDrive file not downloaded yet is fetched first, as the import does), then
/// the document and its labels built on the read's queue — cancellable, never blocking the window.
/// `PDFDocument(url:)` ran on the main actor and would have frozen it while a cloud file materialized.
/// A coordinated write held by the test stands in for a file that isn't available yet.
@Suite("Phase 2 fixes RD: reader open", .serialized)
struct RDReaderLoadTests {
    /// A coordinated write on `url` held until `release()` (readers must wait), like FileOpsTests'.
    final class WriteLock: @unchecked Sendable {
        let queue = OperationQueue()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        private let gate = DispatchSemaphore(value: 0)

        static func hold(_ url: URL, cap: Double = 60) async -> WriteLock {
            let lock = WriteLock()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.coordinator.coordinate(with: [.writingIntent(with: url, options: [])], queue: lock.queue) { _ in
                    cont.resume()
                    _ = lock.gate.wait(timeout: .now() + cap)
                }
            }
            return lock
        }

        func release() async {
            gate.signal()
            let queue = self.queue
            await BlockingIO.run { queue.waitUntilAllOperationsAreFinished() }
        }
    }

    /// Main-actor ticks counted while an open waits.
    final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-rd-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func lockedPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux = [kCGPDFContextUserPassword: "rd-fixture", kCGPDFContextOwnerPassword: "rd-fixture-owner"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, aux) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 600, width: 200, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    @Test func theOutcomes() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.pdf")
        try ReaderFixturePDF.sample().write(to: good)
        guard case .opened(let opened) = await ReaderDocumentLoader.open(good) else {
            Issue.record("the sample didn't open")
            return
        }
        #expect(opened.pageCount == 6 && opened.labels == ["i", "ii", "1201", "1202", "1203", "1204"])
        #expect(opened.data == (try Data(contentsOf: good)))
        #expect(opened.document.page(at: 2)?.string?.contains("regularize") == true)

        guard case .missing = await ReaderDocumentLoader.open(dir.appendingPathComponent("gone.pdf")) else {
            Issue.record("a missing file isn't .missing"); return
        }
        let broken = dir.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4\nthis is not a PDF body\n%%EOF\n".utf8).write(to: broken)
        guard case .unreadable = await ReaderDocumentLoader.open(broken) else { Issue.record("a damaged file isn't .unreadable"); return }
        let locked = dir.appendingPathComponent("locked.pdf")
        try Self.lockedPDF().write(to: locked)
        guard case .locked = await ReaderDocumentLoader.open(locked) else { Issue.record("a locked file isn't .locked"); return }
    }

    /// A file that isn't available (held by another coordinator, as a download would): the open
    /// waits off the main actor — the main actor keeps running meanwhile — and gives up at the limit.
    @MainActor @Test func aFileThatIsntAvailableTimesOutWithoutBlockingTheMainActor() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cloud.pdf")
        try ReaderFixturePDF.sample().write(to: url)
        let writer = await WriteLock.hold(url)
        let ticks = Ticks()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                ticks.add()
            }
        }
        let t0 = ContinuousClock.now
        let result = await ReaderDocumentLoader.open(url, timeout: .milliseconds(500))
        let waited = ContinuousClock.now - t0
        ticker.cancel()
        await writer.release()
        guard case .timedOut = result else { Issue.record("expected .timedOut, got \(result)"); return }
        #expect(waited >= .milliseconds(450))
        // A waiting main actor would tick 0 times; other suites' main-actor tests may take some turns.
        #expect(ticks.count >= 3, "the main actor ran only \(ticks.count) times while the open waited")
        // Once available, the same file opens.
        guard case .opened = await ReaderDocumentLoader.open(url) else { Issue.record("didn't open once available"); return }
    }

    /// Closing the window while the open waits: it stops at once (no 90 s wait), `.cancelled`.
    @Test func closingTheWindowCancelsTheWait() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cloud.pdf")
        try ReaderFixturePDF.sample().write(to: url)
        let writer = await WriteLock.hold(url)
        let open = Task { await ReaderDocumentLoader.open(url) }
        try await Task.sleep(for: .milliseconds(150))
        let t0 = ContinuousClock.now
        open.cancel()
        let result = await open.value
        #expect(ContinuousClock.now - t0 < .seconds(5))
        await writer.release()
        guard case .cancelled = result else { Issue.record("expected .cancelled, got \(result)"); return }
    }
}
