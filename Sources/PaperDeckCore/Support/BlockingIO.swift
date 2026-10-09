import Foundation

/// Runs blocking work (PDFKit parsing, hashing, file copies) on a dedicated
/// concurrent GCD queue so it never starves Swift's cooperative thread pool.
package enum BlockingIO {
    private static let queue = DispatchQueue(label: "\(Log.subsystem).blocking",
                                             qos: .userInitiated, attributes: .concurrent)

    package static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try autoreleasepool { try work() }) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    package static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: autoreleasepool { work() }) }
        }
    }
}
