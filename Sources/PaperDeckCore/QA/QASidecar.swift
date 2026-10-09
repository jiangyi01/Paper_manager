import Foundation

/// `qa.json` in a paper's folder (DQ §6.4, schema `paperdeck.qa/1`): the paper's single-paper Q&A
/// threads, so a rebuild from the folders keeps them. Never written for a paper whose privacy
/// verdict isn't `.ok` (marked confidential / unpublished, a person's email without an id, never-AI):
/// those threads live in the database only. Written like `card.json` — atomically, only when the
/// bytes change, never creating a directory. Multi-paper threads are not stored here.
package struct QASidecar: Codable, Equatable, Sendable {
    package static let schemaID = "paperdeck.qa/1"
    package static let fileName = "qa.json"

    package struct Message: Codable, Equatable, Sendable {
        package var id: String
        package var role: String
        package var text: String
        package var state: String
        package var citations: [QACitation]?
        package var provider: String?
        package var model: String?
        package var depth: String?
        package var lang: String?
        package var durationMs: Int?
        package var createdAt: String
    }

    package struct Thread: Codable, Equatable, Sendable {
        package var id: String
        package var title: String
        package var lang: String
        package var mode: String
        package var createdAt: String
        package var updatedAt: String
        package var messages: [Message]
    }

    package var schema: String
    package var paperID: String
    package var threads: [Thread]

    package init(paperID: String, threads: [(QAThread, [QAMessage])]) {
        schema = Self.schemaID
        self.paperID = paperID
        self.threads = threads.filter { $0.0.scope == .paper }.map { t, messages in
            Thread(id: t.id, title: t.title, lang: t.language.rawValue, mode: t.mode.rawValue,
                   createdAt: Database.timestamp(t.createdAt), updatedAt: Database.timestamp(t.updatedAt),
                   messages: messages.filter { $0.state != .streaming }.map { m in
                       Message(id: m.id, role: m.role.rawValue, text: m.text, state: m.state.rawValue,
                               citations: m.citations.isEmpty ? nil : m.citations, provider: m.meta?.provider,
                               model: m.meta.flatMap { $0.model.isEmpty ? nil : $0.model },
                               depth: m.depth?.rawValue, lang: m.language, durationMs: m.meta?.totalMs,
                               createdAt: Database.timestamp(m.createdAt))
                   })
        }
    }

    /// Sorted keys, pretty-printed: the same threads always give the same bytes.
    package func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// A `paperdeck.qa/1` file; anything else throws.
    package static func decode(_ data: Data) throws -> QASidecar {
        let s = try JSONDecoder().decode(QASidecar.self, from: data)
        guard s.schema == schemaID else { throw QAError.unsupportedSidecar(s.schema) }
        return s
    }

    /// The threads and messages as stored values (a message still `streaming` comes back
    /// `cancelled`; unknown roles are skipped).
    package func restored() -> [(QAThread, [QAMessage])] {
        threads.map { t in
            var thread = QAThread(id: t.id, paperIDs: [paperID], title: t.title,
                                  mode: QAContextMode(rawValue: t.mode) ?? .fullText,
                                  createdAt: Database.date(fromTimestamp: t.createdAt) ?? .distantPast,
                                  language: AssistSettings.AnswerLanguage(rawValue: t.lang) ?? .auto, persisted: true)
            thread.updatedAt = Database.date(fromTimestamp: t.updatedAt) ?? thread.createdAt
            let messages: [QAMessage] = t.messages.enumerated().compactMap { i, m in
                guard let role = AssistTurnText.Role(rawValue: m.role) else { return nil }
                var state = QAMessage.State(rawValue: m.state) ?? .done
                if state == .streaming { state = .cancelled }
                let meta = m.provider.map {
                    AssistMeta(provider: $0, model: m.model ?? "", totalMs: m.durationMs ?? 0)
                }
                return QAMessage(id: m.id, threadID: t.id, role: role, text: m.text, state: state, meta: meta,
                                 createdAt: Database.date(fromTimestamp: m.createdAt) ?? thread.createdAt,
                                 citations: m.citations ?? [], language: m.lang,
                                 depth: m.depth.flatMap(AssistSettings.Depth.init(rawValue:)), ord: i)
            }
            return (thread, messages)
        }
    }
}
