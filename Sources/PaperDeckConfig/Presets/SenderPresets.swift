import Foundation
import PaperDeckCore

/// One alert-sender preset. `verified == false`: the pattern hasn't been checked against a real
/// alert yet (shown under "More presets" with a hint to check the sender address).
package struct SenderPresetEntry: Sendable, Equatable {
    package var rule: SenderRule
    package var verified: Bool

    package init(rule: SenderRule, verified: Bool) {
        self.rule = rule; self.verified = verified
    }
}

/// Every alert-sender preset; a field suggests its verified `senderPresetIDs` first.
/// All presets are alert rules (AI `always`): the confidentiality guard and the mailing-list rule
/// (an alert rule triages only List-Id / List-Unsubscribe mail on its own) apply unchanged, so a
/// wrong domain does no harm. Ids are append-only.
package enum SenderPresetCatalog {
    /// Today's 9 presets (`SenderRule.presets`, verified) in today's order, then the new ones
    /// (not verified yet, PORTABILITY_PLAN §7.3 V12).
    package static let all: [SenderPresetEntry] =
        SenderRule.presets.map { SenderPresetEntry(rule: $0, verified: true) }
        + unverified.map { SenderPresetEntry(rule: SenderRule(id: $0.id, pattern: $0.pattern, label: $0.label, kind: .alert),
                                             verified: false) }

    private static let unverified: [(id: String, pattern: String, label: String)] = [
        ("preset-acm", "@acm.org", "ACM"),
        ("preset-ieee", "@ieee.org", "IEEE"),
        ("preset-openreview", "@openreview.net", "OpenReview"),
        ("preset-semantic-scholar", "@semanticscholar.org", "Semantic Scholar"),
        ("preset-aps", "@aps.org", "APS (Physical Review)"),
        ("preset-iop", "@ioppublishing.org", "IOP Publishing"),
        ("preset-acs", "@acs.org", "ACS Publications"),
        ("preset-rsc", "@rsc.org", "Royal Society of Chemistry"),
        ("preset-chemrxiv", "@chemrxiv.org", "ChemRxiv"),
        ("preset-science", "@aaas.org", "Science (AAAS)"),
        ("preset-pnas", "@pnas.org", "PNAS"),
        ("preset-springer", "@*.springernature.com", "Springer Nature"),
        ("preset-wiley", "@wiley.com", "Wiley"),
        ("preset-nejm", "@nejm.org", "NEJM"),
        ("preset-jama", "@jamanetwork.com", "JAMA Network"),
        ("preset-lancet", "@lancet.com", "The Lancet"),
        ("preset-ssrn", "@ssrn.com", "SSRN"),
        ("preset-nber", "@nber.org", "NBER"),
    ]

    package static func entry(id: String) -> SenderPresetEntry? { all.first { $0.rule.id == id } }

    /// The field's suggested presets, in the field's order: the verified ones ("Suggested for
    /// <field>"). The life-sciences field suggests exactly `SenderRule.presets`, in order.
    package static func suggested(for f: FieldPreset) -> [SenderRule] {
        f.senderPresetIDs.compactMap { entry(id: $0) }.filter(\.verified).map(\.rule)
    }

    /// Every other preset, in catalog order ("More presets"): the field's unverified ones included.
    package static func others(for f: FieldPreset) -> [SenderRule] {
        let suggestedIDs = Set(suggested(for: f).map(\.id))
        return all.map(\.rule).filter { !suggestedIDs.contains($0.id) }
    }
}
