import Foundation

struct ScorePlayer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var score = 0
    /// Index into `ScoreTint`; a player keeps their colour when others come and go.
    var tint: Int
}

/// A game of two to six players kept from the band. Pure value type, so it is tested
/// without a band.
struct ScoreGame: Codable, Equatable, Sendable {
    static let minPlayers = 2, maxPlayers = 6
    static let nameLimit = 16
    static func defaultName(_ index: Int) -> String { "Player \(index + 1)" }

    private(set) var players = [ScorePlayer(name: ScoreGame.defaultName(0), tint: 0), ScorePlayer(name: ScoreGame.defaultName(1), tint: 1)]
    /// The player on screen, and the one the band changes when there are more than two.
    /// Changing a player's score selects them.
    private(set) var selected = 0
    /// While live, the game's gestures change the score and mappings that use them are off.
    var live = false

    var names: [String] { players.map(\.name) }
    var scores: [Int] { players.map(\.score) }
    var isEmpty: Bool { players.allSatisfy { $0.score == 0 } }
    var canAdd: Bool { players.count < Self.maxPlayers }
    var canRemove: Bool { players.count > Self.minPlayers }
    /// Two players have a finger each. With more, the band changes one selected player
    /// and steps between them.
    var usesSelection: Bool { players.count > 2 }

    /// Adds `delta` to a player and selects them. A score never goes below zero.
    mutating func change(_ index: Int, by delta: Int) {
        guard players.indices.contains(index) else { return }
        players[index].score = max(0, players[index].score + delta)
        selected = index
    }

    mutating func select(_ index: Int) {
        if players.indices.contains(index) { selected = index }
    }

    /// Moves the selection forward or back, wrapping at the ends.
    mutating func select(step: Int) {
        selected = ((selected + step) % players.count + players.count) % players.count
    }

    mutating func reset() { for i in players.indices { players[i].score = 0 } }

    /// Adds a player with the first colour nobody has. False when the game is full.
    @discardableResult
    mutating func addPlayer() -> Bool {
        guard canAdd else { return false }
        let used = Set(players.map(\.tint))
        let tint = (0..<Self.maxPlayers).first { !used.contains($0) } ?? players.count
        players.append(ScorePlayer(name: Self.defaultName(players.count), tint: tint))
        return true
    }

    /// Removes a player; a game keeps at least two.
    @discardableResult
    mutating func removePlayer(_ index: Int) -> Bool {
        guard canRemove, players.indices.contains(index) else { return false }
        players.remove(at: index)
        if selected > index || selected >= players.count { selected = max(0, selected - 1) }
        return true
    }

    mutating func rename(_ index: Int, to name: String) {
        guard players.indices.contains(index) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        players[index].name = trimmed.isEmpty ? Self.defaultName(index) : trimmed
    }

    /// "Player 1 3 · Player 2 2", for the applications list.
    var summary: String { players.map { "\($0.name) \($0.score)" }.joined(separator: " · ") }

    /// Carries out a band action and returns a line confirming it, or nil when the action
    /// names a player who isn't in the game.
    @discardableResult
    mutating func apply(_ action: ScoreAction) -> String? {
        switch action {
        case .addSelected, .takeSelected:
            change(selected, by: action == .addSelected ? 1 : -1)
            return "\(players[selected].name) \(players[selected].score)"
        case .add(let index), .take(let index):
            guard players.indices.contains(index) else { return nil }
            change(index, by: action == .add(index) ? 1 : -1)
            return summary
        case .next, .previous:
            select(step: action == .next ? 1 : -1)
            return "\(players[selected].name), \(players[selected].score)"
        }
    }
}

/// Something the band can do to a live game. Each one is given a gesture or a combo in
/// Score settings (`ScoreControls`).
enum ScoreAction: Hashable, Sendable, Identifiable {
    case addSelected, takeSelected, next, previous
    /// A point to, or from, one player by position (0-based), whoever is selected.
    case add(Int), take(Int)

    /// Every action, in the order settings lists them.
    static let all: [ScoreAction] = [.addSelected, .takeSelected, .next, .previous]
        + (0..<ScoreGame.maxPlayers).flatMap { [ScoreAction.add($0), .take($0)] }

    var id: String {
        switch self {
        case .addSelected: "add-selected"
        case .takeSelected: "take-selected"
        case .next: "next"
        case .previous: "previous"
        case .add(let i): "add-\(i + 1)"
        case .take(let i): "take-\(i + 1)"
        }
    }
    init?(id: String) {
        guard let action = Self.all.first(where: { $0.id == id }) else { return nil }
        self = action
    }

    var title: String {
        switch self {
        case .addSelected: "Add a point"
        case .takeSelected: "Take a point away"
        case .next: "Next player"
        case .previous: "Previous player"
        case .add(let i): "Add a point to player \(i + 1)"
        case .take(let i): "Take a point from player \(i + 1)"
        }
    }
    var detail: String {
        switch self {
        case .addSelected: "To the selected player."
        case .takeSelected: "From the selected player."
        case .next: "Selects the next player, wrapping round to the first."
        case .previous: "Selects the one before, wrapping round to the last."
        case .add, .take: "Also selects them."
        }
    }
    /// The player this action always changes, if it names one.
    var player: Int? {
        switch self { case .add(let i), .take(let i): i; default: nil }
    }
}

/// What sets off an action: one gesture, or a combo of two to eight finger and swipe steps.
struct ScoreTrigger: Codable, Hashable, Sendable {
    var steps: [ComboStep]
    var intervalMs: Int = ComboRules.defaultTime

    static func gesture(_ kind: GestureKind) -> ScoreTrigger { ScoreTrigger(steps: [ComboStep(kind)]) }

    var isCombo: Bool { steps.count > 1 }
    /// The gesture when this is a single one.
    var gesture: GestureKind? { isCombo ? nil : steps.first?.gesture }
    var name: String { steps.map(\.name).joined(separator: ", then ") }

    /// Gestures a trigger may use on its own. Swipe up belongs to the score screen's zoom,
    /// and releases only make sense inside a combo.
    static let singleChoices = GestureKind.motions.filter { $0 != .swipeUp }
    /// Steps a combo may use: finger gestures and swipes. Motion and air gestures would need
    /// the band's motion streams for the whole game.
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] {
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }

    var isValid: Bool {
        if let gesture { return Self.singleChoices.contains(gesture) }
        return ComboRules.valid(steps) && ComboRules.times.contains(intervalMs)
            && steps.allSatisfy { !$0.gesture.isMotion && !$0.gesture.isAir }
    }
}

/// How a game is kept from the band: the trigger for each action, and its sounds.
struct ScoreControls: Codable, Hashable, Sendable {
    private(set) var triggers: [String: ScoreTrigger]
    var sounds = ScoreSounds()

    /// A point to and from the selected player on the index finger; side swipes step
    /// through the players, as on screen.
    static let standard = ScoreControls(triggers: [
        ScoreAction.addSelected.id: .gesture(.doubleTapIndex),
        ScoreAction.takeSelected.id: .gesture(.holdIndex),
        ScoreAction.next.id: .gesture(.swipeRight),
        ScoreAction.previous.id: .gesture(.swipeLeft),
    ])

    func trigger(for action: ScoreAction) -> ScoreTrigger? { triggers[action.id] }

    /// Sets an action's trigger (nil clears it). An action that already had the same trigger
    /// takes this action's old one, so no two actions share one.
    mutating func set(_ trigger: ScoreTrigger?, for action: ScoreAction) {
        let old = triggers[action.id]
        if let trigger, let other = triggers.first(where: { $0.key != action.id && $0.value.steps == trigger.steps })?.key {
            triggers[other] = old
        }
        triggers[action.id] = trigger
    }

    /// Valid triggers and their actions.
    var live: [(action: ScoreAction, trigger: ScoreTrigger)] {
        ScoreAction.all.compactMap { action in
            triggers[action.id].flatMap { $0.isValid ? (action, $0) : nil }
        }
    }

    /// The gestures a live game takes; mappings that use one are off until the game ends.
    /// A double tap arrives after the tap that began it and a hold ends with a release, so
    /// a finger's single tap and release are taken with them; otherwise each would also run.
    var reserved: Set<GestureKind> {
        var gestures = Set(live.flatMap { $0.trigger.steps.map(\.gesture) })
        if gestures.contains(.doubleTapIndex) { gestures.insert(.tapIndex) }
        if gestures.contains(.doubleTapMiddle) { gestures.insert(.tapMiddle) }
        if gestures.contains(.holdIndex) { gestures.insert(.releaseIndex) }
        if gestures.contains(.holdMiddle) { gestures.insert(.releaseMiddle) }
        return gestures
    }

    /// The triggers as mappings, for a `MappingEngine` that only decides which one fired.
    /// A single gesture's mapping must be named after it; the placeholder action is never run.
    var mappings: [Mapping] {
        live.map { action, trigger in
            if let gesture = trigger.gesture { return Mapping(id: gesture.rawValue, enabled: true, actions: [.haptic(.light)]) }
            return Mapping(id: "score:" + action.id, enabled: true, actions: [.haptic(.light)], steps: trigger.steps, intervalMs: trigger.intervalMs)
        }
    }
    /// The action a fired mapping stands for.
    func action(forMapping id: String) -> ScoreAction? {
        if id.hasPrefix("score:") { return ScoreAction(id: String(id.dropFirst(6))) }
        return live.first { $0.trigger.gesture?.rawValue == id }?.action
    }

    private enum Keys: String, CodingKey { case triggers, sounds }
    init(triggers: [String: ScoreTrigger], sounds: ScoreSounds = ScoreSounds()) { self.triggers = triggers; self.sounds = sounds }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        triggers = try c.decodeIfPresent([String: ScoreTrigger].self, forKey: .triggers) ?? Self.standard.triggers
        sounds = (try? c.decodeIfPresent(ScoreSounds.self, forKey: .sounds)) ?? ScoreSounds()
    }
}

/// The sounds a live game plays, from the Mac's library. Players each have their own sound,
/// and no two share one: selecting a player is heard, not seen.
struct ScoreSounds: Codable, Hashable, Sendable {
    static let standardAdd = SoundVoice.resolve, standardTake = SoundVoice.bounce

    var on = true
    /// 0...1.
    var volume = 0.8
    /// Nil plays nothing for that change.
    var add: SoundVoice? = standardAdd
    var take: SoundVoice? = standardTake
    /// The set of player sounds; nil plays nothing when a player is selected.
    var players: ScorePlayerSounds? = .mallets

    /// Each player also has their own pitch (a pentatonic step up from G4), so voices that
    /// follow pitch are told apart twice over.
    static func pitch(player: Int) -> Double {
        let steps = [0, 2, 4, 7, 9, 12]
        return 392 * pow(2, Double(steps[min(max(player, 0), steps.count - 1)]) / 12)
    }

    func player(_ index: Int) -> SoundVoice? {
        players.map { $0.voices[min(max(index, 0), $0.voices.count - 1)] }
    }

    private enum Keys: String, CodingKey { case on, volume, add, take, players = "playerSounds" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        on = (try? c.decode(Bool.self, forKey: .on)) ?? true
        volume = min(1, max(0, (try? c.decode(Double.self, forKey: .volume)) ?? 0.8))
        // A missing key is an older save and gets the default; null is a chosen "None".
        func value<T: Decodable>(_ key: Keys, _ fallback: T) -> T? {
            guard c.contains(key) else { return fallback }
            if (try? c.decodeNil(forKey: key)) == true { return nil }
            return (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        add = value(.add, Self.standardAdd)
        take = value(.take, Self.standardTake)
        players = value(.players, ScorePlayerSounds.mallets)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(on, forKey: .on)
        try c.encode(volume, forKey: .volume)
        // Null when None, so it isn't read back as the default.
        try c.encode(add, forKey: .add)
        try c.encode(take, forKey: .take)
        try c.encode(players, forKey: .players)
    }
}

/// Curated sets of player sounds. Each set gives every player a different voice from the
/// Mac's library, chosen to be told apart by ear, and none uses the add or take-away defaults.
enum ScorePlayerSounds: String, Codable, CaseIterable, Identifiable, Sendable {
    case mallets, chimes, arcade, percussion, soft

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mallets: "Mallets"
        case .chimes: "Chimes"
        case .arcade: "Arcade"
        case .percussion: "Percussion"
        case .soft: "Soft"
        }
    }
    /// One voice per player position, all different.
    var voices: [SoundVoice] {
        switch self {
        case .mallets: [.marimba, .wood, .kalimba, .pluck, .glass, .harp]
        case .chimes: [.pip, .bell, .droplet, .sparkle, .sonar, .shimmer]
        case .arcade: [.blip, .coin, .chirp, .bubble, .laser, .pop]
        case .percussion: [.tick, .rim, .click, .wood, .tap, .swoosh]
        case .soft: [.soft, .whole, .hum, .warm, .lift, .tone]
        }
    }
    var detail: String {
        switch self {
        case .mallets: "Wooden and plucked notes. Clear without being loud."
        case .chimes: "Bright, ringing notes that carry from a pocket."
        case .arcade: "Game blips, each with its own shape."
        case .percussion: "Short knocks and clicks, quickest to hear."
        case .soft: "Gentle tones for a quiet room."
        }
    }
}

/// The sound for a change to a live game, so it can be kept without looking (`ScoreAudio`).
enum ScoreCue: Hashable, Sendable {
    case add, subtract
    /// A player became the selected one; carries their index.
    case select(Int)

    /// What changed from `old` to `new`: a score going up or down wins over the selection
    /// (changing a player also selects them). Nil when nothing a listener cares about changed.
    init?(from old: ScoreGame, to new: ScoreGame) {
        let before = old.scores.reduce(0, +), after = new.scores.reduce(0, +)
        if old.players.map(\.id) == new.players.map(\.id), after != before {
            self = after > before ? .add : .subtract
        } else if old.selected != new.selected {
            self = .select(new.selected)
        } else {
            return nil
        }
    }
}
