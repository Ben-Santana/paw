import Foundation
import CryptoKit

enum OwnershipStep {
    case write(Data), claim(certificate: Data, serial: String, secondary: Data, nonce: Data, appPoint: Data)
    case pair(receipt: String, signature: Data), complete(BandIdentity)
}
struct PairCompletion { let signature: Data; let receipt: String; var bandPoint: Data? }

struct BandSetupAuthorization {
    struct Request: Equatable { let id = UUID(); let band: UUID }
    private(set) var current: Request?

    mutating func begin(for band: UUID) -> Request {
        let request = Request(band: band); current = request; return request
    }
    mutating func cancel() { current = nil }
    mutating func finish(_ request: Request) -> Bool {
        guard current == request else { return false }
        current = nil; return true
    }
    func validate(_ request: Request, selected: UUID?, foreground: Bool) throws {
        guard current == request, selected == request.band else { throw BandError.cancelled }
        guard foreground else { throw BandError.authentication("Return to Runes to set up your band.") }
    }
    static func canRestart(_ snapshot: SessionSnapshot, for band: UUID? = nil, foreground: Bool, signingIn: Bool) -> Bool {
        foreground && !signingIn && snapshot.selected != nil && !snapshot.wantsConnection
            && (band == nil || snapshot.selected == band)
            && [.failed, .disconnected].contains(snapshot.state)
    }
}

struct IdentityConfirmation {
    enum Result: Equatable { case reconnect, committed, ignored }
    private enum Phase { case inactive, connecting, reconnectRequired, verifying }
    private var phase = Phase.inactive

    mutating func beginConnection() { if phase != .verifying { phase = .connecting } }
    mutating func enrolled() { phase = .reconnectRequired }
    mutating func cancel() { phase = .inactive }
    mutating func authenticated(commit: () throws -> Void) rethrows -> Result {
        switch phase {
        case .inactive: return .ignored
        case .reconnectRequired: phase = .verifying; return .reconnect
        case .connecting, .verifying:
            try commit(); phase = .inactive; return .committed
        }
    }
}

final class OwnershipCeremony {
    private(set) var record: BandIdentity
    private var certificate = Data(), secondary = Data(), serial = ""
    private let persist: (BandIdentity) throws -> Void
    init(previous: BandIdentity?, allowMissingBandKey: Bool = false, persist: @escaping (BandIdentity) throws -> Void) throws {
        // Every explicit restart repeats the ceremony with its persisted host key.
        record = BandIdentity(privateKey: previous?.privateKey ?? P256.Signing.PrivateKey().rawRepresentation, bandPoint: previous?.bandPoint, stage: "identity", allowMissingBandKey: allowMissingBandKey ? true : nil)
        self.persist = persist; try persist(record)
    }
    private func advance(_ stage: String) throws { record.stage = stage; try persist(record) }
    func start() throws -> Data { try Frame(channel: 0x8002, words: [0x81000024, 0x02003000], payload: Data()).encoded() }
    func receive(kind: UInt32, payload: Data) throws -> OwnershipStep {
        let f = try Fields(payload)
        switch (record.stage, kind) {
        case ("identity", 0x02003001):
            certificate = try f.bytes(1); secondary = try f.bytes(5)
            guard let text = String(data: try f.bytes(2), encoding: .ascii), !text.isEmpty, certificate.count > 256, secondary.count > 256 else { throw BandError.authentication("Band identity is incomplete.") }
            serial = text; try advance("nonce")
            return .write(try Frame(channel: 0x8002, words: [0x02002000], payload: Data()).encoded())
        case ("nonce", 0x02002001):
            let nonce = try f.bytes(1, count: 16); try advance("pair_request")
            let key = try P256.Signing.PrivateKey(rawRepresentation: record.privateKey)
            return .claim(certificate: certificate, serial: serial, secondary: secondary, nonce: nonce, appPoint: BandCrypto.point(key))
        case ("start", 0x02002003):
            let signature = try f.bytes(1)
            guard let receipt = String(data: try f.bytes(2), encoding: .utf8), !receipt.isEmpty, !signature.isEmpty else { throw BandError.authentication("Band ownership receipt is invalid.") }
            try advance("pair"); return .pair(receipt: receipt, signature: signature)
        case ("finish", 0x02002005) where payload.isEmpty:
            try advance("confirmed"); return .complete(record)
        default: throw BandError.authentication("Unexpected ownership response at \(record.stage).")
        }
    }
    func resume(_ completion: PairCompletion) throws -> Data {
        guard !completion.signature.isEmpty, !completion.receipt.isEmpty else { throw BandError.authentication("Ownership service returned an empty receipt.") }
        let kind: UInt32
        switch record.stage {
        case "pair_request": kind = 0x02002002; try advance("start")
        case "pair":
            // Preserve a known band key when the service omits it. A supplied
            // malformed or conflicting key must never fall back to compatibility.
            if let point = completion.bandPoint {
                guard point.count == 64 else { throw BandError.authentication("Ownership service returned an invalid band key.") }
                _ = try P256.Signing.PublicKey(x963Representation: Data([4]) + point)
                if let expected = record.bandPoint, expected != point { throw BandError.authentication("Ownership service returned a different band key.") }
                record.bandPoint = point
            }
            guard record.bandPoint != nil || record.allowMissingBandKey == true else {
                throw BandError.authentication("Ownership service omitted the band public key. Verified enrollment cannot finish.")
            }
            if record.bandPoint != nil { record.allowMissingBandKey = nil }
            kind = 0x02002004; try advance("finish")
        default: throw BandError.authentication("Enrollment is not waiting for a server response.")
        }
        return try Frame(channel: 0x8002, words: [kind], payload: PB.field(1, completion.signature) + PB.field(2, Data(completion.receipt.utf8))).encoded()
    }
}
