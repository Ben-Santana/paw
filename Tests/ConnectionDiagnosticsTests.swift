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

    func requestHand(_ operation: String, payload: Data = Data(), now: TimeInterval = 4) throws -> Frame {
        let output = try host.request(operation, channel: 6, field: 5, payload: payload, now: now)
        return try DataXReceiver().feed(bandRx.feed(output)[0])[0]
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
        try handSettings()
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

    static func handSettings() throws {
        precondition(Handedness.right.configuration == Data([0x50, 0x00]))
        precondition(Handedness.left.configuration == Data([0x50, 0x01]))
        for hand in [Handedness.left, .right] {
            let fixture = try TrustFixture(); try fixture.authenticate()
            let write = try fixture.requestHand("set_hand", payload: hand.configuration)
            let fields = try Fields(write.payload), id = try fields.integer(1)
            let writtenConfig = try fields.bytes(5)
            precondition(writtenConfig == hand.configuration, "Only field10 may be written")
            _ = caught { _ = try fixture.requestHand("read_hand") }
            for (channel, replyID): (UInt16, UInt64) in [(5, id), (6, id + 100)] {
                let stale = try fixture.send(Frame(channel: channel, words: [0x02000315], payload: PB.field(1, replyID) + PB.field(2, 1)), now: 5)
                precondition(stale.1.isEmpty)
            }
            let written = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 1)), now: 5)
            precondition(written.1.contains { if case .reply("set_hand", _) = $0 { return true }; return false })
            let read = try fixture.requestHand("read_hand", now: 6)
            let readFields = try Fields(read.payload), readID = try readFields.integer(1)
            let readConfig = try readFields.bytes(5)
            precondition(readConfig.isEmpty)
            let payload = PB.field(1, readID) + PB.field(2, 1) + PB.field(6, hand.configuration + PB.field(6, 2))
            let readBack = try fixture.send(Frame(channel: 6, words: [0x02000315], payload: payload), now: 7)
            precondition(readBack.1.contains { if case .reply("read_hand", let value) = $0 { return Handedness.read(value) == hand }; return false })
        }
        for config in [Data(), PB.field(10, 2), PB.field(10, 0) + PB.field(10, 1), PB.field(10, Data())] {
            precondition(Handedness.read(PB.field(6, config)) == nil)
        }

        for operation in ["read_hand", "set_hand"] {
            let refused = try TrustFixture(); try refused.authenticate()
            let request = try refused.requestHand(operation, payload: operation == "set_hand" ? Handedness.left.configuration : Data())
            let id = try Fields(request.payload).integer(1)
            let signals = try refused.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 5).1
            precondition(signals.contains { if case .handUnavailable = $0 { return true }; return false })
            precondition(refused.host.stage == "ready")
            _ = try refused.requestHand("read_hand", now: 6)

            let timeout = try TrustFixture(); try timeout.authenticate()
            let pending = try timeout.requestHand(operation)
            let staleID = try Fields(pending.payload).integer(1)
            let expired = try timeout.host.tick(now: 13)
            precondition(expired.contains { if case .handUnavailable = $0 { return true }; return false })
            precondition(timeout.host.stage == "ready")
            let lateClose = try timeout.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 13)
            precondition(lateClose.1.isEmpty && timeout.host.stage == "ready")
            _ = try timeout.requestHand("read_hand", now: 14)
            let stale = try timeout.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, staleID) + PB.field(2, 1) + PB.field(6, Handedness.left.configuration)), now: 15)
            precondition(stale.1.isEmpty)

            let closed = try TrustFixture(); try closed.authenticate()
            _ = try closed.requestHand(operation)
            let close = try closed.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 5)
            precondition(close.1.contains { if case .handUnavailable = $0 { return true }; return false })
            let reopened = try closed.requestHand("read_hand", now: 6)
            precondition(reopened.words == [0x8100ce56, 0x02000314])

            for status in [Data(), PB.field(2, 1) + PB.field(2, 1), PB.field(2, Data()), PB.field(2, 2)] {
                let malformed = try TrustFixture(); try malformed.authenticate()
                let request = try malformed.requestHand(operation)
                let id = try Fields(request.payload).integer(1)
                let reply = try malformed.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + status), now: 5)
                precondition(reply.1.contains { if case .handUnavailable = $0 { return true }; return false })
                precondition(malformed.host.stage == "ready")
            }
        }
        let required = try TrustFixture(); try required.authenticate()
        let request = try required.requestHand("request_active", payload: PB.field(6, 2))
        let id = try Fields(request.payload).integer(1)
        _ = caught { _ = try required.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 5) }
        _ = try required.requestHand("request_active", payload: PB.field(6, 2), now: 6)
        _ = caught { _ = try required.send(Frame(channel: 6, words: [0x03000001], payload: Data()), now: 7) }

        let live = try TrustFixture(); try live.authenticate()
        let flags = BandProtocol.streamFlags(gyro: false, orientation: false)
        let start = try live.host.request("start_streams", channel: 5, field: 4, payload: flags, now: 4)
        let startFrame = try DataXReceiver().feed(live.bandRx.feed(start)[0])[0]
        let startID = try Fields(startFrame.payload).integer(1)
        _ = try live.send(Frame(channel: 5, words: [0x02000315], payload: PB.field(1, startID) + PB.field(2, 1) + PB.field(5, flags)), now: 5)
        for timedOut in [false, true] {
            let request = try live.requestHand("set_hand", payload: Handedness.left.configuration, now: timedOut ? 10 : 6)
            let id = try Fields(request.payload).integer(1)
            if timedOut { _ = try live.host.tick(now: 19) }
            else { _ = try live.send(Frame(channel: 6, words: [0x02000315], payload: PB.field(1, id) + PB.field(2, 0)), now: 7) }
            let gesture = try live.send(Frame(channel: 0x8005, words: [0x0200020d], payload:
                PB.field(1, timedOut ? 2 : 1) + PB.field(2, 100) + PB.field(3, 2) + PB.field(4, 1)), now: timedOut ? 20 : 8)
            precondition(gesture.1.contains { if case .gesture(2, 1, _, _, _, _) = $0 { return true }; return false })
        }

        var setting = HandSetting(confirmed: .right)
        precondition(setting.read() && !setting.change(to: .left))
        precondition(setting.received(.right))
        precondition(setting.change(to: .left) && !setting.change(to: .right) && !setting.read())
        precondition(setting.confirmed == nil && !setting.received(.left))
        precondition(setting.wrote() && !setting.wrote() && setting.confirmed == nil)
        precondition(setting.received(.left) && setting.confirmed == .left && !setting.busy && setting.error == nil)
        precondition(setting.change(to: .right) && setting.wrote())
        precondition(setting.received(.left) && setting.confirmed == .left && setting.error != nil)
        precondition(setting.change(to: .right) && setting.wrote())
        precondition(!setting.received(nil) && setting.confirmed == nil && setting.error != nil)
        precondition(setting.change(to: .right)); setting.fail("Timed out")
        precondition(setting.confirmed == nil && !setting.busy)
        precondition(setting.change(to: .left), "A cached value must remain selectable after an uncertain write")
        setting.cancel()
        precondition(setting.change(to: .right)); setting.cancel()
        precondition(!setting.wrote() && !setting.received(.right) && setting.confirmed == nil)
        setting = HandSetting()
        precondition(!setting.received(.right) && setting.confirmed == nil)
        print("Wrist setting checks passed: explicit0/1 partial writes, serialized readback, rejection, timeout, stale replies and confirmed state.")
    }
}
