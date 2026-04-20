import Foundation
import Security

class KeychainService: @unchecked Sendable {
    private let serviceName = Constants.keychainService
    private let accountName = Constants.keychainAccount
    private let porcupineAccount = Constants.keychainPorcupineAccount
    private var cachedKey: String?
    private var cachedPorcupineKey: String?

    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        deleteAPIKey()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            cachedKey = key
        } else {
            LoggingService.shared.log("Keychain save failed: \(status)", level: .error)
        }
        return status == errSecSuccess
    }

    func getAPIKey() -> String? {
        if let cachedKey { return cachedKey }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        let key = String(data: data, encoding: .utf8)
        cachedKey = key
        return key
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        cachedKey = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Drop the in-memory cached key so the next `getAPIKey()` call re-reads from the Keychain.
    /// Call this after any out-of-band change (e.g. Settings save) so streaming chats pick up
    /// a freshly rotated key without requiring an app relaunch.
    func clearCache() {
        cachedKey = nil
        cachedPorcupineKey = nil
    }

    var hasAPIKey: Bool { getAPIKey() != nil }

    // MARK: - Porcupine AccessKey

    func savePorcupineKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        _ = deletePorcupineKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: porcupineAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            cachedPorcupineKey = key
        } else {
            LoggingService.shared.log("Keychain Porcupine save failed: \(status)", level: .error)
        }
        return status == errSecSuccess
    }

    func getPorcupineKey() -> String? {
        if let cachedPorcupineKey { return cachedPorcupineKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: porcupineAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)
        cachedPorcupineKey = key
        return key
    }

    @discardableResult
    func deletePorcupineKey() -> Bool {
        cachedPorcupineKey = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: porcupineAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Anthropic API Key

    private var cachedAnthropicKey: String?

    func saveAnthropicKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        _ = deleteAnthropicKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Constants.keychainAnthropicAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { cachedAnthropicKey = key }
        return status == errSecSuccess
    }

    func getAnthropicKey() -> String? {
        if let cachedAnthropicKey { return cachedAnthropicKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Constants.keychainAnthropicAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)
        cachedAnthropicKey = key
        return key
    }

    @discardableResult
    func deleteAnthropicKey() -> Bool {
        cachedAnthropicKey = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Constants.keychainAnthropicAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
