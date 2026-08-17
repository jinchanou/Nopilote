import Foundation
import Security

struct KeychainStore: Sendable {
    // Use a new service name so this build never touches the old v2 item and
    // its stale login-keychain ACL. The default app-scoped Keychain item works
    // with the ad-hoc development signature; Data Protection Keychain and
    // custom access groups require a real Apple signing identity.
    private let service = "dev.jace.nopilote.v3"

    func value(for account: String) -> String? {
        do {
            return try read(for: account)
        } catch {
            return nil
        }
    }

    func read(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func set(_ value: String, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .status(let status):
            if status == errSecMissingEntitlement {
                "This app could not access its Keychain entry because of a signing entitlement. Rebuild or reinstall Nopilote, then save the API key again."
            } else {
                "Keychain error \(status). macOS may need permission to access the saved API key."
            }
        case .invalidData: "The saved API key could not be read from Keychain."
        }
    }
}
