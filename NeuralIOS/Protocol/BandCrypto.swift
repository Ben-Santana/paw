import Foundation
import CryptoKit
import CommonCrypto
import Security

enum BandCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw BandError.authentication("Secure random generation failed.") }
        return Data(bytes)
    }
    static func point(_ key: P256.Signing.PrivateKey) -> Data { Data(key.publicKey.x963Representation.dropFirst()) }
    static func transcript(_ challenge: Data, _ receiver: Data, _ seed: Data, _ sender: Data) -> Data {
        Data(SHA256.hash(data: Data(SHA256.hash(data: challenge + receiver)) + Data(SHA256.hash(data: seed + sender))))
    }
    static func key(secret: Data, challenge: Data, seed: Data) -> Data {
        let hashed = Data(SHA256.hash(data: secret))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: hashed), salt: Data(SHA256.hash(data: hashed + challenge + seed)), info: Data("AirShield".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

final class AirShieldCipher {
    private let key: Data
    private var iv: Data
    private var counter: UInt32
    private var records: UInt64 = 0
    init(key: Data, iv: Data, counter: UInt64) throws {
        guard key.count == 32, iv.count == 16, counter <= UInt32.max else { throw BandError.wire("Invalid AirShield parameters.") }
        self.key = key; self.iv = iv; self.counter = UInt32(counter)
    }
    private func tag(_ body: Data) throws -> Data {
        guard records < 1 << 32 else { throw BandError.authentication("Encryption counter exhausted; reconnect.") }
        var count = counter.littleEndian
        let prefix = Swift.withUnsafeBytes(of: &count) { Data($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: prefix + body, using: SymmetricKey(data: key)).prefix(8))
    }
    private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count + 16), written = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in input.withUnsafeBytes { p in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, v.baseAddress, p.baseAddress, input.count, &output, output.count, &written)
        } } }
        guard status == kCCSuccess else { throw BandError.authentication("Band encryption failed.") }
        return Data(output.prefix(written))
    }
    private func advance(_ ciphertext: Data) { iv = Data(ciphertext.suffix(16)); counter &+= 1; records += 1 }
    func encrypt(_ data: Data) throws -> Data {
        var plain = data; let padding = (16 - plain.count % 16) % 16
        plain.append(contentsOf: repeatElement(UInt8(0xc0 + padding), count: padding))
        guard !plain.isEmpty, plain.count <= 4096 else { throw BandError.wire("Invalid record length.") }
        let ciphertext = try crypt(plain, operation: CCOperation(kCCEncrypt))
        let body = Data([UInt8(ciphertext.count / 16 - 1)]) + ciphertext
        let out = try Data([0x40]) + tag(body) + body; advance(ciphertext); return out
    }
    func decrypt(_ packet: Data) throws -> Data {
        guard packet.count >= 26, packet.octet(0) == 0x40, packet.count == 10 + (Int(packet.octet(9)) + 1) * 16 else { throw BandError.wire("Invalid encrypted record.") }
        guard try BandCrypto.equal(packet.portion(1..<9), tag(packet.portion(9..<packet.count))) else { throw BandError.authentication("Band record authentication failed.") }
        let ciphertext = packet.portion(10..<packet.count), plain = try crypt(ciphertext, operation: CCOperation(kCCDecrypt))
        advance(ciphertext); return plain
    }
}

final class AirShieldReceiver {
    let cipher: AirShieldCipher
    private var pending = Data()
    init(_ cipher: AirShieldCipher) { self.cipher = cipher }
    func feed(_ data: Data) throws -> [Data] {
        guard pending.count + data.count <= 1 << 20 else { throw BandError.wire("Encrypted receive buffer overflow.") }
        pending.append(data); var result: [Data] = []
        while !pending.isEmpty {
            let marker = pending.octet(0)
            if marker == 0x81 || marker == 0x82 {
                if pending.count < 2 { break }
                guard pending.octet(1) <= 1 else { throw BandError.wire("Unsupported AirShield control.") }
                pending = Data(pending.dropFirst(2)); continue
            }
            if marker == 1 || marker == 2 {
                if pending.count < 2 { break }
                let length = 3 + Int(pending.octet(1)); if pending.count < length { break }
                pending = Data(pending.dropFirst(length)); continue
            }
            guard [0x40, 0x41, 0x42].contains(marker) else { throw BandError.wire("Unsupported encrypted record marker.") }
            if pending.count < 10 { break }
            let length = 10 + (Int(pending.octet(9)) + 1) * 16
            if pending.count < length { break }
            if marker == 0x40 { result.append(try cipher.decrypt(pending.portion(0..<length))) }
            pending = Data(pending.dropFirst(length))
        }
        return result
    }
}

extension BandCrypto {
    // The wire protocol signs an already-hashed transcript. Do not hash it again.
    static func sign(_ digest: Data, privateKey: Data) throws -> Data {
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
              let signature = SecKeyCreateSignature(secKey, .ecdsaSignatureDigestX962SHA256, digest as CFData, nil) else { throw BandError.authentication("Cannot sign band trust transcript.") }
        return try P256.Signing.ECDSASignature(derRepresentation: signature as Data).rawRepresentation
    }
    static func verify(_ digest: Data, signature: Data, point: Data) throws {
        let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + point)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 256]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil) else { throw BandError.authentication("Invalid saved band key.") }
        let der = try P256.Signing.ECDSASignature(rawRepresentation: signature).derRepresentation
        guard SecKeyVerifySignature(secKey, .ecdsaSignatureDigestX962SHA256, digest as CFData, der as CFData, nil) else { throw BandError.authentication("Band proof does not match the saved key. Disconnect and check the selected identity; do not re-enroll as a connection repair.") }
    }
}
