import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckShared

/// `BuildIdentity.resolve` (PORTABILITY_PLAN §2.11, §5.7): what `build_app.sh` stamps into the
/// staged Info.plists, and the fallbacks that keep a build with the script's defaults identical to
/// every earlier build (same defaults domain, keychain service, log subsystem, widget id).
@Suite("Build identity")
struct BuildIdentityTests {
    /// Today's literals, spelled out once.
    static let legacyBundle = BuildIdentity.defaultBundleID

    @Test func nothingStampedGivesTodaysConstants() {
        let id = BuildIdentity.resolve(info: nil, mainBundleID: nil)
        #expect(id.bundleID == Self.legacyBundle)
        #expect(id.widgetBundleID == Self.legacyBundle + ".widget")
        #expect(id.keychainService == Self.legacyBundle + ".mail")
        #expect(id.logSubsystem == Self.legacyBundle)
        #expect(id.signingIdentityName == nil)
        #expect(id.channel == .local)
        // An Info.plist without PD* keys (every build before this one) changes nothing either.
        let old: [String: Any] = ["CFBundleIdentifier": Self.legacyBundle, "CFBundleVersion": "27"]
        #expect(BuildIdentity.resolve(info: old, mainBundleID: Self.legacyBundle) == id)
        #expect(BuildIdentity.resolve(info: [:], mainBundleID: "") == id)
    }

    @Test func theScriptDefaultsStampTheSameIdentity() {
        // What `./build_app.sh` stamps with no configuration (`--print-config` shows the same).
        let stamped: [String: Any] = [
            "PDHostBundleIdentifier": Self.legacyBundle,
            "PDWidgetBundleIdentifier": Self.legacyBundle + ".widget",
            "PDKeychainService": Self.legacyBundle + ".mail",
            "PDSigningIdentity": BuildIdentity.defaultSigningIdentityName,
            "PDBuildChannel": "local",
        ]
        let id = BuildIdentity.resolve(info: stamped, mainBundleID: Self.legacyBundle)
        var expected = BuildIdentity.resolve(info: nil, mainBundleID: nil)
        expected.signingIdentityName = BuildIdentity.defaultSigningIdentityName
        #expect(id == expected)
    }

    @Test func theHostBundleIDWins() {
        let info: [String: Any] = ["PDHostBundleIdentifier": "org.example.paperdeck"]
        let id = BuildIdentity.resolve(info: info, mainBundleID: "org.example.other")
        #expect(id.bundleID == "org.example.paperdeck")
        #expect(id.widgetBundleID == "org.example.paperdeck.widget")
        #expect(id.keychainService == "org.example.paperdeck.mail")
        #expect(id.logSubsystem == "org.example.paperdeck")
        // The widget extension reads the same stamp (its own id is the host's + ".widget").
        #expect(BuildIdentity.resolve(info: info, mainBundleID: "org.example.paperdeck.widget") == id)
    }

    @Test func aWidgetMainBundleIDIsStripped() {
        let id = BuildIdentity.resolve(info: nil, mainBundleID: "org.example.paperdeck.widget")
        #expect(id.bundleID == "org.example.paperdeck")
        #expect(id.widgetBundleID == "org.example.paperdeck.widget")
        #expect(BuildIdentity.resolve(info: nil, mainBundleID: "org.example.paperdeck").bundleID == "org.example.paperdeck")
    }

    @Test func keychainServiceAndChannelAreRead() {
        let info: [String: Any] = ["PDKeychainService": "org.example.mail-items", "PDBuildChannel": "distribution",
                                   "PDSigningIdentity": "adhoc"]
        let id = BuildIdentity.resolve(info: info, mainBundleID: "org.example.paperdeck")
        #expect(id.keychainService == "org.example.mail-items")
        #expect(id.channel == .distribution)
        #expect(id.signingIdentityName == "adhoc")
        #expect(id.bundleID == "org.example.paperdeck")
        #expect(BuildIdentity.resolve(info: ["PDBuildChannel": "Distribution"], mainBundleID: nil).channel == .distribution)
    }

    @Test func malformedValuesFallBack() {
        // An unknown channel, blank strings and ids that aren't reverse-DNS never produce an empty
        // or odd identity.
        let info: [String: Any] = ["PDHostBundleIdentifier": "not a bundle id", "PDKeychainService": "  ",
                                   "PDBuildChannel": "beta", "PDSigningIdentity": ""]
        let id = BuildIdentity.resolve(info: info, mainBundleID: nil)
        #expect(id == BuildIdentity.resolve(info: nil, mainBundleID: nil))
        #expect(BuildIdentity.resolve(info: ["PDHostBundleIdentifier": 42], mainBundleID: nil).bundleID == Self.legacyBundle)
        #expect(BuildIdentity.resolve(info: nil, mainBundleID: "single").bundleID == Self.legacyBundle)
        #expect(BuildIdentity.resolve(info: nil, mainBundleID: ".widget").bundleID == Self.legacyBundle)
    }

    /// portability-cli-8: a custom `PAPERDECK_WIDGET_ID` (`PDWidgetBundleIdentifier`) is the widget
    /// id Settings ▸ Widget, Help and `--doctor` query; the default stays `<bundle id>.widget`.
    @Test func aStampedWidgetIDUnderTheBundleIDIsUsed() {
        let info: [String: Any] = ["PDHostBundleIdentifier": "org.example.paperdeck",
                                   "PDWidgetBundleIdentifier": "org.example.paperdeck.desk"]
        let id = BuildIdentity.resolve(info: info, mainBundleID: "org.example.paperdeck")
        #expect(id.widgetBundleID == "org.example.paperdeck.desk")
        #expect(id.bundleID == "org.example.paperdeck" && id.keychainService == "org.example.paperdeck.mail")
        // The widget extension itself (its own id is the custom one) resolves the same identity.
        #expect(BuildIdentity.resolve(info: info, mainBundleID: "org.example.paperdeck.desk") == id)
        // Deeper labels are fine too (build_app.sh accepts any reverse-DNS id under '<bundle id>.').
        let deep = BuildIdentity.resolve(info: ["PDHostBundleIdentifier": "org.example.paperdeck",
                                                "PDWidgetBundleIdentifier": "org.example.paperdeck.widgets.desk"], mainBundleID: nil)
        #expect(deep.widgetBundleID == "org.example.paperdeck.widgets.desk")
        // The script's defaults stamp `<bundle id>.widget`: identical to the unstamped identity.
        let defaults: [String: Any] = ["PDHostBundleIdentifier": Self.legacyBundle,
                                       "PDWidgetBundleIdentifier": Self.legacyBundle + ".widget"]
        #expect(BuildIdentity.resolve(info: defaults, mainBundleID: Self.legacyBundle) == BuildIdentity.resolve(info: nil, mainBundleID: nil))
    }

    @Test func aWidgetIDOutsideTheBundleIDIsIgnored() {
        for bad in ["org.other.widget", "org.example.paperdeck", "org.example.paperdeck.", "org.example.paperdecks.widget",
                    "org.example.paperdeck..x", "org.example.paperdeck.de sk", "  ", ""] {
            let info: [String: Any] = ["PDHostBundleIdentifier": "org.example.paperdeck", "PDWidgetBundleIdentifier": bad]
            #expect(BuildIdentity.resolve(info: info, mainBundleID: nil).widgetBundleID == "org.example.paperdeck.widget", "\(bad)")
        }
        #expect(BuildIdentity.resolve(info: ["PDWidgetBundleIdentifier": 7], mainBundleID: nil).widgetBundleID == Self.legacyBundle + ".widget")
        #expect(BuildIdentity.isValidWidgetID("org.example.paperdeck.desk", bundleID: "org.example.paperdeck"))
        #expect(!BuildIdentity.isValidWidgetID("org.example.paperdeck", bundleID: "org.example.paperdeck"))
    }

    @Test func bundleIDValidationMatchesTheBuildScript() {
        // build_app.sh: ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$
        for good in ["org.example.paperdeck", "a.b", "edu.lab-7.Paper-Deck"] { #expect(BuildIdentity.isValidBundleID(good), "\(good)") }
        for bad in ["", "paperdeck", "org..paperdeck", ".org.example", "org.example.", "org.exa mple", "org.example_x", "org.ex/ample"] {
            #expect(!BuildIdentity.isValidBundleID(bad), "\(bad)")
        }
    }

    @Test func everyDerivedValueFollowsTheRunningIdentity() {
        // The values the app and the engine use are the resolved identity's (the same strings as
        // before for a default build): defaults domain, widget id, keychain service, log subsystem.
        let id = BuildIdentity.current
        #expect(SharedPaths.bundleID == id.bundleID)
        #expect(SharedPaths.widgetBundleID == id.widgetBundleID)
        #expect(KeychainMailSecretStore.defaultService == id.keychainService)
        #expect(Log.subsystem == id.logSubsystem)
        #expect(id == BuildIdentity.resolve(info: Bundle.main.infoDictionary, mainBundleID: Bundle.main.bundleIdentifier))
    }
}
