import Foundation

/// Splits a byte stream into newline-terminated lines (NDJSON: `claude --output-format stream-json`,
/// `codex exec --json`). Chunks may cut a line (or a UTF-8 sequence) anywhere; a line is handed out
/// only once its `\n` arrived, without the `\n` (a trailing `\r` is dropped too).
///
/// A line longer than `maxLine` bytes is never buffered whole: its bytes are dropped up to the next
/// newline and one `oversizeMarker` line stands in for it, so a runaway child can't grow memory.
package struct LineSplitter: Sendable {
    /// 8 MB: far above any real event line (an image is never echoed back).
    package static let defaultMaxLine = 8 << 20
    /// What an oversize line becomes (a parser recognizes it as `_oversize`).
    package static let oversizeMarker = Data(#"{"type":"_oversize"}"#.utf8)

    package let maxLine: Int
    private var buffer = Data()
    /// Inside an oversize line: drop bytes until the next newline.
    private var discarding = false

    package init(maxLine: Int = LineSplitter.defaultMaxLine) {
        self.maxLine = max(1, maxLine)
    }

    /// The complete lines `chunk` finished, in order.
    package mutating func push(_ chunk: UnsafeRawBufferPointer) -> [Data] {
        var lines: [Data] = []
        var start = 0
        let count = chunk.count
        while start < count {
            // The next newline in the chunk, if any.
            var nl = start
            while nl < count && chunk[nl] != 0x0A { nl += 1 }
            let piece = UnsafeRawBufferPointer(rebasing: chunk[start..<nl])
            if discarding {
                if nl < count { discarding = false }
            } else if buffer.count + piece.count > maxLine {
                buffer.removeAll(keepingCapacity: false)
                lines.append(Self.oversizeMarker)
                if nl >= count { discarding = true }
            } else {
                buffer.append(contentsOf: piece)
                if nl < count {
                    lines.append(Self.trimCR(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            start = nl + 1
        }
        return lines
    }

    /// Convenience for tests and fixtures.
    package mutating func push(_ data: Data) -> [Data] {
        data.withUnsafeBytes { push($0) }
    }

    /// The unterminated rest at EOF (nil when there is none); the splitter is empty afterwards.
    package mutating func finish() -> Data? {
        defer { buffer = Data(); discarding = false }
        guard !discarding, !buffer.isEmpty else { return nil }
        return Self.trimCR(buffer)
    }

    private static func trimCR(_ d: Data) -> Data {
        guard let last = d.last, last == 0x0D else { return Data(d) }
        return Data(d.dropLast())
    }
}
