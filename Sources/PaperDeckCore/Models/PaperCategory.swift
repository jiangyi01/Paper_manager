import Foundation

package struct PaperCategory: Sendable, Identifiable, Equatable, Codable {
    package var pk: Int64
    package var name: String               // unique, case-insensitive
    package var description: String?       // one line, sent to Claude so it picks consistently
    package var hue: Int                   // index into the 10-colour chip palette
    package var origin: CategoryOrigin
    package var acknowledged: Bool         // false → "NEW" badge until the user sees it
    package var createdAt: Date

    package var id: Int64 { pk }

    package init(pk: Int64 = 0, name: String, description: String? = nil, hue: Int = 0,
                 origin: CategoryOrigin, acknowledged: Bool = true, createdAt: Date = Date()) {
        self.pk = pk; self.name = name; self.description = description; self.hue = hue
        self.origin = origin; self.acknowledged = acknowledged; self.createdAt = createdAt
    }

    /// Seed categories (tailored to the user's biology / comp-bio / AI-for-science reading).
    package static let starters: [(name: String, description: String)] = [
        ("AI Agents for Science", "LLM agents, benchmarks and autonomous systems for scientific research"),
        ("ML & Foundation Models for Biology", "Machine learning methods and foundation models applied to biological data"),
        ("Single-cell & Spatial Omics", "Single-cell and spatial transcriptomics/proteomics methods and atlases"),
        ("Genomics & Gene Regulation", "Genome sequencing, variants, chromatin and transcriptional regulation"),
        ("Neuroscience & Development", "Brain, neural circuits, and developmental biology"),
        ("Protein & Structural Biology", "Protein structure, design, and molecular interactions"),
        ("Microbiome & Metabolism", "Microbial communities, host–microbe interactions and metabolism"),
    ]
}

package struct Tag: Sendable, Equatable, Hashable, Codable {
    package var name: String               // lowercase kebab-case
    package var origin: TagOrigin
    package init(name: String, origin: TagOrigin) { self.name = name; self.origin = origin }
}
