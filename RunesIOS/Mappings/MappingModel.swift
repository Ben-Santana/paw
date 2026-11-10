import Foundation

// The Mac app's mapping model (runes_mac/src/shortcuts.ts), ported for iPhone.
// Same gesture ids, the same combo rules (2–8 steps, hold/release pairing, the same timing
// choices) and the same idea of one action or several linked actions run in order.
// Keyboard shortcuts, mouse, radial menus and adjust don't exist on iPhone, so the action
// catalog is the iPhone's own.

// MARK: Gestures

/// One step a person can make. Raw values match the Mac app's gesture ids.
enum GestureKind: String, Codable, CaseIterable, Sendable, Hashable {
    case tapIndex = "tap-index", tapMiddle = "tap-middle"
    case doubleTapIndex = "double-tap-index", doubleTapMiddle = "double-tap-middle"
    case holdIndex = "hold-index", holdMiddle = "hold-middle"
    case releaseIndex = "release-index", releaseMiddle = "release-middle"
    case swipeUp = "swipe-up", swipeDown = "swipe-down", swipeLeft = "swipe-left", swipeRight = "swipe-right"
    /// Combo-only motion steps, read from the band's orientation and gyroscope streams.
    case rotation, movement
    /// Combo-only: a shape traced with the wrist, recorded after the preceding gesture.
    case air

    /// Gestures that can be mapped on their own. A release only exists inside a combo.
    static let motions: [GestureKind] = [.tapIndex, .tapMiddle, .doubleTapIndex, .doubleTapMiddle, .holdIndex, .holdMiddle,
                                         .swipeUp, .swipeDown, .swipeLeft, .swipeRight]

    var name: String {
        switch self {
        case .tapIndex: "Tap index"
        case .tapMiddle: "Tap middle"
        case .doubleTapIndex: "Double tap index"
        case .doubleTapMiddle: "Double tap middle"
        case .holdIndex: "Tap and hold index"
        case .holdMiddle: "Tap and hold middle"
        case .releaseIndex: "Release index"
        case .releaseMiddle: "Release middle"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .rotation: "Rotation"
        case .movement: "Movement"
        case .air: "Air gesture"
        }
    }
    /// Short form for step chips.
    var shortName: String {
        switch self {
        case .tapIndex, .tapMiddle: "Tap"
        case .doubleTapIndex, .doubleTapMiddle: "Double"
        case .holdIndex, .holdMiddle: "Hold"
        case .releaseIndex, .releaseMiddle: "Release"
        case .swipeUp: "Up"
        case .swipeDown: "Down"
        case .swipeLeft: "Left"
        case .swipeRight: "Right"
        case .rotation: "Rotate"
        case .movement: "Move"
        case .air: "Air"
        }
    }
    var finger: String? {
        switch self {
        case .tapIndex, .doubleTapIndex, .holdIndex, .releaseIndex: "index"
        case .tapMiddle, .doubleTapMiddle, .holdMiddle, .releaseMiddle: "middle"
        default: nil
        }
    }
    var isHold: Bool { self == .holdIndex || self == .holdMiddle }
    var isRelease: Bool { self == .releaseIndex || self == .releaseMiddle }
    var isMotion: Bool { self == .rotation || self == .movement }
    var isAir: Bool { self == .air }
    var isTap: Bool { self == .tapIndex || self == .tapMiddle }
    var doubleTap: GestureKind? { self == .tapIndex ? .doubleTapIndex : self == .tapMiddle ? .doubleTapMiddle : nil }
    var release: GestureKind? { self == .holdIndex ? .releaseIndex : self == .holdMiddle ? .releaseMiddle : nil }

    /// The band's physical gesture, as `GestureInterpreter` reports it. Finger 2 is index, 3 is middle.
    init?(_ gesture: BandGesture) {
        let index = gesture.finger == 2, middle = gesture.finger == 3
        switch gesture.kind {
        case .tap: guard index || middle else { return nil }; self = index ? .tapIndex : .tapMiddle
        case .doubleTap: guard index || middle else { return nil }; self = index ? .doubleTapIndex : .doubleTapMiddle
        case .holdBegan: guard index || middle else { return nil }; self = index ? .holdIndex : .holdMiddle
        case .holdEnded: guard index || middle else { return nil }; self = index ? .releaseIndex : .releaseMiddle
        case .swipe(.up): self = .swipeUp
        case .swipe(.down): self = .swipeDown
        case .swipe(.left): self = .swipeLeft
        case .swipe(.right): self = .swipeRight
        }
    }
}

enum Axis: String, Codable, CaseIterable, Sendable, Hashable { case x, y, z }
enum RotationDirection: String, Codable, CaseIterable, Sendable, Hashable {
    case left, right, any
    var arrow: String { switch self { case .left: "←"; case .right: "→"; case .any: "↔" } }
}

/// One combo step, saved in the Mac's format: `{"gesture": "rotation", "axis": "x", "direction": "left"}`.
/// Motion steps need an axis; a rotation may also need a direction (missing means either way).
/// An air step carries its shape: `{"gesture": "air", "air": {...}}`.
struct ComboStep: Codable, Hashable, Sendable {
    var gesture: GestureKind
    var axis: Axis?
    var direction: RotationDirection?
    var air: AirShape?

    init(_ gesture: GestureKind, axis: Axis? = nil, direction: RotationDirection? = nil, air: AirShape? = nil) {
        self.gesture = gesture
        self.axis = gesture.isMotion ? (axis ?? .x) : nil
        self.direction = gesture == .rotation ? (direction ?? .any) : nil
        self.air = gesture == .air ? air : nil
    }
    static func airShape(_ shape: AirShape) -> ComboStep { ComboStep(.air, air: shape) }
    static func rotation(_ axis: Axis, _ direction: RotationDirection = .any) -> ComboStep { ComboStep(.rotation, axis: axis, direction: direction) }
    static func movement(_ axis: Axis) -> ComboStep { ComboStep(.movement, axis: axis) }

    var name: String {
        switch gesture {
        case .rotation: "Rotate \(axis?.rawValue.uppercased() ?? "X") \((direction ?? .any).arrow)"
        case .movement: "Move \(axis?.rawValue.uppercased() ?? "X")"
        case .air: air?.name.flatMap { $0.isEmpty ? nil : "Air “\($0)”" } ?? gesture.name
        default: gesture.name
        }
    }
    /// Chip label; the icon beside it already shows a motion step's axis and direction.
    var shortName: String { gesture.shortName }

    /// Whether a recognized input fills this step. A rotation step set to "any" takes either way.
    func matches(_ input: ComboStep) -> Bool {
        guard input.gesture == gesture, input.axis == axis else { return false }
        // The engine reports a matched air shape with the step's own shape.
        if gesture == .air { return input.air == air }
        return gesture != .rotation || (direction ?? .any) == .any || direction == input.direction
    }

    private enum Keys: String, CodingKey { case gesture, axis, direction, air }
    init(from decoder: Decoder) throws {
        // The first iPhone build saved plain gesture ids.
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(GestureKind.self) { self.init(id); return }
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(try c.decode(GestureKind.self, forKey: .gesture), axis: try c.decodeIfPresent(Axis.self, forKey: .axis),
                  direction: try c.decodeIfPresent(RotationDirection.self, forKey: .direction),
                  air: try c.decodeIfPresent(AirShape.self, forKey: .air))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(gesture, forKey: .gesture)
        try c.encodeIfPresent(axis, forKey: .axis)
        try c.encodeIfPresent(direction, forKey: .direction)
        try c.encodeIfPresent(air, forKey: .air)
    }
}

extension Array where Element == GestureKind {
    var steps: [ComboStep] { map { ComboStep($0) } }
}

enum ComboRules {
    /// The Mac app's timing choices, in milliseconds.
    static let times = [200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000]
    static let defaultTime = 750
    static let steps = 2...8
    static let actions = 1...16

    /// Fingers still held after these steps, or nil when a hold repeats or a release has no hold.
    static func activeHolds(_ steps: [ComboStep]) -> Set<String>? {
        var held = Set<String>()
        for step in steps.map(\.gesture) {
            guard let finger = step.finger else { continue }
            if step.isHold { if held.contains(finger) { return nil }; held.insert(finger) }
            if step.isRelease { if !held.contains(finger) { return nil }; held.remove(finger) }
        }
        return held
    }
    static func valid(_ steps: [ComboStep]) -> Bool {
        Self.steps.contains(steps.count) && activeHolds(steps) != nil && steps.allSatisfy { !$0.gesture.isMotion || $0.axis != nil }
            && airPlacementValid(steps) && steps.allSatisfy { !$0.gesture.isAir || ($0.air?.isValid ?? false) }
    }
    /// An air shape needs a gesture before it to start recording, and two can't be in a row.
    static func airPlacementValid(_ steps: [ComboStep]) -> Bool {
        steps.indices.allSatisfy { i in !steps[i].gesture.isAir || (i > 0 && !steps[i - 1].gesture.isAir) }
    }

    /// Steps that may follow the current ones without breaking hold/release order.
    static func allowedNext(after steps: [ComboStep]) -> [GestureKind] {
        let held = activeHolds(steps) ?? []
        return GestureKind.allCases.filter { kind in
            if kind.isAir { return !(steps.last?.gesture.isAir ?? true) }
            guard let finger = kind.finger else { return true }
            if kind.isHold { return !held.contains(finger) }
            if kind.isRelease { return held.contains(finger) }
            return true
        }
    }
    static func problem(_ steps: [ComboStep]) -> String? {
        if steps.count < Self.steps.lowerBound { return "A combo needs at least two steps." }
        if steps.count > Self.steps.upperBound { return "A combo can have up to eight steps." }
        if activeHolds(steps) == nil { return "Each release needs a hold before it, and a finger can’t be held twice." }
        if !airPlacementValid(steps) { return "An air gesture needs another gesture before it to start recording." }
        if steps.contains(where: { $0.gesture.isAir && !($0.air?.isValid ?? false) }) { return "Draw or record the air gesture’s shape." }
        return nil
    }
}

// MARK: Actions

enum HTTPMethod: String, Codable, CaseIterable, Sendable { case GET, POST, PUT, PATCH, DELETE }
enum HapticStyle: String, Codable, CaseIterable, Sendable { case light, medium, heavy, success, warning }
enum ProfileDirection: String, Codable, Sendable { case up, down }

/// What a Spotify action does to the person's current playback.
enum SpotifyCommand: String, Codable, CaseIterable, Sendable {
    case playPause, play, pause, next, previous, volumeUp, volumeDown, seekForward, seekBack, toggleShuffle, cycleRepeat, saveTrack

    var title: String {
        switch self {
        case .playPause: "Play / pause"
        case .play: "Play"
        case .pause: "Pause"
        case .next: "Next track"
        case .previous: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .seekForward: "Skip ahead 15 s"
        case .seekBack: "Back 15 s"
        case .toggleShuffle: "Shuffle on / off"
        case .cycleRepeat: "Repeat off / all / one"
        case .saveTrack: "Like current track"
        }
    }
}

/// One thing the phone does. A mapping runs one of these, or several in order.
enum MappingAction: Codable, Hashable, Sendable {
    case openURL(String)
    case runShortcut(String)
    case apiCall(method: HTTPMethod, url: String, headers: [String: String], body: String, timeoutMs: Int)
    case notify(title: String, body: String)
    case copyText(String)
    case haptic(HapticStyle)
    case wait(ms: Int)
    case changeProfile(String)
    case moveProfile(ProfileDirection)
    case spotify(SpotifyCommand)

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case runShortcut, openURL, spotify, apiCall, notify, copyText, haptic, wait, changeProfile, moveProfile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .runShortcut: "Run an Apple Shortcut"
            case .openURL: "Open a link or app"
            case .apiCall: "Call a web API"
            case .notify: "Show a notification"
            case .copyText: "Copy text"
            case .haptic: "Haptic"
            case .wait: "Wait"
            case .changeProfile: "Switch to profile"
            case .moveProfile: "Next or previous profile"
            case .spotify: "Control Spotify"
            }
        }
        var group: String {
            switch self {
            case .runShortcut, .openURL, .spotify: "Apps"
            case .apiCall, .notify, .copyText: "Send"
            case .haptic, .wait: "Feedback & timing"
            case .changeProfile, .moveProfile: "Profiles"
            }
        }
        /// Opening apps needs Runes on screen; everything else also runs while the phone is locked.
        var needsForeground: Bool { self == .runShortcut || self == .openURL || self == .copyText || self == .haptic }
        var template: MappingAction {
            switch self {
            case .runShortcut: .runShortcut("")
            case .openURL: .openURL("")
            case .apiCall: .apiCall(method: .POST, url: "https://", headers: [:], body: "", timeoutMs: 10_000)
            case .notify: .notify(title: "Runes", body: "")
            case .copyText: .copyText("")
            case .haptic: .haptic(.medium)
            case .wait: .wait(ms: 500)
            case .changeProfile: .changeProfile("")
            case .moveProfile: .moveProfile(.down)
            case .spotify: .spotify(.playPause)
            }
        }
    }

    var kind: Kind {
        switch self {
        case .openURL: .openURL
        case .runShortcut: .runShortcut
        case .apiCall: .apiCall
        case .notify: .notify
        case .copyText: .copyText
        case .haptic: .haptic
        case .wait: .wait
        case .changeProfile: .changeProfile
        case .moveProfile: .moveProfile
        case .spotify: .spotify
        }
    }

    func label(profiles: [MappingProfile] = []) -> String {
        switch self {
        case .openURL(let url): return url.isEmpty ? "Open a link" : "Open \(Self.host(url))"
        case .runShortcut(let name): return name.isEmpty ? "Run a shortcut" : "Run “\(name)”"
        case .apiCall(let method, let url, _, _, _): return "\(method.rawValue) \(Self.host(url))"
        case .notify(let title, let body): return "Notify “\(body.isEmpty ? title : body)”"
        case .copyText(let text): return "Copy “\(text.prefix(24))”"
        case .haptic(let style): return "\(style.rawValue.capitalized) haptic"
        case .wait(let ms): return ms % 1000 == 0 ? "Wait \(ms / 1000) s" : "Wait \(String(format: "%.1f", Double(ms) / 1000)) s"
        case .changeProfile(let id): return "Switch to \(profiles.first { $0.id == id }?.name ?? "a profile")"
        case .moveProfile(let direction): return direction == .down ? "Next profile" : "Previous profile"
        case .spotify(let command): return "Spotify: \(command.title)"
        }
    }

    private static func host(_ text: String) -> String {
        if let url = URL(string: text), let host = url.host(), !host.isEmpty { return host }
        return text.isEmpty ? "—" : String(text.prefix(28))
    }

    /// Mirrors the Mac validators: what a saved action must look like to run.
    var problem: String? {
        switch self {
        case .openURL(let text):
            guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme, !scheme.isEmpty else { return "Enter a link, like https://example.com or music://." }
            return nil
        case .runShortcut(let name): return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter the shortcut’s exact name." : nil
        case .apiCall(_, let text, let headers, _, let timeoutMs):
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else { return "Enter an http or https URL." }
            if url.user() != nil || url.password() != nil { return "Put credentials in a header, not the URL." }
            if headers.keys.contains(where: { $0.isEmpty || $0.contains(where: { $0.isWhitespace || $0 == ":" }) }) { return "Header names can’t contain spaces or colons." }
            if headers.values.contains(where: { $0.contains(where: \.isNewline) }) { return "Header values must be one line." }
            if !(1000...120_000).contains(timeoutMs) { return "Timeout must be 1–120 seconds." }
            return nil
        case .notify(let title, let body): return title.isEmpty && body.isEmpty ? "Enter a message." : nil
        case .copyText(let text): return text.isEmpty ? "Enter the text to copy." : nil
        case .wait(let ms): return (50...30_000).contains(ms) ? nil : "Wait 0.05–30 seconds."
        case .changeProfile(let id): return id.isEmpty ? "Choose a profile." : nil
        case .haptic, .moveProfile, .spotify: return nil
        }
    }
}

// MARK: Mappings and profiles

/// One gesture or combo and what it does. Single gestures use the gesture's id; combos use "combo-<uuid>".
struct Mapping: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var enabled: Bool
    /// One action, or several run in order (the Mac's "sequence").
    var actions: [MappingAction]
    /// Combos only.
    var steps: [ComboStep]?
    var intervalMs: Int?
    /// Optional name for a combo.
    var name: String?

    var isCombo: Bool { steps != nil }
    var motion: GestureKind? { isCombo ? nil : GestureKind(rawValue: id).flatMap { GestureKind.motions.contains($0) ? $0 : nil } }
    /// Combos with rotation or movement steps need the band's motion streams.
    var usesMotion: Bool { steps?.contains { $0.gesture.isMotion || $0.gesture.isAir } ?? false }
    var hasActions: Bool { !actions.isEmpty }
    /// Whether the gesture, or any step of the combo, is one of `gestures`.
    func uses(_ gestures: Set<GestureKind>) -> Bool {
        if let steps { return steps.contains { gestures.contains($0.gesture) } }
        return motion.map(gestures.contains) ?? false
    }
    /// Live only when enabled, complete and valid.
    var isLive: Bool {
        guard enabled, ComboRules.actions.contains(actions.count), actions.allSatisfy({ $0.problem == nil }) else { return false }
        if let steps { return ComboRules.valid(steps) && ComboRules.times.contains(intervalMs ?? 0) }
        return motion != nil
    }

    /// The key both apps use for a gesture or combo (RelayWire.Binding.trigger).
    var trigger: String {
        guard let steps else { return id }
        return steps.map { step in
            switch step.gesture {
            case .rotation: "rotation:\(step.axis?.rawValue ?? "x"):\((step.direction ?? .any).rawValue)"
            case .movement: "movement:\(step.axis?.rawValue ?? "x")"
            default: step.gesture.rawValue
            }
        }.joined(separator: " ")
    }

    static func gesture(_ kind: GestureKind) -> Mapping { Mapping(id: kind.rawValue, enabled: false, actions: []) }
    static func newCombo() -> Mapping {
        Mapping(id: "combo-\(UUID().uuidString.lowercased())", enabled: true, actions: [], steps: [], intervalMs: ComboRules.defaultTime)
    }
}

struct MappingProfile: Codable, Identifiable, Hashable, Sendable {
    /// The Mac's profile icon keys (MenuIcons.tsx `profileIcons`).
    static let icons = ProfileIcon.keys
    var id: String
    var name: String
    var icon: String
    var mappings: [Mapping]

    static func new(name: String, icon: String = "home") -> MappingProfile {
        MappingProfile(id: UUID().uuidString.lowercased(), name: name, icon: icon, mappings: []).normalized()
    }

    /// Every motion has a row; combos follow in their saved order. Invalid entries are dropped.
    func normalized() -> MappingProfile {
        var copy = self
        if !Self.icons.contains(icon) { copy.icon = ProfileIcon.fallback }
        let gestures = GestureKind.motions.map { kind in mappings.first { $0.id == kind.rawValue } ?? .gesture(kind) }
        let combos = mappings.filter { $0.id.hasPrefix("combo-") && $0.steps != nil }
        copy.mappings = gestures + combos
        return copy
    }
    var gestures: [Mapping] { mappings.filter { !$0.isCombo } }
    var combos: [Mapping] { mappings.filter(\.isCombo) }
}

struct MappingLibrary: Codable, Sendable {
    var profiles: [MappingProfile]
    var activeID: String

    static let initial: MappingLibrary = {
        let main = MappingProfile(id: "main", name: "Main", icon: "home", mappings: []).normalized()
        return MappingLibrary(profiles: [main], activeID: main.id)
    }()

    var active: MappingProfile { profiles.first { $0.id == activeID } ?? profiles[0] }

    func normalized() -> MappingLibrary {
        var copy = self
        copy.profiles = profiles.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.normalized() }
        if copy.profiles.isEmpty { return .initial }
        if !copy.profiles.contains(where: { $0.id == activeID }) { copy.activeID = copy.profiles[0].id }
        return copy
    }
}
