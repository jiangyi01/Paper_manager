import Foundation

/// `paperdeck://` URLs used by notifications, the widget and the menu bar.
/// Parsing is strict: unknown hosts, malformed ids or extra path segments → nil.
public enum DeepLink: Equatable, Sendable {
    case today
    case paper(id: String)          // open the detail view
    case openPDF(id: String)        // open the PDF in the reader app
    case dropzone                   // arm the floating drop panel
    case settings(tab: String?)
    case mail(id: String?)          // Mail inbox; with an id, that email's card is selected
    case debugRemind(inSeconds: Int)   // only honoured when `debugURLs` is on
    case debugPending
    case help(topic: String?)       // paperdeck://help[/<topic>] — Help Center (topic ^[a-z0-9-]{1,48}$)
    case setup                      // paperdeck://setup — Setup Assistant

    public static let scheme = "paperdeck"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        switch (host, parts.count) {
        case ("today", 0): self = .today
        case ("dropzone", 0): self = .dropzone
        case ("paper", 1) where DeepLink.isValidID(parts[0]): self = .paper(id: parts[0].lowercased())
        case ("open", 1) where DeepLink.isValidID(parts[0]): self = .openPDF(id: parts[0].lowercased())
        case ("mail", 0): self = .mail(id: nil)
        case ("mail", 1) where DeepLink.isValidID(parts[0]): self = .mail(id: parts[0].lowercased())
        case ("settings", 0): self = .settings(tab: nil)
        case ("settings", 1): self = .settings(tab: parts[0])
        // Help Center and Setup Assistant: navigation only (no deep link ever changes a setting).
        case ("help", 0): self = .help(topic: nil)
        case ("help", 1) where DeepLink.isValidTopic(parts[0]): self = .help(topic: parts[0])
        case ("setup", 0): self = .setup
        case ("debug", 1) where parts[0] == "pending": self = .debugPending
        case ("debug", 1) where parts[0] == "remind":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let secs = q?.first(where: { $0.name == "in" })?.value.flatMap(Int.init) ?? 60
            self = .debugRemind(inSeconds: max(5, min(secs, 3600)))
        default: return nil
        }
    }

    public var url: URL {
        let s: String
        switch self {
        case .today: s = "paperdeck://today"
        case .paper(let id): s = "paperdeck://paper/\(id)"
        case .openPDF(let id): s = "paperdeck://open/\(id)"
        case .dropzone: s = "paperdeck://dropzone"
        case .settings(let tab): s = tab.map { "paperdeck://settings/\($0)" } ?? "paperdeck://settings"
        case .mail(let id): s = id.map { "paperdeck://mail/\($0)" } ?? "paperdeck://mail"
        case .debugRemind(let secs): s = "paperdeck://debug/remind?in=\(secs)"
        case .debugPending: s = "paperdeck://debug/pending"
        case .help(let topic): s = topic.map { "paperdeck://help/\($0)" } ?? "paperdeck://help"
        case .setup: s = "paperdeck://setup"
        }
        return URL(string: s)!
    }

    /// Help topic ids (`paperdeck://help/<topic>`): lowercase letters, digits and dashes, 1–48
    /// characters. Anything else (upper case, dots, `..`, longer) is not a topic.
    public static func isValidTopic(_ s: String) -> Bool {
        (1...48).contains(s.utf8.count) && s.utf8.allSatisfy { c in
            (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D
        }
    }

    /// Paper and mail ids are lowercase UUID strings.
    public static func isValidID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: .regularExpression) != nil
    }
}
