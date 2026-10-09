import Foundation

/// A finished HTTP exchange. Non-2xx statuses are values, not errors, so the
/// resolver can cache 404s and HostGate can back off on 429/5xx.
package struct HTTPResult: Sendable, Equatable {
    package var status: Int
    package var body: Data
    package var headers: [String: String]

    package init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
    }

    /// Case-insensitive header lookup (HTTP field names are case-insensitive).
    package func header(_ name: String) -> String? {
        if let v = headers[name] { return v }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    package var isSuccess: Bool { (200..<300).contains(status) }
}

/// Minimal GET transport so the resolver can be tested offline with a fake.
/// Implementations throw only for transport failures (DNS, TLS, timeout, cancellation).
package protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult
}

/// Production transport: an ephemeral session with no cookies and no URL cache
/// (responses are cached in `meta_cache` instead, keyed without the mailto).
package final class URLSessionHTTPFetcher: HTTPFetching {
    /// Bibliographic responses are < 100 KB; anything this large is not what we asked for.
    private static let maxBodyBytes = 8 << 20
    private let session: URLSession

    package init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    package func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = self.session
        let frozen = request
        // URLRequest.timeoutInterval is an idle timeout; race a timer so `timeout` bounds the whole exchange.
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: frozen) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0.01, timeout)))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maxBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String { fields[k] = "\(value)" }
        }
        return HTTPResult(status: http.statusCode, body: data, headers: fields)
    }
}

/// Response cache keyed by request URL (without mailto). The DB-backed store maps
/// onto `meta_cache`; freshness (2xx forever, 404 for 30 days) is decided by the
/// resolver via `MetadataResolver.isFresh`, so stores stay dumb.
package protocol MetadataCacheStore: Sendable {
    func cached(key: String) async -> (status: Int, body: Data, fetchedAt: Date)?
    func store(key: String, status: Int, body: Data, at: Date) async
}

/// Dictionary-backed cache for tests and for running without a database.
package actor InMemoryMetadataCache: MetadataCacheStore {
    private var entries: [String: (status: Int, body: Data, fetchedAt: Date)] = [:]
    package private(set) var storeCount = 0

    package init() {}

    package func cached(key: String) -> (status: Int, body: Data, fetchedAt: Date)? { entries[key] }

    package func store(key: String, status: Int, body: Data, at: Date) {
        entries[key] = (status, body, at)
        storeCount += 1
    }

    package var keys: [String] { entries.keys.sorted() }
}
