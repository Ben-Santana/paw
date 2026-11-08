import Foundation
import Security
import CryptoKit

struct IdentityStore {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private let service = "com.runes.ios.band-identity.v1"
    private func query(_ id: UUID, pending: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString + (pending ? ".pending" : ".identity")]
    }
    func load(_ id: UUID, pending: Bool = false) throws -> BandIdentity? {
        var q = query(id, pending: pending); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BandError.storage("Cannot read band identity from Keychain (\(status)). Unlock the phone first.") }
        do {
            let record = try JSONDecoder().decode(BandIdentity.self, from: data)
            _ = try P256.Signing.PrivateKey(rawRepresentation: record.privateKey)
            if let point = record.bandPoint { _ = try P256.Signing.PublicKey(x963Representation: Data([4]) + point) }
            return record
        } catch { throw BandError.storage("Saved band identity is invalid.") }
    }
    func save(_ identity: BandIdentity, for id: UUID, pending: Bool = false) throws {
        let data = try JSONEncoder().encode(identity), q = query(id, pending: pending)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw BandError.storage("Cannot save band identity to Keychain (\(status)).") }
    }
    func clearPending(_ id: UUID) throws {
        let status = SecItemDelete(query(id, pending: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BandError.storage("Cannot clear pending enrollment (\(status)).") }
    }
}

/// Public metadata only. Existing Keychain UUID accounts remain stable credential
/// records; a peripheral UUID is an alias committed only after authentication.
struct IdentityChoice: Identifiable, Sendable {
    let account: UUID
    let pending: Bool
    let fingerprint: String
    let stage: String
    let hasBandKey: Bool
    let eligible: Bool
    var id: String { account.uuidString + (pending ? ".pending" : ".identity") }
}

extension IdentityStore {
    func account(for peripheral: UUID) -> UUID {
        let aliases = preferences.dictionary(forKey: "bandIdentityBindings.v1") as? [String: String] ?? [:]
        return aliases[peripheral.uuidString].flatMap(UUID.init(uuidString:)) ?? peripheral
    }
    func bind(_ peripheral: UUID, to account: UUID) {
        var aliases = preferences.dictionary(forKey: "bandIdentityBindings.v1") as? [String: String] ?? [:]
        aliases[peripheral.uuidString] = account.uuidString
        preferences.set(aliases, forKey: "bandIdentityBindings.v1")
    }
    func choices() throws -> [IdentityChoice] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: service, kSecReturnAttributes as String: true,
                               kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw BandError.storage("Cannot list saved identities (\(status)). Unlock the phone first.") }
        var choices: [IdentityChoice] = []
        for item in result as? [[String: Any]] ?? [] {
            guard let name = item[kSecAttrAccount as String] as? String else { continue }
            let pending = name.hasSuffix(".pending")
            guard name.hasSuffix(".identity") || pending,
                  let id = UUID(uuidString: String(name.prefix(36))) else { continue }
            do {
                guard let identity = try load(id, pending: pending) else { continue }
                choices.append(IdentityChoice(account: id, pending: pending, fingerprint: try identity.publicFingerprint,
                                              stage: identity.stage, hasBandKey: identity.bandPoint != nil,
                                              eligible: identity.isConnectionCandidate))
            } catch {
                choices.append(IdentityChoice(account: id, pending: pending, fingerprint: "Unavailable", stage: "unavailable", hasBandKey: false, eligible: false))
            }
        }
        return choices.sorted { $0.id < $1.id }
    }
}

extension BandIdentity {
    var isConnectionCandidate: Bool {
        canAuthenticate && ["verified", "host_verified", "imported", "finish", "confirmed"].contains(stage)
    }
    var publicFingerprint: String {
        get throws {
            let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
            return SHA256.hash(data: Data(key.publicKey.x963Representation.dropFirst())).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// One selection policy for foreground Connect, cold launch and restoration.
enum ConnectionIdentitySelection {
    static func choose(saved: BandIdentity?, pending: BandIdentity?, preferPending: Bool? = nil) throws -> (identity: BandIdentity, pending: Bool) {
        let usePending = preferPending ?? (saved == nil && pending?.isConnectionCandidate == true)
        guard let identity = usePending ? pending : saved, identity.isConnectionCandidate else {
            throw BandError.storage("No usable identity for this selection. Choose an existing saved identity or import the Mac QR. Enrollment is only for deliberately changing ownership.")
        }
        return (identity, usePending)
    }
}
