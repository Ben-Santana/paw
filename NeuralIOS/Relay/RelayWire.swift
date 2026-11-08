import Foundation
import CryptoKit

enum RelayWire {
    static let service = "2B67A830-8040-46D0-BA77-6E1A7E94F50A"
    static let control = "2B67A831-8040-46D0-BA77-6E1A7E94F50A"
    static let events = "2B67A832-8040-46D0-BA77-6E1A7E94F50A"
    /// Reading this encrypted characteristic makes iOS bond with the Mac.
    static let bond = "2B67A833-8040-46D0-BA77-6E1A7E94F50A"
    static let maxFrame = 4096

    struct Invitation: Codable {
        var kind = "neural-ble-prototype-v1"
        let key: Data
        let expires: Date

        static func parse(_ text: String, now: Date = Date()) throws -> Self {
            guard text.utf8.count <= 512,
                  let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
                  value.kind == "neural-ble-prototype-v1", value.key.count == 32,
                  value.expires > now else { throw Failure.invalidInvitation }
            return value
        }
    }

    enum Failure: LocalizedError {
        case invalidInvitation, invalidFrame, invalidSequence
        var errorDescription: String? {
            switch self {
            case .invalidInvitation: return "This test QR code is invalid or has expired."
            case .invalidFrame: return "Invalid Bluetooth relay frame."
            case .invalidSequence: return "Bluetooth relay sequence is out of order."
            }
        }
    }

    struct Demand: Codable, Equatable, Sendable {
        let active: Bool
        let gyro: Bool
        let orientation: Bool
        static let idle = Self(active: false, gyro: false, orientation: false)
        static let gestures = Self(active: true, gyro: false, orientation: false)
        static let motion = Self(active: true, gyro: true, orientation: true)
    }

    struct Event: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case gesture, gyro, orientation }
        let kind: Kind
        let sequence: UInt64
        let timestamp: UInt64
        let phoneUptime: TimeInterval
        let phoneTime: Date
        var gesture: [UInt64]? = nil
        var values: [Double]? = nil
    }

    /// A GATT notification from the Mac. It is the wake signal under test.
    struct Heartbeat: Codable, Sendable {
        let sequence: UInt64
        let macTime: Date
    }

    struct HeartbeatAck: Codable, Sendable {
        let sequence: UInt64
        let phoneTime: Date
        let applicationState: String
        let bandState: String
        /// Seconds since the last L2CAP bytes from the band, if any arrived.
        let bandDataAge: TimeInterval?
        /// Times the phone process stopped running for over `WakeProbe.gapThreshold`.
        let suspensionGaps: Int
        let longestGap: TimeInterval
        let batteryLevel: Float?
        let lowPowerMode: Bool
    }

    enum Message: Codable {
        case hello
        case demand(Demand)
        case ready(Demand?)
        case event(Event)
        case heartbeat(Heartbeat)
        case heartbeatAck(HeartbeatAck)
    }

    static func frame(_ payload: Data) throws -> Data {
        guard (1...maxFrame).contains(payload.count) else { throw Failure.invalidFrame }
        return Data([UInt8(payload.count >> 8), UInt8(payload.count & 255)]) + payload
    }

    struct Framer {
        private var buffer = Data()

        mutating func append(_ bytes: Data) throws -> [Data] {
            guard buffer.count + bytes.count <= maxFrame * 2 + 2 else { throw Failure.invalidFrame }
            buffer.append(bytes)
            var frames: [Data] = []
            while buffer.count >= 2 {
                let length = Int(buffer[buffer.startIndex]) * 256 + Int(buffer[buffer.startIndex + 1])
                guard (1...maxFrame).contains(length) else { throw Failure.invalidFrame }
                guard buffer.count >= length + 2 else { break }
                frames.append(Data(buffer.dropFirst(2).prefix(length)))
                buffer = Data(buffer.dropFirst(length + 2))
            }
            return frames
        }
    }

    /// Fresh challenges from both peers separate links. Directional keys separate control and events.
    /// Counters authenticated as associated data reject replay and reordering within a link.
    struct Cipher {
        private let sendKey: SymmetricKey
        private let receiveKey: SymmetricKey
        private var sent: UInt64 = 0
        private var received: UInt64 = 0

        init(key: Data, challenge: Data, isPhone: Bool) throws {
            guard key.count == 32, challenge.count == 64 else { throw Failure.invalidFrame }
            let secret = SymmetricKey(data: key)
            func derive(_ direction: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: challenge,
                                       info: Data("neural-ble-prototype-v1/\(direction)".utf8), outputByteCount: 32)
            }
            sendKey = derive(isPhone ? "phone-to-mac" : "mac-to-phone")
            receiveKey = derive(isPhone ? "mac-to-phone" : "phone-to-mac")
        }

        private func counter(_ value: UInt64) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }

        mutating func seal(_ message: Message) throws -> Data {
            guard sent < UInt64.max else { throw Failure.invalidSequence }
            let prefix = counter(sent)
            let box = try AES.GCM.seal(JSONEncoder().encode(message), using: sendKey, authenticating: prefix)
            guard let combined = box.combined else { throw Failure.invalidFrame }
            let frame = try RelayWire.frame(prefix + combined)
            sent += 1
            return frame
        }

        mutating func open(_ payload: Data) throws -> Message {
            guard received < UInt64.max, payload.count >= 36,
                  payload.prefix(8) == counter(received) else { throw Failure.invalidSequence }
            let box = try AES.GCM.SealedBox(combined: payload.dropFirst(8))
            let message = try JSONDecoder().decode(Message.self, from: AES.GCM.open(box, using: receiveKey, authenticating: payload.prefix(8)))
            received += 1
            return message
        }
    }
}
