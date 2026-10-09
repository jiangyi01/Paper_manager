import Foundation

/// One starter category of a research field's pack (`FieldPreset.starterCategories`).
package struct StarterCategory: Sendable, Equatable, Codable {
    package var name: String
    package var description: String

    package init(name: String, description: String) {
        self.name = name; self.description = description
    }
}

/// Starter-pack rules shared by the pristine replacement and the "add missing" action.
package enum StarterPack {
    /// The pack cleaned for insertion: names trimmed to one line (≤ 40 characters), descriptions
    /// to one line (≤ 200), empty names and case-insensitive duplicates dropped, at most
    /// `Taxonomy.autoCreateLimit` entries. Nil when nothing is left.
    package static func normalized(_ pack: [StarterCategory]) -> [StarterCategory]? {
        var seen = Set<String>()
        var out: [StarterCategory] = []
        for c in pack {
            let name = oneLine(c.name, cap: 40)
            guard !name.isEmpty, seen.insert(key(name)).inserted else { continue }
            out.append(StarterCategory(name: name, description: oneLine(c.description, cap: 200)))
            if out.count >= Taxonomy.autoCreateLimit { break }
        }
        return out.isEmpty ? nil : out
    }

    /// Today's built-in starters as a pack.
    package static var builtIn: [StarterCategory] {
        PaperCategory.starters.map { StarterCategory(name: $0.name, description: $0.description) }
    }

    static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func oneLine(_ s: String, cap: Int) -> String {
        let line = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(line.prefix(cap)).trimmingCharacters(in: .whitespaces)
    }
}

extension Engine {
    /// Replaces today's built-in starter categories with `pack` — only on a pristine library: no
    /// paper (live or deleted), every category `origin = starter` and exactly
    /// `PaperCategory.starters`, no manifest on disk. Runs before `start()`, so the first manifest
    /// already holds the pack. Returns true when the pack was applied (false for an empty pack or
    /// one equal to today's starters).
    package func applyStarterPackIfPristine(_ pack: [StarterCategory]) async throws -> Bool {
        guard let pack = StarterPack.normalized(pack), pack != StarterPack.builtIn else { return false }
        let manifestURL = paths.libraryManifest
        let hasManifest = await BlockingIO.run { FileManager.default.fileExists(atPath: manifestURL.path) }
        guard !hasManifest else { return false }
        let now = ctx.now()
        let applied = try await db.transaction { db -> Bool in
            guard try db.allPapers().isEmpty else { return false }
            let existing = try db.categories()
            let builtIn = PaperCategory.starters
            guard existing.count == builtIn.count, existing.allSatisfy({ $0.origin == .starter }),
                  zip(existing, builtIn).allSatisfy({ $0.name == $1.name && $0.description == $1.description })
            else { return false }
            for c in existing { try db.deleteCategory(pk: c.pk) }
            for (i, s) in pack.enumerated() {
                try db.insertCategory(PaperCategory(name: s.name, description: s.description.isEmpty ? nil : s.description,
                                                    hue: i % 10, origin: .starter, acknowledged: true, createdAt: now))
            }
            return true
        }
        if applied { Log.storage.notice("starter pack applied: \(pack.count, privacy: .public) categories") }
        return applied
    }

    /// Inserts the pack's categories whose names are missing (case-insensitive; never renames or
    /// deletes), capped at `Taxonomy.autoCreateLimit` categories in total. Returns how many were
    /// added; the manifest mirrors them.
    package func addMissingStarterCategories(_ pack: [StarterCategory]) async throws -> Int {
        guard let pack = StarterPack.normalized(pack) else { return 0 }
        let now = ctx.now()
        let added = try await db.transaction { db -> Int in
            var existing = try db.categories()
            var keys = Set(existing.map { StarterPack.key($0.name) })
            var added = 0
            for s in pack where !keys.contains(StarterPack.key(s.name)) {
                guard existing.count < Taxonomy.autoCreateLimit else { break }
                let saved = try db.insertCategory(PaperCategory(
                    name: s.name, description: s.description.isEmpty ? nil : s.description,
                    hue: Taxonomy.nextHue(existing: existing), origin: .starter, acknowledged: true, createdAt: now))
                existing.append(saved)
                keys.insert(StarterPack.key(s.name))
                added += 1
            }
            return added
        }
        if added > 0 { await ctx.writeManifest() }
        return added
    }

    /// The category table becomes exactly `pack` (an index without papers: "Start new empty").
    func replaceCategories(with pack: [StarterCategory]) async throws -> Int {
        let now = ctx.now()
        return try await db.transaction { db -> Int in
            guard try db.allPapers().isEmpty else { return try db.categories().count }
            for c in try db.categories() { try db.deleteCategory(pk: c.pk) }
            for (i, s) in pack.enumerated() {
                try db.insertCategory(PaperCategory(name: s.name, description: s.description.isEmpty ? nil : s.description,
                                                    hue: i % 10, origin: .starter, acknowledged: true, createdAt: now))
            }
            return pack.count
        }
    }
}
