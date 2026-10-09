import Foundation

/// Extracted full text per paper, LZFSE-compressed at `support/text/<id>.txt.lzfse`.
/// Reused for agent prompts and re-indexing so the PDF is not parsed again (§5).
/// Synchronous file I/O: call from `BlockingIO.run` (or an accessor) for large texts.
package struct TextStore: Sendable {
    package static let fileExtension = "txt.lzfse"

    package let directory: URL

    package init(directory: URL) { self.directory = directory }
    package init(paths: AppPaths) { self.init(directory: paths.textCache) }

    package func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).\(Self.fileExtension)")
    }

    package func save(_ text: String, id: String) throws {
        let file = try checkedURL(for: id)
        let raw = Data(text.utf8)
        let payload: Data
        do { payload = raw.isEmpty ? Data() : try (raw as NSData).compressed(using: .lzfse) as Data }
        catch { throw FileOpsError.io("lzfse compression failed: \(error.localizedDescription)") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try payload.write(to: file, options: .atomic)
        } catch {
            throw FileOps.classify(error)
        }
    }

    /// nil when no text is cached; throws when the cache file is unreadable or corrupt.
    package func load(id: String) throws -> String? {
        let file = try checkedURL(for: id)
        let payload: Data
        do { payload = try Data(contentsOf: file) } catch {
            let mapped = FileOps.classify(error)
            if mapped == .sourceMissing { return nil }
            throw mapped
        }
        if payload.isEmpty { return "" }
        do {
            let raw = try (payload as NSData).decompressed(using: .lzfse) as Data
            return String(decoding: raw, as: UTF8.self)
        } catch {
            throw FileOpsError.io("corrupt text cache for \(id)")
        }
    }

    package func exists(id: String) -> Bool {
        guard let file = try? checkedURL(for: id) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Missing files are fine; returns whether something was removed.
    @discardableResult
    package func delete(id: String) -> Bool {
        guard let file = try? checkedURL(for: id) else { return false }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }

    /// Σ logical size of the cached text files.
    package func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return files.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Ids become file names, so only [A-Za-z0-9_-] is allowed (no "..", no "/").
    private func checkedURL(for id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { throw FileOpsError.io("invalid paper id \(id.debugDescription)") }
        return url(for: id)
    }
}
