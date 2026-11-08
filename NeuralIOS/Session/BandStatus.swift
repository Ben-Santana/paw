import Foundation

/// The four things the interface ever says about the connection, plus "paused" for a band
/// the person disconnected on purpose.
enum BandPhase: Equatable, Sendable {
    case notSetUp, paused, connecting, connected, attention

    var title: String {
        switch self {
        case .notSetUp: return "Not set up"
        case .paused: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .attention: return "Needs attention"
        }
    }
}

/// Everything a screen needs, as plain values. Views take this instead of the controller,
/// so previews can show fixed states without any Bluetooth or band.
struct BandStatus: Equatable, Sendable {
    var phase: BandPhase
    var issue: SessionIssue?
    var battery: Int?
    var hand: Handedness?
    var lastGesture: String?
    var lastGestureAt: Date?
    /// Physical gestures, not packets.
    var gestureCount = 0
    /// The latest gesture, for the ring's reaction.
    var gesture: BandGesture?
    var macLink: String?

    var detail: String {
        if let issue, phase == .attention { return issue.sentence }
        switch phase {
        case .notSetUp: return "Set up your band to start."
        case .paused: return "Tap to connect your band."
        case .connecting: return "Looking for your band."
        case .connected: return "Ready for gestures."
        case .attention: return "Something needs your attention."
        }
    }
}

extension BandStatus {
    init(_ snapshot: SessionSnapshot, setupComplete: Bool, relayStatus: String?) {
        let hasIdentity = snapshot.isSetUp
        let issue = snapshot.issue
        let phase: BandPhase
        if snapshot.selected == nil || (!hasIdentity && !setupComplete) { phase = .notSetUp }
        else if let issue, !issue.isGentle, snapshot.state != .streaming { phase = .attention }
        else if snapshot.state == .streaming { phase = .connected }
        else if snapshot.wantsConnection { phase = .connecting }
        else { phase = .paused }
        let last = snapshot.lastGesture
        self.init(phase: phase, issue: issue, battery: snapshot.battery, hand: snapshot.hand,
                  lastGesture: last?.title, lastGestureAt: last?.at,
                  gestureCount: snapshot.gestureTotal, gesture: last, macLink: relayStatus)
    }
}
