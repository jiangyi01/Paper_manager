import Foundation
import Testing
@testable import PaperDeckCore

/// Fixture access for the mail-parse suites (synthetic .eml files under Fixtures/mail/mail-parse).
enum MailParseFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml",
                                                 subdirectory: "Fixtures/mail/mail-parse"))
        return try Data(contentsOf: url)
    }

    static func content(_ name: String, maxAttachmentBytes: Int = 50 << 20) throws -> MailContent {
        try MIMEParser.parse(data(name), maxAttachmentBytes: maxAttachmentBytes)
    }

    static func extraction(_ name: String, kind: SenderKind, bodyCap: Int = 12_000) throws -> (MailContent, MailExtraction) {
        let c = try content(name)
        return (c, MailExtractor.extract(c, senderKind: kind, bodyCap: bodyCap))
    }

    /// Builds a message from LF-separated text with CRLF line endings.
    static func eml(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static let chicago: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }()

    static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    static func header(from: String = "prof@wustl.edu", name: String? = nil, subject: String = "Paper",
                       received: String = "2026-09-29T15:00:00Z") -> MailHeader {
        MailHeader(ref: "", internetMessageID: "<t@x>", fromAddress: from, fromName: name, subject: subject,
                   receivedAt: date(received))
    }
}
