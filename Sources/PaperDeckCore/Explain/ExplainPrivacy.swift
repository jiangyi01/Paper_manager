import CoreGraphics
import Foundation

/// Mail and chat on screen (plan §2 "the host app"; proposal §4: a screenshot of a mail window asks
/// first). `AssistPrivacy.messagingHosts` covers the native apps (plus `moreMessagingHosts` and
/// macOS's notification banners here); a browser — or a web app it installed — is a mail window when
/// its title shows a webmail (a segment "Gmail", "Outlook", "Inbox…", an e-mail address) or a web
/// chat. Pure; reason codes only (the App words them).
package enum MailWindow {
    /// Browsers whose window title tells which site is showing.
    package static let browsers: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.canary",
        "com.google.chrome.beta", "com.google.chrome.dev", "org.chromium.chromium", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.microsoft.edgemac", "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.dev", "com.brave.browser", "company.thebrowser.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "com.kagi.kagimacos", "com.duckduckgo.macos.browser", "app.zen-browser.zen",
        "org.torproject.torbrowser", "com.openai.atlas",
    ]
    /// Web apps a browser installed ("Add to Dock", a Chrome / Edge / Brave app): a site in a window
    /// of its own, its title tells which (a Gmail web app is mail).
    package static let webAppPrefixes = ["com.apple.safari.webapp.", "com.google.chrome.app.", "com.microsoft.edgemac.app.",
                                         "com.brave.browser.app.", "org.chromium.chromium.app."]
    /// Mail and chat apps beyond `AssistPrivacy.messagingHosts` (lower-cased), and macOS's
    /// notification banners (a message's sender and first lines).
    package static let moreMessagingHosts: Set<String> = [
        "com.apple.notificationcenterui", "com.mimestream.mimestream", "it.bloop.airmail2", "com.freron.mailmate",
        "com.postbox-inc.postbox", "org.whispersystems.signal-desktop", "com.skype.skype", "im.riot.app",
        "jp.naver.line.mac", "com.viber.osx", "com.tencent.qq", "com.tencent.weworkmac", "com.alibaba.dingtalkmac",
        "com.electron.lark", "com.bytedance.lark", "com.bytedance.feishu", "com.microsoft.skype.teams",
        "com.readdle.spark-desktop", "com.canarymail.mac", "com.edisonmail.edisonmail", "net.shinyfrog.bear-mail",
    ]

    /// A whole title segment naming a webmail or a web chat (case-insensitive).
    package static let webMessagingSegments: Set<String> = [
        "gmail", "google mail", "outlook", "outlook.com", "microsoft outlook", "outlook web app", "mail", "yahoo mail",
        "yahoo! mail", "proton mail", "protonmail", "icloud mail", "fastmail", "zoho mail", "aol mail", "gmx", "mail.com",
        "tutanota", "tuta", "hey", "superhuman", "slack", "microsoft teams", "teams", "whatsapp", "messenger",
        "discord", "telegram", "telegram web", "wechat", "微信", "邮箱", "qq邮箱", "网易邮箱", "163邮箱", "outlook 邮箱",
        "google chat", "google messages", "messages for web", "messaging", "skype", "zulip", "mattermost", "rocket.chat",
        "微信网页版", "企业微信", "钉钉", "飞书", "腾讯企业邮", "126邮箱",
    ]

    private static let separators = #"\s+[-–—|·•]\s+"#

    /// The capture comes from a mail or chat window: a native messaging app, or a browser (or an
    /// unknown app) whose title shows one.
    package static func isMessaging(bundleID: String?, windowTitle: String?) -> Bool {
        let id = bundleID?.lowercased()
        if let id, AssistPrivacy.messagingHosts.contains(where: { $0.lowercased() == id }) || moreMessagingHosts.contains(id) {
            return true
        }
        guard let title = windowTitle, id.map(showsSites) ?? true else { return false }
        return titleShowsMessaging(title)
    }

    /// A browser or a browser's web app (its title names the site).
    package static func showsSites(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return browsers.contains(id) || webAppPrefixes.contains { id.hasPrefix($0) }
    }

    /// A webmail / web chat title: a segment that is one of `webMessagingSegments`, starts with
    /// "Inbox" / "收件箱", or is an e-mail address.
    package static func titleShowsMessaging(_ title: String) -> Bool {
        let flat = OCRPostProcess.cleanLine(title)
        guard !flat.isEmpty else { return false }
        let segments = flat.replacingOccurrences(of: separators, with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
        for raw in segments {
            let seg = raw.lowercased().replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            if webMessagingSegments.contains(seg) { return true }
            if seg.hasPrefix("inbox") || seg.hasPrefix("收件箱") { return true }
            if seg.range(of: #"^[^\s@]+@[^\s@]+\.[a-z]{2,}$"#, options: .regularExpression) != nil { return true }
        }
        return false
    }
}

extension ExplainContext {
    /// The privacy verdict for a turn about this context, captured from `hostBundleID` with
    /// `windowTitle` (nil: inside PaperDeck / exact text with no window): the located paper's
    /// policy and provenance (`AssistPrivacy`), plus `.messagingHost` for a mail / chat window —
    /// native or in a browser. A never-AI paper stays blocked. When the paper's inputs couldn't
    /// be read (`privacyUnchecked`), the caller must not send without asking.
    package func privacy(hostBundleID: String?, windowTitle: String?) -> AssistPrivacy.Verdict {
        let base = AssistPrivacy.verdict(policy: policy, aiNote: aiNote, provenance: provenance, hostBundleID: hostBundleID)
        guard MailWindow.isMessaging(bundleID: hostBundleID, windowTitle: windowTitle) else { return base }
        switch base {
        case .blocked:
            return .blocked
        case .ok:
            return .confirm([.messagingHost])
        case .confirm(let reasons):
            let all = Set(reasons).union([.messagingHost])
            return .confirm(AssistPrivacy.Reason.allCases.filter(all.contains))
        }
    }
}

/// Who was on screen under a capture (phase-3 fixes F1 / F2): every window that shows part of it,
/// sampled on a grid front to back — a box over a Mail window's corner counts, a window hidden
/// behind another doesn't — with PaperDeck's own windows and the papers they show; for text triggers
/// (Services, the clipboard) the frontmost window and the app the text was copied in. Local only:
/// the privacy check reads it; nothing here is sent, logged or stored. Pure — the App reads the
/// window list (`WindowTitleReader.surroundings`), tests feed entries.
package struct CaptureSurroundings: Sendable, Equatable {
    /// What one of PaperDeck's own windows shows.
    package enum Shows: Sendable, Equatable {
        /// The built-in reader: this paper, at this physical page (1-based; nil: unknown).
        case reader(paperID: String, page: Int?)
        /// Other paper content (the library's inspector and selection, an Ask window): these papers.
        case papers([String])
        /// PaperDeck's own mail inbox (the library's Mail section: e-mail cards and a message's full
        /// text): a mail window like any other — it asks first (phase-3 fixes, lead integration).
        case mail
    }

    /// One window (or app) that shows part of the capture.
    package struct Host: Sendable, Equatable {
        package var bundleID: String?
        /// Its title (with Screen Recording only): the webmail check and locating; never sent.
        package var title: String?
        /// Set for PaperDeck's own windows that show papers.
        package var shows: Shows?

        package init(bundleID: String?, title: String? = nil, shows: Shows? = nil) {
            self.bundleID = bundleID; self.title = title; self.shows = shows
        }

        /// A mail or chat window (native, in a browser, a notification banner, PaperDeck's own inbox).
        package var isMessaging: Bool {
            if case .mail? = shows { return true }
            return MailWindow.isMessaging(bundleID: bundleID, windowTitle: title)
        }
    }

    /// The windows showing part of the capture, each once (in the order the samples met them).
    package var hosts: [Host]
    /// Row-major samples over the region (`columns` × `rows`): the indices in `hosts` of what is
    /// visible at each. Empty for text triggers: every host counts.
    package var grid: [[Int]]
    package var columns: Int
    package var rows: Int
    /// The host under the capture's point (the click, else the region's centre).
    package var primary: Int?

    package init(hosts: [Host], grid: [[Int]] = [], columns: Int = 0, rows: Int = 0, primary: Int? = nil) {
        self.hosts = hosts; self.grid = grid; self.columns = columns; self.rows = rows; self.primary = primary
    }

    /// Samples per side of a region (12 × 12: a window showing more than about 1/12 of the box in
    /// either direction is seen; the window under the point always is).
    package static let samples = 12
    /// Windows at or above this layer (the Dock, menus, status items, banners, other apps'
    /// overlays) never hide what is under them, but are seen themselves.
    package static let overlayLayer = 20
    /// The screen saver's layer: Explain's own overlay and anything above it are never part of a capture.
    package static let screenSaverLayer = 1000

    /// The host under the point.
    package var primaryHost: Host? { primary.flatMap { hosts.indices.contains($0) ? hosts[$0] : nil } }

    /// A mail or chat window shows part of the capture.
    package var showsMessaging: Bool { hosts.contains(where: \.isMessaging) }

    /// PaperDeck's reader under the capture's point: its paper and page (the capture's match).
    package var reader: (paperID: String, page: Int?)? {
        guard case .reader(let id, let page)? = primaryHost?.shows else { return nil }
        return (id, page)
    }

    /// Every paper PaperDeck's own windows show in the capture (each paper's AI policy applies), in order.
    package var shownPaperIDs: [String] {
        var out: [String] = []
        for h in hosts {
            switch h.shows {
            case .reader(let id, _)?: if !out.contains(id) { out.append(id) }
            case .papers(let ids)?: for id in ids where !out.contains(id) { out.append(id) }
            case .mail?, nil: break
            }
        }
        return out
    }

    /// Only the part of the capture inside `unit` (fractions of the region, top-left origin): the
    /// hosts visible at the samples inside it — at the sample nearest its centre when none is. A
    /// clicked paragraph sends only its own crop, so only the windows under that crop count. Text
    /// triggers (no grid) are returned unchanged.
    package func restricted(toUnit unit: CGRect) -> CaptureSurroundings {
        guard columns > 0, rows > 0, grid.count == columns * rows else { return self }
        let r = unit.standardized
        var keep = Set<Int>()
        var nearest: (d: CGFloat, i: Int)?
        for row in 0..<rows {
            for col in 0..<columns {
                let i = row * columns + col
                let p = CGPoint(x: (CGFloat(col) + 0.5) / CGFloat(columns), y: (CGFloat(row) + 0.5) / CGFloat(rows))
                if r.contains(p) { keep.formUnion(grid[i]) }
                let d = hypot(p.x - r.midX, p.y - r.midY)
                if nearest == nil || d < nearest!.d { nearest = (d, i) }
            }
        }
        if keep.isEmpty, let n = nearest { keep.formUnion(grid[n.i]) }
        if let primary { keep.insert(primary) }
        let kept = hosts.indices.filter(keep.contains)
        let remap = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        return CaptureSurroundings(hosts: kept.map { hosts[$0] }, grid: grid.map { $0.compactMap { remap[$0] } },
                                   columns: columns, rows: rows, primary: primary.flatMap { remap[$0] })
    }

    /// The surroundings of `region` (global Quartz points) from the window list's `entries` (front
    /// to back): at each sample the front-most normal window (layers below `overlayLayer`) and every
    /// overlay-layer window there; `point` (default: the centre) names the primary window — the
    /// front-most normal one, 40 pt or larger, like `WindowList.window(at:)`. `excluding`: Explain's
    /// own overlay and panels. PaperDeck's other windows (`ownPID`) are kept, with what `own` says
    /// they show — the capture includes them, so their papers' policies apply.
    package static func make(region: CGRect, point: CGPoint? = nil, entries: [WindowList.Entry], excluding: Set<CGWindowID>,
                             ownPID: Int32, ownBundleID: String?, own: [CGWindowID: Shows],
                             bundleID: (Int32) -> String?, samples: Int = CaptureSurroundings.samples) -> CaptureSurroundings {
        let r = region.standardized
        let candidates = entries.filter { e in
            !excluding.contains(e.windowID) && e.alpha > 0.01 && e.layer < screenSaverLayer
                && e.bounds.width >= 8 && e.bounds.height >= 8 && e.bounds.intersects(r)
        }
        var hosts: [Host] = []
        var indexOf: [CGWindowID: Int] = [:]
        func index(_ e: WindowList.Entry) -> Int {
            if let i = indexOf[e.windowID] { return i }
            let mine = e.ownerPID == ownPID
            hosts.append(Host(bundleID: mine ? ownBundleID : bundleID(e.ownerPID), title: e.title, shows: mine ? own[e.windowID] : nil))
            indexOf[e.windowID] = hosts.count - 1
            return hosts.count - 1
        }
        func visible(at p: CGPoint) -> [Int] {
            var out: [Int] = []
            for e in candidates where e.bounds.contains(p) {
                out.append(index(e))
                if e.layer < overlayLayer { break }             // a normal window hides what is behind it
            }
            return out
        }
        let n = max(samples, 1)
        let columns = r.width > 0 ? n : 1, rows = r.height > 0 ? n : 1
        var grid: [[Int]] = []
        for row in 0..<rows {
            for col in 0..<columns {
                grid.append(visible(at: CGPoint(x: r.minX + (CGFloat(col) + 0.5) * r.width / CGFloat(columns),
                                                y: r.minY + (CGFloat(row) + 0.5) * r.height / CGFloat(rows))))
            }
        }
        let at = point ?? CGPoint(x: r.midX, y: r.midY)
        let primary = candidates.first { $0.layer == 0 && $0.bounds.contains(at) && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
            .map(index)
        return CaptureSurroundings(hosts: hosts, grid: grid, columns: columns, rows: rows, primary: primary)
    }

    /// A text trigger's surroundings (Services, the clipboard): these hosts all count; the first is primary.
    package static func text(_ hosts: [Host]) -> CaptureSurroundings? {
        var unique: [Host] = []
        for h in hosts where !unique.contains(h) { unique.append(h) }
        return unique.isEmpty ? nil : CaptureSurroundings(hosts: unique, primary: 0)
    }
}

/// How a turn's privacy verdict is put together from everything its capture showed (F1 / F2): the
/// located paper's verdict (the engine's), the verdict of every paper PaperDeck's own windows show
/// in the capture, and `.messagingHost` when a mail or chat window — the capture's own host, any
/// window in its region, the app the text was copied in — shows part of it. Pure.
package enum ExplainPrivacyRules {
    /// The papers whose policy applies besides `match` (PaperDeck's own windows in the capture).
    package static func shownPapers(_ s: CaptureSurroundings?, besides match: String?) -> [String] {
        (s?.shownPaperIDs ?? []).filter { $0.lowercased() != match?.lowercased() }
    }

    /// A mail or chat window shows part of the capture: its host app / window, or any surrounding one.
    package static func showsMessaging(_ capture: ExplainCapture, surroundings: CaptureSurroundings?) -> Bool {
        MailWindow.isMessaging(bundleID: capture.hostBundleID, windowTitle: capture.windowTitle)
            || (surroundings?.showsMessaging ?? false)
    }

    /// The verdicts as one: any unreadable (nil) → nil, nothing is sent (fail closed); any never-AI
    /// → blocked; else every confirmation reason (in `Reason.allCases` order), with
    /// `.messagingHost` when `messaging`.
    package static func combine(_ verdicts: [AssistPrivacy.Verdict?], messaging: Bool) -> AssistPrivacy.Verdict? {
        var reasons = Set<AssistPrivacy.Reason>()
        if messaging { reasons.insert(.messagingHost) }
        var blocked = false
        for v in verdicts {
            switch v {
            case nil: return nil
            case .blocked?: blocked = true
            case .confirm(let rs)?: reasons.formUnion(rs)
            case .ok?: break
            }
        }
        if blocked { return .blocked }
        let ordered = AssistPrivacy.Reason.allCases.filter(reasons.contains)
        return ordered.isEmpty ? .ok : .confirm(ordered)
    }
}
