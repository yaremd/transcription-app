import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for storing small secrets (the
/// optional cloud API key). Keeps secrets out of UserDefaults / the plist.
enum Keychain {
    private static let service = "com.yarem.LocalScribe"

    /// Stores (or, for an empty value, removes) a secret for `account`.
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Reads the secret for `account`, or nil if none is stored.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
