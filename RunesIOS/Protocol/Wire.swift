// Protocol port of meta-neural-py 0.1.0a1. See THIRD_PARTY_NOTICES.md.
import Foundation

enum BandError: LocalizedError {
    case transport(String), pairing(String), wire(String), authentication(String), storage(String), cancelled
    var errorDescription: String? {
        switch self {
        case .transport(let s), .pairing(let s), .wire(let s), .authentication(let s), .storage(let s): return s
        case .cancelled: return "Operation cancelled."
        }
    }
    var requiresUser: Bool {
        switch self { case .authentication, .storage, .pairing, .wire: return true; default: return false }
    }
}

extension Data {
    func octet(_ offset: Int) -> UInt8 { self[index(startIndex, offsetBy: offset)] }
    func portion(_ range: Range<Int>) -> Data { Data(self[index(startIndex, offsetBy: range.lowerBound)..<index(startIndex, offsetBy: range.upperBound)]) }
    func be16(_ offset: Int) -> UInt16 { UInt16(octet(offset)) << 8 | UInt16(octet(offset + 1)) }
    func be32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(octet(offset + $1)) } }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}

enum PB {
    static func varint(_ value: UInt64) -> Data {
        var n = value, out = Data()
        while n >= 128 { out.append(UInt8(n & 127) | 128); n >>= 7 }
        out.append(UInt8(n)); return out
    }
    static func field(_ n: Int, _ value: UInt64) -> Data { varint(UInt64(n << 3)) + varint(value) }
    static func field(_ n: Int, _ value: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(value.count)) + value }
}

struct Fields {
    enum Value { case integer(UInt64), bytes(Int, Data) }
    private(set) var values: [Int: [Value]] = [:]
    init(_ data: Data) throws {
        guard data.count <= 1 << 20 else { throw BandError.wire("Protobuf message exceeds limit.") }
        var offset = 0
        func read() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw BandError.wire("Truncated protobuf varint.") }
                let byte = data.octet(offset); offset += 1
                guard shift < 63 || byte <= 1 else { throw BandError.wire("Protobuf varint overflow.") }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw BandError.wire("Invalid protobuf varint.")
        }
        while offset < data.count {
            let tag = try read(), number = tag >> 3, wire = Int(tag & 7)
            guard number > 0, number < 1 << 29 else { throw BandError.wire("Invalid protobuf field.") }
            let value: Value
            if wire == 0 { value = .integer(try read()) }
            else {
                guard [1, 2, 5].contains(wire) else { throw BandError.wire("Unsupported protobuf wire type.") }
                let length = try wire == 2 ? read() : UInt64(wire == 1 ? 8 : 4)
                guard length <= UInt64(data.count - offset) else { throw BandError.wire("Truncated protobuf field.") }
                value = .bytes(wire, data.portion(offset..<(offset + Int(length)))); offset += Int(length)
            }
            values[Int(number), default: []].append(value)
        }
    }
    func integer(_ n: Int, default fallback: UInt64? = nil) throws -> UInt64 {
        if values[n] == nil, let fallback { return fallback }
        guard let v = values[n], v.count == 1, case .integer(let x) = v[0] else { throw BandError.wire("Expected integer field \(n).") }
        return x
    }
    func bytes(_ n: Int, count: Int? = nil) throws -> Data {
        guard let v = values[n], v.count == 1, case .bytes(2, let x) = v[0], count == nil || count == x.count else { throw BandError.wire("Invalid byte field \(n).") }
        return x
    }
}

struct Frame {
    var channel: UInt16
    var words: [UInt32]
    var payload: Data
    func encoded() throws -> Data {
        guard payload.count + words.count * 4 <= 0x7fff,
              words.enumerated().allSatisfy({ (($0.element & 0x80000000) != 0) == ($0.offset < words.count - 1) }) else { throw BandError.wire("Invalid DataX frame.") }
        var out = Data(); out.appendBE(UInt16(payload.count + words.count * 4) | (words.isEmpty ? 0 : 0x8000)); out.appendBE(channel)
        for word in words { out.appendBE(word) }; out.append(payload); return out
    }
}

final class DataXReceiver {
    var pending = Data()
    func feed(_ input: Data, padded: Bool = true) throws -> [Frame] {
        var data = input
        if padded {
            guard !data.isEmpty, data.count % 16 == 0 else { throw BandError.wire("Unaligned DataX record.") }
            let padding = Int(data.octet(data.count - 1)) - 0xc0
            if (1...15).contains(padding), data.suffix(padding).allSatisfy({ $0 == UInt8(0xc0 + padding) }), !endsAtBoundary(data) { data.removeLast(padding) }
        }
        guard pending.count + data.count <= 1 << 20 else { throw BandError.wire("DataX buffer overflow.") }
        pending.append(data); var result: [Frame] = []
        while pending.count >= 4 {
            let length = pending.be16(0), size = Int(length & 0x7fff) + 4
            if pending.count < size { break }
            var offset = 4, words: [UInt32] = []
            if length & 0x8000 != 0 {
                while true {
                    guard offset + 4 <= size else { throw BandError.wire("Truncated DataX header.") }
                    let word = pending.be32(offset); words.append(word); offset += 4
                    if word & 0x80000000 == 0 { break }
                }
            }
            result.append(Frame(channel: pending.be16(2), words: words, payload: pending.portion(offset..<size)))
            pending = Data(pending.dropFirst(size))
        }
        return result
    }
    private func endsAtBoundary(_ data: Data) -> Bool {
        let combined = pending + data; var offset = 0
        while offset + 4 <= combined.count {
            offset += Int(combined.be16(offset) & 0x7fff) + 4
            if offset == combined.count { return true }
        }
        return false
    }
}

extension BandError {
    static func bluetooth(domain: String, code: Int, description: String, fallback: String) -> BandError {
        let detail = "\(domain):\(code) \(description)"
        if domain == "CBErrorDomain", code == 14 {
            return .pairing("Bluetooth pairing information no longer agrees (\(detail)). Disconnect other clients. Forget the obsolete OS pairing in Settings if needed, rediscover, and reuse the saved identity. This does not require ownership enrollment.")
        }
        return .transport("\(fallback) \(detail)")
    }
}

enum ConnectionRetryPolicy {
    static func delay(for error: BandError, retries: Int) -> TimeInterval? {
        guard !error.requiresUser, retries < 5 else { return nil }
        return min(30, pow(2, Double(retries)))
    }
}
