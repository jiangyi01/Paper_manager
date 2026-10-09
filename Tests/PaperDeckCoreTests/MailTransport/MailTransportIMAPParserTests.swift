import Foundation
import Testing
@testable import PaperDeckCore

private func transportFixture(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext,
                                             subdirectory: "Fixtures/mail/mail-transport"))
    return try Data(contentsOf: url)
}

/// Feeds `data` in `chunk`-byte pieces and parses every complete response.
private func parseStream(_ data: Data, chunk: Int, maxLiteral: Int = 1 << 20) throws -> [IMAPResponse] {
    var framer = IMAPFramer(maxLiteral: maxLiteral)
    var out: [IMAPResponse] = []
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        let end = min(bytes.count, i + chunk)
        framer.append(Array(bytes[i..<end]))
        i = end
        while let raw = try framer.next() { out.append(try IMAPResponseParser.parse(raw)) }
    }
    #expect(framer.bufferedBytes == 0)
    return out
}

private func parseOne(_ s: String) throws -> IMAPResponse {
    var framer = IMAPFramer()
    framer.append(Data(s.utf8))
    let raw = try #require(try framer.next())
    return try IMAPResponseParser.parse(raw)
}

@Suite struct MailTransportIMAPParserTests {

    // MARK: Recorded transcripts

    @Test func gmailTranscript() throws {
        let data = try transportFixture("gmail-transcript", "imap")
        let rs = try parseStream(data, chunk: 4096)
        #expect(rs.count == 24)
        guard rs.count == 24 else { return }

        #expect(rs[0] == .status(.ok, code: nil, text: "Gimap ready for requests from 203.0.113.7 a1mb12345abc.12"))
        guard case .capability(let caps) = rs[1] else { Issue.record("capability"); return }
        #expect(caps.contains("IMAP4rev1") && caps.contains("AUTH=PLAIN") && caps.contains("X-GM-EXT-1"))
        #expect(rs[4] == .tagged(tag: "A002", status: .ok, code: nil, text: "me@gmail.com authenticated (Success)"))
        guard case .flags(let flags) = rs[5] else { Issue.record("flags"); return }
        #expect(flags.contains("\\Seen") && flags.contains("$Phishing"))
        #expect(rs[6] == .status(.ok, code: IMAPResponseCode(name: "PERMANENTFLAGS", arguments: "()"), text: "Flags permitted."))
        #expect(rs[7] == .status(.ok, code: IMAPResponseCode(name: "UIDVALIDITY", arguments: "1"), text: "UIDs valid."))
        #expect(rs[8] == .exists(5321))
        #expect(rs[9] == .recent(0))
        guard case .status(.ok, let next?, _) = rs[10] else { Issue.record("uidnext"); return }
        #expect(next.name == "UIDNEXT" && next.number == 90210)
        #expect(rs[11] == .status(.ok, code: IMAPResponseCode(name: "HIGHESTMODSEQ", arguments: "4412345"), text: ""))
        #expect(rs[12] == .tagged(tag: "A003", status: .ok, code: IMAPResponseCode(name: "READ-ONLY"),
                                  text: "INBOX selected. (Success)"))
        #expect(rs[13] == .search([90001, 90005]))

        guard case .fetch(let f1) = rs[15], case .fetch(let f2) = rs[16], case .fetch(let body) = rs[18] else {
            Issue.record("fetch responses"); return
        }
        let alert = try transportFixture("alert-biorxiv", "eml")
        let advisor = try transportFixture("advisor-request", "eml")
        #expect(f1.sequence == 5301 && f1.uid == 90001 && f1.size == alert.count)
        #expect(f1.internalDate == Date(timeIntervalSince1970: 1_790_690_700))      // 2026-09-29 14:05:00Z
        let h1 = try #require(f1.headerFields)
        #expect(String(decoding: h1, as: UTF8.self).hasPrefix("Authentication-Results: mx.google.com;"))
        #expect(String(decoding: h1, as: UTF8.self).hasSuffix("\r\n\r\n"))
        #expect(f1.body == nil)
        // Space-padded day and a negative zone: " 1-Oct-2026 09:30:12 -0500" = 14:30:12Z.
        #expect(f2.uid == 90005 && f2.internalDate == Date(timeIntervalSince1970: 1_790_865_012))
        #expect(body.uid == 90005 && body.body == advisor)

        let parsed = try MIMEParser.parseHeaders(h1)
        #expect(parsed.fromAddress == "alerts@biorxiv.org")
        #expect(parsed.subject == "New results in Neuroscience")

        #expect(rs[20] == .tagged(tag: "A007", status: .no, code: IMAPResponseCode(name: "AUTHENTICATIONFAILED"),
                                  text: "Invalid credentials (Failure)"))
        guard case .tagged("A008", .no, let alertCode?, let alertText) = rs[21] else { Issue.record("A008"); return }
        #expect(alertCode.name == "ALERT" && alertText.hasPrefix("Application-specific password required"))
        #expect(rs[22] == .status(.bye, code: nil, text: "LOGOUT Requested"))
        #expect(rs[23] == .tagged(tag: "A009", status: .ok, code: nil, text: "73 good day (Success)"))
    }

    @Test func dovecotTranscript() throws {
        let data = try transportFixture("dovecot-transcript", "imap")
        let rs = try parseStream(data, chunk: 4096)
        #expect(rs.count == 22)
        guard rs.count == 22 else { return }

        guard case .status(.ok, let greetCode?, "Dovecot ready.") = rs[0] else { Issue.record("greeting"); return }
        #expect(greetCode.name == "CAPABILITY" && greetCode.arguments.contains("LITERAL+"))
        guard case .tagged("a1", .ok, let loginCode?, "Logged in") = rs[1] else { Issue.record("login"); return }
        #expect(loginCode.name == "CAPABILITY" && loginCode.arguments.contains("UIDPLUS"))
        #expect(rs[6] == .status(.ok, code: IMAPResponseCode(name: "UIDVALIDITY", arguments: "1601234567"), text: "UIDs valid"))
        #expect(rs[8] == .tagged(tag: "a2", status: .ok, code: IMAPResponseCode(name: "READ-ONLY"),
                                 text: "Examine completed (0.001 + 0.000 secs)."))
        #expect(rs[9] == .search([40, 41, 42]))

        guard case .fetch(let f1) = rs[11], case .fetch(let f2) = rs[12], case .fetch(let f3) = rs[13] else {
            Issue.record("fetch responses"); return
        }
        #expect(f1.uid == 40 && f1.internalDate == Date(timeIntervalSince1970: 1_790_748_001))   // 06:00:01Z
        // Multi-literal FETCH with FLAGS / MODSEQ between the sections.
        let advisor = try transportFixture("advisor-request", "eml")
        #expect(f2.uid == 41 && f2.flags == ["\\Seen"] && f2.size == advisor.count)
        #expect(Set(f2.sections.keys) == ["HEADER.FIELDS (FROM SUBJECT)", "TEXT"])
        let text = try #require(f2.sections["TEXT"])
        #expect(String(decoding: text, as: UTF8.self).hasSuffix(")\r\nThanks, X\r\n"))
        #expect(String(decoding: try #require(f2.headerFields), as: UTF8.self).hasPrefix("From: \"Prof. X\""))
        // Unsolicited flag update: no UID, no sections.
        #expect(f3.sequence == 3 && f3.uid == nil && f3.flags == ["\\Seen", "\\Flagged"] && f3.sections.isEmpty)
        #expect(rs[14] == .expunge(42))
        guard case .other("ID", let idValues) = rs[15] else { Issue.record("ID"); return }
        #expect(idValues.first?.list?.first == .quoted("name"))
        #expect(rs[17] == .tagged(tag: "a5", status: .no, code: IMAPResponseCode(name: "AUTHENTICATIONFAILED"),
                                  text: "Authentication failed."))
        #expect(rs[18] == .tagged(tag: "a6", status: .bad, code: nil,
                                  text: "Error in IMAP command UID FETCH: Invalid uidset"))
        #expect(rs[19] == .continuation("OK"))
        #expect(rs[20] == .status(.bye, code: nil, text: "Logging out"))
    }

    @Test(arguments: [1, 2, 3, 7, 64, 333])
    func framingIndependentOfChunkBoundaries(chunk: Int) throws {
        for name in ["gmail-transcript", "dovecot-transcript"] {
            let data = try transportFixture(name, "imap")
            #expect(try parseStream(data, chunk: chunk) == parseStream(data, chunk: data.count))
        }
    }

    // MARK: Framing

    @Test func literalBytesAreNotScannedForMarkersOrLineEnds() throws {
        let payload = "line one {5}\r\n)\r\n* 9 EXISTS\r\n"
        let wire = "* 1 FETCH (UID 7 BODY[] {\(payload.utf8.count)}\r\n\(payload))\r\nA1 OK done\r\n"
        let rs = try parseStream(Data(wire.utf8), chunk: 5)
        #expect(rs.count == 2)
        guard case .fetch(let f) = rs.first else { Issue.record("fetch"); return }
        #expect(f.uid == 7 && f.body == Data(payload.utf8))
        #expect(rs.last == .tagged(tag: "A1", status: .ok, code: nil, text: "done"))
    }

    @Test func incompleteLiteralWaitsForMoreBytes() throws {
        var framer = IMAPFramer()
        framer.append(Data("* 1 FETCH (UID 3 BODY[]<0> {10}\r\n01234".utf8))
        #expect(try framer.next() == nil)
        framer.append(Data("56789)\r\n".utf8))
        let raw = try #require(try framer.next())
        guard case .fetch(let f) = try IMAPResponseParser.parse(raw) else { Issue.record("fetch"); return }
        #expect(f.body == Data("0123456789".utf8))
        #expect(try framer.next() == nil)
    }

    @Test func oversizedLiteralIsRejectedBeforeBuffering() {
        var framer = IMAPFramer(maxLiteral: 100)
        framer.append(Data("* 1 FETCH (UID 3 BODY[] {5000000}\r\n".utf8))
        #expect(throws: IMAPParseError.literalTooLarge(5_000_000)) { _ = try framer.next() }
    }

    @Test func oversizedLiteralCanBeDiscardedWithoutLosingTheStream() throws {
        var framer = IMAPFramer(maxLiteral: 8)
        framer.discardOversizedLiterals = true
        let big = String(repeating: "H", count: 5000)
        let wire = "* 1 FETCH (UID 3 BODY[HEADER] {5000}\r\n\(big))\r\n* 2 FETCH (UID 4 BODY[HEADER] {4}\r\nA: b)\r\nA1 OK\r\n"
        var out: [IMAPResponse] = []
        for chunk in Array(wire.utf8).chunked(97) {
            framer.append(chunk)
            while let raw = try framer.next() { out.append(try IMAPResponseParser.parse(raw)) }
        }
        #expect(framer.discardedLiterals == 1)
        #expect(framer.bufferedBytes == 0)
        guard out.count == 3, case .fetch(let dropped) = out[0], case .fetch(let kept) = out[1] else {
            Issue.record("responses \(out.count)"); return
        }
        #expect(dropped.uid == 3 && dropped.headerFields == Data())
        #expect(kept.uid == 4 && kept.headerFields == Data("A: b".utf8))
    }

    @Test func overlongLineIsRejected() {
        var framer = IMAPFramer(maxLiteral: 100, maxLine: 64)
        framer.append(Data(String(repeating: "x", count: 100).utf8))
        #expect(throws: IMAPParseError.lineTooLong) { _ = try framer.next() }
    }

    @Test func bareLineFeedsAreTolerated() throws {
        let rs = try parseStream(Data("* 4 EXISTS\nA1 OK fine\n".utf8), chunk: 3)
        #expect(rs == [.exists(4), .tagged(tag: "A1", status: .ok, code: nil, text: "fine")])
    }

    @Test func literal8MarkerIsAccepted() throws {
        let r = try parseOne("* 2 FETCH (UID 9 BINARY[] ~{3}\r\nabc)\r\n")
        guard case .fetch(let f) = r else { Issue.record("fetch"); return }
        #expect(f.body == Data("abc".utf8))
    }

    // MARK: Parsing details

    @Test func statusResponsesAndCodes() throws {
        #expect(try parseOne("A12 BAD [PARSE] Missing ) (0.001 secs)\r\n")
                == .tagged(tag: "A12", status: .bad, code: IMAPResponseCode(name: "PARSE"), text: "Missing ) (0.001 secs)"))
        // Unbalanced quote in resp-text must not break parsing (text is not tokenized).
        #expect(try parseOne("A13 NO Mailbox doesn't exist: \"Paper\r\n")
                == .tagged(tag: "A13", status: .no, code: nil, text: "Mailbox doesn't exist: \"Paper"))
        #expect(try parseOne("* PREAUTH [CAPABILITY IMAP4rev1] ready\r\n")
                == .status(.preauth, code: IMAPResponseCode(name: "CAPABILITY", arguments: "IMAP4rev1"), text: "ready"))
        #expect(try parseOne("+\r\n") == .continuation(""))
        #expect(try parseOne("* SEARCH\r\n") == .search([]))
        #expect(try parseOne("* SEARCH 5 9 (MODSEQ 917162500)\r\n") == .search([5, 9]))
        #expect(throws: IMAPParseError.self) { _ = try parseOne("A14 MAYBE whatever\r\n") }
        #expect(throws: IMAPParseError.self) { _ = try parseOne("* 3 FETCH (UID 4 BODY[] \"unterminated\r\n") }
    }

    @Test func fetchWithQuotedAndNilSections() throws {
        let r = try parseOne("* 5 FETCH (UID 11 RFC822.SIZE 42 BODY[HEADER.FIELDS (FROM)] \"From: a@b.c\" BODY[] NIL X-GM-THRID 1234)\r\n")
        guard case .fetch(let f) = r else { Issue.record("fetch"); return }
        #expect(f.uid == 11 && f.size == 42)
        #expect(f.headerFields == Data("From: a@b.c".utf8))
        #expect(f.body == nil)
    }

    @Test func internalDates() {
        #expect(IMAPResponseParser.parseInternalDate("17-Jul-1996 02:44:25 -0700") == Date(timeIntervalSince1970: 837_596_665))
        #expect(IMAPResponseParser.parseInternalDate(" 1-Oct-2026 00:00:00 +0000") == Date(timeIntervalSince1970: 1_790_812_800))
        #expect(IMAPResponseParser.parseInternalDate("01-oct-2026 05:30:00 +0530") == Date(timeIntervalSince1970: 1_790_812_800))
        #expect(IMAPResponseParser.parseInternalDate("yesterday") == nil)
        #expect(IMAPResponseParser.parseInternalDate("32-Foo-2026 00:00:00 +0000") == nil)
    }

    @Test func searchDateFormat() {
        #expect(IMAPResponseParser.searchDate(Date(timeIntervalSince1970: 1_790_812_800)) == "1-Oct-2026")
        #expect(IMAPResponseParser.searchDate(Date(timeIntervalSince1970: 1_789_603_200)) == "17-Sep-2026")
    }

    @Test func quotedStrings() {
        #expect(IMAPResponseParser.quoted("INBOX") == "\"INBOX\"")
        #expect(IMAPResponseParser.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
        #expect(IMAPResponseParser.quoted("abcd efgh ijkl mnop") == "\"abcd efgh ijkl mnop\"")
        #expect(IMAPResponseParser.quoted("pässword") == nil)
        #expect(IMAPResponseParser.quoted("line\r\nbreak") == nil)
    }

    @Test func uidSets() {
        #expect(IMAPResponseParser.uidSet([5, 1, 2, 3, 9, 10, 7, 3]) == "1:3,5,7,9:10")
        #expect(IMAPResponseParser.uidSet([42]) == "42")
        #expect(IMAPResponseParser.uidSet([]) == "")
    }

    @Test func modifiedUTF7MailboxNames() {
        // RFC 3501 §5.1.3 example.
        #expect(IMAPResponseParser.encodeMailboxName("~peter/mail/台北/日本語") == "~peter/mail/&U,BTFw-/&ZeVnLIqe-")
        #expect(IMAPResponseParser.decodeMailboxName("~peter/mail/&U,BTFw-/&ZeVnLIqe-") == "~peter/mail/台北/日本語")
        #expect(IMAPResponseParser.encodeMailboxName("R&D") == "R&-D")
        #expect(IMAPResponseParser.decodeMailboxName("R&-D") == "R&D")
        #expect(IMAPResponseParser.encodeMailboxName("[Gmail]/All Mail") == "[Gmail]/All Mail")
        for name in ["论文/PaperDeck", "Été 📚 papers", "INBOX"] {
            #expect(IMAPResponseParser.decodeMailboxName(IMAPResponseParser.encodeMailboxName(name)) == name)
        }
        #expect(IMAPResponseParser.decodeMailboxName("&Zm9v") == nil)
    }

    @Test func messageRefsParseFromTheRight() {
        let r = IMAPMessageRef("Lists:Neuro:1601234567:42")
        #expect(r == IMAPMessageRef(mailbox: "Lists:Neuro", uidValidity: 1_601_234_567, uid: 42))
        #expect(r?.string == "Lists:Neuro:1601234567:42")
        #expect(IMAPMessageRef("INBOX:x:1") == nil)
        #expect(IMAPMessageRef(":1:2") == nil)
        #expect(IMAPMessageRef("a.eml") == nil)
    }

    @Test func cursorJSONRoundTrip() throws {
        let s = IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 103, since: "17-Sep-2026")
        #expect(s.cursor.value == #"{"lastUID":103,"mailbox":"INBOX","since":"17-Sep-2026","uidvalidity":777,"v":1}"#)
        #expect(IMAPCursorState(s.cursor) == s)
        #expect(IMAPCursorState(MailCursor("not json")) == nil)
        #expect(IMAPCursorState(nil) == nil)
    }

    @Test func traceSummariesNeverContainLiteralBytes() throws {
        let header = "Subject: secret project\r\n\r\n"
        let r = try parseOne("* 1 FETCH (UID 7 BODY[HEADER.FIELDS (SUBJECT)] {\(header.utf8.count)}\r\n\(header))\r\n")
        let line = IMAPClient.summary(r)
        #expect(!line.contains("secret"))
        #expect(line.contains("\(header.utf8.count) literal bytes"))
    }
}

private extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
