import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig

/// The Power Automate flow (work / school Microsoft 365 → OneDrive `.eml` → watched folder), step by
/// step with copyable values — exactly the flow the user builds by hand: V3 trigger with a From
/// allowlist → Export email (V2) with the trigger's Message Id → OneDrive for Business Create file
/// (Folder Path, the fx File Name expression, File Content = body('Export_email_(V2)')) — plus the
/// ready-made import package from Core (`PowerAutomatePackage`, the same three steps). The From
/// value is generated from the sender list.
struct MailPowerAutomateGuide: View {
    let senders: [SenderRule]
    /// The watched local folder; its path inside OneDrive becomes the flow's Folder Path.
    var localFolder: String? = nil
    /// Opened from a 「不是完整的邮件」 hint: the File Content step is highlighted.
    var highlightFileContent = false
    @State private var packageResult: (kind: StatusKind, text: String)?
    @State private var packageName: String?
    @State private var copiedAll = false

    /// What goes into the fx (Insert expression) box: the package's expressions without the
    /// workflow-language `@` — File Name = UTC timestamp + GUID (never the subject).
    static let fileNameExpression = fx(PowerAutomatePackage.fileNameExpression)
    static let fileContentExpression = fx(PowerAutomatePackage.exportBodyExpression)
    static let defaultFolderPath = PowerAutomatePackage.defaultFolderPath

    private static func fx(_ expression: String) -> String {
        expression.hasPrefix("@") ? String(expression.dropFirst()) : expression
    }
    static let defaultPortalURL = URL(string: "https://make.powerautomate.com")!

    /// The organization's Power Automate portal (an https link from its preset / custom entry),
    /// else make.powerautomate.com.
    static func portalURL(_ org: OrganizationProfile) -> URL {
        guard let url = org.mail.powerAutomatePortal, url.scheme?.lowercased() == "https" else { return defaultPortalURL }
        return url
    }

    /// `~/Library/CloudStorage/<OneDrive root>/Lab/PaperDeck Mail` → `/Lab/PaperDeck Mail` (the path
    /// inside the cloud root, `CloudRootLocator.split`; also the legacy `~/OneDrive - <Org>`).
    static func oneDrivePath(_ local: String?, home: URL = SharedPaths.realHome) -> String {
        guard let local, !local.isEmpty,
              let split = CloudRootLocator.split((local as NSString).expandingTildeInPath, home: home) else { return defaultFolderPath }
        let inside = split.relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return inside.isEmpty ? defaultFolderPath : "/" + inside
    }

    private var folderPath: String { Self.oneDrivePath(localFolder) }
    private var portalURL: URL { Self.portalURL(L.org) }

    private var plan: PowerAutomatePackage.SenderPlan {
        PowerAutomatePackage.senderPlan(PowerAutomatePackage.senders(from: senders))
    }

    /// Exact addresses joined by ';' (what the V3 trigger's From field accepts).
    private var fromValue: String { plan.addresses.joined(separator: ";") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoteText(L.MailPref.paIntro)
            Text(L.MailPref.paManualTitle).font(.subheadline.weight(.semibold))
            step(1, L.MailPref.paStep1) {
                Button(L.MailPref.openPowerAutomate) { NSWorkspace.shared.open(portalURL) }
                    .controlSize(.small)
            }
            step(2, L.MailPref.paStep2) {
                fromBlock
            }
            step(3, L.MailPref.paStep3) { EmptyView() }
            step(4, L.MailPref.paStep4) {
                labeled(L.MailPref.paFolderPath, folderPath)
            }
            step(5, L.MailPref.paStep5) {
                labeled(L.MailPref.paFileName, Self.fileNameExpression)
            }
            step(6, L.MailPref.paStep6) {
                labeled(L.MailPref.paFileContent, Self.fileContentExpression)
                StatusLine(.warning, L.MailPref.paFileContentWarning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(highlightFileContent ? 8 : 0)
            .background {
                if highlightFileContent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.10))
                }
            }
            step(7, L.MailPref.paStep7) { EmptyView() }
            HStack {
                Button(copiedAll ? L.Pref.copied : L.MailPref.copyAllSteps) { copyAll() }
                Spacer()
            }
            .controlSize(.small)
            Divider()
            packageBlock
        }
        .padding(.vertical, 4)
    }

    // MARK: Package

    private var packageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.MailPref.paPackageTitle).font(.subheadline.weight(.semibold))
                    Text(L.MailPref.paPackageHint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L.MailPref.savePackage) { savePackage() }
                    .controlSize(.small)
            }
            if let packageResult { StatusLine(packageResult.kind, packageResult.text).font(.callout) }
            if let packageName {
                Text(PowerAutomatePackage.importInstructions(fileName: packageName, folderPath: folderPath, lang: L.lang))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Steps

    private func step<Extra: View>(_ n: Int, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                extra()
            }
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            MailCopyBox(value: value)
        }
    }

    @ViewBuilder
    private var fromBlock: some View {
        let p = plan
        if p.addresses.isEmpty {
            NoteText(p.domainRules.isEmpty ? L.MailPref.paFromNoSenders : L.MailPref.paFromOnlyDomains(p.domainRules),
                     symbol: "exclamationmark.triangle")
        } else {
            labeled(L.MailPref.paFromLabel(p.addresses.count), fromValue)
            if !p.domainRules.isEmpty {
                NoteText(L.MailPref.paFromDomains(p.domainRules), symbol: "exclamationmark.triangle")
            }
        }
        if !p.ignored.isEmpty {
            NoteText(L.MailPref.paFromIgnored(p.ignored), symbol: "questionmark.circle")
        }
    }

    // MARK: Actions

    /// The whole guide as plain text (for a note / an email to yourself).
    private var allStepsText: String {
        let from = fromValue.isEmpty ? L.MailPref.paFromEmptyText : fromValue
        return [
            L.MailPref.paManualTitle,
            "1. " + L.MailPref.paStep1 + " " + portalURL.absoluteString,
            "2. " + L.MailPref.paStep2 + "\n   From: " + from,
            "3. " + L.MailPref.paStep3,
            "4. " + L.MailPref.paStep4 + "\n   " + L.MailPref.paFolderPath + ": " + folderPath,
            "5. " + L.MailPref.paStep5 + "\n   " + L.MailPref.paFileName + ": " + Self.fileNameExpression,
            "6. " + L.MailPref.paStep6 + "\n   " + L.MailPref.paFileContent + ": " + Self.fileContentExpression
                + "\n   " + L.MailPref.paFileContentWarning,
            "7. " + L.MailPref.paStep7,
        ].joined(separator: "\n")
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allStepsText, forType: .string)
        copiedAll = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedAll = false
        }
    }

    private func savePackage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PowerAutomatePackage.suggestedFileName()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.message = L.MailPref.savePackageMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let list = PowerAutomatePackage.senders(from: senders)
        let folder = folderPath
        Task {
            do {
                try await MailSettingsIO.writeFlowPackage(senders: list, folderPath: folder, to: url)
                packageName = url.lastPathComponent
                packageResult = (.ok, L.MailPref.packageSaved(SettingsFormat.tildePath(url.path)))
            } catch {
                packageName = nil
                packageResult = (.error, L.MailPref.packageFailed(String(describing: error)))
            }
        }
    }
}

/// The guide as its own sheet (Settings ▸ Mail account row / the inbox's 「不是完整的邮件」 notice):
/// what is wrong, then the steps with File Content highlighted.
struct MailPowerAutomateGuideSheet: View {
    let state: AppState
    let account: MailAccount?
    let notEmailFiles: Int
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.MailPref.guideTitle).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Form {
                if notEmailFiles > 0 {
                    Section {
                        StatusLine(.warning, MailSyncText.notEmailFiles(notEmailFiles, L.lang))
                            .fixedSize(horizontal: false, vertical: true)
                    } header: {
                        Text(L.MailPref.guideFixHeader)
                    }
                }
                Section {
                    MailPowerAutomateGuide(senders: state.settings.mailSenders, localFolder: account?.folderPath,
                                           highlightFileContent: notEmailFiles > 0)
                } header: {
                    Text(L.MailPref.paGuideSection)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(L.MailPref.done) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 700)
    }
}
