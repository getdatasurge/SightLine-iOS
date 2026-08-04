import Foundation
import Security

struct KeychainError: Error { let status: OSStatus }

final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "device-session"

    init(service: String = "com.getdatasurge.sightline.field") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> TokenPair? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        guard let pair = try? JSONDecoder().decode(TokenPair.self, from: data) else {
            assertionFailure("corrupt token data in keychain")
            return nil
        }
        return pair
    }

    func save(_ pair: TokenPair) throws {
        let data = try JSONEncoder().encode(pair)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

// @unchecked: NSLock serializes all state access
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var pair: TokenPair?
    private let lock = NSLock()
    func load() -> TokenPair? { lock.withLock { pair } }
    func save(_ p: TokenPair) throws { lock.withLock { pair = p } }
    func clear() { lock.withLock { pair = nil } }
}
