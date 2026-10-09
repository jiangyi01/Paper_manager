import AppKit
import Compression
import Foundation
import PDFKit
import Testing
@testable import PaperDeckCore

/// Synthetic documents and emails for the MailDocuments suites — all generated in memory:
/// Word / RTF / ODT / .doc files written by NSAttributedString, signature-only slide decks and
/// password-protected packages, and RFC 822 messages with base64 attachments and Outlook Safe
/// Links. Nothing here reads the user's mail, library or any network.
enum DocKit {
    static let manuscriptTitle = "Cortical Progenitor Dynamics In Organoids"
    static let lastLine = "End of the synthetic manuscript."

    /// A manuscript: a large bold title, `paragraphs` body paragraphs, a closing line.
    static func attributed(title: String = manuscriptTitle, paragraphs: Int = 40) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 22)]))
        s.append(NSAttributedString(string: "Ada Lovelace, Grace Hopper\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        for i in 0..<paragraphs {
            s.append(NSAttributedString(string: "Paragraph \(i + 1). Radial glia divide asymmetrically and give rise to cortical neurons across development.\n",
                                        attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        }
        s.append(NSAttributedString(string: lastLine + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        return s
    }

    static func write(_ s: NSAttributedString, _ type: NSAttributedString.DocumentType) throws -> Data {
        try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: type])
    }

    static func docx(title: String = manuscriptTitle, paragraphs: Int = 40) throws -> Data {
        try write(attributed(title: title, paragraphs: paragraphs), .officeOpenXML)
    }
    static func rtf(paragraphs: Int = 10) throws -> Data { try write(attributed(paragraphs: paragraphs), .rtf) }
    static func odt(paragraphs: Int = 10) throws -> Data { try write(attributed(paragraphs: paragraphs), .openDocument) }
    static func doc(paragraphs: Int = 10) throws -> Data { try write(attributed(paragraphs: paragraphs), .docFormat) }

    /// A file that only has a zip package's signature and end record (stands in for .pptx / .key).
    static func zipStub(_ tag: String = UUID().uuidString) -> Data {
        var d = Data([0x50, 0x4B, 0x03, 0x04])
        d.append(Data("slides \(tag)".utf8))
        d.append(Data([0x50, 0x4B, 0x05, 0x06]))
        d.append(Data(repeating: 0, count: 18))
        return d
    }

    /// Office's password-protected package: an OLE2 compound file under a .docx name.
    static func encryptedDocx() -> Data {
        var d = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        d.append(Data(repeating: 0, count: 1024))
        return d
    }

    /// A minimal OLE2 file whose directory names a "WordDocument" stream starting with a FIB
    /// (wIdent 0xA5EC) whose flags word has `fEncrypted` set or not.
    static func wordBinary(encrypted: Bool) -> Data {
        var b = [UInt8](repeating: 0, count: 512 * 3)
        b.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        b[0x1E] = 9                                           // 512-byte sectors
        // first directory sector = 0 (at 0x30, already 0)
        let dir = 512                                          // sector 0
        let entry = dir + 128                                  // second entry
        for (i, u) in Array("WordDocument".utf16).enumerated() {
            b[entry + i * 2] = UInt8(u & 0xFF); b[entry + i * 2 + 1] = UInt8(u >> 8)
        }
        b[entry + 0x40] = 26                                   // name length incl. terminator
        b[entry + 0x74] = 1                                    // start sector 1
        let fib = 1024                                         // (1 + 1) * 512
        b[fib] = 0xEC; b[fib + 1] = 0xA5
        b[fib + 0x0B] = encrypted ? 0x01 : 0x00                // flags word at 0x0A: bit 0x0100
        return Data(b)
    }

    // MARK: Emails

    static func safeLink(_ target: String) -> String {
        let enc = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
        return "https://nam10.safelinks.protection.outlook.com/?url=\(enc)&data=05%7C02%7Cyi%40wustl.edu%7Cabc&sdata=xyz%3D&reserved=0"
    }

    static let sharepointLinks = [
        "https://gowustl-my.sharepoint.com/:w:/g/personal/jsmith_wustl_edu/EaBc111?e=AbC1",
        "https://gowustl-my.sharepoint.com/:w:/g/personal/jsmith_wustl_edu/EaBc222?e=AbC2",
        "https://gowustl-my.sharepoint.com/:b:/g/personal/jsmith_wustl_edu/EaBc333?e=AbC3",
        "https://gowustl-my.sharepoint.com/:f:/g/personal/jsmith_wustl_edu/EaBc444?e=AbC4",
    ]

    struct Attachment {
        var name: String
        var type: String
        var data: Data
        var inline: Bool = false
    }

    /// A multipart/mixed message: an HTML body (with `links` as Safe-Links-wrapped anchors) and
    /// base64 attachments.
    static func eml(from: String = "jsmith@wustl.edu", fromName: String = "Prof. Smith",
                    subject: String = "Lab manuscript draft", messageID: String = "<doc-\(UUID().uuidString)@wustl.edu>",
                    body: String = "Hi Yi,<br>Here is the latest draft of our manuscript and the figure files. Comments welcome.",
                    links: [String] = [], attachments: [Attachment] = [], listID: Bool = false,
                    date: String = "Tue, 29 Sep 2026 09:00:00 -0500") -> Data {
        let boundary = "b-\(UUID().uuidString)"
        var html = "<html><body><p>\(body)</p>"
        for (i, l) in links.enumerated() {
            html += "<p><a href=\"\(safeLink(l))\">Draft part \(i + 1)</a></p>"
        }
        html += "<p>Best,<br>J. Smith</p></body></html>"
        var s = """
        From: \(fromName) <\(from)>
        To: Yi <yi@wustl.edu>
        Subject: \(subject)
        Date: \(date)
        Message-ID: \(messageID)
        MIME-Version: 1.0

        """
        if listID { s += "List-Id: <alerts.example.org>\n" }
        s += """
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 8bit

        \(html)

        """
        for a in attachments {
            let b64 = a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            s += """
            --\(boundary)
            Content-Type: \(a.type); name="\(a.name)"
            Content-Disposition: \(a.inline ? "inline" : "attachment"); filename="\(a.name)"
            Content-Transfer-Encoding: base64

            \(b64)

            """
        }
        s += "--\(boundary)--\n"
        return Data(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static let docxType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    static let pptxType = "application/vnd.openxmlformats-officedocument.presentationml.presentation"

    /// The user's real case, synthesized: an advisor's manuscript as a Word file plus four
    /// SharePoint links wrapped by Outlook Safe Links, no request phrase.
    static func advisorManuscriptEML(messageID: String = "<manuscript-\(UUID().uuidString)@wustl.edu>",
                                     docx: Data? = nil) throws -> Data {
        eml(messageID: messageID, links: sharepointLinks,
            attachments: [Attachment(name: "Smith_lab_manuscript_v3.docx", type: docxType, data: try docx ?? DocKit.docx())])
    }
}

/// PDF text via PDFKit (the converter's output is checked the way the importer reads it).
enum PDFTextProbe {
    static func text(_ data: Data) -> String { PDFDocument(data: data)?.string ?? "" }
    static func pageCount(_ data: Data) -> Int { PDFDocument(data: data)?.pageCount ?? 0 }
    static func mediaBox(_ data: Data) -> CGRect { PDFDocument(data: data)?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero }
}

/// A minimal zip writer (stored entries, CRC-32) for synthetic Word packages with figures —
/// NSAttributedString writes .docx without pictures.
enum MiniZip {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Raw DEFLATE (what zip's method 8 stores).
    static func deflate(_ d: Data) -> Data {
        var out = [UInt8](repeating: 0, count: d.count + 1024)
        let n = d.withUnsafeBytes { s in
            out.withUnsafeMutableBufferPointer { o in
                compression_encode_buffer(o.baseAddress!, o.count, s.bindMemory(to: UInt8.self).baseAddress!, d.count, nil,
                                          COMPRESSION_ZLIB)
            }
        }
        return Data(out.prefix(n))
    }

    static func make(_ entries: [(String, Data)], deflated: Bool = false) -> Data {
        var out = Data(), central = Data()
        func u16(_ d: inout Data, _ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ d: inout Data, _ v: UInt32) {
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
        }
        for (name, data) in entries {
            let n = Data(name.utf8), crc = crc32(data), offset = UInt32(out.count)
            let packed = deflated && !data.isEmpty
            let body = packed ? deflate(data) : data
            let method = packed ? 8 : 0
            u32(&out, 0x0403_4B50); u16(&out, 20); u16(&out, 0); u16(&out, method); u16(&out, 0); u16(&out, 0)
            u32(&out, crc); u32(&out, UInt32(body.count)); u32(&out, UInt32(data.count)); u16(&out, n.count); u16(&out, 0)
            out.append(n); out.append(body)
            u32(&central, 0x0201_4B50); u16(&central, 20); u16(&central, 20); u16(&central, 0); u16(&central, method)
            u16(&central, 0); u16(&central, 0); u32(&central, crc); u32(&central, UInt32(body.count))
            u32(&central, UInt32(data.count)); u16(&central, n.count); u16(&central, 0); u16(&central, 0); u16(&central, 0)
            u16(&central, 0); u32(&central, 0); u32(&central, offset)
            central.append(n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(&out, 0x0605_4B50); u16(&out, 0); u16(&out, 0); u16(&out, entries.count); u16(&out, entries.count)
        u32(&out, UInt32(central.count)); u32(&out, cdOffset); u16(&out, 0)
        return out
    }
}

extension DocKit {
    /// A solid-colour PNG.
    static func png(width: Int, height: Int, red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 1) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        g.cgContext.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        g.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return rep.representation(using: .png, properties: [:])!
    }

    /// A Word package as Word writes figures: inline DrawingML pictures referencing word/media/*
    /// through relationships. `figures` in document order; their relationship ids are listed in
    /// reverse so order must come from the document, not the .rels file.
    static func docxWithFigures(_ figures: [Data], extraMedia: [(String, Data)] = [], deflated: Bool = false) -> Data {
        let ct = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="emf" ContentType="image/x-emf"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        var docRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for i in figures.indices.reversed() {
            docRels += #"<Relationship Id="rIdImg\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image\#(i + 1).png"/>"#
        }
        docRels += #"<Relationship Id="rIdExt" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="https://example.com/x.png" TargetMode="External"/>"#
        docRels += #"<Relationship Id="rIdEmf" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/chart.emf"/>"#
        docRels += "</Relationships>"
        func drawing(_ rid: String) -> String {
            #"<w:p><w:r><w:drawing><wp:inline><wp:extent cx="3810000" cy="2286000"/><wp:docPr id="1" name="Picture"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="p"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\#(rid)"/></pic:blipFill><pic:spPr/></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"#
        }
        var body = #"<w:p><w:r><w:rPr><w:b/><w:sz w:val="40"/></w:rPr><w:t>\#(manuscriptTitle)</w:t></w:r></w:p>"#
        body += #"<w:p><w:r><w:t>Figure 1 shows the progenitors.</w:t></w:r></w:p>"#
        body += drawing("rIdExt") + drawing("rIdEmf")
        for i in figures.indices { body += drawing("rIdImg\(i + 1)") }
        if !figures.isEmpty { body += drawing("rIdImg\(figures.count)") }           // the last picture again
        body += #"<w:p><w:r><w:t>\#(lastLine)</w:t></w:r></w:p>"#
        let doc = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>"#
            + body + "</w:body></w:document>"
        var entries: [(String, Data)] = [("[Content_Types].xml", Data(ct.utf8)), ("_rels/.rels", Data(rels.utf8)),
                                         ("word/document.xml", Data(doc.utf8)), ("word/_rels/document.xml.rels", Data(docRels.utf8))]
        for (i, f) in figures.enumerated() { entries.append(("word/media/image\(i + 1).png", f)) }
        entries.append(("word/media/chart.emf", Data([1, 0, 0, 0, 0x6C, 0, 0, 0])))
        entries += extraMedia
        return MiniZip.make(entries, deflated: deflated)
    }
}
