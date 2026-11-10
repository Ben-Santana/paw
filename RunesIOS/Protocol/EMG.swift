import Foundation

/// The band's EMG stream (sensor kind 0x0200020A), ported from meta-neural-py.
enum EMG {
    /// Raw little-endian 16-bit EMG samples, 16 samples × 8 channels.
    static func decode(_ bytes: Data) -> [UInt16] {
        (0..<128).map { UInt16(bytes.octet($0 * 2)) | UInt16(bytes.octet($0 * 2 + 1)) << 8 }
    }
    /// Validates the band's EMG layout (reply to `emg_configuration`). Only 2048 Hz, 8 channels,
    /// 16-bit, 16 samples per batch, encoding 0 is understood, matching meta-neural-py.
    static func configuration(_ payload: Data) -> Result<String, BandError> {
        do {
            let rpc = try Fields(payload)
            guard try rpc.integer(2) == 1 else { return .failure(.wire("Band refused the EMG configuration read.")) }
            let emg = try Fields(Fields(rpc.bytes(6)).bytes(42))
            let v = try [1, 2, 4, 5, 10].map { try emg.integer($0, default: 0) }
            let summary = "rate=\(v[0])Hz channels=\(v[1]) bits=\(v[2]) samples=\(v[3]) encoding=\(v[4])"
            guard v == [2048, 8, 16, 16, 0] else { return .failure(.wire("Unsupported EMG layout: \(summary).")) }
            return .success(summary)
        } catch { return .failure(.wire("EMG configuration could not be read.")) }
    }
}
