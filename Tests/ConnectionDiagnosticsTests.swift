// Offline protocol fixtures with ephemeral keys; no Bluetooth, Keychain access or saved credentials.
import Foundation
import CryptoKit

private struct TrustFixture {
    let host: BandProtocol
    let bandTx: AirShieldCipher
    let bandRx: AirShieldReceiver
    let signingKey: P256.Signing.PrivateKey
    let proof: Data

    init() throws {
        let hostKey = P256.Signing.PrivateKey(), bandKey = P256.Signing.PrivateKey()
        signingKey = bandKey
        host = try BandProtocol(identity: BandIdentity(privateKey: hostKey.rawRepresentation,
                                                      bandPoint: BandCrypto.point(bandKey), stage: "verified"))
        let request = try DataXReceiver().feed(host.start(now: 0), padded: false)[0]
        let fields = try Fields(request.payload)
        let hostPoint = try fields.bytes(1), hostChallenge = try fields.bytes(2)
        let peer = P256.KeyAgreement.PrivateKey()
        let peerPoint = Data(peer.publicKey.x963Representation.dropFirst())
        let peerChallenge = Data(repeating: 1, count: 16), peerSeed = Data(repeating: 2, count: 32)
        let peerIV = Data(repeating: 3, count: 16)
        let hello = try Frame(channel: 0x8001, words: [0x02000001], payload:
            PB.field(1, peerPoint) + PB.field(2, peerChallenge) + PB.field(3, 0) + PB.field(4, 3)).encoded()
        let answer = try host.feed(hello, now: 1).0
        let response = try Fields(DataXReceiver().feed(answer, padded: false)[0].payload)
        let secret = try peer.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + hostPoint))
            .withUnsafeBytes { Data($0) }
        bandTx = try AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: hostChallenge, seed: peerSeed), iv: peerIV, counter: 7)
        bandRx = try AirShieldReceiver(AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: peerChallenge, seed: response.bytes(2)),
                                                      iv: response.bytes(3), counter: response.integer(4)))
        let finish = try Frame(channel: 1, words: [0x02000002], payload:
            PB.field(1, peerPoint) + PB.field(2, peerSeed) + PB.field(3, peerIV) + PB.field(4, 7) + PB.field(5, 3)).encoded()
        let trust = try host.feed(finish, now: 2).0
        _ = try bandRx.feed(trust)
        proof = BandCrypto.transcript(hostChallenge, hostPoint, peerSeed, peerPoint)
        precondition(host.stage == "trust")
    }

    func send(_ frame: Frame, now: TimeInterval = 3) throws -> (Data, [BandProtocol.Signal]) {
        try host.feed(bandTx.encrypt(frame.encoded()), now: now)
    }

    func authenticate() throws {
        _ = try send(Frame(channel: 2, words: [0x03001000], payload: Data()))
        let signature = try BandCrypto.sign(proof, privateKey: signingKey.rawRepresentation)
        let end = try send(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, signature))).0
        _ = try bandRx.feed(end)
        let deviceInfo = try send(Frame(channel: 0x8001, words: [0x02001000], payload: PB.field(1, 1) + PB.field(2, Data(repeating: 4, count: 16)))).0
        let plain = try bandRx.feed(deviceInfo)[0]
        let request = try DataXReceiver().feed(plain)[0]
        let id = try Fields(request.payload).integer(1)
        let ready = try send(Frame(channel: 3, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1) + PB.field(4, Data())))
        precondition(ready.1.contains { if case .ready = $0 { return true }; return false })
    }
}

@main
struct ConnectionDiagnosticsTests {
    static func caught(_ work: () throws -> Void) -> BandError {
        do { try work(); preconditionFailure("Expected failure") }
        catch let error as BandError { return error }
        catch { preconditionFailure("Unexpected error type") }
    }

    static func main() throws {
        for (code, expected): (UInt32, ConnectionFailure.Kind) in [
            (0x03001043, .identityMismatch), (0x03001044, .signatureRejected), (0x0300ABCD, .unknownRejection)
        ] {
            let fixture = try TrustFixture()
            let error = caught { _ = try fixture.send(Frame(channel: 2, words: [code], payload: Data())) }
            let failure = ConnectionFailure(error)
            precondition(failure.kind == expected && failure.result == code && failure.channel == 2)
            precondition(error.localizedDescription.contains(String(format: "0x%08X", code)))
            precondition(ConnectionRetryPolicy.stopsAutoConnect(error))
        }
        let timeout = try TrustFixture()
        let expired = caught { try timeout.host.tick(now: 20) }
        precondition(ConnectionFailure(expired).kind == .timeout)
        precondition(ConnectionFailure(expired).result == nil)
        precondition(SessionIssue.from(expired) == .bandNotResponding)
        precondition(ConnectionRetryPolicy.stopsAutoConnect(expired))

        let starting = try BandProtocol(identity: BandIdentity(privateKey: P256.Signing.PrivateKey().rawRepresentation,
                                                              bandPoint: nil, stage: "host_verified", allowMissingBandKey: true))
        _ = try starting.start(now: 0)
        let startupTimeout = caught { try starting.tick(now: 16) }
        precondition(ConnectionFailure(startupTimeout).kind == .timeout)
        precondition(!ConnectionRetryPolicy.stopsAutoConnect(startupTimeout))

        let invalidProof = try TrustFixture()
        let wrongSignature = try BandCrypto.sign(Data(repeating: 0, count: 32), privateKey: P256.Signing.PrivateKey().rawRepresentation)
        let proofError = caught { _ = try invalidProof.send(Frame(channel: 0x8002, words: [0x02001001], payload: PB.field(2, wrongSignature))) }
        precondition(ConnectionFailure(proofError).kind == .invalidBandProof)
        precondition(ConnectionFailure(proofError).result == nil)

        var attempt = ConnectionAttempt()
        attempt.fail(.transport("unrelated event"))
        precondition(attempt.startedAt == nil && attempt.failure == nil)
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        attempt.begin(at: old); attempt.reach(.channelOpen); attempt.reach(.encryption)
        let success = try TrustFixture()
        attempt.observeProtocolStage(success.host.stage)
        precondition(attempt.steps.contains(.encrypted) && !attempt.steps.contains(.trusted) && attempt.outcome == .connecting)
        attempt.fail(.trust(.rejected(result: 0x03001043, channel: 2)))
        attempt.stop(); attempt.reach(.ready)
        precondition(attempt.failure?.kind == .identityMismatch && attempt.outcome == .failed)
        attempt.begin(at: new)
        precondition(attempt.startedAt == new && attempt.failure == nil && attempt.steps == [.connecting])
        try success.authenticate()
        attempt.observeProtocolStage(success.host.stage)
        precondition(attempt.steps.contains(.trusted) && !attempt.steps.contains(.ready) && attempt.outcome == .connecting)
        attempt.reach(.subscribing); attempt.reach(.ready)
        precondition(attempt.failure == nil && attempt.outcome == .ready)
        for _ in 0..<100 { attempt.observeProtocolStage("ready") }
        precondition(attempt.steps.count <= ConnectionStep.allCases.count)
        attempt.stop(); precondition(attempt.outcome == .stopped)
        attempt = ConnectionAttempt()
        precondition(attempt.startedAt == nil && attempt.failure == nil && attempt.steps.isEmpty)

        let privateFixture = "fixture-private-not-real-credentials"
        let generic = ConnectionFailure(.authentication(privateFixture))
        precondition(!generic.title.contains(privateFixture) && !generic.detail.contains(privateFixture))
        let unknown = ConnectionFailure(.trust(.rejected(result: 0x0300ABCD, channel: 0x8002)))
        precondition(unknown.result == 0x0300ABCD && unknown.channel == 0x8002 && unknown.kind == .unknownRejection)
        let setup = ConnectionFailure(.setupRejected(result: 0x03001043, channel: 3))
        precondition(setup.kind == .setupRejected && setup.result == 0x03001043)
        print("Connection diagnostics passed: encrypted trust refusal, signature rejection, unknown results, timeouts, proof verification, and attempt lifecycle.")
    }
}
