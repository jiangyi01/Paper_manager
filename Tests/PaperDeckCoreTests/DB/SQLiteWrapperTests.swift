import Foundation
import SQLite3
import Testing
@testable import PaperDeckCore

@Suite struct SQLiteWrapperTests {
    private func memory() throws -> SQLiteConnection {
        let c = try SQLiteConnection(path: ":memory:")
        try c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT, b BLOB, u TEXT UNIQUE)")
        return c
    }

    @Test func bindAndReadEveryType() throws {
        let c = try memory()
        let weird = "a\u{0}b — 单细胞 🧬"
        try c.run("INSERT INTO t(i, r, s, b) VALUES(?, ?, ?, ?)",
                  [.integer(Int64.max), .real(-2.5), .text(weird), .blob(Data([0, 1, 2, 255]))])
        try c.run("INSERT INTO t(i, r, s, b) VALUES(?, ?, ?, ?)", [.null, .null, .text(""), .blob(Data())])
        try c.run("INSERT INTO t(i, r, s, b) VALUES(?, ?, ?, ?)",
                  [.int(nil), .double(nil), .string(nil), .data(nil)])

        let rows = try c.query("SELECT i, r, s, b FROM t ORDER BY id") {
            ($0.optionalInt64(0), $0.optionalDouble(1), $0.optionalString(2), $0.data(3))
        }
        #expect(rows.count == 3)
        #expect(rows[0].0 == Int64.max)
        #expect(rows[0].1 == -2.5)
        #expect(rows[0].2 == weird)                      // embedded NUL and non-BMP survive
        #expect(rows[0].3 == Data([0, 1, 2, 255]))
        #expect(rows[1].0 == nil && rows[1].1 == nil)
        #expect(rows[1].2 == "")                         // empty string is not NULL
        #expect(rows[1].3 == Data())                     // empty blob is not NULL
        #expect(rows[2].2 == nil && rows[2].3 == nil)
        #expect(try c.scalarInt("SELECT typeof(s) = 'text' FROM t WHERE id = 2") == 1)
    }

    @Test func literalsAndFactories() throws {
        let c = try memory()
        try c.run("INSERT INTO t(i, r, s) VALUES(?, ?, ?)", [42, 1.5, "x"])
        try c.run("INSERT INTO t(i, s) VALUES(?, ?)", [.bool(true), .string("y")])
        #expect(try c.query("SELECT i, s FROM t ORDER BY id") { "\($0.int(0))\($0.string(1))" } == ["42x", "1y"])
        #expect(c.lastInsertRowID == 2)
        try c.run("UPDATE t SET i = 0")
        #expect(c.changes == 2)
    }

    @Test func namedParameters() throws {
        let c = try memory()
        let s = try c.prepare("SELECT :a + :b")
        try s.bind(.integer(2), named: ":a")
        try s.bind(.integer(3), named: ":b")
        #expect(try s.step())
        #expect(s.int(0) == 5)
        #expect(s.columnCount == 1)
        #expect(throws: SQLiteError.self) { try s.bind(.null, named: ":missing") }
    }

    @Test func constraintErrorsAreTyped() throws {
        let c = try memory()
        try c.run("INSERT INTO t(u) VALUES('same')")
        do {
            try c.run("INSERT INTO t(u) VALUES('same')")
            Issue.record("expected a unique violation")
        } catch let e as SQLiteError {
            #expect(e.code == SQLITE_CONSTRAINT)
            #expect(e.isConstraintViolation && e.isUniqueViolation)
            #expect(e.message.contains("UNIQUE"))
            #expect(e.sql?.contains("INSERT") == true)
        }
        #expect(throws: SQLiteError.self) { try c.exec("SELEKT 1") }
        #expect(throws: SQLiteError.self) { _ = try c.prepare("SELECT * FROM nope") }
    }

    @Test func transactionCommitsAndRollsBack() throws {
        let c = try memory()
        try c.transaction { try c.run("INSERT INTO t(i) VALUES(1)") }
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try c.transaction {
                try c.run("INSERT INTO t(i) VALUES(2)")
                throw Boom()
            }
        }
        #expect(!c.isInTransaction)
        #expect(try c.query("SELECT i FROM t") { $0.int(0) } == [1])
    }

    @Test func nestedTransactionUsesSavepoint() throws {
        let c = try memory()
        struct Boom: Error {}
        try c.transaction {
            try c.run("INSERT INTO t(i) VALUES(1)")
            _ = try? c.transaction {                      // inner failure rolls back only itself
                try c.run("INSERT INTO t(i) VALUES(2)")
                throw Boom()
            }
            try c.transaction { try c.run("INSERT INTO t(i) VALUES(3)") }
        }
        #expect(try c.query("SELECT i FROM t ORDER BY i") { $0.int(0) } == [1, 3])
    }

    @Test func cachedStatementIsReentrant() throws {
        let c = try memory()
        for i in 1...3 { try c.run("INSERT INTO t(i) VALUES(?)", [.int(i)]) }
        let sql = "SELECT i FROM t ORDER BY i"
        // The same SQL runs again inside the row mapper; the cache must not reset the outer iteration.
        let pairs = try c.query(sql) { row in (row.int(0), try c.query(sql) { $0.int(0) }.count) }
        #expect(pairs.map(\.0) == [1, 2, 3])
        #expect(pairs.allSatisfy { $0.1 == 3 })
    }

    @Test func userVersionAndClose() throws {
        let c = try memory()
        #expect(try c.userVersion() == 0)
        try c.setUserVersion(7)
        #expect(try c.userVersion() == 7)
        c.close()
        c.close()                                         // idempotent
        #expect(!c.isOpen)
        #expect(throws: SQLiteError.self) { try c.exec("SELECT 1") }
    }
}

@Suite struct FTSQueryTests {
    @Test func hostileInputIsNeutralized() {
        #expect(FTSQuery(#""foo" OR bar*) NEAR("#) == .match(#""foo" "bar"*"#))
        #expect(FTSQuery.matchExpression(#"title:x ^y "z"#) == #""title x" "y" "z"*"#)
        #expect(FTSQuery("***  ((( ") == .empty)
        #expect(FTSQuery("   ") == .empty)
        #expect(FTSQuery("NOT AND OR") == .empty)
    }

    @Test func wordsBecomeQuotedPhrasesWithPrefixOnLast() {
        #expect(FTSQuery("single-cell atlas") == .match(#""single cell" "atlas"*"#))
        #expect(FTSQuery("Müller neocort") == .match(#""Müller" "neocort"*"#))
        let many = (1...30).map { "w\($0)" }.joined(separator: " ")
        guard case .match(let expr) = FTSQuery(many) else { Issue.record("expected match"); return }
        #expect(expr.components(separatedBy: " ").count == 16)
        #expect(expr.hasSuffix(#""w16"*"#))
    }

    @Test func cjkAndShortInputFallBackToLike() {
        #expect(FTSQuery("单细胞") == .like("单细胞"))
        #expect(FTSQuery("spatial 转录组") == .like("spatial 转录组"))
        #expect(FTSQuery(" AI ") == .like("AI"))
        #expect(FTSQuery("x") == .like("x"))
        #expect(FTSQuery.containsCJK("ひらがな") && FTSQuery.containsCJK("한국어") && !FTSQuery.containsCJK("naïve"))
    }

    @Test func doiShapes() {
        #expect(FTSQuery("10.1038/S41586-024-08351-7") == .doi("10.1038/s41586-024-08351-7"))
        #expect(FTSQuery("https://doi.org/10.1101/2025.09.01.673319.") == .doi("10.1101/2025.09.01.673319"))
        #expect(FTSQuery("doi: 10.1016/j.cell.2024.10.023") == .doi("10.1016/j.cell.2024.10.023"))
        #expect(FTSQuery.parseDOI("10.1002/(SICI)1097-0258(19980815)17:15)") == "10.1002/(sici)1097-0258(19980815)17:15")
        #expect(FTSQuery.parseDOI("10.12/x y") == nil)
        #expect(FTSQuery.parseDOI("see 10.1038/abc") == nil)
    }

    @Test func arxivShapes() {
        #expect(FTSQuery("2606.24530v2") == .arxiv("2606.24530"))
        #expect(FTSQuery("arXiv:2604.09554") == .arxiv("2604.09554"))
        #expect(FTSQuery("https://arxiv.org/pdf/2606.24530v2.pdf") == .arxiv("2606.24530"))
        #expect(FTSQuery("math.GT/0309136v1") == .arxiv("math.GT/0309136"))
        #expect(FTSQuery.parseArxivID("2606.245") == nil)
    }

    @Test func likePatternEscapesWildcards() {
        #expect(FTSQuery.likePattern(#"50%_a\b"#) == #"%50\%\_a\\b%"#)
    }
}
