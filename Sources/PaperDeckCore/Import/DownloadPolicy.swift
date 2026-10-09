import Foundation

/// Where a download that came out of an email may go. Checked on the URL before anything is
/// sent and again on every redirect (`URLSessionPDFDownloader`), so a link can neither start
/// nor end on the user's own machine or network:
///
/// - always: http(s) only, no user:password in the URL, a public DNS name — no IP literal (any
///   notation), no `localhost`, no single-label host, no `.local` / `.internal` / `.lan` /
///   `.home.arpa`-style private suffixes;
/// - `mailAutomatic` (a sender's auto-merge, nobody clicked): https on the default port, and
///   only arXiv / bioRxiv / medRxiv — the hosts the design trusts without a click. Anything else
///   waits for the user's 「下载」 / 「合并」.
///
/// Decisions are made on the unwrapped target (Outlook Safe Links and other wrappers removed
/// by `LinkUnwrapper`), never on the wrapper's host. A public name that resolves to a private
/// address is not caught here (no DNS lookup is made).
package struct DownloadPolicy: Sendable, Equatable {
    package var httpsOnly: Bool
    /// Hosts allowed (each also with its subdomains); nil = any public host.
    package var allowedDomains: Set<String>?
    /// Exact hosts let through the public-host check (tests: a loopback fixture server). Never
    /// set by the app.
    package var exemptHosts: Set<String>

    package init(httpsOnly: Bool, allowedDomains: Set<String>?, exemptHosts: Set<String> = []) {
        self.httpsOnly = httpsOnly; self.allowedDomains = allowedDomains; self.exemptHosts = exemptHosts
    }

    /// The preprint servers automatic downloads may reach (the canonical rewrites of
    /// `PaperLinkClassifier.pdfURL` all point here).
    package static let knownPreprintDomains: Set<String> = ["arxiv.org", "biorxiv.org", "medrxiv.org"]

    /// A download the user asked for on a mail row: any public http(s) host.
    package static let mailUserAction = DownloadPolicy(httpsOnly: false, allowedDomains: nil)
    /// A download nobody clicked (auto-merge): https to arXiv / bioRxiv / medRxiv only.
    package static let mailAutomatic = DownloadPolicy(httpsOnly: true, allowedDomains: knownPreprintDomains)

    package func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || (!httpsOnly && scheme == "http") else {
            return false
        }
        guard url.user == nil, url.password == nil, let host = Self.host(of: url),
              exemptHosts.contains(host) || Self.isPublicHostName(host) else {
            return false
        }
        guard let domains = allowedDomains else { return true }
        if let port = url.port, port != 443 { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The URL's host, lowercased, without a trailing dot; nil when there is none.
    static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Suffixes that only ever name the user's own machine or network.
    private static let privateSuffixes = ["localhost", "local", "internal", "intranet", "lan", "home", "corp",
                                          "localdomain", "home.arpa", "arpa", "test", "invalid", "example", "onion"]

    /// A DNS name on the public Internet: at least two labels, a real top-level domain (letters,
    /// or an IDN `xn--` label — so every IPv4 notation fails), no IPv6 literal, no private suffix.
    package static func isPublicHostName(_ raw: String) -> Bool {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":"), !host.contains("["), !host.contains("%"),
              !host.contains("/"), !host.contains("@") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        for suffix in privateSuffixes where host == suffix || host.hasSuffix("." + suffix) { return false }
        let tld = labels[labels.count - 1]
        if tld.hasPrefix("xn--") {
            return tld.count > 4 && tld.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return tld.count >= 2 && tld.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

/// A download stopped by its `DownloadPolicy` (the URL itself, or a redirect).
package struct DownloadBlockedError: Error, Sendable, Equatable {
    package init() {}
}
