import Foundation
import PaperDeckCore

/// The bilingual Help Center content: one file per group, each a list of topics (Swift literals —
/// no resource bundle), built once. Every topic id of `GuideTopicID.catalog` (PORTABILITY_PLAN §3.8)
/// has exactly one topic; the steps of the tutorials in §3.4 are normative.
///
/// Rules the content follows (checked by `GuideLint` and the content tests):
/// - English and Chinese for every title, summary, keyword, step and manual reason;
/// - no institution, person, address or home path — wording is the same for every organization;
///   what differs per institution comes from the configuration at run time;
/// - links only to the official sites in `GuideLinks` (https); commands never contain `/Users/`
///   or a real-looking address;
/// - at most one `.manual` step per topic; `.impliedBy` points to a later step (0-based index);
/// - troubleshooting entries carry a `diagnosis` whose problem state means "applies now".
package enum GuideContent {
    /// The month the content was last checked against the app and the third-party sites.
    static let reviewed = "2026-10"

    static func t(_ en: String, _ zh: String) -> LocalizedText { LocalizedText(en: en, zh: zh) }

    /// An official page (`GuideLinks` allowlists the host).
    static func link(_ s: String) -> GuideAction { .openURL(URL(string: s)!) }

    /// The app as installed by default, for Terminal commands (never a home path).
    static let appBinary = "/Applications/PaperDeck.app/Contents/MacOS/PaperDeck"

    /// A shell expression for the installed app's bundle id. Commands never spell the id out: the
    /// same text then fits any build, and the docs generated from these topics name no build.
    static let bundleIDOfInstalledApp = "defaults read /Applications/PaperDeck.app/Contents/Info CFBundleIdentifier"
}
