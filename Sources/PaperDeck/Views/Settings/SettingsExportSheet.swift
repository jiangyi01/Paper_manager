import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig

/// Export Settings…: section checkboxes, the personal-data choices — the mailbox addresses (on: a
/// new Mac needs them; off leaves them out of accounts, account names and cloud folder names) and
/// the Crossref contact email (off) — then a `paperdeck.settings/1` file (`SettingsExporter` over
/// the allowlist — unknown keys, passwords and app passwords never leave). Writes
/// `transfer.lastExportedAt`.
struct SettingsExportSheet: View {
    let settings: SettingsStore
    let onClose: () -> Void

    /// The checkbox groups (Profile & institution are one).
    static let groups: [[SettingsSection]] = [
        [.profile, .organization], [.general], [.plan], [.ai], [.library], [.mailSenders], [.mailAccounts], [.panel],
    ]

    @State private var chosen = Set(SettingsSection.allCases)
    @State private var includePersonal = false
    @State private var includeAddresses = true
    @State private var working = false
    @State private var result: (kind: StatusKind, text: String)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.Transfer.exportTitle).font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Form {
                Section {
                    ForEach(Self.groups, id: \.self) { group in
                        Toggle(L.Transfer.sectionName(group[0]), isOn: binding(group))
                            .toggleStyle(.checkbox)
                    }
                    Toggle(L.Transfer.includeAddresses, isOn: $includeAddresses)
                        .toggleStyle(.checkbox)
                    if chosen.contains(.mailAccounts) {
                        NoteText(includeAddresses ? L.Transfer.accountsHaveAddresses : L.Transfer.addressesLeftOut,
                                 symbol: "person.crop.circle")
                    }
                    Toggle(L.Transfer.includePersonal, isOn: $includePersonal)
                        .toggleStyle(.checkbox)
                } footer: {
                    NoteText(L.Transfer.exportIntro, symbol: "lock.shield")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let result { StatusLine(result.kind, result.text).font(.callout).lineLimit(2) }
                Spacer()
                Button(L.cancel, role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    export()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(L.Transfer.exportButton) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || chosen.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 520)
    }

    private func binding(_ group: [SettingsSection]) -> Binding<Bool> {
        Binding {
            group.allSatisfy(chosen.contains)
        } set: { on in
            if on { chosen.formUnion(group) } else { chosen.subtract(group) }
        }
    }

    /// "PaperDeck 1.0 (27)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "PaperDeck \(v) (\(b))"
    }

    /// The file's bytes (the importer's `JSONDecoder` reads them back: default date coding).
    static func encode(_ bundle: SettingsBundle) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(bundle)
    }

    private func export() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = L.Transfer.defaultFileName(day)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = L.Transfer.saveMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        result = nil
        let domain = settings.persistedDomain
        let sections = chosen
        let personal = includePersonal
        let addresses = includeAddresses
        Task {
            let roots = await MailSettingsIO.cloudRoots(home: SharedPaths.realHome).roots
            let now = Date()
            let bundle = SettingsExporter.export(domain, sections: sections, includePersonal: personal,
                                                 includeAddresses: addresses, home: SharedPaths.realHome, roots: roots,
                                                 app: Self.appVersion, now: now)
            do {
                let data = try Self.encode(bundle)
                try await BlockingIO.run { try data.write(to: url, options: .atomic) }
                settings.markSettingsExported(at: now)
                result = (.ok, L.Transfer.exported(SettingsFormat.tildePath(url.path)))
            } catch {
                result = (.error, L.Transfer.exportFailed(error.localizedDescription))
            }
            working = false
        }
    }
}
