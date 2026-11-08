import Foundation

struct BandDevice: Identifiable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int?
}

enum SessionState: String, Sendable {
    case disconnected, disconnecting, scanning, connecting, enrollmentRequired, enrolling, authenticating, subscribing, streaming, reconnecting, failed
    var title: String {
        switch self {
        case .enrollmentRequired: return "Choose an identity"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

struct ReceiptContext: Codable, Sendable {
    let wallTime: Date
    let uptime: TimeInterval
    let applicationState: String
}

struct GestureEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let fingerCode: UInt64
    let actionCode: UInt64
    let derivedActionCode: UInt64
    let synthetic: Bool
    let sequence: UInt64
    let deviceTimestamp: UInt64
    let received: ReceiptContext
    var sourceClock: String { "gesture-device-clock" }
    var finger: String { Self.label(fingerCode, ["unknown", "thumb", "index", "middle", "not applicable"]) }
    var action: String { Self.label(actionCode, Self.actions) }
    var derivedAction: String { Self.label(derivedActionCode, Self.derived) }
    var title: String { "\(finger.capitalized) · \(actionCode == 0 && derivedActionCode != 0 ? derivedAction : action)" }
    var layer: String { actionCode != 0 && derivedActionCode != 0 ? "Both layers" : (derivedActionCode != 0 ? "Derived interaction" : "Raw gesture") }
    static let actions = ["unknown", "press", "release", "tap", "doubletap", "click", "up", "down", "left", "right", "wake", "swipeIn", "swipeOut", "ia", "partialPress", "partialRelease", "partialClick", "partialUp", "partialDown", "partialLeft", "partialRight"]
    static let derived = ["unknown", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp", "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]
    static func label(_ code: UInt64, _ labels: [String]) -> String { code < labels.count ? labels[Int(code)] : "unknown:\(code)" }
}

struct BandIdentity: Codable {
    let privateKey: Data
    var bandPoint: Data?
    var stage: String
    var allowMissingBandKey: Bool? = nil
    var canAuthenticate: Bool { bandPoint != nil || allowMissingBandKey == true }
}
