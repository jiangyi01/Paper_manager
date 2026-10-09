import Foundation

/// Removes security/tracking wrappers from mail links, purely by rewriting the string —
/// nothing is ever fetched (following a redirect would send a click ping).
///
/// The unwrapped URL is for identification only; 「打开链接」 opens the original so the
/// university's time-of-click scan still runs (MAIL_DESIGN Part A §2.3). Handles nested
/// wrappers (Safe Links → Proofpoint v3 → Scholar → publisher) and strips `utm_*` and other
/// tracking parameters. Non-http(s) results (`javascript:`, `data:`…) are never returned as
/// the unwrapped target; the wrapper itself is returned instead.
package enum LinkUnwrapper {

    /// Wrapping depth handled (real mail rarely exceeds 3).
    package static let maxLayers = 8

    package static func unwrap(_ url: URL) -> URL {
        var current = url
        for _ in 0..<maxLayers {
            guard let inner = unwrapOnce(current), inner != current else { break }
            guard let scheme = inner.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  inner.host?.isEmpty == false else { break }
            current = inner
        }
        return stripTracking(current)
    }

    /// Lenient parse of a link found in mail (spaces and non-ASCII characters are encoded).
    package static func url(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 8_192 else { return nil }
        if s.lowercased().hasPrefix("www.") { s = "https://" + s }
        if let u = URL(string: s) { return u }
        return URL(string: s, encodingInvalidCharacters: true)
    }

    // MARK: - One layer

    static func unwrapOnce(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            comps?.queryItems?.first(where: { $0.name.lowercased() == name })?.value
        }

        // Microsoft Defender Safe Links: https://nam02.safelinks.protection.outlook.com/?url=<enc>&data=…
        if host.hasSuffix("safelinks.protection.outlook.com") || host.hasSuffix("safelinks.protection.office365.us") {
            return query("url").flatMap(Self.url(from:))
        }
        // Proofpoint URL Defense.
        if host == "urldefense.proofpoint.com" || host == "urldefense.com" || host.hasSuffix(".urldefense.com") {
            let path = url.path
            if path.hasPrefix("/v3/") { return proofpointV3(url.absoluteString) }
            if path.hasPrefix("/v2/"), let u = query("u") {
                let translated = u.replacingOccurrences(of: "-", with: "%").replacingOccurrences(of: "_", with: "/")
                return (translated.removingPercentEncoding ?? translated).flatMapURL()
            }
            if path.hasPrefix("/v1/"), let u = query("u") { return Self.url(from: u) }
            return nil
        }
        // Google Scholar result links and Google redirects.
        if isGoogleHost(host) {
            if url.path == "/scholar_url" || url.path == "/url" {
                return (query("url") ?? query("q")).flatMap(Self.url(from:))
            }
            return nil
        }
        // Amazon SES click tracking (Elsevier/Cell alerts): /CL0/<percent-encoded URL>/1/<id>/<sig>
        let abs = url.absoluteString
        if let r = abs.range(of: "/CL0/") {
            let rest = abs[r.upperBound...]
            let target = rest.range(of: "/1/").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            if let decoded = target.removingPercentEncoding, decoded.lowercased().hasPrefix("http") {
                return Self.url(from: decoded)
            }
        }
        // Generic redirectors that carry the full target in a query parameter (never social share links).
        guard !isShareHost(host) else { return nil }
        for name in ["url", "u", "q", "target", "dest", "destination", "redirect", "redirect_url", "redirecturl", "link", "l"] {
            if let v = query(name), let target = Self.url(from: v), let s = target.scheme?.lowercased(),
               s == "http" || s == "https", target.host?.isEmpty == false {
                return target
            }
        }
        return nil
    }

    /// v3: https://urldefense.com/v3/__<url with * placeholders>__;<base64url bytes>!!…$
    /// Each `*` takes the next character of the decoded bytes, `**X` a run of them.
    static func proofpointV3(_ s: String) -> URL? {
        guard let start = s.range(of: "/v3/__"), let end = s.range(of: "__;", range: start.upperBound..<s.endIndex) else {
            return nil
        }
        let embedded = String(s[start.upperBound..<end.lowerBound])
        var tail = s[end.upperBound...]
        if let bang = tail.firstIndex(of: "!") { tail = tail[..<bang] }
        var b64 = tail.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let replacement = Array(Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self) } ?? "")
        let runAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        let chars = Array(embedded.removingPercentEncoding ?? embedded)
        var out = ""
        var marker = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "*" {
                if i + 2 < chars.count, chars[i + 1] == "*", let run = runAlphabet.firstIndex(of: chars[i + 2]) {
                    let n = run + 2
                    let upper = min(replacement.count, marker + n)
                    if marker < upper { out += String(replacement[marker..<upper]) }
                    marker = upper
                    i += 3
                    continue
                }
                if marker < replacement.count { out.append(replacement[marker]) }
                marker += 1
                i += 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return url(from: out)
    }

    // MARK: - Tracking parameters

    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "hsctatracking", "mkt_tok",
        "dgcid", "cmpid", "s_cid", "sc_cid", "et_rid", "et_cid", "_ga", "_gl", "vero_id", "oly_enc_id",
        "oly_anon_id", "rb_clickid", "spmailingid", "spuserid", "spjobid", "spreportid", "trk", "trkcampaign",
        "sap-outbound-id", "ss_source", "ss_campaign_id", "ss_email_id", "ref_src", "wt.mc_id", "wt.ec_id",
        "wt.tsrc", "_hsfp", "__hstc", "__hssc", "__hsfp", "hsa_cam", "rss", "error", "code", "sf_rid", "cid_hash",
    ]

    /// Drops `utm_*`, `elq*`, `WT.*` and other click-tracking parameters. `error`/`code` are only
    /// dropped for nature.com (its "cookies_not_supported" redirect decoration).
    package static func stripTracking(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems,
              !items.isEmpty else { return url }
        let host = url.host?.lowercased() ?? ""
        let isNature = host == "nature.com" || host.hasSuffix(".nature.com")
        let kept = items.filter { item in
            let n = item.name.lowercased()
            if n.hasPrefix("utm_") || n.hasPrefix("elq") || n.hasPrefix("wt.") || n.hasPrefix("pk_") || n.hasPrefix("mtm_") { return false }
            if n == "error" || n == "code" { return !isNature }
            if n == "rss" { return false }
            return !trackingNames.contains(n)
        }
        guard kept.count != items.count else { return url }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url ?? url
    }

    // MARK: - Hosts

    static func isGoogleHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard let i = parts.firstIndex(of: "google") else { return false }
        return i == parts.count - 2 || (i == parts.count - 3 && ["co", "com"].contains(String(parts[i + 1])))
            || host.hasPrefix("scholar.google.")
    }

    /// Social "share" endpoints put the article URL in `?url=` — that is not a wrapper.
    static func isShareHost(_ host: String) -> Bool {
        let share = ["twitter.com", "x.com", "facebook.com", "linkedin.com", "reddit.com", "bsky.app", "weibo.com",
                     "pinterest.com", "tumblr.com", "wa.me", "whatsapp.com", "t.me", "telegram.me", "mastodon.social",
                     "service.weibo.com", "getpocket.com", "mendeley.com", "citeulike.org", "addthis.com"]
        return share.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

private extension String {
    func flatMapURL() -> URL? { LinkUnwrapper.url(from: self) }
}
