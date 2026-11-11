// swiftc RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Protocol/BandCrypto.swift RunesIOS/Authentication/OwnershipCeremony.swift Tests/BandRecoveryTests.swift -o /private/tmp/runes-band-recovery-tests
// Synthetic state and receipts only; no Bluetooth, Meta calls or Keychain access.
import Foundation
import CryptoKit

@main
struct BandRecoveryTests {
    enum Failure: Error { case synthetic }

    static func identity() -> BandIdentity {
        BandIdentity(privateKey: P256.Signing.PrivateKey().rawRepresentation, bandPoint: nil,
                     stage: "host_verified", allowMissingBandKey: true)
    }

    static func claim(_ ceremony: OwnershipCeremony) throws {
        _ = try ceremony.receive(kind: 0x02003001, payload:
            PB.field(1, Data(repeating: 1, count: 257)) + PB.field(2, Data("test-band".utf8))
            + PB.field(5, Data(repeating: 2, count: 257)))
        _ = try ceremony.receive(kind: 0x02002001, payload: PB.field(1, Data(repeating: 3, count: 16)))
    }

    static func complete(_ ceremony: OwnershipCeremony) throws -> BandIdentity {
        try claim(ceremony)
        _ = try ceremony.resume(PairCompletion(signature: Data([4]), receipt: "test-pending"))
        _ = try ceremony.receive(kind: 0x02002003, payload: PB.field(1, Data([5])) + PB.field(2, Data("test-band-receipt".utf8)))
        _ = try ceremony.resume(PairCompletion(signature: Data([6]), receipt: "test-final"))
        guard case .complete(let candidate) = try ceremony.receive(kind: 0x02002005, payload: Data()) else {
            preconditionFailure("Expected a completed ceremony")
        }
        return candidate
    }

    static func main() throws {
        let firstBand = UUID(), otherBand = UUID()
        var authorization = BandSetupAuthorization()
        let cancelled = authorization.begin(for: firstBand)
        authorization.cancel()
        let current = authorization.begin(for: firstBand)
        do {
            try authorization.validate(cancelled, selected: firstBand, foreground: true)
            preconditionFailure("A cancelled login callback was accepted")
        } catch BandError.cancelled {}
        precondition(!authorization.finish(cancelled), "An old task must not finish a newer login")
        try authorization.validate(current, selected: firstBand, foreground: true)
        for (band, foreground) in [(otherBand, true), (firstBand, false)] {
            do {
                try authorization.validate(current, selected: band, foreground: foreground)
                preconditionFailure("A changed selection or background login was accepted")
            } catch is BandError {}
        }
        precondition(authorization.finish(current))

        var snapshot = SessionSnapshot()
        snapshot.selected = firstBand; snapshot.state = .failed; snapshot.issue = .notRecognised
        precondition(BandSetupAuthorization.canRestart(snapshot, foreground: true, signingIn: false))
        snapshot.selected = otherBand
        precondition(!BandSetupAuthorization.canRestart(snapshot, for: firstBand, foreground: true, signingIn: false),
                     "Confirming band A must not authorize band B after the settings sheet closes")
        snapshot.selected = firstBand
        for state in [SessionState.connecting, .reconnecting, .authenticating, .enrolling, .subscribing, .streaming, .disconnecting, .scanning] {
            snapshot.state = state
            precondition(!BandSetupAuthorization.canRestart(snapshot, foreground: true, signingIn: false))
        }
        snapshot.state = .failed
        precondition(!BandSetupAuthorization.canRestart(snapshot, foreground: false, signingIn: false))
        precondition(!BandSetupAuthorization.canRestart(snapshot, foreground: true, signingIn: true))
        snapshot.wantsConnection = true
        precondition(!BandSetupAuthorization.canRestart(snapshot, foreground: true, signingIn: false))
        snapshot.wantsConnection = false; snapshot.selected = nil
        precondition(!BandSetupAuthorization.canRestart(snapshot, foreground: true, signingIn: false))

        let old = identity()
        var saved = old, pending: BandIdentity?
        let interrupted = try OwnershipCeremony(previous: nil, allowMissingBandKey: true) { pending = $0 }
        try claim(interrupted)
        precondition(saved.privateKey == old.privateKey && pending?.stage == "pair_request")
        let stagedKey = pending!.privateKey
        let restarted = try OwnershipCeremony(previous: pending, allowMissingBandKey: true) { pending = $0 }
        precondition(restarted.record.privateKey == stagedKey && saved.privateKey == old.privateKey)

        for ending in ["cancelled", "fresh trust failed", "save failed", "success"] {
            saved = old; pending = nil
            let ceremony = try OwnershipCeremony(previous: nil, allowMissingBandKey: true) { pending = $0 }
            let candidate = try complete(ceremony)
            var confirmation = IdentityConfirmation(), commits = 0
            confirmation.beginConnection(); confirmation.enrolled()
            let first = confirmation.authenticated { commits += 1; saved = candidate; pending = nil }
            precondition(first == .reconnect && commits == 0)
            precondition(saved.privateKey == old.privateKey && pending?.stage == "confirmed")
            confirmation.beginConnection()
            if ending == "cancelled" || ending == "fresh trust failed" {
                confirmation.cancel()
            } else if ending == "save failed" {
                do {
                    _ = try confirmation.authenticated { throw Failure.synthetic }
                    preconditionFailure("A failed save was accepted")
                } catch Failure.synthetic {}
                confirmation.cancel()
            }
            let result = confirmation.authenticated { commits += 1; saved = candidate; pending = nil }
            if ending == "success" {
                precondition(result == .committed && commits == 1 && pending == nil)
                precondition(saved.privateKey == candidate.privateKey && saved.privateKey != old.privateKey)
            } else {
                precondition(result == .ignored && commits == 0)
                precondition(saved.privateKey == old.privateKey && pending?.privateKey == candidate.privateKey)
            }
            precondition(confirmation.authenticated { commits += 1 } == .ignored)
        }
        print("Band recovery checks passed: stale login rejection, foreground/selection gates, pending retention, fresh-connection confirmation and one-time promotion.")
    }
}
