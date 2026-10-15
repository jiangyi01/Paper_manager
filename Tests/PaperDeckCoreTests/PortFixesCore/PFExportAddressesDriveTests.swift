import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Settings export / import, lane 2 (hunt findings):
/// - portability-cli-6: "Include the Crossref contact email" also dropped every IMAP account's
///   address (needed on the new Mac), while account names still carried it. The mailbox addresses
///   are now their own choice (`includeAddresses`, on in the sheet); left out, they leave the
///   accounts, the account names and a Google Drive root's name.
/// - portability-cli-4: a folder in a Google Drive "Shared drives" area came back under
///   "<account>/My Drive/Shared drives/…". The file keeps the form every build writes (a My Drive
///   path without `My Drive/`, a Shared drives path with its area), and import now puts a path in
///   another area of the account folder back there (`CloudRootLocator.googleFolder`) — so a file
///   of this build still means the same folder to an earlier build, and the other way round.
/// Pure: synthetic paths under a temporary root (never ~/Library/CloudStorage); nothing is created.
@Suite struct PFExportAddressesDriveTests {
    /// A made-up home folder: nothing under it is read or written.
    static let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("paperdeck-tests-lane2-home", isDirectory: true)
    static var cloudStorage: URL { CloudRootLocator.cloudStorage(home: home) }
    static let account = "GoogleDrive-jane.doe@example.com"
    static var roots: [CloudRoot] { CloudRootLocator.classify(names: [account, "OneDrive-Contoso"], cloudStorage: cloudStorage) }
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func export(_ d: [String: Any], personal: Bool, addresses: Bool) -> SettingsBundle {
        SettingsExporter.export(PersistedDomain(d), sections: Set(SettingsSection.allCases), includePersonal: personal,
                                includeAddresses: addresses, home: home, roots: roots, app: "PaperDeck 1.0 (27)", now: now)
    }

    static func plan(_ b: SettingsBundle, current: [String: Any] = [:], roots: [CloudRoot]) -> ImportPlan {
        SettingsImporter.plan(b, current: PersistedDomain(current), sections: Set(SettingsSection.allCases),
                              keepPeopleAlways: false, acceptReaderDescription: false, home: home, roots: roots)
    }

    static func json(_ b: SettingsBundle) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(b), as: UTF8.self)
    }

    static func accounts(_ b: SettingsBundle) -> [[String: JSONValue]] {
        guard case .array(let items)? = b.sections[SettingsSection.mailAccounts.rawValue]?.objectValue?[MailSettings.Keys.accounts]
        else { return [] }
        return items.compactMap(\.objectValue)
    }

    /// A resolution as "exact <path>" / "sameProvider <path>" / "unresolved" (paths, not URLs: a
    /// URL's trailing slash depends on what exists on disk).
    static func place(_ r: PortablePath.Resolution) -> String {
        switch r {
        case .exact(let u): "exact \(u.path)"
        case .sameProvider(let u): "sameProvider \(u.path)"
        case .unresolved: "unresolved"
        }
    }

    static func written(_ p: ImportPlan) -> [MailAccount] {
        MailSettings.list(p.writes[MailSettings.Keys.accounts]?.stringValue, MailAccount.self, what: "a")
    }

    static let gmail = MailAccount(id: "gm", kind: .imap, displayName: "Gmail — jane.doe@example.com", imapPreset: .gmail,
                                   host: "imap.gmail.com", port: 993, username: "jane.doe@example.com")
    static var sharedFolder: String {
        cloudStorage.appendingPathComponent("\(account)/Shared drives/Lab/PaperDeck Mail").path
    }
    static var myDriveFolder: String {
        cloudStorage.appendingPathComponent("\(account)/My Drive/PaperDeck Mail").path
    }
    static var folderAccount: MailAccount {
        MailAccount(id: "drive", kind: .folder, displayName: "Lab drive", folderPath: sharedFolder)
    }
    static var domain: [String: Any] {
        [MailSettings.Keys.accounts: MailSettings.encode([gmail, folderAccount]),
         "metadata.mailto": "contact@example.org",
         ConfigKeys.mailCloudRoot: account,
         "library.path": myDriveFolder]
    }

    // MARK: portability-cli-6 — mailbox addresses are their own choice

    @Test func addressesAreOnTheirOwnSwitchApartFromTheCrossrefEmail() throws {
        // The sheet's default: addresses in, the Crossref contact email out.
        let moving = Self.export(Self.domain, personal: false, addresses: true)
        let gm = try #require(Self.accounts(moving).first { $0["id"] == .string("gm") })
        #expect(gm["username"] == .string("jane.doe@example.com"))
        #expect(gm["displayName"] == .string("Gmail — jane.doe@example.com"))
        let movingText = try Self.json(moving)
        #expect(!movingText.contains("contact@example.org"))
        // The new Mac gets the address: the account is ready once its app password is typed.
        let arrived = Self.written(Self.plan(moving, roots: Self.roots))
        #expect(arrived.first { $0.id == "gm" }?.username == "jane.doe@example.com")

        // Addresses left out, the Crossref email in: no address anywhere but the contact email.
        let private1 = Self.export(Self.domain, personal: true, addresses: false)
        let text = try Self.json(private1)
        #expect(!text.contains("jane.doe@example.com"), "\(text)")
        #expect(text.contains("contact@example.org"))
        let gm2 = try #require(Self.accounts(private1).first { $0["id"] == .string("gm") })
        #expect(gm2["username"] == nil && gm2["displayName"] == .string("Gmail"))
        // The cloud root's name held the address: the folder keeps its provider and its area, and
        // the last-used root (only a name) is left out.
        let drive = try #require(Self.accounts(private1).first { $0["id"] == .string("drive") })
        #expect(try drive["folder"]?.decode(PortablePath.self)
                == .cloud(provider: .googleDrive, root: "GoogleDrive", relative: "Shared drives/Lab/PaperDeck Mail"))
        #expect(private1.sections[SettingsSection.mailAccounts.rawValue]?.objectValue?[ConfigKeys.mailCloudRoot] == nil)
    }

    @Test func aFolderExportedWithoutAddressesGoesToTheOnlyGoogleRootThere() throws {
        let b = Self.export(Self.domain, personal: false, addresses: false)
        let newMac = CloudRootLocator.classify(names: ["GoogleDrive-someone@example.org"], cloudStorage: Self.cloudStorage)
        let p = Self.plan(b, roots: newMac)
        let drive = try #require(Self.written(p).first { $0.id == "drive" })
        let expected = Self.cloudStorage.appendingPathComponent("GoogleDrive-someone@example.org/Shared drives/Lab/PaperDeck Mail").path
        #expect(drive.folderPath == expected)
        #expect(p.warnings.contains(.folderRemapped(account: "Lab drive", to: expected)))
    }

    @Test func anAccountNameLosesOnlyItsAddresses() {
        let cases: [(String, String)] = [
            ("Gmail — jane.doe@example.com", "Gmail"),
            ("Work (jane@example.edu)", "Work"),
            ("<jane@example.edu> lab inbox", "lab inbox"),
            ("Lab drop", "Lab drop"),
            ("a@example.com, b@example.org", ""),
        ]
        for (name, expected) in cases {
            #expect(SettingsExporter.withoutAddresses(name) == expected, "\(name)")
        }
        let bare = MailAccount(kind: .imap, displayName: "jane@example.com", imapPreset: .icloud)
        #expect(SettingsExporter.accountNameWithoutAddresses(bare) == "iCloud")
        let custom = MailAccount(kind: .imap, displayName: "jane@example.com", imapPreset: .custom)
        #expect(SettingsExporter.accountNameWithoutAddresses(custom) == "IMAP")
        #expect(CloudRootLocator.rootNameWithoutAddress("GoogleDrive-jane@example.com", provider: .googleDrive) == "GoogleDrive")
        #expect(CloudRootLocator.rootNameWithoutAddress("OneDrive-Contoso", provider: .oneDriveBusiness) == "OneDrive-Contoso")
    }

    // MARK: portability-cli-4 — Google Drive areas survive the round trip

    @Test func aSharedDrivesFolderComesBackWhereItWas() throws {
        let encoded = PortablePath.encode(Self.sharedFolder, home: Self.home, roots: Self.roots)
        #expect(encoded == .cloud(provider: .googleDrive, root: Self.account, relative: "Shared drives/Lab/PaperDeck Mail"))
        #expect(Self.place(encoded.resolve(home: Self.home, roots: Self.roots)) == "exact \(Self.sharedFolder)")
        let myDrive = PortablePath.encode(Self.myDriveFolder, home: Self.home, roots: Self.roots)
        #expect(myDrive == .cloud(provider: .googleDrive, root: Self.account, relative: "PaperDeck Mail"))
        #expect(Self.place(myDrive.resolve(home: Self.home, roots: Self.roots)) == "exact \(Self.myDriveFolder)")
        // Another Google account on the new Mac: the same area there.
        let other = CloudRootLocator.classify(names: ["GoogleDrive-other@example.org"], cloudStorage: Self.cloudStorage)
        let there = Self.cloudStorage.appendingPathComponent("GoogleDrive-other@example.org/Shared drives/Lab/PaperDeck Mail").path
        #expect(Self.place(encoded.resolve(home: Self.home, roots: other)) == "sameProvider \(there)")
    }

    /// Review fix: the file form is the one earlier builds write and read. A My Drive path
    /// travels without `My Drive/` (an earlier build resolves it under its My Drive, never
    /// `My Drive/My Drive/…`); only the import of a path in another area changed.
    @Test func theFileFormStaysTheEarlierBuildsForMyDrive() {
        let myDrive = PortablePath.encode(Self.myDriveFolder, home: Self.home, roots: Self.roots)
        guard case .cloud(_, _, let relative) = myDrive else { Issue.record("\(myDrive)"); return }
        #expect(!relative.hasPrefix("My Drive"), "\(relative)")
        // What an earlier build's resolve did with it (the root's My Drive + the relative path).
        let earlier = Self.roots.first { $0.name == Self.account }.map { $0.url.appendingPathComponent(relative).path }
        #expect(earlier == Self.myDriveFolder)
        // Other computers and the account folder's own My Drive come back where they were.
        let computers = Self.cloudStorage.appendingPathComponent("\(Self.account)/Other computers/Lab Mac/Mail").path
        let encoded = PortablePath.encode(computers, home: Self.home, roots: Self.roots)
        #expect(encoded == .cloud(provider: .googleDrive, root: Self.account, relative: "Other computers/Lab Mac/Mail"))
        #expect(Self.place(encoded.resolve(home: Self.home, roots: Self.roots)) == "exact \(computers)")
        let top = Self.cloudStorage.appendingPathComponent("\(Self.account)/My Drive").path
        #expect(Self.place(PortablePath.encode(top, home: Self.home, roots: Self.roots).resolve(home: Self.home, roots: Self.roots))
                == "exact \(top)")
    }

    @Test func anEarlierBuildsGooglePathStillMeansMyDrive() {
        let legacy = PortablePath.cloud(provider: .googleDrive, root: Self.account, relative: "PaperDeck Mail")
        #expect(Self.place(legacy.resolve(home: Self.home, roots: Self.roots)) == "exact \(Self.myDriveFolder)")
        let legacyRoot = PortablePath.cloud(provider: .googleDrive, root: Self.account, relative: "")
        #expect(Self.place(legacyRoot.resolve(home: Self.home, roots: Self.roots))
                == "exact \(Self.cloudStorage.appendingPathComponent("\(Self.account)/My Drive").path)")
        // Earlier builds kept a Shared drives path as is: it resolves there now.
        let legacyShared = PortablePath.cloud(provider: .googleDrive, root: Self.account, relative: "Shared drives/Lab/PaperDeck Mail")
        #expect(Self.place(legacyShared.resolve(home: Self.home, roots: Self.roots)) == "exact \(Self.sharedFolder)")
        // Other providers are unchanged.
        let oneDrive = PortablePath.cloud(provider: .oneDriveBusiness, root: "OneDrive-Contoso", relative: "PaperDeck Mail")
        #expect(Self.place(oneDrive.resolve(home: Self.home, roots: Self.roots))
                == "exact \(Self.cloudStorage.appendingPathComponent("OneDrive-Contoso/PaperDeck Mail").path)")
    }

    @Test func aSameMacExportAndImportKeepsTheSharedDrivesFolderAndLibrary() throws {
        let b = Self.export(Self.domain, personal: false, addresses: true)
        // Onto an empty Mac with the same Google account.
        let p = Self.plan(b, roots: Self.roots)
        #expect(Self.written(p).first { $0.id == "drive" }?.folderPath == Self.sharedFolder)
        #expect(p.writes["library.path"] == .string(Self.myDriveFolder))
        #expect(!p.warnings.contains { if case .folderRemapped = $0 { true } else if case .folderUnresolved = $0 { true } else { false } })
        // Back onto this Mac: nothing changes.
        let same = Self.plan(b, current: Self.domain, roots: Self.roots)
        #expect(same.writes[MailSettings.Keys.accounts] == nil && same.writes["library.path"] == nil, "\(same.writes.keys.sorted())")
    }
}
