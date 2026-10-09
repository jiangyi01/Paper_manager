import AppKit
import PaperDeckCore

/// Receives file promises (Mail attachments, browser download items).
///
/// The reader callback runs on a background OperationQueue, so everything here is
/// nonisolated and the closure is explicitly @Sendable — a MainActor-inferred
/// closure would trap in `dispatch_assert_queue` under Swift 6.
nonisolated enum PromiseReceiving {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "\(Log.subsystem).promises"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    static func receive(_ receivers: [NSFilePromiseReceiver], into dir: URL,
                                    completion: @escaping @Sendable ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for receiver in receivers {
            let expected = max(1, receiver.fileNames.count)
            for _ in 0..<expected { group.enter() }
            let remaining = Counter(expected)
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { @Sendable url, error in
                if error == nil { box.append(url) }
                if remaining.decrement() >= 0 { group.leave() }
            }
        }
        // A source app that never delivers must not wedge the drop: give up after 2 minutes.
        let once = Once()
        group.notify(queue: .main) { if once.claim() { completion(box.urls) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { if once.claim() { completion(box.urls) } }
    }

    nonisolated private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    nonisolated private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        func append(_ u: URL) { lock.lock(); storage.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Guards against a receiver reporting more files than announced.
    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ v: Int) { value = v }
        func decrement() -> Int { lock.lock(); defer { lock.unlock() }; value -= 1; return value }
    }
}
