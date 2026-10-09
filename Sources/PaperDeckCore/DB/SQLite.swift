import Foundation
import SQLite3

// A deliberately small wrapper over the system libsqlite3. Connections and
// statements are NOT Sendable: they live inside the `Database` actor and are
// only touched from its serial executor.

/// A failed libsqlite3 call: primary result code, extended code and the message.
package struct SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    package var code: Int32              // primary result code, e.g. SQLITE_CONSTRAINT
    package var extendedCode: Int32      // e.g. SQLITE_CONSTRAINT_UNIQUE (2067)
    package var message: String
    package var sql: String?

    package init(code: Int32, extendedCode: Int32? = nil, message: String, sql: String? = nil) {
        self.code = code & 0xFF
        self.extendedCode = extendedCode ?? code
        self.message = message
        self.sql = sql
    }

    package var isConstraintViolation: Bool { code == SQLITE_CONSTRAINT }
    /// UNIQUE / PRIMARY KEY conflict (duplicate sha256, live DOI, active agent job…).
    package var isUniqueViolation: Bool {
        extendedCode == sqliteConstraintUnique || extendedCode == sqliteConstraintPrimaryKey
    }
    package var isBusy: Bool { code == SQLITE_BUSY || code == SQLITE_LOCKED }
    package var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }

    package var description: String {
        var s = "SQLite error \(extendedCode): \(message)"
        if let sql { s += " [\(sql.prefix(120))]" }
        return s
    }

    static let closed = SQLiteError(code: SQLITE_MISUSE, message: "database connection is closed")
}

// Macros the Swift importer cannot see (casts / compound expressions).
private let sqliteConstraintUnique: Int32 = 2067        // SQLITE_CONSTRAINT | (8 << 8)
private let sqliteConstraintPrimaryKey: Int32 = 1555    // SQLITE_CONSTRAINT | (6 << 8)
/// SQLITE_TRANSIENT: SQLite copies the bytes before the bind call returns.
private var sqliteTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

/// A value to bind. The lower-case factories map Swift optionals to NULL.
package enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    package static func int(_ v: Int?) -> SQLiteValue { v.map { .integer(Int64($0)) } ?? .null }
    package static func int64(_ v: Int64?) -> SQLiteValue { v.map { .integer($0) } ?? .null }
    package static func double(_ v: Double?) -> SQLiteValue { v.map { .real($0) } ?? .null }
    package static func string(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
    package static func data(_ v: Data?) -> SQLiteValue { v.map { .blob($0) } ?? .null }
    package static func bool(_ v: Bool) -> SQLiteValue { .integer(v ? 1 : 0) }
}

extension SQLiteValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    package init(integerLiteral value: Int64) { self = .integer(value) }
    package init(floatLiteral value: Double) { self = .real(value) }
    package init(stringLiteral value: String) { self = .text(value) }
}

/// A prepared statement. Parameters are 1-based, columns 0-based (SQLite convention).
package final class SQLiteStatement {
    private let handle: OpaquePointer
    private let db: OpaquePointer
    package let sql: String
    /// Set while rows are being iterated, so the connection's cache hands out a
    /// fresh statement instead of resetting this one underneath the caller.
    fileprivate var inUse = false

    fileprivate init(db: OpaquePointer, sql: String, persistent: Bool) throws {
        var stmt: OpaquePointer?
        let flags = persistent ? UInt32(SQLITE_PREPARE_PERSISTENT) : 0
        let rc = sqlite3_prepare_v3(db, sql, -1, flags, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(db),
                              message: rc == SQLITE_OK ? "empty statement" : String(cString: sqlite3_errmsg(db)),
                              sql: sql)
        }
        self.handle = stmt
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    private func failure(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(db),
                    message: String(cString: sqlite3_errmsg(db)), sql: sql)
    }

    /// Ends any in-progress step (releasing its read snapshot) and clears bindings.
    package func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Resets, then binds `values` to parameters 1…n.
    package func bind(_ values: [SQLiteValue]) throws {
        reset()
        for (i, v) in values.enumerated() { try bind(v, at: Int32(i + 1)) }
    }

    package func bind(_ value: SQLiteValue, at index: Int32) throws {
        let h = handle
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(h, index)
        case .integer(let v):
            rc = sqlite3_bind_int64(h, index, v)
        case .real(let v):
            rc = sqlite3_bind_double(h, index, v)
        case .text(let s):
            var s = s
            rc = s.withUTF8 { buf -> Int32 in
                // A nil base address would bind NULL instead of ''.
                guard let base = buf.baseAddress else { return sqlite3_bind_text(h, index, "", 0, sqliteTransient) }
                return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    sqlite3_bind_text64(h, index, $0, sqlite3_uint64(buf.count), sqliteTransient, UInt8(SQLITE_UTF8))
                }
            }
        case .blob(let d):
            rc = d.withUnsafeBytes { buf -> Int32 in
                guard let base = buf.baseAddress, buf.count > 0 else { return sqlite3_bind_zeroblob(h, index, 0) }
                return sqlite3_bind_blob64(h, index, base, sqlite3_uint64(buf.count), sqliteTransient)
            }
        }
        guard rc == SQLITE_OK else { throw failure(rc) }
    }

    package func bind(_ value: SQLiteValue, named name: String) throws {
        let index = sqlite3_bind_parameter_index(handle, name)
        guard index > 0 else {
            throw SQLiteError(code: SQLITE_RANGE, message: "no parameter named \(name)", sql: sql)
        }
        try bind(value, at: index)
    }

    /// Advances one row: true when a row is available, false when done.
    /// On error the statement is reset so it never keeps a snapshot open.
    package func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let err = failure(rc)
            sqlite3_reset(handle)
            throw err
        }
    }

    /// Binds, steps to completion and resets (INSERT/UPDATE/DELETE/DDL).
    package func run(_ values: [SQLiteValue] = []) throws {
        try bind(values)
        defer { reset() }
        while try step() {}
    }

    /// Binds, maps every row, resets. The closure must not keep the statement.
    package func map<T>(_ values: [SQLiteValue] = [], _ transform: (SQLiteStatement) throws -> T) throws -> [T] {
        try bind(values)
        inUse = true
        defer { inUse = false; reset() }
        var out: [T] = []
        while try step() { out.append(try transform(self)) }
        return out
    }

    // MARK: Columns (valid only while positioned on a row)

    package var columnCount: Int32 { sqlite3_column_count(handle) }
    package func columnName(_ i: Int32) -> String { sqlite3_column_name(handle, i).map { String(cString: $0) } ?? "" }
    package func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }

    package func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    package func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(handle, i)) }
    package func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    package func bool(_ i: Int32) -> Bool { sqlite3_column_int64(handle, i) != 0 }
    /// Text of the column; "" for NULL. Decoded with the byte count so embedded NULs survive.
    package func string(_ i: Int32) -> String { optionalString(i) ?? "" }

    package func optionalInt64(_ i: Int32) -> Int64? { isNull(i) ? nil : int64(i) }
    package func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    package func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    package func optionalString(_ i: Int32) -> String? {
        guard !isNull(i), let p = sqlite3_column_text(handle, i) else { return nil }
        let n = Int(sqlite3_column_bytes(handle, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
    /// Blob of the column; nil for NULL, empty Data for a zero-length blob.
    package func data(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(handle, i))
        guard n > 0, let p = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: p, count: n)
    }

    package func value(_ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(handle, i) {
        case SQLITE_INTEGER: return .integer(int64(i))
        case SQLITE_FLOAT: return .real(double(i))
        case SQLITE_TEXT: return .text(string(i))
        case SQLITE_BLOB: return .blob(data(i) ?? Data())
        default: return .null
        }
    }
}

/// One libsqlite3 connection (serialized mode). Caches prepared statements by SQL text.
package final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var cache: [String: SQLiteStatement] = [:]
    private var savepointDepth = 0
    package let path: String

    /// Opens (creating if needed) the database at `path`; ":memory:" for a private in-memory DB.
    package init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(h)
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        sqlite3_extended_result_codes(h, 1)
        self.handle = h
        self.path = path
    }

    deinit { close() }

    package var isOpen: Bool { handle != nil }

    /// Finalizes cached statements and closes. Idempotent; later calls throw `SQLITE_MISUSE`.
    package func close() {
        cache.removeAll()
        if let h = handle { sqlite3_close_v2(h) }
        handle = nil
    }

    private func open() throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.closed }
        return handle
    }

    /// Runs one or more `;`-separated statements without parameters.
    package func exec(_ sql: String) throws {
        let h = try open()
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        guard rc == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(h))
            sqlite3_free(err)
            throw SQLiteError(code: rc, extendedCode: sqlite3_extended_errcode(h), message: message, sql: sql)
        }
    }

    /// A new statement owned by the caller (not cached).
    package func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(db: open(), sql: sql, persistent: false)
    }

    /// A cached statement for hot SQL; a fresh one if the cached copy is mid-iteration.
    package func cached(_ sql: String) throws -> SQLiteStatement {
        let h = try open()
        if let s = cache[sql] {
            if !s.inUse { return s }
            return try SQLiteStatement(db: h, sql: sql, persistent: false)
        }
        if cache.count >= 256 { cache = cache.filter { $0.value.inUse } }   // bound growth from ad-hoc SQL
        let s = try SQLiteStatement(db: h, sql: sql, persistent: true)
        cache[sql] = s
        return s
    }

    package func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try cached(sql).run(values)
    }

    package func query<T>(_ sql: String, _ values: [SQLiteValue] = [],
                          _ transform: (SQLiteStatement) throws -> T) throws -> [T] {
        try cached(sql).map(values, transform)
    }

    package func queryOne<T>(_ sql: String, _ values: [SQLiteValue] = [],
                             _ transform: (SQLiteStatement) throws -> T) throws -> T? {
        let s = try cached(sql)
        try s.bind(values)
        s.inUse = true
        defer { s.inUse = false; s.reset() }
        return try s.step() ? transform(s) : nil
    }

    /// First column of the first row (nil when no row or NULL).
    package func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        try queryOne(sql, values) { $0.optionalInt64(0) } ?? nil
    }

    package func scalarString(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        try queryOne(sql, values) { $0.optionalString(0) } ?? nil
    }

    /// Runs `body` atomically: BEGIN [IMMEDIATE]…COMMIT, or a SAVEPOINT when a
    /// transaction is already open, so write helpers compose. Any throw rolls back.
    package func transaction<T>(immediate: Bool = true, _ body: () throws -> T) throws -> T {
        let h = try open()
        if sqlite3_get_autocommit(h) == 0 {
            savepointDepth += 1
            defer { savepointDepth -= 1 }
            let name = "pd_sp\(savepointDepth)"
            try exec("SAVEPOINT \(name)")
            do {
                let result = try body()
                try exec("RELEASE \(name)")
                return result
            } catch {
                try? exec("ROLLBACK TO \(name)")
                try? exec("RELEASE \(name)")
                throw error
            }
        }
        try exec(immediate ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            if sqlite3_get_autocommit(h) == 0 { try? exec("ROLLBACK") }
            throw error
        }
    }

    package var isInTransaction: Bool { handle.map { sqlite3_get_autocommit($0) == 0 } ?? false }
    package var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    package var changes: Int { handle.map { Int(sqlite3_changes64($0)) } ?? 0 }

    package func userVersion() throws -> Int {
        Int(try scalarInt("PRAGMA user_version") ?? 0)
    }

    package func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version)")
    }
}
