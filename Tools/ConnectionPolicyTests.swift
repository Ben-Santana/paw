// Isolated checks: no Core Bluetooth, Keychain queries, Meta calls or production defaults.
import Foundation
import CryptoKit

@main
struct ConnectionPolicyTests {
    static func main() throws {
        let raw = P256.Signing.PrivateKey().rawRepresentation
        let saved = BandIdentity(privateKey: raw, bandPoint: nil, stage: "host_verified", allowMissingBandKey: true)
        let pending = BandIdentity(privateKey: P256.Signing.PrivateKey().rawRepresentation, bandPoint: nil, stage: "imported", allowMissingBandKey: true)
        let normal = try ConnectionIdentitySelection.choose(saved: saved, pending: pending)
        precondition(!normal.pending && normal.identity.privateKey == raw)
        let explicit = try ConnectionIdentitySelection.choose(saved: saved, pending: pending, preferPending: true)
        precondition(explicit.pending && explicit.identity.privateKey == pending.privateKey)
        let onlyPending = try ConnectionIdentitySelection.choose(saved: nil, pending: pending)
        precondition(onlyPending.pending)
        for stage in ["identity", "nonce", "start", "pair", "pair_request"] {
            var incomplete = pending; incomplete.stage = stage
            do {
                _ = try ConnectionIdentitySelection.choose(saved: nil, pending: incomplete)
                preconditionFailure("Incomplete pending record was accepted")
            } catch is BandError { }
            let fallback = try ConnectionIdentitySelection.choose(saved: saved, pending: incomplete)
            precondition(!fallback.pending)
        }
        var denied = pending; denied.allowMissingBandKey = nil
        precondition(!denied.isConnectionCandidate)
        let savedFingerprint = try saved.publicFingerprint
        let pendingFingerprint = try pending.publicFingerprint
        precondition(savedFingerprint.count == 64)
        precondition(savedFingerprint != pendingFingerprint)
        precondition(BandError.pairing("OS bond mismatch").requiresUser)
        precondition(BandError.authentication("host rejected").requiresUser)
        precondition(BandError.wire("invalid response").requiresUser)
        precondition(!BandError.transport("out of range").requiresUser)
        let bondError = BandError.bluetooth(domain: "CBErrorDomain", code: 14, description: "Peer removed pairing information", fallback: "Failed")
        precondition(bondError.requiresUser && bondError.localizedDescription.contains("CBErrorDomain:14"))
        precondition(!BandError.bluetooth(domain: "CBErrorDomain", code: 6, description: "Timeout", fallback: "Failed").requiresUser)
        for retries in 0..<5 {
            precondition(ConnectionRetryPolicy.delay(for: .transport("lost"), retries: retries) == pow(2, Double(retries)))
            precondition(ConnectionRetryPolicy.delay(for: bondError, retries: retries) == nil)
        }
        precondition(ConnectionRetryPolicy.delay(for: .transport("lost"), retries: 5) == nil)
        let suite = "runes-isolated-policy-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IdentityStore(preferences: defaults)
        let old = UUID(), rediscovered = UUID()
        precondition(store.account(for: rediscovered) == rediscovered)
        store.bind(rediscovered, to: old)
        precondition(store.account(for: rediscovered) == old)
        precondition(store.account(for: old) == old)
        precondition(IdentityStore(preferences: defaults).account(for: rediscovered) == old)
        print("Connection policy checks passed: saved/pending selection, compatibility, public fingerprints, failure classification, persistent aliases. No hardware or identity storage accessed.")
    }
}
