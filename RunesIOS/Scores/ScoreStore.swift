import Foundation

/// The game being scored. While it is live, its band gestures are taken here, mappings that
/// use them are off, and every change from the band is confirmed without the screen: the
/// Live Activity alerts with a sound and the new score.
@MainActor
final class ScoreStore: ObservableObject {
    static let shared = ScoreStore()
    private static let key = "runes.score.v1"

    private struct Saved: Codable {
        var game: ScoreGame
        /// Missing in games saved before gestures could be chosen.
        var controls: ScoreControls?
        /// The user's own game types; missing in saves from before there were any.
        var types: [ScoreRules]?
    }

    @Published private(set) var game: ScoreGame { didSet { cue(from: oldValue) } }
    /// Which gesture or combo does what, and the sounds; chosen in Score settings.
    @Published private(set) var controls: ScoreControls { didSet { configureEngine() } }

    /// Game types the user has made, listed after the built-in ones.
    @Published private(set) var types: [ScoreRules]

    /// Told when the game goes live or ends, so its sounds can keep running with the screen off.
    var onLive: ((Bool) -> Void)? { didSet { onLive?(game.live) } }
    /// Told the sound for each change to a live game: selecting a player, adding or taking a point.
    var onCue: ((ScoreCue) -> Void)?

    /// Shows the score on the Live Activity (nil restores band status); the string is an alert.
    var onActivity: ((ScoreActivityState?, String?) -> Void)? { didSet { if game.live { show() } } }

    /// Told which gestures the game holds (none when it isn't live), so mappings that use
    /// them turn off for as long as it does.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    private var reservedNow: Set<GestureKind> {
        (game.live && !yielded ? controls.reserved.union(SwitchControls.reserved(switchMapping)) : []).union(onScreen && !yielded ? [.swipeUp] : [])
    }
    /// The switch-controls combo, while this is the app the band switches to and from and
    /// its controls are selected. Set by `ControlSwitch`.
    var switchMapping: Mapping? {
        didSet { if switchMapping != oldValue { configureEngine(); if !previewOnly { onReserve?(reservedNow) } } }
    }
    /// True while the regular mappings have the band though a game is live. The score stays.
    /// The screen's own swipe up is given back too, so a combo that uses it can be made.
    var yielded = false { didSet { if yielded != oldValue, !previewOnly { onReserve?(reservedNow) } } }

    /// True while the score screen is in front of the user. A band swipe up then zooms
    /// between one player and everyone's scores, live game or not.
    var onScreen = false { didSet { if onScreen != oldValue, !previewOnly { onReserve?(reservedNow) } } }
    /// Counts band swipes up taken while the screen is in view; the screen toggles on each.
    @Published private(set) var showAllToggles = 0

    private var previewOnly = false
    /// Decides which trigger a band gesture completes, combos included.
    private var engine = MappingEngine()
    private var ticker: Timer?

    private init() {
        var saved = Saved(game: ScoreGame())
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded }
        game = saved.game
        controls = saved.controls ?? .standard
        types = (saved.types ?? []).filter { !$0.isPreset }
        configureEngine()
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview game: ScoreGame, controls: ScoreControls = .standard, types: [ScoreRules] = []) {
        self.game = game; self.controls = controls; self.types = types; previewOnly = true
    }
    #endif

    // MARK: Settings

    func setTrigger(_ trigger: ScoreTrigger?, for action: ScoreAction) { controls.set(trigger, for: action); settingsChanged() }
    func setSounds(_ change: (inout ScoreSounds) -> Void) { change(&controls.sounds); settingsChanged() }
    func resetGestures() { controls = ScoreControls(triggers: ScoreControls.standard.triggers, sounds: controls.sounds); settingsChanged() }

    private func settingsChanged() {
        persist()
        guard !previewOnly else { return }
        onReserve?(reservedNow)
    }

    // MARK: Actions

    func start() { game.live = true; changed() }

    /// Gives the gestures back to mappings. The score stays until it is reset.
    func end() {
        game.live = false
        persist()
        onReserve?(reservedNow)
        onActivity?(nil, nil)
    }

    func change(_ index: Int, by delta: Int) { game.change(index, by: delta); changed() }
    func select(_ index: Int) { guard index != game.selected else { return }; game.select(index); changed() }
    func reset() { game.reset(); changed() }

    /// Switches the game type; everyone starts from zero.
    func play(_ rules: ScoreRules) { game.play(rules); changed() }

    /// Adds one of the user's own game types, or changes it. A game being played by it
    /// takes the new rules and starts again.
    func saveType(_ rules: ScoreRules) {
        guard !rules.isPreset else { return }
        if let index = types.firstIndex(where: { $0.id == rules.id }) { types[index] = rules } else { types.append(rules) }
        if game.rules.id == rules.id { game.play(rules) }
        changed()
    }

    /// Deletes one of the user's own game types. A game being played by it goes back to free play.
    func deleteType(_ id: String) {
        types.removeAll { $0.id == id }
        if game.rules.id == id { game.play(.open) }
        changed()
    }
    func rename(_ index: Int, to name: String) { game.rename(index, to: name); changed() }
    func addPlayer() { if game.addPlayer() { changed() } }
    func removePlayer(_ index: Int) { if game.removePlayer(index) { changed() } }

    /// Takes a band gesture while a game is live, and swipe up while the screen is in view.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        let ours = game.live && !yielded && controls.reserved.union(SwitchControls.reserved(switchMapping)).contains(kind)
        if kind == .swipeUp, onScreen, !ours { showAllToggles += 1; return true }
        handle(engine.receive(kind, at: ProcessInfo.processInfo.systemUptime))
        if !engine.isIdle, ticker == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        return true
    }

    private func tick() {
        handle(engine.tick(at: ProcessInfo.processInfo.systemUptime))
        if engine.isIdle { ticker?.invalidate(); ticker = nil }
    }

    private func handle(_ events: [MappingEngine.Event]) {
        for event in events {
            guard case .fire(let id, _) = event, game.live else { continue }
            if id == SwitchControls.mappingID { ControlSwitch.shared.toggle(); continue }
            guard let action = controls.action(forMapping: id) else { continue }
            if let alert = game.apply(action) { changed(alert: alert) }
        }
    }

    private func configureEngine() {
        engine.configure(SwitchControls.adding(switchMapping, to: controls.mappings))
        ticker?.invalidate(); ticker = nil
    }

    /// Saves and shows the game. `alert` is the confirmation for a change made from the band.
    private func changed(alert: String? = nil) {
        persist()
        guard !previewOnly else { return }
        onReserve?(reservedNow)
        if game.live { show(alert: alert) }
    }

    private func cue(from old: ScoreGame) {
        guard !previewOnly else { return }
        if old.live != game.live { onLive?(game.live) }
        if controls.sounds.buzz, let buzz = ScoreBuzz.Kind(from: old, to: game) { ScoreBuzz.shared.play(buzz) }
        if game.live, let cue = ScoreCue(from: old, to: game) {
            onCue?(cue)
            if let point = ScoreCue.point(from: old, to: game) { onCue?(.point(point)) }
        }
    }

    private func show(alert: String? = nil) {
        let all = game.players.indices
        // The Lock Screen has no room for words: sets and games as "S1 G3".
        let standings = all.map { index -> String in
            let player = game.players[index]
            return ([game.winner == index ? "Won" : nil, game.rules.sets > 1 ? "S\(player.sets)" : nil, game.rules.games > 1 ? "G\(player.games)" : nil] as [String?])
                .compactMap { $0 }.joined(separator: " ")
        }
        onActivity?(ScoreActivityState(names: game.names, scores: game.scores, labels: all.map(game.points), standings: standings,
                                       toGo: all.map { game.toGo($0) ?? 0 }, pointNames: all.map { game.pointName($0) ?? "" }, tints: game.players.map(\.tint),
                                       selected: game.usesSelection ? game.selected : nil), alert)
    }

    private func persist() {
        guard !previewOnly else { return }
        if let data = try? JSONEncoder().encode(Saved(game: game, controls: controls, types: types)) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
