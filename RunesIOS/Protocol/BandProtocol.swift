import Foundation
import CryptoKit

// Mutated exclusively on the transport's run-loop thread.
final class BandProtocol {
    enum Signal {
        case ready, reply(operation: String, payload: Data), ownership(OwnershipStep), enrolled(BandIdentity)
        case motion(kind: RelayWire.Event.Kind, values: [Double], sequence: UInt64, timestamp: UInt64)
        case gesture(finger: UInt64, action: UInt64, derived: UInt64, synthetic: Bool, sequence: UInt64, timestamp: UInt64)
        /// One EMG batch: 16 samples × 8 channels, sample-major, raw 16-bit ADC counts.
        case emg(values: [UInt16], sequence: UInt64, timestamp: UInt64)
        /// The band would not provide EMG. The connection stays up; EMG is simply left off.
        case emgUnavailable(String)
    }
    private struct Pending { let operation: String; let id: UInt64; let deadline: TimeInterval; let flags: Data? }
    private var identity: BandIdentity?
    private let ceremony: OwnershipCeremony?
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let challenge: Data, seed: Data, iv: Data, counter: UInt64
    private var point: Data { Data(ephemeral.publicKey.x963Representation.dropFirst()) }
    private var peerPoint: Data?, peerChallenge: Data?, peerSeed: Data?
    private var tx: AirShieldCipher?, rx: AirShieldReceiver?
    private let clear = DataXReceiver(), frames = DataXReceiver()
    private var types: [UInt16: UInt32] = [:], pending: [UInt16: Pending] = [:], opened: Set<UInt16> = []
    private var nextID: UInt64 = 0
    private var hostTrusted = false, bandTrusted = false, endSent = false, gesturesEnabled = false, gyroEnabled = false, orientationEnabled = false, emgEnabled = false
    private(set) var stage = "idle"
    private var deadline = TimeInterval.infinity
    init(identity: BandIdentity?, ceremony: OwnershipCeremony? = nil) throws {
        guard (identity == nil) != (ceremony == nil) else { throw BandError.authentication("Provide identity or explicit enrollment.") }
        self.identity = identity; self.ceremony = ceremony
        challenge = try BandCrypto.random(16); seed = try BandCrypto.random(32); iv = try BandCrypto.random(16)
        counter = UInt64(try BandCrypto.random(4).be32(0))
    }
    private func frame(_ channel: UInt16, _ words: [UInt32], _ payload: Data = Data()) throws -> Data { try Frame(channel: channel, words: words, payload: payload).encoded() }
    func start(now: TimeInterval) throws -> Data {
        stage = "encryption"; deadline = now + 15
        return try frame(0x8001, [0x81000005, 0x02000001], PB.field(1, point) + PB.field(2, challenge) + PB.field(3, 0) + PB.field(4, 31) + PB.field(7, 16))
    }
    func tick(now: TimeInterval) throws {
        if now >= deadline {
            if ["trust", "ceremony"].contains(stage) { throw BandError.authentication("Band authentication timed out at \(stage). Retry in the foreground.") }
            throw BandError.transport("Band startup timed out at \(stage).")
        }
        if let p = pending.values.first(where: { now >= $0.deadline }) { throw BandError.transport("Band request timed out: \(p.operation).") }
    }
    func encrypt(_ data: Data) throws -> Data {
        guard let tx else { throw BandError.wire("Encryption is not established.") }
        var output = Data(), offset = 0
        while offset < data.count { let end = min(offset + 4096, data.count); output.append(try tx.encrypt(data.portion(offset..<end))); offset = end }
        return output
    }
    func resume(_ completion: PairCompletion) throws -> Data {
        guard stage == "ceremony", let ceremony else { throw BandError.authentication("No enrollment is pending.") }
        return try encrypt(ceremony.resume(completion))
    }
    func request(_ operation: String, channel: UInt16, field: Int, payload: Data, now: TimeInterval, setup: Bool = false) throws -> Data {
        guard stage == "ready" || setup, pending[channel] == nil else { throw BandError.wire("Request is invalid for this protocol state.") }
        nextID += 1
        let words: [UInt32] = opened.contains(channel) ? [] : [0x8100ce56, 0x02000314]
        if !words.isEmpty { types[channel] = nil; types[channel | 0x8000] = nil }
        opened.insert(channel)
        pending[channel] = Pending(operation: operation, id: nextID, deadline: now + 8, flags: ["start_streams", "stop_streams"].contains(operation) ? payload : nil)
        return try encrypt(frame(channel | 0x8000, words, PB.field(1, nextID) + PB.field(field, payload)))
    }
    func feed(_ input: Data, now: TimeInterval) throws -> (Data, [Signal]) {
        try tick(now: now)
        var output = Data(), signals: [Signal] = [], data = input
        if rx == nil {
            guard clear.pending.count + input.count <= 1 << 20 else { throw BandError.wire("Setup buffer overflow.") }
            clear.pending.append(input); data = Data()
            while rx == nil, clear.pending.count >= 4 {
                let size = Int(clear.pending.be16(0) & 0x7fff) + 4
                guard size >= 8, clear.pending.octet(0) & 0x80 != 0 else { throw BandError.wire("Invalid clear handshake frame.") }
                if clear.pending.count < size { break }
                let packet = clear.pending.portion(0..<size); clear.pending = Data(clear.pending.dropFirst(size))
                guard let frame = try DataXReceiver().feed(packet, padded: false).first else { throw BandError.wire("Empty handshake frame.") }
                output.append(try handshake(frame, now: now))
            }
            if rx != nil { data = clear.pending; clear.pending = Data() }
        }
        if let rx {
            for plain in try rx.feed(data) {
                for packet in try frames.feed(plain) {
                    let (out, emitted) = try receive(packet, now: now); output.append(out); signals.append(contentsOf: emitted)
                }
            }
        }
        return (output, signals)
    }
    private func handshake(_ packet: Frame, now: TimeInterval) throws -> Data {
        guard let kind = packet.words.last else { throw BandError.wire("Untyped encryption response.") }
        let f = try Fields(packet.payload), peer = try f.bytes(1, count: 64)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + peer)
        if kind == 0x02000001 {
            guard packet.channel == 0x8001, peerPoint == nil, try f.integer(3) == 0, try f.integer(4) == 3 else { throw BandError.wire("Unsupported encryption request.") }
            peerPoint = peer; peerChallenge = try f.bytes(2, count: 16)
            return try frame(1, [0x02000002], PB.field(1, point) + PB.field(2, seed) + PB.field(3, iv) + PB.field(4, counter) + PB.field(5, 3))
        }
        guard kind == 0x02000002, packet.channel == 1, peer == peerPoint, let peerChallenge, try f.integer(5) == 3 else { throw BandError.wire("Unexpected encryption response.") }
        let peerSeed = try f.bytes(2, count: 32); self.peerSeed = peerSeed
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        tx = try AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: peerChallenge, seed: seed), iv: iv, counter: counter)
        rx = try AirShieldReceiver(AirShieldCipher(key: BandCrypto.key(secret: secret, challenge: challenge, seed: peerSeed), iv: f.bytes(3, count: 16), counter: f.integer(4)))
        if let ceremony { stage = "ceremony"; deadline = now + 180; return try encrypt(ceremony.start()) }
        stage = "trust"; deadline = now + 15; return try enableTrust()
    }
    private func enableTrust(opened: Bool = false) throws -> Data {
        guard let identity, let peerPoint, let peerChallenge else { throw BandError.authentication("Incomplete trust transcript.") }
        let key = try P256.Signing.PrivateKey(rawRepresentation: identity.privateKey)
        let signature = try BandCrypto.sign(BandCrypto.transcript(peerChallenge, peerPoint, seed, point), privateKey: identity.privateKey)
        return try encrypt(frame(0x8002, opened ? [0x02001000] : [0x81000024, 0x02001000], PB.field(1, Data(SHA256.hash(data: BandCrypto.point(key)))) + PB.field(2, signature)))
    }
    private func maybeEnd() throws -> Data {
        if hostTrusted && bandTrusted && !endSent {
            endSent = true
            return try encrypt(frame(0x8001, [0x02001000], PB.field(1, 1) + PB.field(2, BandCrypto.random(16))))
        }
        return Data()
    }
    private func receive(_ packet: Frame, now: TimeInterval) throws -> (Data, [Signal]) {
        let kind: UInt32
        if let word = packet.words.last {
            if word & 0xff000000 == 0x03000000 { return try result(packet, kind: word) }
            guard types.count < 1024 || types[packet.channel] != nil else { throw BandError.wire("Too many protocol channels.") }
            types[packet.channel] = word; kind = word
        } else if let word = types[packet.channel] { kind = word } else { return (Data(), []) }
        if kind == 0x02001001 && bandTrusted { throw BandError.authentication("Duplicate band proof.") }
        if stage == "ceremony", let ceremony {
            guard packet.channel & 0x7fff == 2 else { return (Data(), []) }
            let step = try ceremony.receive(kind: kind, payload: packet.payload)
            switch step {
            case .write(let bytes): return (try encrypt(bytes), [])
            case .complete(let identity):
                self.identity = identity; stage = "trust"; deadline = now + 15
                return (try enableTrust(opened: true), [.enrolled(identity)])
            default: return (Data(), [.ownership(step)])
            }
        }
        if stage == "trust" {
            if kind == 0x02001001, packet.channel & 0x8000 != 0 {
                guard let identity, let peerPoint, let peerSeed else { throw BandError.authentication("Verified band identity is missing.") }
                let signature = try Fields(packet.payload).bytes(2, count: 64)
                if let bandPoint = identity.bandPoint {
                    try BandCrypto.verify(BandCrypto.transcript(challenge, point, peerSeed, peerPoint), signature: signature, point: bandPoint)
                } else if identity.allowMissingBandKey != true {
                    throw BandError.authentication("Band proof requires a saved public key.")
                }
                bandTrusted = true
                return (try encrypt(frame(packet.channel & 0x7fff, [0x03001000])) + maybeEnd(), [])
            }
            if kind == 0x02001000, packet.channel == 0x8001, endSent {
                let f = try Fields(packet.payload)
                guard try f.integer(1) == 1 else { throw BandError.wire("Invalid setup acknowledgement.") }
                _ = try f.bytes(2, count: 16); stage = "device_info"; deadline = now + 8
                return (try request("device_info", channel: 3, field: 3, payload: Data(), now: now, setup: true), [])
            }
            return (Data(), [])
        }
        if kind == 0x02000315, packet.channel & 0x8000 == 0 {
            let f = try Fields(packet.payload), id = try f.integer(1)
            guard let p = pending[packet.channel], p.id == id else { return (Data(), []) }
            pending[packet.channel] = nil
            // EMG is optional: a refused configuration read is reported, never fatal.
            if p.operation == "emg_configuration" { return (Data(), [.reply(operation: p.operation, payload: packet.payload)]) }
            let wantsEMG = try p.flags.map { try Fields($0).integer(2) == 1 } ?? false
            if try f.integer(2) != 1, wantsEMG {
                return (Data(), [.emgUnavailable("Band rejected a stream request that included EMG.")])
            }
            guard try f.integer(2) == 1 else { throw BandError.wire("Band rejected \(p.operation).") }
            if p.operation == "device_info" {
                _ = try Fields(f.bytes(4)); stage = "ready"; deadline = .infinity
                return (Data(), [.ready])
            }
            if let flags = p.flags {
                let wanted = try Fields(flags), accepted = try Fields(f.bytes(5))
                if try wanted.integer(2) == 1, try accepted.integer(2, default: 0) != 1 {
                    return (Data(), [.emgUnavailable("Band acknowledged streams without EMG.")])
                }
                for n in [2, 3, 6, 8] { guard try accepted.integer(n) == wanted.integer(n) else { throw BandError.wire("Band stream acknowledgement differs from request.") } }
                gesturesEnabled = try wanted.integer(3) == 1
                gyroEnabled = try wanted.integer(6) == 1
                orientationEnabled = try wanted.integer(8) == 1
                emgEnabled = try wanted.integer(2) == 1
            }
            return (Data(), [.reply(operation: p.operation, payload: packet.payload)])
        }
        if stage == "ready", gesturesEnabled, kind == 0x0200020d {
            let f = try Fields(packet.payload), synthetic = try f.integer(12, default: 0)
            guard synthetic <= 1 else { throw BandError.wire("Invalid gesture synthetic flag.") }
            return (Data(), [.gesture(finger: try f.integer(3, default: 0), action: try f.integer(4, default: 0), derived: try f.integer(5, default: 0), synthetic: synthetic == 1, sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", gyroEnabled, kind == 0x0200020f {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 6)
            return (Data(), [.motion(kind: .gyro, values: Self.gyro(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", orientationEnabled, kind == 0x02000212 {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 16)
            return (Data(), [.motion(kind: .orientation, values: try Self.orientation(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        if stage == "ready", emgEnabled, kind == 0x0200020a {
            let f = try Fields(packet.payload), bytes = try f.bytes(3, count: 256)
            return (Data(), [.emg(values: EMG.decode(bytes), sequence: try f.integer(1), timestamp: try f.integer(2))])
        }
        return (Data(), [])
    }
    private func result(_ packet: Frame, kind: UInt32) throws -> (Data, [Signal]) {
        let channel = packet.channel & 0x7fff
        if stage == "trust", channel == 2 {
            guard kind == 0x03001000 else { throw BandError.authentication("Band rejected host identity (result 0x\(String(kind, radix: 16)), channel \(packet.channel)). Check the selected public host fingerprint.") }
            guard !hostTrusted else { throw BandError.wire("Duplicate host authentication acknowledgement (channel \(packet.channel)).") }
            hostTrusted = true; return (try maybeEnd(), [])
        }
        if stage != "ready" { throw BandError.authentication("Band setup rejected (\(String(kind, radix: 16))).") }
        if let p = pending[channel], p.operation == "emg_configuration" {
            pending[channel] = nil
            return (Data(), [.emgUnavailable("Band closed the EMG configuration service (\(String(kind, radix: 16))).")])
        }
        if pending[channel] != nil || [5, 6, 7].contains(channel) { throw BandError.wire("Band service closed (\(String(kind, radix: 16))).") }
        return (Data(), [])
    }
    static func streamFlags(gyro: Bool, orientation: Bool, emg: Bool = false) -> Data {
        PB.field(2, emg ? 1 : 0) + PB.field(3, 1) + PB.field(6, gyro ? 1 : 0) + PB.field(8, orientation ? 1 : 0)
    }
    static func gyro(_ bytes: Data) -> [Double] {
        (0..<3).map { index in
            let offset = index * 2
            let bits = UInt16(bytes.octet(offset)) | UInt16(bytes.octet(offset + 1)) << 8
            return Double(Int16(bitPattern: bits))
        }
    }
    static func orientation(_ bytes: Data) throws -> [Double] {
        let values = (0..<4).map { Double(Float(bitPattern: bytes.be32($0 * 4).byteSwapped)) }
        guard values.allSatisfy(\.isFinite) else { throw BandError.wire("Invalid orientation sample.") }
        return values
    }
    static let stopFlags = PB.field(2, 0) + PB.field(3, 0) + PB.field(6, 0) + PB.field(8, 0)
}
