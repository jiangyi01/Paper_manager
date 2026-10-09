import Foundation
import Security
import PaperDeckShared

// Credential storage for mail accounts (IMAP app passwords).
//
// Production: the app's own generic-password items in the file-based login keychain
// (no kSecUseDataProtectionKeychain — that needs entitlements a self-signed build can't
// have; TN3137). The item's access list trusts the creating app's signature, so a build
// signed with the same stable certificate reads it back without prompts. Never logged.
// Tests use InMemoryMailSecretStore.

package enum MailSecretStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case keychain(OSStatus)

    package var description: String {
        switch self {
        case .keychain(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "error"
            return "Keychain: \(msg) (\(s))"
        }
    }
}

package final class KeychainMailSecretStore: MailSecretStore {
    /// `BuildIdentity.current.keychainService`: `PDKeychainService` when stamped, else
    /// "<bundle id>.mail" — the same service as before for a build with the script's defaults.
    package static let defaultService = BuildIdentity.current.keychainService
    package let service: String

    package init(service: String = KeychainMailSecretStore.defaultService) {
        self.service = service
    }

    package func secret(for key: String) async -> String? {
        let service = self.service
        return await BlockingIO.run { () -> String? in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            guard status == errSecSuccess, let data = out as? Data else {
                if status != errSecItemNotFound {
                    MailTransportLog.logger.error("keychain read failed (\(status, privacy: .public))")
                }
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Stores `value` (update or add); nil deletes the item.
    package func setSecret(_ value: String?, for key: String) async throws {
        let service = self.service
        try await BlockingIO.run {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            guard let value else {
                let status = SecItemDelete(base as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw MailSecretStoreError.keychain(status)
                }
                return
            }
            let data = Data(value.utf8)
            let update: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw MailSecretStoreError.keychain(status) }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrSynchronizable as String] = kCFBooleanFalse
            add[kSecAttrLabel as String] = "PaperDeck Mail (\(key))"
            add[kSecAttrDescription as String] = "PaperDeck IMAP app password"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MailSecretStoreError.keychain(addStatus) }
        }
        MailTransportLog.logger.info("keychain item \(value == nil ? "deleted" : "saved", privacy: .public)")
    }
}

/// Process-local store for tests and `--root` self-tests (never persisted).
package actor InMemoryMailSecretStore: MailSecretStore {
    private var values: [String: String]
    package private(set) var reads = 0

    package init(_ values: [String: String] = [:]) { self.values = values }

    package func secret(for key: String) async -> String? {
        reads += 1
        return values[key]
    }

    package func setSecret(_ value: String?, for key: String) async throws {
        values[key] = value
    }
}
