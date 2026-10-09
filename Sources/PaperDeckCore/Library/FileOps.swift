import CryptoKit
import Darwin
import Foundation

/// Typed failures of library file operations, mapped from Cocoa/POSIX errors so the
/// import pipeline can pick the right toast (§6.1 失败) without parsing NSErrors.
package enum FileOpsError: Error, Equatable, Sendable, CustomStringConvertible {
    case notPDF
    case sourceMissing              // ENOENT: "请重新拖入"
    case permissionDenied           // EPERM/EACCES/EROFS (TCC or POSIX)
    case diskFull                   // ENOSPC → pause the pipeline
    case hashMismatch(expected: String, actual: String)
    case timeout                    // coordinated read not granted within the limit
    case destinationExists
    case libraryUnavailable         // the library folder (or its parent) is gone
    case io(String)

    package var description: String {
        switch self {
        case .notPDF: "not a PDF"
        case .sourceMissing: "source file missing"
        case .permissionDenied: "permission denied"
        case .diskFull: "disk full"
        case .hashMismatch(let e, let a): "hash mismatch (expected \(e.prefix(12)), got \(a.prefix(12)))"
        case .timeout: "timed out"
        case .destinationExists: "destination exists"
        case .libraryUnavailable: "library folder unavailable"
        case .io(let msg): msg
        }
    }
}

/// Byte-level file operations for the library: hashing, coordinated reads of dropped
/// (possibly cloud-backed) files, APFS clones, no-clobber renames and trashing.
/// Everything here is synchronous and blocking except `coordinatedRead` — call the
/// rest from an accessor, `BlockingIO.run`, or another non-cooperative thread.
package enum FileOps {
    package static let hashChunkSize = 1 << 20
    package static let headSize = 1024

    /// Where coordinated-read accessors run (§6.1: at most two ingests touch disk at once).
    package static let ingestQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "\(Log.subsystem).ingest"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    // MARK: - Hashing and sniffing

    /// Lowercase hex SHA-256 of the file, streamed in 1 MB chunks.
    package static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw classify(error) }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let chunk: Data? = try autoreleasepool { try handle.read(upToCount: hashChunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
        } catch {
            throw classify(error)
        }
        return hex(hasher.finalize())
    }

    package static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// First `bytes` bytes (fewer if the file is shorter).
    package static func readHead(_ url: URL, bytes: Int = headSize) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: max(0, bytes)) ?? Data()
        } catch {
            throw classify(error)
        }
    }

    /// PDF readers accept junk before the header, so look anywhere in the first KB.
    package static func isPDF(head: Data) -> Bool {
        head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// Throws `.notPDF` unless `url` is a regular file whose first KB contains `%PDF-`.
    package static func checkPDF(_ url: URL) throws {
        var st = stat()
        let err = posix(url) { stat($0, &st) }
        guard err == 0 else { throw classifyErrno(err) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileOpsError.notPDF }
        guard isPDF(head: try readHead(url)) else { throw FileOpsError.notPDF }
    }

    // MARK: - Coordinated reads

    /// Runs `accessor` with coordinated read access to `source` (materializing
    /// OneDrive/iCloud placeholders first). Uses the asynchronous NSFileCoordinator
    /// API — the synchronous one has no timeout — and calls `cancel()` if access is
    /// not granted within `timeout` (→ `.timeout`) or the task is cancelled
    /// (→ `CancellationError`). Once the accessor has started it runs to completion.
    /// The accessor receives the intent's URL, which may differ from `source`.
    package static func coordinatedRead<T: Sendable>(
        source: URL,
        timeout: Duration = .seconds(120),
        queue: OperationQueue = FileOps.ingestQueue,
        _ accessor: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let read = CoordinatedRead<T>()
        let intent = NSFileAccessIntent.readingIntent(with: source, options: .withoutChanges)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                guard read.install(cont) else { return }
                let timer = DispatchWorkItem { read.giveUp(with: FileOpsError.timeout) }
                read.setTimer(timer)
                read.coordinator.coordinate(with: [intent], queue: queue) { error in
                    if let error {
                        read.finish(.failure(classify(error)))
                        return
                    }
                    guard read.beginAccess() else { return }
                    read.finish(Result { try accessor(intent.url) })
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + dispatchInterval(timeout),
                                                                      execute: timer)
            }
        } onCancel: {
            read.giveUp(with: CancellationError())
        }
    }

    // MARK: - Clone into the library

    /// Copies `source` to `partialDir/<uuid>.pdf` (an APFS clone on the same volume),
    /// makes the copy owner-writable (clones keep 0444 from Mail/fixtures), re-hashes the
    /// copy — failing with `.hashMismatch` if it differs from `expectedSHA256` — and strips
    /// `com.apple.fileprovider.*` / quarantine xattrs. chmod/xattr failures are only logged.
    /// Creates `partialDir` itself if needed, but never the library above it.
    ///
    /// The copy's modification date is set to now (a clone keeps the source's), and it is
    /// registered in `InFlightPartials.shared` before it exists — the launch sweep of stale
    /// partials leaves it alone until the caller `remove`s it once consumed.
    package static func cloneIntoPartial(source: URL, partialDir: URL,
                                         expectedSHA256: String? = nil) throws -> (url: URL, sha256: String) {
        let fm = FileManager.default
        let src = source.resolvingSymlinksInPath()
        var st = stat()
        let err = posix(src) { stat($0, &st) }
        guard err == 0 else { throw classifyErrno(err) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileOpsError.notPDF }
        try ensureLeafDirectory(partialDir)

        let dest = partialDir.appendingPathComponent(UUID().uuidString.lowercased() + ".pdf")
        InFlightPartials.shared.insert(dest)
        do { try fm.copyItem(at: src, to: dest) } catch {
            InFlightPartials.shared.remove(dest)
            throw classify(error)
        }
        do {
            makeOwnerWritable(dest)
            touch(dest)
            let sha = try sha256(of: dest)
            if let expected = expectedSHA256?.lowercased(), expected != sha {
                throw FileOpsError.hashMismatch(expected: expected, actual: sha)
            }
            removeProviderAttributes(dest)
            return (dest, sha)
        } catch {
            try? fm.removeItem(at: dest)
            InFlightPartials.shared.remove(dest)
            throw classify(error)
        }
    }

    /// Sets the modification date to now. Returns false (and logs) on failure — never fatal.
    @discardableResult
    package static func touch(_ url: URL) -> Bool {
        let err = posix(url) { utimes($0, nil) }
        if err != 0 { Log.storage.error("utimes failed (\(err)) for \(url.lastPathComponent, privacy: .public)") }
        return err == 0
    }

    /// Adds u+w when missing. Returns false (and logs) on failure — never fatal.
    @discardableResult
    package static func makeOwnerWritable(_ url: URL) -> Bool {
        var st = stat()
        let statErr = posix(url) { lstat($0, &st) }
        guard statErr == 0 else {
            Log.storage.error("chmod u+w: stat failed (\(statErr)) for \(url.lastPathComponent, privacy: .public)")
            return false
        }
        if st.st_mode & S_IWUSR != 0 { return true }
        let mode = (st.st_mode & 0o7777) | S_IWUSR
        let err = posix(url) { chmod($0, mode) }
        if err != 0 { Log.storage.error("chmod u+w failed (\(err)) for \(url.lastPathComponent, privacy: .public)") }
        return err == 0
    }

    /// Removes `com.apple.fileprovider.*` and `com.apple.quarantine`. Returns the names
    /// that could not be removed (logged, never thrown).
    @discardableResult
    package static func removeProviderAttributes(_ url: URL) -> [String] {
        var failed: [String] = []
        for name in extendedAttributeNames(url)
        where name.hasPrefix("com.apple.fileprovider.") || name == "com.apple.quarantine" {
            let err = posix(url) { removexattr($0, name, XATTR_NOFOLLOW) }
            if err != 0 {
                failed.append(name)
                Log.storage.info("xattr \(name, privacy: .public) not removed (\(err)) — ignored")
            }
        }
        return failed
    }

    package static func extendedAttributeNames(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { p -> [String] in
            guard let p else { return [] }
            for _ in 0..<2 {
                let size = listxattr(p, nil, 0, XATTR_NOFOLLOW)
                guard size > 0 else { return [] }
                var buf = [CChar](repeating: 0, count: size)
                let got = listxattr(p, &buf, size, XATTR_NOFOLLOW)
                let err = errno
                if got < 0 { if err == ERANGE { continue } else { return [] } }
                return buf[..<got].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            }
            return []
        }
    }

    // MARK: - Renames, moves, trash

    /// rename(2) that refuses to replace an existing destination (`.destinationExists`).
    /// A case-only rename of the same item is allowed on case-insensitive volumes.
    package static func atomicRename(from src: URL, to dst: URL) throws {
        let err = renameNoClobber(src, dst)
        if err != 0 { throw classifyErrno(err) }
    }

    /// Moves a paper folder (refile, soft delete). Atomic on the same volume; across
    /// volumes it falls back to copy+delete, still refusing to overwrite.
    package static func moveFolder(from src: URL, to dst: URL) throws {
        let err = renameNoClobber(src, dst)
        if err == 0 { return }
        guard err == EXDEV else { throw classifyErrno(err) }
        guard !FileManager.default.fileExists(atPath: dst.path) else { throw FileOpsError.destinationExists }
        do { try FileManager.default.moveItem(at: src, to: dst) } catch { throw classify(error) }
    }

    /// Creates one directory whose parent must already exist (no intermediates, so a
    /// vanished library root is never silently recreated). Existing directory → no-op.
    package static func createFolder(_ url: URL) throws {
        try ensureLeafDirectory(url)
    }

    /// Moves `url` to the Trash. False on any failure — notably EPERM when the parent
    /// isn't writable (the UI then says "原文件已保留"); failures are info-level.
    @discardableResult
    package static func trash(_ url: URL) -> Bool {
        moveToTrash(url) != nil
    }

    /// Like `trash`, returning where the item landed (nil on failure).
    @discardableResult
    package static func moveToTrash(_ url: URL) -> URL? {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return (resulting as URL?) ?? url
        } catch {
            Log.storage.info("trash failed for \(url.lastPathComponent, privacy: .public): \(classify(error).description, privacy: .public)")
            return nil
        }
    }

    // MARK: - Facts

    /// "May share storage with another file" (was cloned). nil if unknown.
    package static func mayShareFileContent(_ url: URL) -> Bool? {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.mayShareFileContentKey]))?.mayShareFileContent
    }

    /// Logical size in bytes, nil if the item can't be stat'ed.
    package static func fileSize(_ url: URL) -> Int64? {
        var st = stat()
        guard posix(url, { stat($0, &st) }) == 0 else { return nil }
        return Int64(st.st_size)
    }

    /// True for items in iCloud Drive / File Provider folders (OneDrive), which may be
    /// dataless placeholders until a coordinated read materializes them.
    package static func isUbiquitous(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    // MARK: - Error mapping

    /// Maps any Cocoa/POSIX error to a `FileOpsError` (passes FileOpsError through).
    package static func classify(_ error: any Error) -> FileOpsError {
        if let e = error as? FileOpsError { return e }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return classifyErrno(Int32(truncatingIfNeeded: ns.code)) }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .sourceMissing
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return .permissionDenied
            case NSFileWriteOutOfSpaceError: return .diskFull
            case NSFileWriteFileExistsError: return .destinationExists
            default: break
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return classifyErrno(Int32(truncatingIfNeeded: underlying.code))
            }
        }
        return .io(ns.localizedDescription)
    }

    package static func classifyErrno(_ code: Int32) -> FileOpsError {
        switch code {
        case ENOENT, ENOTDIR: .sourceMissing
        case EPERM, EACCES, EROFS: .permissionDenied
        case ENOSPC, EDQUOT: .diskFull
        case EEXIST, ENOTEMPTY: .destinationExists
        case ETIMEDOUT: .timeout
        default: .io(String(cString: strerror(code)))
        }
    }

    // MARK: - Private helpers

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func dispatchInterval(_ d: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = d.components
        let ns = max(0, seconds) &* 1_000_000_000 &+ max(0, attoseconds) / 1_000_000_000
        return .nanoseconds(Int(clamping: ns))
    }

    /// Runs a POSIX call on the file-system representation of `url`; returns 0 on success
    /// or the errno captured immediately after the call.
    private static func posix(_ url: URL, _ call: (UnsafePointer<CChar>) -> Int32) -> Int32 {
        url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return EINVAL }
            return call(p) == 0 ? 0 : errno
        }
    }

    private static func posix(_ a: URL, _ b: URL, _ call: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32) -> Int32 {
        a.withUnsafeFileSystemRepresentation { pa in
            b.withUnsafeFileSystemRepresentation { pb in
                guard let pa, let pb else { return EINVAL }
                return call(pa, pb) == 0 ? 0 : errno
            }
        }
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard posix(a, { lstat($0, &sa) }) == 0, posix(b, { lstat($0, &sb) }) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// 0 on success, else the errno of the failed rename.
    private static func renameNoClobber(_ src: URL, _ dst: URL) -> Int32 {
        let err = posix(src, dst) { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
        guard err == EEXIST, isSameItem(src, dst) else { return err }
        return posix(src, dst) { rename($0, $1) }
    }

    private static func ensureLeafDirectory(_ url: URL) throws {
        var st = stat()
        if posix(url, { stat($0, &st) }) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR else { throw FileOpsError.destinationExists }
            return
        }
        var parent = stat()
        guard posix(url.deletingLastPathComponent(), { stat($0, &parent) }) == 0,
              (parent.st_mode & S_IFMT) == S_IFDIR else {
            throw FileOpsError.libraryUnavailable
        }
        let err = posix(url) { mkdir($0, 0o755) }
        if err != 0, err != EEXIST { throw classifyErrno(err) }
    }
}

/// `.partial/` files an import is working on right now (process-wide, by path). The launch
/// sweep of stale partials skips them even when their modification date looks old, so an
/// ingest running while `Engine.start()` cleans up never loses its copy. Entries are cheap
/// and harmless once their file is gone.
package final class InFlightPartials: @unchecked Sendable {
    package static let shared = InFlightPartials()

    private let lock = NSLock()
    private var paths: Set<String> = []

    package func insert(_ url: URL) { lock.withLock { _ = paths.insert(Self.key(url)) } }
    package func remove(_ url: URL) { lock.withLock { _ = paths.remove(Self.key(url)) } }
    package func contains(_ url: URL) -> Bool { lock.withLock { paths.contains(Self.key(url)) } }

    /// The parent resolved (`/var` vs `/private/var` listings) + the file name, which stays
    /// stable after the file itself is gone.
    private static func key(_ url: URL) -> String {
        let u = url.standardizedFileURL
        return u.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" + u.lastPathComponent
    }
}

/// Shared state of one coordinated read: exactly one resume of the continuation,
/// and the timeout/cancel path only wins while access has not been granted yet.
private final class CoordinatedRead<T: Sendable>: @unchecked Sendable {
    private enum Phase { case waiting, accessing, finished }

    let coordinator = NSFileCoordinator(filePresenter: nil)
    private let lock = NSLock()
    private var phase = Phase.waiting
    private var continuation: CheckedContinuation<T, any Error>?
    private var earlyError: (any Error)?
    private var timer: DispatchWorkItem?

    /// False if the read was already abandoned (task cancelled before start); the
    /// continuation is then resumed here.
    func install(_ cont: CheckedContinuation<T, any Error>) -> Bool {
        lock.lock()
        if phase == .finished {
            let error = earlyError ?? CancellationError()
            lock.unlock()
            cont.resume(throwing: error)
            return false
        }
        continuation = cont
        lock.unlock()
        return true
    }

    func setTimer(_ item: DispatchWorkItem) {
        lock.lock(); timer = item; lock.unlock()
    }

    func beginAccess() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .waiting else { return false }
        phase = .accessing
        return true
    }

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        guard phase != .finished else { lock.unlock(); return }
        phase = .finished
        let cont = continuation, item = timer
        continuation = nil; timer = nil
        lock.unlock()
        item?.cancel()
        cont?.resume(with: result)
    }

    /// Timeout or task cancellation: abandons the wait unless the accessor already runs.
    func giveUp(with error: any Error) {
        lock.lock()
        guard phase == .waiting else { lock.unlock(); return }
        phase = .finished
        let cont = continuation, item = timer
        continuation = nil; timer = nil
        if cont == nil { earlyError = error }
        lock.unlock()
        item?.cancel()
        coordinator.cancel()
        cont?.resume(throwing: error)
    }
}
