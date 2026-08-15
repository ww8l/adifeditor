import Foundation
import Security

/// The Keychain, wrapped in three operations.
///
/// §6.5 says QRZ credentials live here and nowhere else — not in a preference file, not
/// in the repo, not in a log. There is deliberately **no fallback**: if the Keychain
/// refuses, the credential is not stored and the user is told, rather than being quietly
/// written somewhere less safe. An app that silently degrades to a plaintext plist is
/// worse than one that says it cannot help.
enum Keychain {

    /// A Keychain call that did not work.
    ///
    /// Carries the `OSStatus` because the interesting failures are specific and
    /// diagnosing them from a generic message is miserable. `errSecMissingEntitlement`
    /// (-34018) in particular means the *build* is wrong, not the password.
    struct Failure: LocalizedError, Equatable {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            return "Could not \(operation) in the Keychain: \(detail)"
        }

        var recoverySuggestion: String? {
            switch status {
            case errSecMissingEntitlement:
                return "The app is not entitled to use the Keychain. This is a problem "
                     + "with how it was built and signed, not with the password."
            case errSecUserCanceled, errSecAuthFailed:
                return "The Keychain would not unlock. Try again."
            default:
                return nil
            }
        }
    }

    /// Store or replace a password.
    ///
    /// `kSecAttrAccessibleWhenUnlocked` rather than the `ThisDeviceOnly` variant: a QRZ
    /// password is the user's to move to a new Mac, and forcing them to retype it there
    /// protects nothing — it is recoverable from qrz.com in a minute either way.
    static func store(_ password: String, account: String, service: String) throws {
        let secret = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Update in place when it already exists. SecItemAdd on a duplicate returns
        // errSecDuplicateItem rather than replacing, so changing a password would
        // otherwise fail with an error that reads like a bug.
        let update: [String: Any] = [kSecValueData as String: secret]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw Failure(operation: "update the password", status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Failure(operation: "store the password", status: addStatus)
        }
    }

    /// The stored password, or `nil` when there is none.
    ///
    /// "Not there" is a normal state — it is what a fresh install looks like — so it
    /// returns `nil` rather than throwing. Anything else is a real failure.
    static func password(account: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(operation: "read the password", status: status)
        }
    }

    /// Remove the password. Removing one that is not there is a success, not an error —
    /// the caller wanted it gone and it is gone.
    static func delete(account: String, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "remove the password", status: status)
        }
    }
}
