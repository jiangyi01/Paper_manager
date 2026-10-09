import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// `--render` pages of Settings ▸ Mail: the full tab, the add-account chooser, the Power
/// Automate and Gmail forms, the Power Automate guide, the sender sheet and the AI sample — plus
/// Settings ▸ Profile and the Power Automate form of an institution-neutral profile next to
/// scratch cloud roots (`portabilityPages`).
/// Demo accounts / senders go into the render suite only (never the user's settings); IMAP
/// secrets are in memory, the engine's mail loop never runs, nothing connects anywhere.
enum MailRenders {
    /// The demo work tenant's OneDrive root (under the scratch `--root` only).
    static let demoTenantRoot = "OneDrive-Contoso"
    /// The roots of the institution-neutral Power Automate render: a work tenant and a personal
    /// OneDrive (which the Power Automate route must never suggest).
    static let scratchRoots = ["OneDrive-Contoso University", ["OneDrive", "Personal"].joined(separator: "-")]

    static func seedDemo(_ settings: SettingsStore, root: URL) {
        let cloud = root.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let roots = CloudRootLocator.classify(names: [demoTenantRoot], cloudStorage: cloud)
        let folder = CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: roots, existingMailFolders: [],
                                                      org: settings.config.organization, lastChoice: nil, home: root)
            ?? cloud.appendingPathComponent(demoTenantRoot, isDirectory: true)
                .appendingPathComponent("PaperDeck Mail", isDirectory: true)
        settings.mailAccounts = [
            MailAccount(id: "demo-work", kind: .folder, displayName: "Work (Power Automate)", folderPath: folder.path,
                        source: MailSourceID.m365PowerAutomate.rawValue),
            MailAccount(id: "demo-gmail", kind: .imap, displayName: "Gmail — paperdeck.alerts@gmail.com", imapPreset: .gmail,
                        host: "imap.gmail.com", port: 993, username: "paperdeck.alerts@gmail.com", mailbox: "PaperDeck"),
        ]
        settings.mailSenders = [
            SenderRule(id: "demo-advisor", pattern: "jsmith@example.edu", label: "Prof. Jane Smith", kind: .advisor,
                       defaultCategory: nil, autoMerge: false),
            SenderRule(id: "demo-lab", pattern: "lab.manager@example.edu", label: "Lab manager", kind: .person, aiPolicy: .never),
        ] + SenderRule.presets.filter { ["preset-google-scholar", "preset-biorxiv", "preset-nature"].contains($0.id) }
        settings.mailCriteria = ReadingCriteria(includeKeywords: ["spatial transcriptomics", "neocortex"],
                                                excludeKeywords: ["retracted"],
                                                researchInterests: "Single-cell and spatial omics of the developing brain; AI agents for biology.")
        settings.mailEnabled = true
        // Renders never reach the engine's mail loop (no settingsDidChange → no triage tick in --root).
        settings.onMailSettingsChange = { _ in }
    }

    static func render(state: AppState, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        let settings = state.settings
        try await PreviewRenderer.captureView(SettingsView(state: state, tab: .mail).frame(width: 640, height: 3000),
                                              size: NSSize(width: 640, height: 3000), appearance: appearance,
                                              png("settings-mail-full"))
        try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: nil, onClose: {}),
                                              size: NSSize(width: 600, height: 700), appearance: appearance,
                                              png("mail-add-account"))
        if let folderAccount = settings.mailAccounts.first(where: { $0.kind == .folder }) {
            try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: folderAccount, onClose: {}),
                                                  size: NSSize(width: 600, height: 700), appearance: appearance,
                                                  png("mail-account-powerautomate"))
        }
        if let gmail = settings.mailAccounts.first(where: { $0.kind == .imap }) {
            try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: gmail, onClose: {}),
                                                  size: NSSize(width: 600, height: 700), appearance: appearance,
                                                  png("mail-account-gmail"))
            // The server was edited: the saved app password must be typed again (never sent to the new host).
            var moved = gmail
            moved.host = "imap.example.org"
            try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: gmail, editedDraft: moved, onClose: {}),
                                                  size: NSSize(width: 600, height: 700), appearance: appearance,
                                                  png("mail-account-gmail-server-changed"))
        }
        try await PreviewRenderer.captureView(
            Form { Section { MailPowerAutomateGuide(senders: settings.mailSenders,
                                                    localFolder: settings.mailAccounts.first?.folderPath) } }.formStyle(.grouped)
                .frame(width: 600, height: 1500),
            size: NSSize(width: 600, height: 1500), appearance: appearance, png("mail-powerautomate-guide"))
        if let advisor = settings.mailSenders.first {
            try await PreviewRenderer.captureView(
                MailSenderRuleSheet(rule: advisor, existing: settings.mailSenders, categories: MailSettingsTab.categoryNames(state),
                                    onClose: { _ in }),
                size: NSSize(width: 560, height: 680), appearance: appearance, png("mail-sender-sheet"))
        }
        try await PreviewRenderer.captureView(MailTriageSampleSheet(state: state, onClose: {}),
                                              size: NSSize(width: 640, height: 700), appearance: appearance,
                                              png("mail-ai-sample"))
        try await portabilityPages(state: state, appearance: appearance, out: out, suffix: suffix,
                                   root: MailAddAccountSheet.detectionHome)
    }

    /// New pages of the portability work (reviewed on their own, not against the seeded baseline):
    /// Settings ▸ Profile, and — with an institution-neutral profile and the scratch cloud roots
    /// a work tenant's OneDrive root and a personal one under `root` — the add-account
    /// chooser and a new Power Automate form (it suggests the Contoso folder, never Personal).
    /// The render suite's configuration is restored afterwards. `root` must be the scratch
    /// `--root` (the roots are created inside it).
    static func portabilityPages(state: AppState, appearance: NSAppearance?, out: URL, suffix: String, root: URL) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        try await PreviewRenderer.captureView(SettingsView(state: state, tab: .profile).frame(width: 640, height: 1400),
                                              size: NSSize(width: 640, height: 1400), appearance: appearance,
                                              png("settings-profile"))
        // General (Help & Setup, Move to another Mac) and Library (Change…, Re-index): no CLI probes.
        for tab in [SettingsTab.general, .library] {
            try await PreviewRenderer.captureView(SettingsView(state: state, tab: tab).frame(width: 640, height: 1200),
                                                  size: NSSize(width: 640, height: 1200), appearance: appearance,
                                                  png("settings-\(tab.rawValue)-portability"))
        }
        let scratch = root.absoluteURL.resolvingSymlinksInPath().path
        guard !scratch.isEmpty, scratch != SharedPaths.realHome.resolvingSymlinksInPath().path else { return }
        let cloud = root.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let fm = FileManager.default
        var created: [URL] = []
        // Scratch fixture names only (the recognition logic is CloudRootLocator's).
        for name in scratchRoots {
            let dir = cloud.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: dir.path) else { continue }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            created.append(dir)
        }
        let config = state.settings.config
        let saved = (config.organizationID, config.fieldID)
        config.organizationID = OrganizationPresets.generic.id
        config.fieldID = FieldPresets.general.id
        defer {
            config.organizationID = saved.0
            config.fieldID = saved.1
            // Later pages see the scratch root as before.
            for dir in created { try? fm.removeItem(at: dir) }
        }
        try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: nil, onClose: {}),
                                              size: NSSize(width: 600, height: 900), appearance: appearance,
                                              png("mail-chooser-generic"))
        try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: nil, initialTemplate: .powerAutomate,
                                                                  onClose: {}),
                                              size: NSSize(width: 600, height: 700), appearance: appearance,
                                              png("mail-add-powerautomate-generic"))
        try await PreviewRenderer.captureView(SettingsView(state: state, tab: .profile).frame(width: 640, height: 1400),
                                              size: NSSize(width: 640, height: 1400), appearance: appearance,
                                              png("settings-profile-generic"))
    }
}
