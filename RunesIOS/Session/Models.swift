import Foundation

struct SessionSnapshot: Sendable {
    var state: SessionState = .disconnected
    /// Journal wording. The interface shows `issue` and the state instead.
    var message = "Select your band to connect."
    var issue: SessionIssue?
    var devices: [BandDevice] = []
    var selected: UUID?
    var events: [GestureEvent] = []
    var eventCount = 0
    var startedAt: Date?
    var journalError: String?
    var wantsConnection = false
    var identityChoices: [IdentityChoice] = []
    var identityAccount: UUID?
    var identityFingerprint: String?
    var battery: Int?
    var hand: Handedness?
    var bluetoothReady = false
    /// The latest physical gesture, one per tap, double tap, hold or swipe.
    var lastGesture: BandGesture?
    /// Physical gestures this session. A double tap upgrades the tap before it, so it is not counted twice.
    var gestureTotal = 0
    /// True once a usable identity exists for the selected band.
    var isSetUp: Bool { selected != nil && identityChoices.contains { $0.eligible && !$0.pending } }
}

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

/// The band numbers raw gestures (press, release, tap…) and derived interactions
/// (single tap, hold…) with two independent counters. Comparing one counter
/// against the other made every interleaved packet look like a gap.
enum GestureStream: String, Sendable { case raw, derived }

extension GestureEvent {
    var stream: GestureStream { actionCode != 0 ? .raw : .derived }
    var isIndexFinger: Bool { fingerCode == 2 }
    /// Plain words for the interface, e.g. "Index tap".
    var plainTitle: String {
        let finger = fingerCode < 4 && fingerCode > 0 ? ["", "Thumb", "Index", "Middle"][Int(fingerCode)] : "Band"
        let words: [UInt64: String] = derivedActionCode != 0
            ? [1: "tap", 2: "double tap", 3: "hold", 4: "release", 5: "up", 6: "down", 7: "left", 8: "right", 9: "press", 10: "release"]
            : [1: "press", 2: "release", 3: "tap", 4: "double tap", 5: "click", 6: "up", 7: "down", 8: "left", 9: "right", 10: "wake", 11: "swipe in", 12: "swipe out"]
        let code = derivedActionCode != 0 ? derivedActionCode : actionCode
        return "\(finger) \(words[code] ?? "gesture")"
    }
}

struct SequenceTracker: Sendable {
    private var last: [GestureStream: UInt64] = [:]
    mutating func reset() { last = [:] }
    /// Returns the previous sequence number when `sequence` does not directly follow it on its own stream.
    mutating func gap(_ sequence: UInt64, stream: GestureStream) -> UInt64? {
        defer { last[stream] = sequence }
        guard let previous = last[stream] else { return nil }
        return sequence == (previous &+ 1) & 0xffffffff ? nil : previous
    }
}

enum Handedness: String, Sendable { case left, right }

/// Everything the interface may say about a problem: one plain sentence and one action.
/// Protocol detail never appears here; it goes to the journal.
enum SessionIssue: String, Sendable, CaseIterable {
    case bluetoothOff, bluetoothDenied, bandNotNearby, pairingChanged, notRecognised,
         bandNotResponding, stillReleasing, pulseMissing, phoneLocked, signInFailed

    enum Action: Sendable { case reconnect, openSettings, setUpAgain, retryRelease, retrySignIn }

    var sentence: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to reconnect."
        case .bluetoothDenied: return "Runes can’t use Bluetooth. Allow it in Settings."
        case .bandNotNearby: return "Band not nearby. Bring it close to your phone."
        case .pairingChanged: return "Your phone and band need to pair again."
        case .notRecognised: return "Your band didn’t recognise this phone."
        case .bandNotResponding: return "Your band stopped responding."
        case .stillReleasing: return "Your band is still disconnecting."
        case .pulseMissing: return "Gestures may pause while your phone is locked."
        case .phoneLocked: return "Unlock your phone to finish connecting."
        case .signInFailed: return "Meta sign-in didn’t finish."
        }
    }
    var action: Action {
        switch self {
        case .bluetoothOff, .bluetoothDenied: return .openSettings
        case .pairingChanged, .notRecognised: return .setUpAgain
        case .stillReleasing: return .retryRelease
        case .signInFailed: return .retrySignIn
        case .bandNotNearby, .bandNotResponding, .pulseMissing, .phoneLocked: return .reconnect
        }
    }
    var actionTitle: String {
        switch action {
        case .reconnect: return self == .pulseMissing ? "Reconnect" : "Try again"
        case .openSettings: return "Open Settings"
        case .setUpAgain: return "Set up again"
        case .retryRelease: return "Try again"
        case .retrySignIn: return "Sign in again"
        }
    }
    /// Gentle issues keep the band connected; the ring stays in its current state.
    var isGentle: Bool { self == .pulseMissing }

    static func from(_ error: BandError) -> SessionIssue {
        switch error {
        case .pairing: return .pairingChanged
        case .authentication: return .notRecognised
        case .storage: return .phoneLocked
        case .wire: return .bandNotResponding
        case .transport, .cancelled: return .bandNotNearby
        }
    }
}

extension ConnectionRetryPolicy {
    /// Only an identity or ownership failure stops automatic connection. Ordinary
    /// connection, protocol and storage errors keep retrying for as long as the user wants
    /// the band connected; the user's Disconnect is the other way to stop.
    static func stopsAutoConnect(_ error: BandError) -> Bool {
        switch error { case .authentication, .pairing: return true; default: return false }
    }
    /// Delay before reconnecting after a failure while the link was up. It never runs out:
    /// after the fast steps (1, 2, 4, 8, 16 s) it stays at the ceiling. A lost link is not
    /// delayed at all, because a pending connect costs nothing while the band is away.
    static let ceiling: TimeInterval = 20
    static func backoff(failures: Int) -> TimeInterval {
        delay(for: .transport("retry"), retries: max(0, failures - 1)).map { min($0, ceiling) } ?? ceiling
    }
}


// MARK: Physical gestures

enum SwipeDirection: String, Sendable, CaseIterable { case up, down, left, right }

/// One thing the person did with their hand. The band describes each of these with
/// several packets (a tap is press, button press, release, button release and single tap);
/// the interface reacts to this instead, exactly once.
struct BandGesture: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case tap, doubleTap, holdBegan, holdEnded, swipe(SwipeDirection) }
    /// Increases with every reaction, so views can tell two identical gestures apart.
    let id: Int
    let kind: Kind
    let finger: UInt64
    let at: Date
    /// A double tap upgrades the single tap the interface already showed.
    var upgradesPrevious: Bool { kind == .doubleTap }
    /// The end of a hold finishes a gesture that already reacted.
    var isNewGesture: Bool { kind != .holdEnded && kind != .doubleTap }

    var fingerName: String {
        switch finger { case 1: return "Thumb"; case 2: return "Index"; case 3: return "Middle"; default: return "Band" }
    }
    var title: String {
        switch kind {
        case .tap: return "\(fingerName) tap"
        case .doubleTap: return "\(fingerName) double tap"
        case .holdBegan, .holdEnded: return "\(fingerName) hold"
        case .swipe(let direction): return "Swipe \(direction.rawValue)"
        }
    }
}

/// Turns the band's packet stream into physical gestures.
///
/// From the 2026-11-08 journal (971 bursts): the derived layer carries the meaning
/// (singleTap, doubleTap, buttonHold, buttonHoldRelease, buttonUp/Down/Left/Right); raw
/// press/release and derived buttonPress/buttonRelease are parts of those and never react.
/// The second tap of a double tap sends singleTap and then doubleTap within ~11 ms, so a
/// single tap waits `settle` before it counts, and a doubleTap inside that wait replaces it.
struct GestureInterpreter: Sendable {
    static let settle: TimeInterval = 0.04
    private var pendingTap: (finger: UInt64, at: Date, uptime: TimeInterval)?
    /// A raw-layer gesture waiting to see whether the derived layer describes it instead.
    private var pendingRaw: (kind: BandGesture.Kind, finger: UInt64, at: Date, uptime: TimeInterval)?
    private var lastDerivedSequence: UInt64?
    private var derivedSeen = false
    private var holding: UInt64?
    private var serial = 0

    var hasPending: Bool { pendingTap != nil || pendingRaw != nil }

    mutating func reset() { pendingTap = nil; pendingRaw = nil; lastDerivedSequence = nil; holding = nil }

    mutating func feed(_ event: GestureEvent) -> [BandGesture] {
        let now = event.received.uptime, at = event.received.wallTime
        if event.stream == .derived {
            derivedSeen = true; pendingRaw = nil
            if event.sequence == lastDerivedSequence { return [] }   // repeated delivery
            lastDerivedSequence = event.sequence
            let code = event.derivedActionCode, finger = event.fingerCode
            if code == 2 {
                // Double tap: drop the second tap's single tap if it is still waiting.
                pendingTap = nil
                return [make(.doubleTap, finger, at)]
            }
            var out = flush(now: .infinity)
            switch code {
            case 1: pendingTap = (finger, at, now)
            case 3: holding = finger; out.append(make(.holdBegan, finger, at))
            case 10: holding = nil; out.append(make(.holdEnded, finger, at))
            case 5: out.append(make(.swipe(.up), finger, at))
            case 6: out.append(make(.swipe(.down), finger, at))
            case 7: out.append(make(.swipe(.left), finger, at))
            case 8: out.append(make(.swipe(.right), finger, at))
            default: break   // buttonPress, buttonRelease: parts of a gesture
            }
            return out
        }
        // Raw packets only stand in when the band sends no derived layer. They wait `settle`
        // first, because the derived packet for the same gesture follows within microseconds.
        guard !derivedSeen else { return [] }
        let kind: BandGesture.Kind
        switch event.actionCode {
        case 3, 5: kind = .tap
        case 4: kind = .doubleTap
        case 6: kind = .swipe(.up)
        case 7: kind = .swipe(.down)
        case 8, 11: kind = .swipe(.left)
        case 9, 12: kind = .swipe(.right)
        default: return []
        }
        let out = flush(now: .infinity)
        pendingRaw = (kind, event.fingerCode, at, now)
        return out
    }

    /// Releases a waiting single tap once `settle` has passed.
    mutating func flush(now: TimeInterval) -> [BandGesture] {
        var out: [BandGesture] = []
        if let raw = pendingRaw, now - raw.uptime >= Self.settle {
            pendingRaw = nil
            if !derivedSeen { out.append(make(raw.kind, raw.finger, raw.at)) }
        }
        if let tap = pendingTap, now - tap.uptime >= Self.settle {
            pendingTap = nil
            out.append(make(.tap, tap.finger, tap.at))
        }
        return out
    }

    private mutating func make(_ kind: BandGesture.Kind, _ finger: UInt64, _ at: Date) -> BandGesture {
        serial += 1
        return BandGesture(id: serial, kind: kind, finger: finger, at: at)
    }
}
