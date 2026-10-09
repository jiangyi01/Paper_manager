import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-4: 「清除所有邮件数据」 and a running `.eml` import are serialized — the clear stops
/// the import at its next file and waits for the email being captured, so no row survives the
/// wipe (and none is left without its attachment files); an import started during a clear waits.
@Suite(.serialized) struct R3ClearImportTests {
    typealias K = MailSyncKit

    /// `n` distinct advisor emails with a PDF attachment each, written as .eml files.
    private static func emlFiles(_ n: Int, in dir: URL) throws -> [URL] {
        let pdf = K.realPDF(title: "Clear all race").base64EncodedString(options: [.lineLength76Characters])
        return try (0..<n).map { i in
            let lines = [
                "From: \"Smith, Jane\" <jsmith@wustl.edu>", "To: yi@wustl.edu", "Subject: Paper \(i)",
                "Date: Tue, 29 Sep 2026 14:05:00 -0500", "Message-ID: <r3-clear-\(i)@wustl.edu>", "MIME-Version: 1.0",
                "Content-Type: multipart/mixed; boundary=\"r3c\"", "",
                "--r3c", "Content-Type: text/plain; charset=utf-8", "", "Please read the attached paper.", "",
                "--r3c", "Content-Type: application/pdf; name=\"p\(i).pdf\"",
                "Content-Disposition: attachment; filename=\"p\(i).pdf\"", "Content-Transfer-Encoding: base64", "",
                pdf, "--r3c--", "",
            ]
            let url = dir.appendingPathComponent("m\(i).eml")
            try Data(lines.joined(separator: "\r\n").utf8).write(to: url)
            return url
        }
    }

    @Test func clearAllWaitsForARunningImportAndLeavesNothingBehind() async throws {
        try await K.run { env in
            let dir = env.root.appendingPathComponent("drops", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = try Self.emlFiles(120, in: dir)
            let importing = Task { await env.engine.mail.importEML(files) }
            #expect(await K.eventually(.seconds(10)) { try await !env.messages().isEmpty })
            try await env.engine.mail.deleteAllMailData()
            _ = await importing.value
            #expect(try await env.messages().isEmpty)                            // nothing captured outlives the wipe
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: env.engine.paths.mailFiles.path)) ?? []
            #expect(leftovers.isEmpty)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.pendingPostKey) == nil)

            // Afterwards imports work again, rows with their files.
            let again = await env.engine.mail.importEML(Array(files.prefix(2)))
            #expect(again.count == 2)
            await env.engine.mail.waitUntilIdle()
            for m in try await env.messages() {
                for item in try await env.db.mailItems(messagePK: m.pk) {
                    let path = try #require(item.pdfPath)
                    #expect(FileManager.default.fileExists(atPath: env.engine.paths.mailFiles.appendingPathComponent(path).path))
                }
            }
        }
    }
}
