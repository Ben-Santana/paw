import Foundation

struct ScorePlayer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    /// Points in the game being played.
    var score = 0
    /// Games won in this set, and sets won, for game types that count them.
    var games = 0
    var sets = 0
    /// Index into `ScoreTint`; a player keeps their colour when others come and go.
    var tint: Int

    init(name: String, tint: Int) { self.name = name; self.tint = tint }

    private enum Keys: String, CodingKey { case id, name, score, games, sets, tint }
    /// Games and sets are missing in games saved before there were game types.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        score = try c.decode(Int.self, forKey: .score)
        games = try c.decodeIfPresent(Int.self, forKey: .games) ?? 0
        sets = try c.decodeIfPresent(Int.self, forKey: .sets) ?? 0
        tint = try c.decode(Int.self, forKey: .tint)
    }
}

/// A game type: how points become games, sets and a win. Free play has no end; the rest
/// are sports, or the user's own. Pure values, so they are tested without a band.
struct ScoreRules: Codable, Hashable, Identifiable, Sendable {
    static let nameLimit = 24

    var id: String
    var name: String
    /// Points that win a game; nil counts up with no end.
    var points: Int?
    /// The lead a game is won by.
    var winBy = 1
    /// Games that win a set. With one set, these win the match.
    var games = 1
    var gamesWinBy = 1
    /// Sets that win the match.
    var sets = 1
    /// Points read 0, 15, 30, 40 and Ad, and a tiebreak to seven settles a set at games all.
    var tennis = false

    static let open = ScoreRules(id: "open", name: "Free play")
    static let presets: [ScoreRules] = [
        open,
        ScoreRules(id: "tennis", name: "Tennis", points: 4, winBy: 2, games: 6, gamesWinBy: 2, sets: 2, tennis: true),
        ScoreRules(id: "table-tennis", name: "Table tennis", points: 11, winBy: 2, games: 3),
        ScoreRules(id: "badminton", name: "Badminton", points: 21, winBy: 2, games: 2),
        ScoreRules(id: "pickleball", name: "Pickleball", points: 11, winBy: 2, games: 2),
        ScoreRules(id: "squash", name: "Squash", points: 11, winBy: 2, games: 3),
        ScoreRules(id: "volleyball", name: "Volleyball", points: 25, winBy: 2, sets: 3),
    ]
    var isPreset: Bool { Self.presets.contains { $0.id == id } }

    /// A type of the user's own: first to `points`, by any lead up to `points` itself, over a number of games.
    static func custom(id: String = "custom-" + UUID().uuidString.lowercased(), name: String, points: Int, winBy: Int, games: Int) -> ScoreRules {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
        return ScoreRules(id: id, name: trimmed.isEmpty ? "My game" : trimmed, points: max(1, points), winBy: min(max(winBy, 1), max(1, points)), games: max(1, games))
    }

    /// The rules in a sentence, under the name wherever types are listed.
    var detail: String {
        guard let points else { return "No limit. Count as high as you like." }
        if tennis { return "Best of \(sets * 2 - 1) sets of \(games) games, with a tiebreak at \(games) all." }
        var text = "First to \(points)" + (winBy > 1 ? ", \(winBy) clear" : "")
        if sets > 1 { text += ". Best of \(sets * 2 - 1) sets" } else if games > 1 { text += ". Best of \(games * 2 - 1) games" }
        return text + "."
    }
}

/// What a player's next point would win, in rising order.
enum ScorePoint: Int, Comparable, Hashable, Sendable {
    case game, set, match

    var name: String {
        switch self {
        case .game: "Game point"
        case .set: "Set point"
        case .match: "Match point"
        }
    }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
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
    /// The game type being played.
    private(set) var rules = ScoreRules.open
    /// Who has won the match. Nobody scores after that until it is reset.
    private(set) var winner: Int?
    /// Everyone's tallies before the point that last won a game, so the winner taking that
    /// point back puts the game back as it was.
    private var undo: Undo?

    private struct Undo: Codable, Equatable, Sendable {
        var winner: Int
        /// Points, games and sets for each player.
        var tallies: [[Int]]
    }

    var names: [String] { players.map(\.name) }
    var scores: [Int] { players.map(\.score) }
    var isEmpty: Bool { players.allSatisfy { $0.score == 0 && $0.games == 0 && $0.sets == 0 } }
    /// Goes up with every point, game and set won, and down when one is taken back.
    var progress: Int { players.reduce(0) { $0 + $1.sets * 1_000_000 + $1.games * 1_000 + $1.score } }
    /// Tennis at games all: this game is a tiebreak, first to seven by two, and wins the set.
    var tiebreak: Bool { rules.tennis && players.filter { $0.games >= rules.games }.count > 1 }
    var canAdd: Bool { players.count < Self.maxPlayers }
    var canRemove: Bool { players.count > Self.minPlayers }
    /// Two players have a finger each. With more, the band changes one selected player
    /// and steps between them.
    var usesSelection: Bool { players.count > 2 }

    /// Adds `delta` to a player and selects them. A score never goes below zero. A point
    /// that reaches the game type's target wins the game, and with it perhaps the set and
    /// the match; the winner taking a point back straight after undoes that.
    mutating func change(_ index: Int, by delta: Int) {
        guard players.indices.contains(index) else { return }
        selected = index
        guard delta != 0 else { return }
        if delta < 0, let undo, undo.winner == index, undo.tallies.count == players.count {
            for (i, tally) in undo.tallies.enumerated() { (players[i].score, players[i].games, players[i].sets) = (tally[0], tally[1], tally[2]) }
            winner = nil; self.undo = nil
            return
        }
        guard delta < 0 || winner == nil else { return }
        let before = players.map { [$0.score, $0.games, $0.sets] }
        undo = nil
        players[index].score = max(0, players[index].score + delta)
        if delta > 0 { settle(index, before: before) }
    }

    /// Whether a player has anything to take back: a point, or the game they just won.
    func canTake(_ index: Int) -> Bool {
        players.indices.contains(index) && (players[index].score > 0 || undo?.winner == index)
    }

    /// Gives the player their game if the point just added won it, then the set and the
    /// match if the game did. Points start again after a game, games after a set; the
    /// match's last tallies stay as they are.
    private mutating func settle(_ index: Int, before: [[Int]]) {
        guard toGo(index, after: 0) == 0 else { return }
        func lead(_ tally: KeyPath<ScorePlayer, Int>) -> Int {
            players[index][keyPath: tally] - (players.indices.filter { $0 != index }.map { players[$0][keyPath: tally] }.max() ?? 0)
        }
        let decider = tiebreak
        players[index].games += 1
        let set = decider || (players[index].games >= rules.games && lead(\.games) >= rules.gamesWinBy)
        if set { players[index].sets += 1 }
        if set, players[index].sets >= rules.sets {
            winner = index
        } else {
            for i in players.indices {
                players[i].score = 0
                if set { players[i].games = 0 }
            }
        }
        undo = Undo(winner: index, tallies: before)
    }

    /// The points and the lead that win the game being played; nil in free play.
    private var goal: (points: Int, by: Int)? {
        rules.points.map { tiebreak ? (7, 2) : ($0, rules.winBy) }
    }

    /// Points the player still needs for the game, were everyone else to stand still:
    /// enough to reach the target, and enough to be far enough ahead.
    private func toGo(_ index: Int, after floor: Int) -> Int? {
        guard let goal, players.indices.contains(index) else { return nil }
        let own = players[index].score
        let other = players.indices.filter { $0 != index }.map { players[$0].score }.max() ?? 0
        return max(goal.points - own, other + goal.by - own, floor)
    }

    /// Points the player still needs to win the game, counted down on their face once the
    /// end is near: within the lead the game is won by, or three points. Nil before then,
    /// in free play, and once the match is won.
    func toGo(_ index: Int) -> Int? {
        guard winner == nil, let goal, let left = toGo(index, after: 1), left <= max(goal.by, 3) else { return nil }
        return left
    }

    /// What the player's next point would win, when it would win something: "Game point",
    /// "Set point" or "Match point".
    func pointName(_ index: Int) -> String? { point(index)?.name }

    /// What the player's next point would win, when it would win something.
    func point(_ index: Int) -> ScorePoint? {
        guard toGo(index) == 1 else { return nil }
        var next = self
        next.change(index, by: 1)
        if next.winner == index { return .match }
        return next.players[index].sets > players[index].sets ? .set : .game
    }

    /// Switches to another game type. Everyone starts from zero.
    mutating func play(_ rules: ScoreRules) {
        guard rules != self.rules else { return }
        self.rules = rules
        reset()
    }

    /// A player's points as the game type reads them: a number, or tennis's 15, 30, 40 and Ad.
    func points(_ index: Int) -> String {
        guard players.indices.contains(index) else { return "" }
        let own = players[index].score
        guard rules.tennis, !tiebreak else { return "\(own)" }
        let other = players.indices.filter { $0 != index }.map { players[$0].score }.max() ?? 0
        if own >= 3, other >= 3 { return own > other ? "Ad" : "40" }
        return ["0", "15", "30", "40"][min(own, 3)]
    }

    /// "Sets 1 · Games 3", for game types that count them, and whether the player has won.
    func standing(_ index: Int) -> String? {
        guard players.indices.contains(index) else { return nil }
        var parts = winner == index ? ["Won"] : []
        if rules.sets > 1 { parts.append("Sets \(players[index].sets)") }
        if rules.games > 1 { parts.append("Games \(players[index].games)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    mutating func select(_ index: Int) {
        if players.indices.contains(index) { selected = index }
    }

    /// Moves the selection forward or back, wrapping at the ends.
    mutating func select(step: Int) {
        selected = ((selected + step) % players.count + players.count) % players.count
    }

    mutating func reset() {
        for i in players.indices { (players[i].score, players[i].games, players[i].sets) = (0, 0, 0) }
        winner = nil; undo = nil
    }

    /// Adds a player with the first colour nobody has. False when the game is full.
    @discardableResult
    mutating func addPlayer() -> Bool {
        guard canAdd else { return false }
        let used = Set(players.map(\.tint))
        let tint = (0..<Self.maxPlayers).first { !used.contains($0) } ?? players.count
        players.append(ScorePlayer(name: Self.defaultName(players.count), tint: tint))
        undo = nil
        return true
    }

    /// Removes a player; a game keeps at least two.
    @discardableResult
    mutating func removePlayer(_ index: Int) -> Bool {
        guard canRemove, players.indices.contains(index) else { return false }
        players.remove(at: index)
        undo = nil
        if let won = winner { winner = won == index ? nil : won > index ? won - 1 : won }
        if selected > index || selected >= players.count { selected = max(0, selected - 1) }
        return true
    }

    mutating func rename(_ index: Int, to name: String) {
        guard players.indices.contains(index) else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        players[index].name = trimmed.isEmpty ? Self.defaultName(index) : trimmed
    }

    /// "Player 1 3 · Player 2 2", for the applications list. Game types that count games
    /// and sets add them: "… · Games 2–1 · Sets 1–0".
    var summary: String {
        var parts = players.indices.map { "\(players[$0].name) \(points($0))" }
        if rules.games > 1 { parts.append("Games " + players.map { "\($0.games)" }.joined(separator: "–")) }
        if rules.sets > 1 { parts.append("Sets " + players.map { "\($0.sets)" }.joined(separator: "–")) }
        return parts.joined(separator: " · ")
    }

    /// What a point just won, said first in the band's confirmation: "Game, Sam".
    private func won(since old: ScoreGame) -> String? {
        guard players.indices.contains(selected), old.players.indices.contains(selected) else { return nil }
        let now = players[selected], then = old.players[selected]
        if winner == selected, old.winner == nil { return "\(now.name) wins" }
        if now.sets > then.sets { return "Set, \(now.name)" }
        if now.games > then.games { return "Game, \(now.name)" }
        return nil
    }

    /// Carries out a band action and returns a line confirming it, or nil when the action
    /// names a player who isn't in the game.
    @discardableResult
    mutating func apply(_ action: ScoreAction) -> String? {
        switch action {
        case .addSelected, .takeSelected:
            let old = self
            change(selected, by: action == .addSelected ? 1 : -1)
            if let won = won(since: old) { return won + " · " + summary }
            return (pointName(selected).map { $0 + " · " } ?? "") + "\(players[selected].name) \(points(selected))"
        case .add(let index), .take(let index):
            guard players.indices.contains(index) else { return nil }
            let old = self
            change(index, by: action == .add(index) ? 1 : -1)
            return ((won(since: old) ?? pointName(index).map { "\($0), \(players[index].name)" }).map { $0 + " · " } ?? "") + summary
        case .next, .previous:
            select(step: action == .next ? 1 : -1)
            return "\(players[selected].name), \(points(selected))"
        }
    }

    private enum Keys: String, CodingKey { case players, selected, live, rules, winner, undo }
}

extension ScoreGame {
    /// The game type and its tallies are missing in games saved before there were any.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init()
        players = try c.decode([ScorePlayer].self, forKey: .players)
        selected = try c.decode(Int.self, forKey: .selected)
        live = try c.decode(Bool.self, forKey: .live)
        rules = (try? c.decodeIfPresent(ScoreRules.self, forKey: .rules)) ?? .open
        winner = (try? c.decodeIfPresent(Int.self, forKey: .winner)).flatMap { players.indices.contains($0) ? $0 : nil }
        undo = try? c.decodeIfPresent(Undo.self, forKey: .undo)
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
    /// Played when a point wins a game, or a set or the match. The stored names keep older saves.
    var gamePoint: SoundVoice? = standardGamePoint
    var setPoint: SoundVoice? = standardSetPoint
    static let standardGamePoint = SoundVoice.bells, standardSetPoint = SoundVoice.sparkle
    /// The set of player sounds; nil plays nothing when a player is selected.
    var players: ScorePlayerSounds? = .mallets
    /// Opt in: the phone buzzes for each change, a single tap for a point and a double
    /// one for a point taken away (`ScoreBuzz`).
    var buzz = false

    /// Each player also has their own pitch (a pentatonic step up from G4), so voices that
    /// follow pitch are told apart twice over.
    static func pitch(player: Int) -> Double {
        let steps = [0, 2, 4, 7, 9, 12]
        return 392 * pow(2, Double(steps[min(max(player, 0), steps.count - 1)]) / 12)
    }

    func player(_ index: Int) -> SoundVoice? {
        players.map { $0.voices[min(max(index, 0), $0.voices.count - 1)] }
    }

    /// Winning the match shares the set sound: in one-set games the match is the only set.
    func voice(for point: ScorePoint) -> SoundVoice? { point == .game ? gamePoint : setPoint }

    private enum Keys: String, CodingKey { case on, volume, add, take, buzz, gamePoint, setPoint, players = "playerSounds" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        on = (try? c.decode(Bool.self, forKey: .on)) ?? true
        volume = min(1, max(0, (try? c.decode(Double.self, forKey: .volume)) ?? 0.8))
        buzz = (try? c.decode(Bool.self, forKey: .buzz)) ?? false
        // A missing key is an older save and gets the default; null is a chosen "None".
        func value<T: Decodable>(_ key: Keys, _ fallback: T) -> T? {
            guard c.contains(key) else { return fallback }
            if (try? c.decodeNil(forKey: key)) == true { return nil }
            return (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        add = value(.add, Self.standardAdd)
        take = value(.take, Self.standardTake)
        gamePoint = value(.gamePoint, Self.standardGamePoint)
        setPoint = value(.setPoint, Self.standardSetPoint)
        players = value(.players, ScorePlayerSounds.mallets)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(on, forKey: .on)
        try c.encode(volume, forKey: .volume)
        try c.encode(buzz, forKey: .buzz)
        // Null when None, so it isn't read back as the default.
        try c.encode(add, forKey: .add)
        try c.encode(take, forKey: .take)
        try c.encode(gamePoint, forKey: .gamePoint)
        try c.encode(setPoint, forKey: .setPoint)
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
    /// A point won a game, a set or the match; follows that point's own cue.
    case point(ScorePoint)

    /// What the point just added won: the game, the set or the match. Nil for a point that
    /// won nothing, and for any point taken back (taking back a winning point undoes it).
    static func point(from old: ScoreGame, to new: ScoreGame) -> ScorePoint? {
        guard old.players.map(\.id) == new.players.map(\.id), new.progress > old.progress else { return nil }
        if let winner = new.winner, old.winner == nil, new.players.indices.contains(winner) { return .match }
        // Winning a set puts everyone's games back to zero, so a set shows only in the sets.
        if new.players.indices.contains(where: { new.players[$0].sets > old.players[$0].sets }) { return .set }
        if new.players.indices.contains(where: { new.players[$0].games > old.players[$0].games }) { return .game }
        return nil
    }

    /// What changed from `old` to `new`: a score going up or down wins over the selection
    /// (changing a player also selects them). Nil when nothing a listener cares about changed.
    init?(from old: ScoreGame, to new: ScoreGame) {
        // Progress, not points: winning a game puts everyone's points back to zero.
        let before = old.progress, after = new.progress
        if old.players.map(\.id) == new.players.map(\.id), after != before {
            self = after > before ? .add : .subtract
        } else if old.selected != new.selected {
            self = .select(new.selected)
        } else {
            return nil
        }
    }
}
