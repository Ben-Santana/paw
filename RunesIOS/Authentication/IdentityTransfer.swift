import Foundation
import CryptoKit

/// Deliberately separate from enrollment: importing never changes band ownership.
struct IdentityTransfer: Decodable {
    let type: String
    let version: Int
    let privateKey: Data
    let bandPoint: Data?
    let allowMissingBandKey: Bool?

    static func parse(_ text: String) throws -> BandIdentity {
        do {
            guard text.utf8.count <= 2048 else { throw BandError.authentication("Invalid identity QR code.") }
            let transfer = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
            guard transfer.type == "runes-band-identity", (transfer.version == 1 || transfer.version == 2),
                  transfer.privateKey.count == 32 else {
                throw BandError.authentication("Invalid identity QR code.")
            }
            _ = try P256.Signing.PrivateKey(rawRepresentation: transfer.privateKey)
            if let point = transfer.bandPoint {
                guard point.count == 64 else { throw BandError.authentication("Invalid band key.") }
                _ = try P256.Signing.PublicKey(x963Representation: Data([4]) + point)
            } else {
                guard transfer.version == 2, transfer.allowMissingBandKey == true else {
                    throw BandError.authentication("Missing band key without compatibility permission.")
                }
            }
            return BandIdentity(privateKey: transfer.privateKey, bandPoint: transfer.bandPoint, stage: "imported", allowMissingBandKey: transfer.bandPoint == nil ? true : nil)
        } catch { throw BandError.authentication("This is not a supported band identity QR code. Export an identity from the updated Mac app.") }
    }
}
