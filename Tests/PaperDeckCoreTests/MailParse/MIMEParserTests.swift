import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · MIMEParser") struct MailParseMIMEParserTests {

    private typealias F = MailParseFixture

    // MARK: Fixtures

    @Test func advisorRequestHeadersAndParts() throws {
        let c = try F.content("advisor-request-pdf")
        #expect(c.header.ref == "")
        #expect(c.header.fromAddress == "jsmith@wustl.edu")
        #expect(c.header.fromName == "Smith, Jane")
        #expect(c.header.subject == "Paper for Thursday's lab meeting")
        #expect(c.header.internetMessageID == "<caf3xyz+abc123@mail.gmail.com>")
        #expect(c.header.receivedAt == F.date("2026-09-29T19:05:00Z"))
        #expect(c.header.hasAttachments == true)
        #expect(MIMEParser.authState(c.header.authResults) == .pass)
        #expect(c.headers["cc"] == "Lab Manager <lab.manager@wustl.edu>")
        #expect(c.plainText?.contains("Please read the attached paper before Thursday's lab meeting and be ready to present Fig. 2.") == true)
        #expect(c.plainText?.contains("\r") == false)
        #expect(c.html?.contains("<a href=\"https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2") == true)
        #expect(c.attachments.count == 1)
        let pdf = try #require(c.attachments.first)
        #expect(pdf.filename == "Smith2026_neocortex.pdf")
        #expect(pdf.contentType == "application/pdf")
        #expect(!pdf.isInline && pdf.looksLikePDF)
        #expect(pdf.data.map { String(decoding: $0.prefix(5), as: UTF8.self) } == "%PDF-")
        #expect(pdf.sizeBytes == pdf.data?.count)
    }

    @Test func parseHeadersReadsOnlyTheHeaderBlock() throws {
        let data = try F.data("advisor-request-pdf")
        let h = try MIMEParser.parseHeaders(data)
        let full = try MIMEParser.parse(data, maxAttachmentBytes: 1 << 20).header
        #expect(h.internetMessageID == full.internetMessageID)
        #expect(h.fromAddress == full.fromAddress && h.subject == full.subject && h.receivedAt == full.receivedAt)
        #expect(h.hasAttachments == true)                 // multipart/mixed

        // Header-like lines in the body are never read as headers.
        let spoof = F.eml("""
        From: Real Sender <real@wustl.edu>
        Subject: Real subject
        Date: Tue, 29 Sep 2026 10:00:00 -0500

        From: Prof X <prof.x@wustl.edu>
        Subject: fake
        Message-ID: <fake@evil>
        """)
        let s = try MIMEParser.parseHeaders(spoof)
        #expect(s.fromAddress == "real@wustl.edu")
        #expect(s.subject == "Real subject")
        #expect(s.internetMessageID?.hasSuffix("@paperdeck.invalid>") == true)
        #expect(s.hasAttachments == false)
    }

    @Test func gb2312AdvisorMail() throws {
        let c = try F.content("advisor-zh-gb2312")
        #expect(c.header.subject == "请在周五前读一下这篇 bioRxiv 文章")      // two B-words split mid-character
        #expect(c.header.fromName == "王老师")
        #expect(c.headers["to"] == "小易 <yi.jiang@wustl.edu>")
        #expect(c.plainText?.contains("请在周五前读一下这篇文章，下周组会我们讨论。") == true)
        #expect(c.plainText?.contains("https://www.biorxiv.org/content/10.64898/2026.09.20.612399v1") == true)
        #expect(c.header.receivedAt == F.date("2026-09-29T02:30:00Z"))
    }

    @Test func rfc2231Filenames() throws {
        let c = try F.content("rfc2231-filename")
        #expect(c.attachments.map(\.filename) == ["单细胞空间组学.pdf", "神经元图谱.pdf", "综述：空间转录组.pdf"])
        #expect(c.attachments.allSatisfy { $0.looksLikePDF && !$0.isInline })
        #expect(c.header.subject == "参考文献")
        #expect(c.header.fromName == "Li Na")
        #expect(c.header.receivedAt == F.date("2026-09-29T08:00:00Z"))   // "29 Sep 26 16:00 +0800"
        #expect(c.plainText == "附件是三篇参考文献，有空看看。\n")
    }

    @Test func alternativeWithInlineImage() throws {
        let c = try F.content("alternative-inline-image")
        #expect(c.plainText?.hasPrefix("Weekly update: the new confocal") == true)
        #expect(c.html?.contains("cid:logo123@wustl") == true)
        #expect(c.attachments.count == 1)
        #expect(c.attachments[0].isInline)
        #expect(c.attachments[0].contentType == "image/png")
        #expect(c.attachments[0].data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(c.header.hasAttachments == false)
    }

    @Test func forwardedMessageAttachmentIsFlattened() throws {
        let c = try F.content("rfc822-attachment")
        let text = try #require(c.plainText)
        #expect(text.hasPrefix("Forwarding this - see the attached message."))
        #expect(text.contains("---------- Forwarded message ---------"))
        #expect(text.contains("Subject: Preprint for our meeting"))
        #expect(text.contains("Please read the attached preprint before our meeting next Tuesday."))
        #expect(c.html == nil)
        #expect(c.attachments.map(\.filename) == ["preprint.pdf"])
        try #require(c.attachments.count > 0)          // no index past a failed expectation (QA-15)
        #expect(c.attachments[0].looksLikePDF && !c.attachments[0].isInline)
        #expect(c.header.subject == "FW: Preprint for our meeting")
        #expect(c.header.internetMessageID == "<outer-001@wustl.edu>")
    }

    @Test func htmlOnlyQuotedPrintable() throws {
        let c = try F.content("scholar-alert")
        #expect(c.plainText == nil)
        let html = try #require(c.html)
        #expect(html.contains("class=\"gse_alrt_title\""))
        #expect(html.contains("&amp;hl=en"))
        #expect(!html.contains("=\r\n") && !html.contains("=\n"))
    }

    // MARK: Encoded words and charsets

    @Test func encodedWords() {
        #expect(MIMEParser.decodeEncodedWords("=?UTF-8?Q?Caf=C3=A9_au_lait?=") == "Café au lait")
        #expect(MIMEParser.decodeEncodedWords("=?utf-8?B?5Y+C6ICD?= =?utf-8?B?5paH54yu?=") == "参考文献")
        #expect(MIMEParser.decodeEncodedWords("Re: =?utf-8?q?hello?= world") == "Re: hello world")
        #expect(MIMEParser.decodeEncodedWords("=?utf-8?q?a?= b =?utf-8?q?c?=") == "a b c")
        #expect(MIMEParser.decodeEncodedWords("=?utf-8*en?Q?English?=") == "English")
        #expect(MIMEParser.decodeEncodedWords("=?big5?B?vdek5b5cxao=?=") == "論文閱讀")
        #expect(MIMEParser.decodeEncodedWords("=?iso-8859-1?Q?Caf=E9?=") == "Café")
        #expect(MIMEParser.decodeEncodedWords("=?windows-1252?Q?=93Hi=94?=") == "“Hi”")
        #expect(MIMEParser.decodeEncodedWords("plain =?bogus") == "plain =?bogus")
    }

    @Test func charsetFallbacks() {
        // A GBK-only character (镕) labelled gb2312 still decodes (GB18030 superset).
        let gbk = Data([0xD6, 0xEC, 0xE9, 0x46, 0xBB, 0xF9])
        #expect(MIMEParser.decode(gbk, charset: "gb2312") == "朱镕基")
        #expect(MIMEParser.decode(Data([0x43, 0x61, 0x66, 0xE9]), charset: "iso-8859-1") == "Café")
        #expect(MIMEParser.decode(Data("naïve".utf8), charset: "us-ascii") == "naïve")      // mislabeled UTF-8
        #expect(MIMEParser.decode(Data([0x43, 0x61, 0x66, 0xE9]), charset: nil) == "Café")  // not UTF-8 → cp1252
        #expect(MIMEParser.decode(Data("ok".utf8), charset: "x-made-up-charset") == "ok")
        #expect(MIMEParser.decode(Data([0xBD, 0xD7, 0xA4, 0xE5]), charset: "big5") == "論文")
        #expect(MIMEParser.encoding(forCharset: "cp1251") != nil)
        #expect(MIMEParser.encoding(forCharset: "windows-1250") != nil)
        #expect(MIMEParser.encoding(forCharset: "iso-8859-2") != nil)
    }

    @Test func parameters() {
        let p = MIMEParser.parseParameters(#"attachment; filename="a;b \"q\".pdf"; size=12"#)
        #expect(p.value == "attachment")
        #expect(p.params["filename"] == #"a;b "q".pdf"#)
        #expect(p.params["size"] == "12")

        let c = MIMEParser.parseParameters("attachment; filename=fallback.pdf; filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf")
        #expect(c.params["filename"] == "中文.pdf")                               // extended beats plain
        let cont = MIMEParser.parseParameters("inline; name*0*=utf-8'en'%E7%A5%9E; name*1=\"-part\"; name*2*=%E7%BB%8F.pdf")
        #expect(cont.params["name"] == "神-part经.pdf")
        let ct = MIMEParser.parseParameters("Multipart/Mixed; BOUNDARY=\"b1\"")
        #expect(ct.value.lowercased() == "multipart/mixed" && ct.params["boundary"] == "b1")
    }

    // MARK: Transfer encodings

    @Test func transferEncodings() {
        #expect(MIMEParser.decodeBase64(Data("aGVs\r\nbG8g\n d29y bGQ=".utf8)) == Data("hello world".utf8))
        #expect(MIMEParser.decodeBase64(Data("aGVsbG8".utf8)) == Data("hello".utf8))      // missing padding
        #expect(MIMEParser.decodeQuotedPrintable(Data("a=3Db soft=\r\nbreak=\nx =ZZ end=".utf8)) == Data("a=b softbreakx =ZZ end".utf8))
        #expect(MIMEParser.decodeQuotedPrintable(Data("caf=C3=A9".utf8)) == Data("café".utf8))
    }

    // MARK: Dates

    @Test(arguments: [
        ("Tue, 29 Sep 2026 14:05:00 -0500", "2026-09-29T19:05:00Z"),
        ("29 Sep 2026 14:05 -0500", "2026-09-29T19:05:00Z"),
        ("Tue, 29 Sep 26 14:05:00 GMT", "2026-09-29T14:05:00Z"),
        ("Tue, 29 Sep 2026 14:05:00 -0500 (CDT)", "2026-09-29T19:05:00Z"),
        ("Tue, 29 Sep 2026 14:05:00 PDT", "2026-09-29T21:05:00Z"),
        ("Tuesday, September 29, 2026 2:05 PM +0000", "2026-09-29T14:05:00Z"),
        ("29-Sep-2026 14:05:00 +0800", "2026-09-29T06:05:00Z"),
        ("Tue Sep 29 14:05:00 2026", "2026-09-29T14:05:00Z"),
        ("2026-09-29T14:05:00Z", "2026-09-29T14:05:00Z"),
        ("2026-09-29 14:05:00 +0000", "2026-09-29T14:05:00Z"),
        ("Tue,  1 Sep 2026 09:00:00 +0530", "2026-09-01T03:30:00Z"),
    ])
    func dates(raw: String, iso: String) {
        #expect(MIMEParser.parseDate(raw) == F.date(iso))
    }

    @Test func invalidDates() {
        #expect(MIMEParser.parseDate("") == nil)
        #expect(MIMEParser.parseDate("not a date") == nil)
        #expect(MIMEParser.parseDate("31 Feb 2026 10:00 +0000") == nil)
    }

    @Test func receivedHeaderBeatsAWildDateHeader() throws {
        let c = try MIMEParser.parse(F.eml("""
        Received: from mx.example.org by mail.wustl.edu; Tue, 29 Sep 2026 10:00:00 -0500
        From: a@b.org
        Date: Fri, 01 Jan 2038 00:00:00 +0000
        Subject: x

        body
        """), maxAttachmentBytes: 0)
        #expect(c.header.receivedAt == F.date("2026-09-29T15:00:00Z"))
    }

    // MARK: Addresses

    @Test func addresses() {
        func a(_ s: String) -> String? { MIMEParser.parseAddress(s)?.address }
        func n(_ s: String) -> String? { MIMEParser.parseAddress(s)?.name }
        #expect(a(#""Smith, Jane" <JSmith@WUSTL.edu>"#) == "jsmith@wustl.edu")
        #expect(n(#""Smith, Jane" <JSmith@WUSTL.edu>"#) == "Smith, Jane")
        #expect(a("jsmith@wustl.edu (Jane Smith)") == "jsmith@wustl.edu")
        #expect(n("jsmith@wustl.edu (Jane Smith)") == "Jane Smith")
        #expect(n("=?utf-8?B?546L6ICB5biI?= <w@x.org>") == "王老师")
        #expect(n(#""=?utf-8?Q?Ren=C3=A9?=" <r@x.org>"#) == "René")
        #expect(a("Prof X prof.x@wustl.edu") == "prof.x@wustl.edu")
        #expect(n("Prof X prof.x@wustl.edu") == "Prof X")
        #expect(a("<@relay.org:user@x.org>") == "user@x.org")
        #expect(a(#""john doe"@example.org"#) == "john doe@example.org")
        #expect(MIMEParser.parseAddressList("Lab: a@x.org, b@y.org;, c@z.org").map(\.address) == ["a@x.org", "b@y.org", "c@z.org"])
        #expect(MIMEParser.parseAddressList("undisclosed-recipients:;").isEmpty)
        // A display name that looks like an address never becomes the address.
        #expect(a(#""prof.x@wustl.edu" <attacker@evil.com>"#) == "attacker@evil.com")
        #expect(n(#""prof.x@wustl.edu" <attacker@evil.com>"#) == "prof.x@wustl.edu")
    }

    // MARK: Message-ID

    @Test func messageIDs() {
        #expect(MIMEParser.normalizeMessageID("<ABC.123@Mail.Example.COM>") == "<abc.123@mail.example.com>")
        #expect(MIMEParser.normalizeMessageID("  <a@b> (comment)") == "<a@b>")
        #expect(MIMEParser.normalizeMessageID("bare-id@host") == "<bare-id@host>")
        #expect(MIMEParser.normalizeMessageID("<ab\r\n cd@x>") == "<abcd@x>")
        #expect(MIMEParser.normalizeMessageID("") == nil)
        #expect(MIMEParser.normalizeMessageID(nil) == nil)
        let a = MIMEParser.fallbackMessageID(from: "a@b.org", date: "Tue, 29 Sep 2026", subject: "Hi")
        #expect(a == MIMEParser.fallbackMessageID(from: "A@B.org", date: " Tue, 29 Sep 2026", subject: "Hi"))
        #expect(a != MIMEParser.fallbackMessageID(from: "a@b.org", date: "Tue, 29 Sep 2026", subject: "Hi!"))
        #expect(a.hasPrefix("<") && a.hasSuffix("@paperdeck.invalid>") && a.count == 64 + 20)
    }

    // MARK: Structure and limits

    @Test func hugeAttachmentsKeepOnlyTheirSize() throws {
        let payload = Data(repeating: 0x41, count: 3 << 20)
        let b64 = payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let raw = F.eml("""
        From: a@b.org
        Subject: big
        Content-Type: multipart/mixed; boundary=X

        --X
        Content-Type: text/plain

        see attached
        --X
        Content-Type: application/pdf; name=big.pdf
        Content-Transfer-Encoding: base64

        \(b64)
        --X--
        """)
        let capped = try MIMEParser.parse(raw, maxAttachmentBytes: 1 << 20)
        #expect(capped.attachments.count == 1)
        #expect(capped.attachments[0].data == nil)
        #expect(capped.attachments[0].sizeBytes == 3 << 20)
        #expect(capped.plainText == "see attached")
        let full = try MIMEParser.parse(raw, maxAttachmentBytes: 10 << 20)
        #expect(full.attachments[0].data == payload)
    }

    @Test func deepNestingIsBounded() throws {
        var body = "leaf text"
        var ct = "text/plain"
        for i in 0..<60 {
            body = "--b\(i)\r\nContent-Type: \(ct)\r\n\r\n\(body)\r\n--b\(i)--"
            ct = "multipart/mixed; boundary=b\(i)"
        }
        let raw = Data("From: a@b.org\r\nContent-Type: \(ct)\r\n\r\n\(body)\r\n".utf8)
        let c = try MIMEParser.parse(raw, maxAttachmentBytes: 1 << 20)
        #expect(c.plainText == nil)                 // below maxDepth nothing is read, and nothing crashes
        #expect(c.header.fromAddress == "a@b.org")
    }

    @Test func formatFlowedAndLFOnlyInput() throws {
        let raw = Data("""
        From: a@b.org
        Subject: flowed
        Content-Type: text/plain; charset=utf-8; format=flowed

        This line is soft\u{20}
        wrapped here.
         >not a quote
        --\u{20}
        sig
        """.utf8)                                   // LF line endings on purpose
        let c = try MIMEParser.parse(raw, maxAttachmentBytes: 0)
        #expect(c.plainText?.hasPrefix("This line is soft wrapped here.\n>not a quote") == true)
        #expect(c.header.subject == "flowed")
    }

    @Test func mboxSeparatorAndMissingContentType() throws {
        let c = try MIMEParser.parse(F.eml("""
        From sender@example.org Tue Sep 29 10:00:00 2026
        From: sender@example.org
        Subject: plain

        just text
        """), maxAttachmentBytes: 0)
        #expect(c.header.fromAddress == "sender@example.org")
        #expect(c.plainText == "just text")
    }

    @Test func rejectsNonMessages() {
        #expect(throws: MIMEParser.ParseError.empty) { try MIMEParser.parse(Data(), maxAttachmentBytes: 0) }
        #expect(throws: MIMEParser.ParseError.notAMessage) { try MIMEParser.parse(Data("hello world".utf8), maxAttachmentBytes: 0) }
        #expect(throws: MIMEParser.ParseError.empty) { try MIMEParser.parseHeaders(Data()) }
    }

    @Test func authenticationResults() {
        #expect(MIMEParser.authState("mx; dkim=pass; spf=pass; dmarc=pass header.from=x") == .pass)
        #expect(MIMEParser.authState("mx; dkim=pass; dmarc=fail") == .fail)
        #expect(MIMEParser.authState("spf=fail smtp.mailfrom=x; dkim=none") == .fail)
        #expect(MIMEParser.authState("dkim=none; dmarc=none action=none; compauth=pass reason=109") == .pass)
        #expect(MIMEParser.authState(nil) == .unknown)
        #expect(MIMEParser.authState("mx.example.org; none") == .unknown)
    }

    @Test func filenamesAreSanitized() {
        #expect(MIMEParser.sanitizeFilename("../../etc/passwd.pdf") == "passwd.pdf")
        #expect(MIMEParser.sanitizeFilename("C:\\Users\\x\\paper.pdf") == "paper.pdf")
        #expect(MIMEParser.sanitizeFilename("..hidden.pdf") == "hidden.pdf")
        #expect(MIMEParser.sanitizeFilename("a\u{0}b\u{202E}fdp.exe") == "abfdp.exe")
        #expect(MIMEParser.sanitizeFilename("   ") == nil)
    }
}
