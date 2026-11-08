import Foundation
import Security

enum RelayKeyStore {
    private static let lookup: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.neural.ble-prototype.v1",
        kSecAttrAccount as String: "relay-key"
    ]

    static func load() throws -> Data? {
        var query = lookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = result as? Data, key.count == 32 else {
            throw StoreError.status(status)
        }
        return key
    }

    static func save(_ key: Data) throws {
        var status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if status == errSecItemNotFound {
            var query = lookup
            query[kSecValueData as String] = key
            #if os(iOS)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.status(status) }
    }

    enum StoreError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self { case .status(let status): return "Could not access the relay test key (\(status))." }
        }
    }
}
