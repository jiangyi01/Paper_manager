import Foundation

/// Sender allowlist matching (MAIL_DESIGN Part A §1). Pure and local: it runs on phase-1
/// headers before any body is fetched, and nothing about non-matching senders is kept.
///
/// Only the address part counts — lowercased, `+tag` stripped — so a display name such as
/// `"prof.x@university.edu" <attacker@evil.com>` never matches `prof.x@university.edu`.
/// Patterns: `prof.x@university.edu` (exact), `@biorxiv.org` (that domain only), `@*.nature.com`
/// (any subdomain; the bare domain too). Precedence by specificity: exact address > exact
/// domain > wildcard subdomain > wildcard apex; among wildcards a longer suffix beats a shorter
/// one; ties keep list order. So a per-sender rule (`@notification.elsevier.com`, AI never)
/// overrides a broad preset (`@*.elsevier.com`). Disabled rules are ignored.
package enum SenderMatcher {

    package static func match(address: String, rules: [SenderRule]) -> SenderRule? {
        let addr = normalize(address)
        guard let at = addr.lastIndex(of: "@") else { return nil }
        let local = addr[..<at], domain = String(addr[addr.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return nil }

        var best: (rank: Int, suffix: Int, rule: SenderRule)?
        for rule in rules where rule.enabled {
            guard let pattern = Pattern(rule.pattern) else { continue }
            let score: (Int, Int)?
            switch pattern {
            case .address(let a):
                score = a == addr ? (4, 0) : nil
            case .domain(let d):
                score = d == domain ? (3, 0) : nil
            case .wildcard(let d):
                if domain.hasSuffix("." + d) { score = (2, d.count) }
                else if domain == d { score = (1, d.count) }
                else { score = nil }
            }
            guard let (rank, suffix) = score else { continue }
            if let b = best, (b.rank, b.suffix) >= (rank, suffix) { continue }
            best = (rank, suffix, rule)
        }
        return best?.rule
    }

    /// `"Name" <Prof.X+papers@University.edu>` → `prof.x@university.edu`. Strips `mailto:`, angle
    /// brackets, surrounding whitespace/quotes, a trailing dot of the domain and the `+tag`.
    package static func normalize(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s = String(s[s.index(after: open)..<close])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'<>")).lowercased()
        if s.hasPrefix("mailto:") { s = String(s.dropFirst(7)) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        guard let at = s.lastIndex(of: "@") else { return s }
        var local = String(s[..<at])
        var domain = String(s[s.index(after: at)...])
        while domain.hasSuffix(".") { domain.removeLast() }
        if let plus = local.firstIndex(of: "+"), plus != local.startIndex { local = String(local[..<plus]) }
        return local + "@" + domain
    }

    /// A parsed rule pattern (also used by the settings editor to validate input).
    package enum Pattern: Equatable, Sendable {
        case address(String)        // normalized full address
        case domain(String)         // "biorxiv.org"
        case wildcard(String)       // "nature.com" from "@*.nature.com"

        /// Accepts `a@b.org`, `Name <a@b.org>`, `@b.org`, `b.org`, `@*.b.org`, `*.b.org`.
        package init?(_ raw: String) {
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let open = p.lastIndex(of: "<"), let close = p[open...].firstIndex(of: ">") {
                p = String(p[p.index(after: open)..<close])
            }
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard !p.isEmpty else { return nil }
            if p.hasPrefix("@") || !p.contains("@") {
                var d = p.hasPrefix("@") ? String(p.dropFirst()) : p
                while d.hasSuffix(".") { d.removeLast() }
                if d.hasPrefix("*.") {
                    let rest = String(d.dropFirst(2))
                    guard Pattern.validDomain(rest) else { return nil }
                    self = .wildcard(rest)
                } else {
                    guard Pattern.validDomain(d) else { return nil }
                    self = .domain(d)
                }
                return
            }
            let n = SenderMatcher.normalize(p)
            guard let at = n.lastIndex(of: "@"), at != n.startIndex,
                  Pattern.validDomain(String(n[n.index(after: at)...])) else { return nil }
            self = .address(n)
        }

        static func validDomain(_ d: String) -> Bool {
            guard d.contains("."), !d.hasPrefix("."), !d.contains(".."), !d.contains("*") else { return false }
            return d.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }
        }
    }
}
