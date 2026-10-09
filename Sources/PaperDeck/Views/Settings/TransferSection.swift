import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Settings ▸ General ▸ Move to another Mac: [Export Settings…] [Import Settings…]. A settings
/// file never holds a password or app password, and an import never turns AI reading or Mail on.
struct TransferSection: View {
    let settings: SettingsStore
    private enum Sheet: String, Identifiable { case export, `import`; var id: String { rawValue } }
    @State private var sheet: Sheet?

    var body: some View {
        Section {
            HStack {
                Button(L.Transfer.export) { sheet = .export }
                Button(L.Transfer.import) { sheet = .import }
                Spacer()
            }
            NoteText(L.Transfer.note, symbol: "lock.shield")
            if let last = settings.lastSettingsExport {
                Text(L.Transfer.lastExported(SettingsFormat.shortDateTime(last)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.Transfer.section)
                HelpButton(.moveToNewMac)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .export: SettingsExportSheet(settings: settings) { sheet = nil }
            case .import: SettingsImportSheet(settings: settings, fileURL: nil) { _ in sheet = nil }
            }
        }
    }
}

extension SettingsStore {
    /// `transfer.lastExportedAt`.
    var lastSettingsExport: Date? {
        persistedDomain.values[ConfigKeys.transferLastExportedAt].flatMap { ($0 as? NSNumber)?.doubleValue }
            .map { Date(timeIntervalSince1970: $0) }
    }
}
