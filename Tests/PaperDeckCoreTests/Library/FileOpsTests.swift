import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

private let fixturesDir = SharedPaths.realHome.appendingPathComponent("Library/Caches/PaperDeck-dev/fixtures")
private let naturePDF = fixturesDir.appendingPathComponent("s41586-024-08351-7.pdf")
private let fakePDF = fixturesDir.appendingPathComponent("bad/fake.pdf")
private let originalsList = fixturesDir.appendingPathComponent("ORIGINALS.sha256")

@Suite struct FileOpsTests {
    /// Fresh temp directory, removed (after restoring write permission) when the test ends.
    private final class TempDir {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pd-fileops-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            if let e = FileManager.default.enumerator(atPath: url.path) {
                for case let rel as String in e { chmod(url.appendingPathComponent(rel).path, 0o755) }
            }
            chmod(url.path, 0o755)
            try? FileManager.default.removeItem(at: url)
        }
        func file(_ name: String, _ contents: Data) throws -> URL {
            let u = url.appendingPathComponent(name)
            try contents.write(to: u)
            return u
        }
    }

    private static func setXattr(_ url: URL, _ name: String, _ value: String = "1") -> Bool {
        let bytes = Array(value.utf8)
        return setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0
    }

    // MARK: Hashing

    @Test func sha256KnownVectors() throws {
        let tmp = try TempDir()
        #expect(try FileOps.sha256(of: tmp.file("abc", Data("abc".utf8)))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try FileOps.sha256(of: tmp.file("empty", Data()))
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(FileOps.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256StreamsAcrossChunkBoundaries() throws {
        let tmp = try TempDir()
        var bytes = [UInt8](repeating: 0, count: 3 * FileOps.hashChunkSize + 12_345)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 7) }
        let data = Data(bytes)
        let file = try tmp.file("big.bin", data)
        #expect(try FileOps.sha256(of: file) == FileOps.sha256(of: data))
    }

    @Test func sha256OfMissingFileIsSourceMissing() {
        #expect(throws: FileOpsError.sourceMissing) {
            try FileOps.sha256(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf"))
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: originalsList.path)))
    func fixtureHashesMatchRecordedOriginals() throws {
        let lines = try String(contentsOf: originalsList, encoding: .utf8).split(separator: "\n")
        var checked = 0
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let file = fixturesDir.appendingPathComponent(parts[1].trimmingCharacters(in: .whitespaces))
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            #expect(try FileOps.sha256(of: file) == String(parts[0]), "\(file.lastPathComponent)")
            checked += 1
        }
        #expect(checked > 0)
    }

    // MARK: Sniffing

    @Test func headAndPDFCheck() throws {
        let tmp = try TempDir()
        let junkThenPDF = try tmp.file("junk.pdf", Data(repeating: 0x20, count: 500) + Data("%PDF-1.7\n".utf8))
        #expect(try FileOps.readHead(junkThenPDF, bytes: 16).count == 16)
        #expect(throws: Never.self) { try FileOps.checkPDF(junkThenPDF) }

        let late = try tmp.file("late.pdf", Data(repeating: 0x20, count: 2000) + Data("%PDF-1.7".utf8))
        #expect(throws: FileOpsError.notPDF) { try FileOps.checkPDF(late) }
        #expect(throws: FileOpsError.notPDF) { try FileOps.checkPDF(tmp.url) }         // a directory
        #expect(throws: FileOpsError.sourceMissing) { try FileOps.checkPDF(tmp.url.appendingPathComponent("nope.pdf")) }
        #expect(try FileOps.readHead(try tmp.file("tiny", Data("%P".utf8))) == Data("%P".utf8))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fakePDF.path)))
    func fakeFixtureIsRejected() {
        #expect(throws: FileOpsError.notPDF) { try FileOps.checkPDF(fakePDF) }
    }

    // MARK: Clone

    @Test func cloneOfReadOnlySourceIsWritableAndVerified() throws {
        let tmp = try TempDir()
        let payload = Data("%PDF-1.4\n".utf8) + Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0) })
        let src = try tmp.file("source.pdf", payload)
        #expect(Self.setXattr(src, "com.apple.quarantine", "0083;00000000;Test;"))
        #expect(Self.setXattr(src, "com.apple.fileprovider.pinned"))
        #expect(Self.setXattr(src, "com.example.keep"))
        #expect(chmod(src.path, 0o444) == 0)

        let partial = tmp.url.appendingPathComponent("Papers/_Inbox/.partial")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = FileOps.sha256(of: payload)
        let (copy, sha) = try FileOps.cloneIntoPartial(source: src, partialDir: partial, expectedSHA256: expected.uppercased())

        #expect(sha == expected)
        #expect(copy.deletingLastPathComponent().lastPathComponent == ".partial")
        #expect(copy.pathExtension == "pdf")
        #expect(FileManager.default.isWritableFile(atPath: copy.path))
        let perms = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect((perms ?? 0) & 0o200 != 0)
        let names = FileOps.extendedAttributeNames(copy)
        #expect(!names.contains("com.apple.quarantine"))
        #expect(!names.contains { $0.hasPrefix("com.apple.fileprovider.") })
        #expect(names.contains("com.example.keep"))
        // The source is untouched.
        #expect(!FileManager.default.isWritableFile(atPath: src.path))
        #expect(FileOps.extendedAttributeNames(src).contains("com.apple.quarantine"))
        #expect(FileOps.fileSize(copy) == Int64(payload.count))
    }

    @Test func cloneHashMismatchRemovesPartial() throws {
        let tmp = try TempDir()
        let src = try tmp.file("s.pdf", Data("%PDF-1.4 hello".utf8))
        let partial = tmp.url.appendingPathComponent("partial")
        #expect(throws: FileOpsError.self) {
            try FileOps.cloneIntoPartial(source: src, partialDir: partial, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: partial.path).isEmpty)
    }

    @Test func cloneFailuresAreTyped() throws {
        let tmp = try TempDir()
        #expect(throws: FileOpsError.sourceMissing) {
            try FileOps.cloneIntoPartial(source: tmp.url.appendingPathComponent("gone.pdf"), partialDir: tmp.url)
        }
        let src = try tmp.file("s.pdf", Data("%PDF-".utf8))
        #expect(throws: FileOpsError.libraryUnavailable) {
            try FileOps.cloneIntoPartial(source: src, partialDir: tmp.url.appendingPathComponent("no/such/.partial"))
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("no").path))
    }

    @Test func cloneSharesStorageOnAPFS() throws {
        let tmp = try TempDir()
        let supportsClone = (try? tmp.url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
        guard supportsClone else { return }
        let src = try tmp.file("s.pdf", Data("%PDF-".utf8) + Data(repeating: 7, count: 200_000))
        let (copy, _) = try FileOps.cloneIntoPartial(source: src, partialDir: tmp.url.appendingPathComponent("p"))
        #expect(FileOps.mayShareFileContent(copy) == true)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: naturePDF.path)))
    func cloneOfRealReadOnlyFixture() throws {
        let tmp = try TempDir()
        let expected = try FileOps.sha256(of: naturePDF)
        try FileOps.checkPDF(naturePDF)
        let (copy, sha) = try FileOps.cloneIntoPartial(source: naturePDF, partialDir: tmp.url.appendingPathComponent(".partial"),
                                                      expectedSHA256: expected)
        #expect(sha == expected)
        #expect(FileManager.default.isWritableFile(atPath: copy.path))
        #expect(!FileOps.extendedAttributeNames(copy).contains("com.apple.quarantine"))
        #expect(try FileOps.sha256(of: naturePDF) == expected)
    }

    @Test func xattrRemovalFailureIsNonFatal() throws {
        let tmp = try TempDir()
        let f = try tmp.file("ro.pdf", Data("%PDF-".utf8))
        #expect(Self.setXattr(f, "com.apple.quarantine"))
        #expect(chmod(f.path, 0o444) == 0)
        // Without u+w the removal may fail; it must only be reported, never thrown.
        let failed = FileOps.removeProviderAttributes(f)
        #expect(failed.isEmpty || failed == ["com.apple.quarantine"])
        #expect(FileOps.removeProviderAttributes(tmp.url.appendingPathComponent("missing")).isEmpty)
        #expect(FileOps.extendedAttributeNames(tmp.url.appendingPathComponent("missing")).isEmpty)
    }

    // MARK: Coordinated reads

    @Test func coordinatedReadOfLocalFile() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("paper.pdf", Data("%PDF-1.7 body".utf8))
        let sha = try await FileOps.coordinatedRead(source: f) { url in try FileOps.sha256(of: url) }
        #expect(sha == FileOps.sha256(of: Data("%PDF-1.7 body".utf8)))

        await #expect(throws: FileOpsError.notPDF) {
            try await FileOps.coordinatedRead(source: f) { _ -> Int in throw FileOpsError.notPDF }
        }
        await #expect(throws: FileOpsError.sourceMissing) {
            try await FileOps.coordinatedRead(source: tmp.url.appendingPathComponent("gone.pdf")) { url in
                try FileOps.sha256(of: url)
            }
        }
    }

    /// A coordinated write on a file from another coordinator (so readers must wait), held until
    /// `release()`. Not a fixed time: under load the reader's 200 ms timer or the test's own
    /// sleep could outlast a timed hold, and the read was then simply granted. `cap` only keeps
    /// a broken reader from hanging the suite (it then fails on the value it got).
    private final class WriteLock: @unchecked Sendable {
        let queue = OperationQueue()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        private let gate = DispatchSemaphore(value: 0)

        /// Returns once the writer owns `url`.
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

        /// Ends the write and waits until the writer is gone.
        func release() async {
            gate.signal()
            let queue = self.queue
            await BlockingIO.run { queue.waitUntilAllOperationsAreFinished() }
        }
    }

    @Test func coordinatedReadTimesOutWhileBlockedByWriter() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("busy.pdf", Data("%PDF-".utf8))
        let writer = await WriteLock.hold(f)
        await #expect(throws: FileOpsError.timeout) {
            try await FileOps.coordinatedRead(source: f, timeout: .milliseconds(200)) { _ in 1 }
        }
        await writer.release()                       // only now: the read gave up while the file was busy

        // Once the writer is gone the same read succeeds.
        #expect(try await FileOps.coordinatedRead(source: f, timeout: .seconds(30)) { _ in 7 } == 7)
    }

    @Test func coordinatedReadHonoursCancellation() async throws {
        let tmp = try TempDir()
        let f = try tmp.file("busy.pdf", Data("%PDF-".utf8))
        let writer = await WriteLock.hold(f)
        let task = Task { try await FileOps.coordinatedRead(source: f, timeout: .seconds(30)) { _ in 1 } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await writer.release()                       // only now: not held until the writer ends
    }

    // MARK: Renames, trash, facts

    @Test func atomicRenameRefusesToClobber() throws {
        let tmp = try TempDir()
        let a = try tmp.file("a.pdf", Data("A".utf8))
        let b = try tmp.file("b.pdf", Data("B".utf8))
        #expect(throws: FileOpsError.destinationExists) { try FileOps.atomicRename(from: a, to: b) }
        #expect(try Data(contentsOf: b) == Data("B".utf8))

        let c = tmp.url.appendingPathComponent("c.pdf")
        try FileOps.atomicRename(from: a, to: c)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(try Data(contentsOf: c) == Data("A".utf8))
        #expect(throws: FileOpsError.sourceMissing) { try FileOps.atomicRename(from: a, to: tmp.url.appendingPathComponent("d.pdf")) }
    }

    @Test func moveFolderIncludingCaseOnlyRename() throws {
        let tmp = try TempDir()
        let inbox = tmp.url.appendingPathComponent("5f31a23c")
        try FileOps.createFolder(inbox)
        try FileOps.createFolder(inbox)                                   // idempotent
        _ = try Data("x".utf8).write(to: inbox.appendingPathComponent("x.pdf"))
        let filed = tmp.url.appendingPathComponent("2024_wang_brain")
        try FileOps.moveFolder(from: inbox, to: filed)
        #expect(FileManager.default.fileExists(atPath: filed.appendingPathComponent("x.pdf").path))

        let recased = tmp.url.appendingPathComponent("2024_Wang_Brain")
        try FileOps.moveFolder(from: filed, to: recased)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).contains("2024_Wang_Brain"))

        let other = tmp.url.appendingPathComponent("other")
        try FileOps.createFolder(other)
        #expect(throws: FileOpsError.destinationExists) { try FileOps.moveFolder(from: other, to: recased) }
        #expect(throws: FileOpsError.libraryUnavailable) { try FileOps.createFolder(tmp.url.appendingPathComponent("a/b")) }
    }

    @Test func trashReportsFailureInsteadOfThrowing() throws {
        let tmp = try TempDir()
        #expect(FileOps.trash(tmp.url.appendingPathComponent("missing.pdf")) == false)

        let locked = tmp.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let kept = locked.appendingPathComponent("original.pdf")
        try Data("%PDF-".utf8).write(to: kept)
        #expect(chmod(locked.path, 0o555) == 0)
        #expect(FileOps.trash(kept) == false)                            // EPERM/EACCES → "原文件已保留"
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test func trashMovesItemAway() throws {
        let tmp = try TempDir()
        let f = try tmp.file("PaperDeckTests-trash-\(UUID().uuidString).txt", Data("x".utf8))
        let landed = FileOps.moveToTrash(f)
        #expect(landed != nil)
        #expect(!FileManager.default.fileExists(atPath: f.path))
        if let landed, landed != f { try? FileManager.default.removeItem(at: landed) }   // don't litter the Trash
    }

    @Test func factsAndErrorMapping() throws {
        let tmp = try TempDir()
        let f = try tmp.file("f", Data(count: 1234))
        #expect(FileOps.fileSize(f) == 1234)
        #expect(FileOps.fileSize(tmp.url.appendingPathComponent("nope")) == nil)
        #expect(FileOps.isUbiquitous(f) == false)

        #expect(FileOps.classify(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
        #expect(FileOps.classify(CocoaError(.fileReadNoSuchFile)) == .sourceMissing)
        #expect(FileOps.classify(CocoaError(.fileWriteNoPermission)) == .permissionDenied)
        #expect(FileOps.classify(POSIXError(.ENOSPC)) == .diskFull)
        #expect(FileOps.classify(POSIXError(.EPERM)) == .permissionDenied)
        #expect(FileOps.classify(FileOpsError.timeout) == .timeout)
    }
}
