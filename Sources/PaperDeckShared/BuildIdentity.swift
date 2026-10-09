import Foundation

/// Who this build is: bundle ids, keychain service, log subsystem, signing identity and channel.
/// `build_app.sh` stamps the values into the staged Info.plists (`PDHostBundleIdentifier`,
/// `PDKeychainService`, `PDSigningIdentity`, `PDBuildChannel`); without them every value is
/// derived from the bundle id, and without a bundle id from `defaultBundleID` — so a build made
/// with the script's defaults keeps the same defaults domain, keychain items, permissions and widget.
public struct BuildIdentity: Sendable, Equatable {
    public enum Channel: String, Sendable {
        case local          // built on this Mac (build instructions are shown)
        case distribution   // a packaged copy someone received
    }

    public static let defaultBundleID = "com.yijiang.paperdeck"
    public static let defaultSigningIdentityName = "PaperDeck Local Signing"

    /// The Info.plist keys `build_app.sh` stamps.
    public enum InfoKey {
        public static let hostBundleID = "PDHostBundleIdentifier"
        public static let keychainService = "PDKeychainService"
        public static let signingIdentity = "PDSigningIdentity"
        public static let channel = "PDBuildChannel"
    }

    /// The widget extension's id is the host's id plus this suffix (pkd requires the prefix).
    public static let widgetSuffix = ".widget"

    public var bundleID: String
    public var widgetBundleID: String
    public var keychainService: String
    public var logSubsystem: String
    /// `PDSigningIdentity`: the certificate name, or "adhoc"; nil = unknown (not stamped).
    public var signingIdentityName: String?
    /// `PDBuildChannel`, else `.local`.
    public var channel: Channel

    public init(bundleID: String, widgetBundleID: String, keychainService: String, logSubsystem: String,
                signingIdentityName: String?, channel: Channel) {
        self.bundleID = bundleID; self.widgetBundleID = widgetBundleID; self.keychainService = keychainService
        self.logSubsystem = logSubsystem; self.signingIdentityName = signingIdentityName; self.channel = channel
    }

    /// The identity of the running app (or widget). A bare binary (`.build/debug/PaperDeck`, the
    /// test runner) has no Info.plist of ours and resolves to the defaults.
    public static let current: BuildIdentity = resolve(info: Bundle.main.infoDictionary,
                                                       mainBundleID: Bundle.main.bundleIdentifier)

    /// Pure and testable. The bundle id is `PDHostBundleIdentifier`, else the main bundle id with
    /// ".widget" stripped (the widget extension reports its own id), else `defaultBundleID`. The
    /// widget id, keychain service and log subsystem derive from it; `PDKeychainService` overrides
    /// the service, `PDSigningIdentity` and `PDBuildChannel` are read as stamped. Malformed values
    /// are ignored (never a crash, never an empty id).
    public static func resolve(info: [String: Any]?, mainBundleID: String?) -> BuildIdentity {
        func text(_ key: String) -> String? {
            guard let s = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                return nil
            }
            return s
        }
        let host = text(InfoKey.hostBundleID).flatMap { isValidBundleID($0) ? $0 : nil }
        let main = mainBundleID.flatMap { raw -> String? in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = id.hasSuffix(widgetSuffix) ? String(id.dropLast(widgetSuffix.count)) : id
            return isValidBundleID(stripped) ? stripped : nil
        }
        var identity = derived(from: host ?? main ?? defaultBundleID)
        if let service = text(InfoKey.keychainService) { identity.keychainService = service }
        identity.signingIdentityName = text(InfoKey.signingIdentity)
        if let channel = text(InfoKey.channel).flatMap({ Channel(rawValue: $0.lowercased()) }) {
            identity.channel = channel
        }
        return identity
    }

    /// Reverse-DNS with at least two labels of letters, digits and hyphens (what `build_app.sh`
    /// accepts for `PAPERDECK_BUNDLE_ID`).
    public static func isValidBundleID(_ id: String) -> Bool {
        let labels = id.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
        }
    }

    /// The values a bundle id implies when nothing else is stamped.
    static func derived(from bundleID: String) -> BuildIdentity {
        BuildIdentity(bundleID: bundleID, widgetBundleID: bundleID + widgetSuffix, keychainService: bundleID + ".mail",
                      logSubsystem: bundleID, signingIdentityName: nil, channel: .local)
    }
}
