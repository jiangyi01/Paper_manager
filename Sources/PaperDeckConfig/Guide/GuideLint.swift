import Foundation
import PaperDeckCore
import PaperDeckShared

/// The content rules every guide topic must follow (unit tests run them over the catalog; W2's
/// lint and the docs sync reuse them). Each problem is one readable line.
package enum GuideLint {
    package static func problems(_ topics: [GuideTopic]) -> [String] {
        var out: [String] = []
        var seen: Set<GuideTopicID> = []
        let ids = Set(topics.map(\.id))
        for t in topics {
            let id = t.id.rawValue
            if !seen.insert(t.id).inserted { out.append("\(id): duplicate id") }
            if !DeepLink.isValidTopic(id) { out.append("\(id): id is not ^[a-z0-9-]{1,48}$") }
            for (name, text) in [("title", t.title), ("summary", t.summary)] where !complete(text) {
                out.append("\(id): \(name) needs en and zh")
            }
            for (i, k) in t.keywords.enumerated() where !complete(k) { out.append("\(id): keyword \(i + 1) needs en and zh") }
            for r in t.related where !ids.contains(r) { out.append("\(id): related \(r.rawValue) doesn't exist") }
            if t.lastReviewed.range(of: "^20[0-9]{2}-[01][0-9]$", options: .regularExpression) == nil {
                out.append("\(id): lastReviewed must be YYYY-MM")
            }
            var manual = 0
            var stepIDs: Set<String> = []
            for (i, s) in t.steps.enumerated() {
                let where_ = "\(id) step \(i + 1)"
                if !stepIDs.insert(s.id).inserted || s.id.isEmpty { out.append("\(where_): step id empty or duplicate") }
                if !complete(s.text) { out.append("\(where_): text needs en and zh") }
                switch s.verification {
                case .manual(let reason):
                    manual += 1
                    if !complete(reason) { out.append("\(where_): a manual step needs a reason in en and zh") }
                case .impliedBy(let later):
                    if later <= i || later >= t.steps.count { out.append("\(where_): impliedBy must point to a later step") }
                case .check, .info:
                    break
                }
                for a in s.actions { out += actionProblems(a, where_, ids) }
                for c in s.commands { out += commandProblems(c, where_) }
            }
            if manual > 1 { out.append("\(id): at most one manual step (has \(manual))") }
        }
        return out
    }

    /// Catalog ids (§3.8) with no topic.
    package static func missing(_ topics: [GuideTopic], catalog: [GuideTopicID] = GuideTopicID.catalog) -> [GuideTopicID] {
        let have = Set(topics.map(\.id))
        return catalog.filter { !have.contains($0) }
    }

    private static func complete(_ t: LocalizedText) -> Bool {
        !t.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !t.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func actionProblems(_ a: GuideAction, _ where_: String, _ ids: Set<GuideTopicID>) -> [String] {
        switch a {
        case .openURL(let url):
            return GuideLinks.isAllowed(url) ? [] : ["\(where_): link host \(url.host ?? url.absoluteString) isn't allowed"]
        case .deepLink(let link):
            return DeepLink(url: link.url) == link ? [] : ["\(where_): deep link \(link.url.absoluteString) doesn't round-trip"]
        case .openTopic(let t):
            return ids.contains(t) || GuideTopicID.catalog.contains(t) ? [] : ["\(where_): topic \(t.rawValue) doesn't exist"]
        default:
            return []
        }
    }

    /// No home paths, no institution names or domains, no real-looking addresses (example domains only).
    private static func commandProblems(_ c: String, _ where_: String) -> [String] {
        var out: [String] = []
        if c.contains("/Users/") { out.append("\(where_): command contains a home path") }
        let lower = c.lowercased()
        for literal in institutionLiterals where lower.contains(literal) {
            out.append("\(where_): command names an institution")
            break
        }
        if let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\\.[A-Za-z]{2,})") {
            for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
                guard let r = Range(m.range(at: 1), in: c) else { continue }
                let domain = c[r].lowercased()
                if !["example.com", "example.edu", "example.org"].contains(domain) {
                    out.append("\(where_): command contains a real-looking address")
                }
            }
        }
        return out
    }

    /// From the built-in presets themselves (this file holds no institution literal).
    private static var institutionLiterals: [String] {
        OrganizationPresets.builtIn.filter { $0.id != OrganizationPresets.generic.id }.flatMap { o -> [String] in
            [o.name?.en, o.shortName, o.mail.oneDriveRootHint].compactMap { $0 } + o.mail.knownSenderDomains
        }
        .map { $0.lowercased() }
        .filter { $0.count >= 3 }
    }
}
