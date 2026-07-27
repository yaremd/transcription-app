import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for storing small secrets (the
/// optional cloud API key). Keeps secrets out of UserDefaults / the plist.
enum Keychain {
    private static let service = "com.yarem.Seal"

    /// Unit tests are hosted inside the app, so `AppSettings.init()` — and its
    /// Keychain read — runs at test startup. The test host's signature differs
    /// from the installed app's, and macOS answers that with an access prompt
    /// no headless run can dismiss: `SecItemCopyMatching` blocks the main
    /// thread and the test runner times out waiting to connect, reporting only
    /// "hung before establishing connection". Tests have no business touching
    /// the user's real secrets in any case, so the store reads as empty and
    /// ignores writes there.
    private static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Stores (or, for an empty value, removes) a secret for `account`.
    static func set(_ value: String, account: String) {
        guard !isUnderTest else { return }
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
        guard !isUnderTest else { return nil }
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

    /// One-time move of a secret from a previous service name to the current one
    /// — used for the com.yarem.LocalScribe → com.yarem.Seal rename. No-op if the
    /// current service already holds a value, or the old one is empty/absent.
    static func migrateService(account: String, from oldService: String) {
        guard !isUnderTest, oldService != service, get(account: account) == nil else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return }
        set(value, account: account)   // write under the new service
        SecItemDelete([                 // drop the old-service copy
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
