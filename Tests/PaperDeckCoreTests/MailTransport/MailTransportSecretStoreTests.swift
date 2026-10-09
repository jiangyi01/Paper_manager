import Foundation
import Security
import Testing
@testable import PaperDeckCore

@Suite struct MailTransportSecretStoreTests {

    @Test func inMemoryStoreSetsReadsAndDeletes() async throws {
        let store = InMemoryMailSecretStore()
        #expect(await store.secret(for: "a.imap") == nil)
        try await store.setSecret("app-password", for: "a.imap")
        #expect(await store.secret(for: "a.imap") == "app-password")
        try await store.setSecret(nil, for: "a.imap")
        #expect(await store.secret(for: "a.imap") == nil)
        #expect(await store.reads == 3)
    }

    @Test func factoryBuildsTheSourceForTheAccountKind() {
        let store = InMemoryMailSecretStore()
        let folder = MailAccount(id: "f1", kind: .folder, displayName: "Folder", folderPath: "/tmp/x")
        let imap = MailAccount(id: "i1", kind: .imap, displayName: "Gmail", imapPreset: .gmail, username: "me@gmail.com")
        let fs = MailSourceFactory.make(folder, secrets: store)
        let isrc = MailSourceFactory.make(imap, secrets: store, lang: .zh)
        #expect(fs is FolderMailSource && fs.accountID == "f1")
        #expect(isrc is IMAPMailSource && isrc.accountID == "i1")
        #expect(imap.secretKey == "i1.imap")
    }

    /// Touches the real login keychain, so it only runs with PAPERDECK_KEYCHAIN_TESTS=1.
    /// Uses a unique service name and deletes its item afterwards.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PAPERDECK_KEYCHAIN_TESTS"] == "1"))
    func keychainStoreRoundTrip() async throws {
        let service = "com.yijiang.paperdeck.mail.test-\(UUID().uuidString.lowercased())"
        let store = KeychainMailSecretStore(service: service)
        let key = "test-account.imap"
        defer {
            // Belt and braces: never leave a test item behind, even if an expectation failed.
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        #expect(await store.secret(for: key) == nil)
        try await store.setSecret("first", for: key)
        #expect(await store.secret(for: key) == "first")
        try await store.setSecret("second", for: key)          // update path
        #expect(await store.secret(for: key) == "second")
        try await store.setSecret(nil, for: key)
        #expect(await store.secret(for: key) == nil)
        try await store.setSecret(nil, for: key)                // deleting nothing is fine
    }
}
