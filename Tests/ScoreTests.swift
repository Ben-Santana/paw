// Isolated checks for the scorekeeper: changes up and down, names, the band's gestures, and mappings going off.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift RunesIOS/Sounds/SoundLibrary.swift RunesIOS/Scores/ScoreModel.swift \
//       Tests/ScoreTests.swift -o /private/tmp/runes-score-tests && /private/tmp/runes-score-tests
import Foundation

@main
struct ScoreTests {
    static func main() {
        var game = ScoreGame()
        precondition(game.scores == [0, 0] && game.isEmpty && game.names == ["Player 1", "Player 2"])

        game.change(0, by: 1); game.change(1, by: 1); game.change(0, by: 1)
        precondition(game.scores == [2, 1] && !game.isEmpty)
        precondition(game.summary == "Player 1 2 · Player 2 1")
        game.change(2, by: 1); game.change(-1, by: 1)
        precondition(game.scores == [2, 1], "Only players in the game score")

        // Each player goes down on their own, and never below zero.
        game.change(1, by: -1); precondition(game.scores == [2, 0])
        game.change(1, by: -1); precondition(game.scores == [2, 0], "A score stops at zero")
        game.change(0, by: -1); precondition(game.scores == [1, 0])
        game.reset()
        precondition(game.isEmpty && game.scores == [0, 0])

        // Names are trimmed, capped, and fall back when emptied.
        game.rename(1, to: "  Sam  "); precondition(game.names == ["Player 1", "Sam"])
        game.rename(1, to: "   "); precondition(game.names == ["Player 1", "Player 2"])
        game.rename(0, to: String(repeating: "a", count: 40)); precondition(game.names[0].count == ScoreGame.nameLimit)
        game.rename(5, to: "Nobody"); precondition(game.names.count == 2)
        game.rename(0, to: "Player 1")

        // Two to six players; each new one takes a colour nobody has and keeps it.
        precondition(!game.canRemove && !game.removePlayer(0), "A game keeps two players")
        precondition(game.addPlayer() && game.names == ["Player 1", "Player 2", "Player 3"] && game.players[2].tint == 2)
        precondition(game.usesSelection)
        game.change(2, by: 4)
        precondition(game.removePlayer(1) && game.names == ["Player 1", "Player 3"] && game.scores == [0, 4])
        precondition(game.players.map(\.tint) == [0, 2] && game.selected == 1, "Selection follows its player")
        precondition(game.addPlayer() && game.players[2].tint == 1, "The freed colour is used next")
        while game.addPlayer() {}
        precondition(game.players.count == ScoreGame.maxPlayers && !game.canAdd)
        precondition(Set(game.players.map(\.tint)).count == ScoreGame.maxPlayers, "Every player has their own colour")

        // A saved game comes back as it was.
        var saved = ScoreGame(); saved.live = true; saved.addPlayer(); saved.change(1, by: 2)
        let decoded = try! JSONDecoder().decode(ScoreGame.self, from: JSONEncoder().encode(saved))
        precondition(decoded == saved && decoded.scores == [0, 2, 0] && decoded.live && decoded.selected == 1)

        // Band actions: the selected player, a named player, or stepping between them.
        var trio = ScoreGame(); trio.addPlayer()
        precondition(trio.apply(.addSelected) == "Player 1 1" && trio.scores == [1, 0, 0])
        precondition(trio.apply(.next) == "Player 2, 0" && trio.apply(.next) == "Player 3, 0")
        precondition(trio.apply(.addSelected) == "Player 3 1" && trio.apply(.takeSelected) == "Player 3 0")
        precondition(trio.apply(.next) == "Player 1, 1", "Selection wraps forward")
        precondition(trio.apply(.previous) == "Player 3, 0", "and back")
        precondition(trio.apply(.add(1)) == "Player 1 1 · Player 2 1 · Player 3 0" && trio.selected == 1, "A named player is changed and selected")
        precondition(trio.apply(.take(1)) != nil && trio.scores == [1, 0, 0])
        precondition(trio.apply(.add(4)) == nil && trio.scores == [1, 0, 0], "A player who isn't in the game is skipped")
        precondition(ScoreAction.all.count == 4 + 2 * ScoreGame.maxPlayers)
        precondition(ScoreAction.all.allSatisfy { ScoreAction(id: $0.id) == $0 } && Set(ScoreAction.all.map(\.id)).count == ScoreAction.all.count)

        // Controls: the standard set, one trigger per action, and no two actions sharing one.
        var controls = ScoreControls.standard
        precondition(controls.trigger(for: .addSelected) == .gesture(.doubleTapIndex) && controls.trigger(for: .next) == .gesture(.swipeRight))
        controls.set(.gesture(.swipeRight), for: .addSelected)
        precondition(controls.trigger(for: .addSelected) == .gesture(.swipeRight) && controls.trigger(for: .next) == .gesture(.doubleTapIndex),
                     "Taking another action's trigger swaps them")
        controls.set(nil, for: .next)
        precondition(controls.trigger(for: .next) == nil)
        controls = .standard
        precondition(!ScoreTrigger.gesture(.swipeUp).isValid && !ScoreTrigger.gesture(.releaseIndex).isValid, "Swipe up is the screen's; releases need a hold")
        let combo = ScoreTrigger(steps: [ComboStep(.holdMiddle), ComboStep(.tapIndex), ComboStep(.releaseMiddle)], intervalMs: 500)
        precondition(combo.isValid && combo.isCombo && combo.gesture == nil)
        precondition(!ScoreTrigger(steps: [ComboStep(.releaseMiddle), ComboStep(.tapIndex)]).isValid, "A release needs its hold")
        precondition(!ScoreTrigger(steps: [ComboStep(.tapIndex), .rotation(.x)]).isValid, "No motion steps in a game")
        precondition(!ScoreTrigger.comboChoices(after: []).contains(.rotation) && ScoreTrigger.comboChoices(after: [ComboStep(.holdIndex)]).contains(.releaseIndex))
        controls.set(combo, for: .add(1))

        // Every trigger's gestures are reserved, with the taps and releases that come with them.
        let reserved = controls.reserved
        precondition(reserved.isSuperset(of: [.tapIndex, .doubleTapIndex, .holdIndex, .releaseIndex, .swipeLeft, .swipeRight, .holdMiddle, .releaseMiddle]))
        precondition(!reserved.contains(.swipeUp) && !reserved.contains(.swipeDown) && !reserved.contains(.doubleTapMiddle))
        precondition(!ScoreControls.standard.reserved.contains(.holdMiddle), "The middle finger keeps its mappings until it's given an action")

        // The engine decides which trigger fired, single gestures and combos alike.
        var scoreEngine = MappingEngine(mappings: controls.mappings)
        func actions(_ events: [MappingEngine.Event]) -> [ScoreAction] {
            events.compactMap { if case .fire(let id, _) = $0 { controls.action(forMapping: id) } else { nil } }
        }
        precondition(actions(scoreEngine.receive(.swipeRight, at: 0)) == [.next])
        precondition(actions(scoreEngine.receive(.holdIndex, at: 1) + scoreEngine.tick(at: 1.2)) == [.takeSelected])
        var comboFired = actions(scoreEngine.receive(.holdMiddle, at: 2))
        comboFired += actions(scoreEngine.receive(.tapIndex, at: 2.2))
        comboFired += actions(scoreEngine.receive(.releaseMiddle, at: 2.4) + scoreEngine.tick(at: 4))
        precondition(comboFired == [.add(1)], "The combo fires once, and its steps run nothing else: \(comboFired)")

        // Saved controls come back; old saves without them get the standard set.
        let roundTrip = try! JSONDecoder().decode(ScoreControls.self, from: JSONEncoder().encode(controls))
        precondition(roundTrip == controls)
        precondition(try! JSONDecoder().decode(ScoreControls.self, from: Data("{}".utf8)) == ScoreControls.standard)

        // Sounds: resolve and bounce for points; player sounds come in curated sets.
        var sounds = ScoreSounds()
        precondition(sounds.add == .resolve && sounds.take == .bounce && sounds.players == .mallets)
        for set in ScorePlayerSounds.allCases {
            precondition(set.voices.count == ScoreGame.maxPlayers && Set(set.voices).count == set.voices.count, "\(set): every player has their own sound")
            precondition(!set.voices.contains(.resolve) && !set.voices.contains(.bounce), "\(set): no player sounds like a point")
        }
        precondition(Set(ScorePlayerSounds.allCases.map(\.voices)).count == ScorePlayerSounds.allCases.count, "The sets differ")
        precondition((0..<ScoreGame.maxPlayers).map(sounds.player) == ScorePlayerSounds.mallets.voices)
        precondition(Set((0..<ScoreGame.maxPlayers).map(ScoreSounds.pitch)).count == ScoreGame.maxPlayers, "and their own pitch")

        // Any sound can be None, and None is kept, not read back as the default.
        sounds.add = nil; sounds.players = nil; sounds.volume = 0.4
        precondition(sounds.player(0) == nil)
        let quiet = try! JSONDecoder().decode(ScoreSounds.self, from: JSONEncoder().encode(sounds))
        precondition(quiet == sounds && quiet.add == nil && quiet.take == .bounce && quiet.players == nil)
        sounds.players = .arcade
        precondition(try! JSONDecoder().decode(ScoreSounds.self, from: JSONEncoder().encode(sounds)).players == .arcade)
        let legacy = try! JSONDecoder().decode(ScoreSounds.self, from: Data(#"{"on":true,"players":["coin","pip"],"volume":4}"#.utf8))
        precondition(legacy.players == .mallets && legacy.add == .resolve && legacy.volume == 1, "Older saves get the defaults, volume capped")

        // The Mac's whole library renders, each voice audible, the same every time, and capped.
        precondition(SoundVoice.sounds.count == 32)
        for voice in SoundVoice.sounds {
            let samples = SoundSynth.render(voice)
            let loudest = samples.map(abs).max() ?? 0
            precondition(samples.count > 1000 && abs(loudest - SoundSynth.peak) < 0.001, "\(voice) renders")
            precondition(samples.allSatisfy(\.isFinite))
        }
        // Band vibrations sit in the library too: silent on the phone, a pulse pattern on the band.
        precondition(SoundVoice.bandBuzzes.count == BandBuzz.allCases.count)
        precondition(Set(SoundVoice.bandBuzzes.compactMap(\.bandBuzz)) == Set(BandBuzz.allCases))
        for voice in SoundVoice.bandBuzzes {
            precondition(SoundSynth.render(voice).isEmpty, "\(voice) is silent")
            let pulses = voice.bandBuzz!.pulses
            precondition(!pulses.isEmpty && pulses.allSatisfy { $0.duration > 0 && $0.amplitude <= 255 })
        }
        precondition(BandBuzz.double.pulses.count == 2 && BandBuzz.triple.pulses.count == 3)
        precondition(BandPulse(duration: 100, amplitude: 230).payload == Data([0x0a, 0x05, 0x08, 0x64, 0x18, 0xe6, 0x01]), "Same request as the wrist setup")
        let picked = try! JSONDecoder().decode(ScoreSounds.self, from: JSONEncoder().encode({ var s = ScoreSounds(); s.add = .bandDouble; return s }()))
        precondition(picked.add == .bandDouble, "A band vibration saves like a sound")
        precondition(SoundSynth.render(.click) == SoundSynth.render(.click), "Clicks are deterministic")
        precondition(SoundSynth.render(.pip, frequency: 392) != SoundSynth.render(.pip, frequency: 440), "Pitch follows the player")

        // Mappings that use a reserved gesture are off during a game; the rest stay on.
        let tap = Mapping(id: "tap-index", enabled: true, actions: [.copyText("a")])
        let up = Mapping(id: "swipe-up", enabled: true, actions: [.copyText("b")])
        let mixed = Mapping(id: "combo-a", enabled: true, actions: [.copyText("c")], steps: [ComboStep(.swipeUp), ComboStep(.holdIndex)], intervalMs: 500)
        let clear = Mapping(id: "combo-b", enabled: true, actions: [.copyText("d")], steps: [ComboStep(.swipeUp), ComboStep(.swipeDown)], intervalMs: 500)
        precondition(tap.uses(ScoreControls.standard.reserved) && mixed.uses(ScoreControls.standard.reserved))
        precondition(!up.uses(ScoreControls.standard.reserved) && !clear.uses(ScoreControls.standard.reserved))
        precondition(!tap.uses([]), "Nothing is off when no game is live")
        var engine = MappingEngine(mappings: [tap, up, mixed, clear].filter { !$0.uses(ScoreControls.standard.reserved) })
        func fired(_ events: [MappingEngine.Event]) -> [String] {
            events.compactMap { if case .fire(let id, _) = $0 { id } else { nil } }
        }
        precondition(fired(engine.receive(.tapIndex, at: 0)).isEmpty, "A reserved gesture runs nothing")
        precondition(fired(engine.receive(.swipeUp, at: 1) + engine.tick(at: 3)) == ["swipe-up"], "A free gesture still runs")

        // Sounds: a point up or down wins over the selection it brings; stepping selects.
        var cueGame = ScoreGame(); cueGame.addPlayer(); cueGame.addPlayer()
        var next = cueGame; next.change(2, by: 1)
        precondition(ScoreCue(from: cueGame, to: next) == .add, "Adding a point sounds as an add even though it selects")
        cueGame = next; next.change(2, by: -1)
        precondition(ScoreCue(from: cueGame, to: next) == .subtract)
        cueGame = next; next.change(2, by: -1)
        precondition(ScoreCue(from: cueGame, to: next) == nil, "Nothing sounds when a score is already zero")
        cueGame = next; next.select(step: 1)
        precondition(ScoreCue(from: cueGame, to: next) == .select(3))
        cueGame = next; next.select(step: 1)
        precondition(ScoreCue(from: cueGame, to: next) == .select(0), "Selection wraps to the first player")
        cueGame = next; next.rename(0, to: "Ann")
        precondition(ScoreCue(from: cueGame, to: next) == nil)

        // Game types. Free play never ends; an older save comes back as free play.
        precondition(ScoreGame().rules == .open && ScoreGame().standing(0) == nil)
        precondition(Set(ScoreRules.presets.map(\.id)).count == ScoreRules.presets.count && ScoreRules.presets.allSatisfy(\.isPreset))
        let old = try! JSONDecoder().decode(ScoreGame.self, from: Data(#"{"players":[{"id":"a","name":"A","score":3,"tint":0},{"id":"b","name":"B","score":1,"tint":1}],"selected":1,"live":false}"#.utf8))
        precondition(old.rules == .open && old.scores == [3, 1] && old.selected == 1 && old.winner == nil)
        func rules(_ id: String) -> ScoreRules { ScoreRules.presets.first { $0.id == id }! }
        func points(_ game: inout ScoreGame, _ player: Int, _ count: Int) { for _ in 0..<count { game.change(player, by: 1) } }

        // Choosing a type starts everyone from zero; choosing the same one again doesn't.
        var match = ScoreGame(); match.change(0, by: 5)
        match.play(rules("table-tennis")); precondition(match.isEmpty)
        match.change(0, by: 1); match.play(rules("table-tennis")); precondition(match.scores == [1, 0])
        match.reset()

        // Table tennis: 11 wins a game, by two; three games win the match.
        points(&match, 0, 10); points(&match, 1, 10); points(&match, 0, 1)
        precondition(match.scores == [11, 10] && match.players[0].games == 0, "11–10 isn't two clear")
        points(&match, 0, 1)
        precondition(match.scores == [0, 0] && match.players.map(\.games) == [1, 0] && match.standing(0) == "Games 1")
        precondition(match.summary == "Player 1 0 · Player 2 0 · Games 1–0")
        // The winner taking the point back puts the game back; nobody else can.
        precondition(match.canTake(0) && !match.canTake(1))
        match.change(0, by: -1)
        precondition(match.scores == [11, 10] && match.players[0].games == 0 && !match.isEmpty)
        points(&match, 0, 1); points(&match, 1, 1); match.change(0, by: -1)
        precondition(match.players.map(\.games) == [1, 0] && match.scores == [0, 1], "After another point the game stands")
        match.change(1, by: -1)
        points(&match, 0, 11); points(&match, 0, 10)
        precondition(match.players[0].games == 2 && match.winner == nil)
        let last = match
        points(&match, 0, 1)
        precondition(match.winner == 0 && match.players[0].games == 3 && match.scores == [11, 0], "The last game's points stay")
        precondition(match.standing(0) == "Won · Games 3" && ScoreCue(from: last, to: match) == .add)
        points(&match, 1, 3); points(&match, 0, 1)
        precondition(match.scores == [11, 0], "Nobody scores once the match is won")
        match.change(0, by: -1)
        precondition(match == last, "Taking the winning point back reopens the match")
        var band = last
        precondition(band.apply(.add(0)) == "Player 1 wins · Player 1 11 · Player 2 0 · Games 3–0")
        match.reset()
        precondition(match.isEmpty && match.winner == nil && match.rules.id == "table-tennis")

        // Near the end each player counts down the points they still need, lead included.
        var close = ScoreGame(); close.play(rules("table-tennis"))
        precondition(close.toGo(0) == nil && close.pointName(0) == nil, "Nothing to count at the start")
        points(&close, 0, 8); precondition(close.toGo(0) == 3 && close.toGo(1) == nil)
        points(&close, 1, 9); precondition(close.toGo(0) == 3 && close.toGo(1) == 2)
        points(&close, 0, 2); precondition(close.toGo(0) == 1 && close.toGo(1) == 3 && close.pointName(0) == "Game point" && close.pointName(1) == nil)
        points(&close, 1, 1); precondition(close.toGo(0) == 2 && close.toGo(1) == 2, "Ten all: two clear each")
        precondition(close.apply(.add(1)) == "Game point, Player 2 · Player 1 10 · Player 2 11 · Games 0–0")
        close.select(0); precondition(close.apply(.addSelected) == "Player 1 11")
        points(&close, 1, 2); points(&close, 1, 11)
        points(&close, 1, 10); precondition(close.pointName(1) == "Match point" && close.apply(.takeSelected) == "Player 2 9")
        points(&close, 1, 2); precondition(close.winner == 1 && close.toGo(1) == nil && close.toGo(0) == nil)
        var far = ScoreGame(); far.play(.custom(name: "Far", points: 11, winBy: 5, games: 1))
        points(&far, 0, 6); precondition(far.toGo(0) == 5 && far.toGo(1) == nil)
        points(&far, 1, 9); precondition(far.toGo(0) == nil && far.toGo(1) == 2, "Eight to go is too far to count")
        var sets = ScoreGame(); sets.play(rules("volleyball")); points(&sets, 0, 24)
        precondition(sets.pointName(0) == "Set point")

        // Game, set and match cues: on the point that wins it, not the one before.
        func cue(_ g: inout ScoreGame, _ player: Int, _ delta: Int = 1) -> ScorePoint? {
            let old = g; g.change(player, by: delta); return ScoreCue.point(from: old, to: g)
        }
        var alert = ScoreGame(); alert.play(rules("table-tennis"))
        points(&alert, 0, 9); precondition(cue(&alert, 0) == nil, "10–0 at eleven is game point, not a game")
        points(&alert, 1, 9); precondition(cue(&alert, 1) == nil, "Ten all wins nothing")
        precondition(cue(&alert, 1) == nil, "Advantage wins nothing yet")
        precondition(cue(&alert, 1) == .game, "Two clear after deuce wins the game")
        precondition(cue(&alert, 1, -1) == nil, "Taking the winning point back is no win")
        precondition(cue(&alert, 1) == .game)
        points(&alert, 0, 22); points(&alert, 0, 10)
        precondition(cue(&alert, 0) == .match, "Third game in a best of five ends the match")
        var setAlert = ScoreGame(); setAlert.play(rules("volleyball")); points(&setAlert, 0, 24)
        precondition(cue(&setAlert, 0) == .set, "Twenty-five wins the set")
        var setTennis = ScoreGame(); setTennis.play(rules("tennis")); points(&setTennis, 0, 4 * 5 + 3)
        precondition(cue(&setTennis, 0) == .set, "The sixth game wins the set though games go back to zero")
        var pointSounds = ScoreSounds()
        precondition(pointSounds.voice(for: .game) == .bells && pointSounds.voice(for: .match) == .sparkle)
        pointSounds.gamePoint = nil; pointSounds.setPoint = .coin
        let savedPoints = try! JSONDecoder().decode(ScoreSounds.self, from: JSONEncoder().encode(pointSounds))
        precondition(savedPoints.gamePoint == nil && savedPoints.setPoint == .coin, "None and a choice both survive saving")
        let olderSave = try! JSONDecoder().decode(ScoreSounds.self, from: Data(#"{"on":true}"#.utf8))
        precondition(olderSave.gamePoint == .bells && olderSave.setPoint == .sparkle, "Older saves get the defaults")

        // Tennis: 15, 30, 40, deuce and advantage; six games by two; a tiebreak at six all.
        var tennis = ScoreGame(); tennis.play(rules("tennis"))
        points(&tennis, 0, 1); precondition(tennis.points(0) == "15" && tennis.points(1) == "0")
        points(&tennis, 0, 2); points(&tennis, 1, 3)
        precondition(tennis.points(0) == "40" && tennis.points(1) == "40")
        points(&tennis, 1, 1); precondition(tennis.points(1) == "Ad" && tennis.points(0) == "40")
        points(&tennis, 0, 1); precondition(tennis.points(0) == "40" && tennis.points(1) == "40", "Back to deuce")
        let deuce = tennis
        points(&tennis, 0, 2)
        precondition(tennis.players.map(\.games) == [1, 0] && tennis.scores == [0, 0])
        var cueFrom = deuce; points(&cueFrom, 0, 1); let cueTo = { var g = cueFrom; g.change(0, by: 1); return g }()
        precondition(ScoreCue(from: cueFrom, to: cueTo) == .add, "A won game sounds as a point added, though the points go back to zero")
        func win(_ g: inout ScoreGame, _ player: Int, _ count: Int = 1) { for _ in 0..<count { points(&g, player, 4) } }
        win(&tennis, 0, 4); win(&tennis, 1, 5)
        precondition(tennis.players.map(\.games) == [5, 5])
        win(&tennis, 0); precondition(tennis.players.map(\.games) == [6, 5] && tennis.players[0].sets == 0, "6–5 isn't a set")
        win(&tennis, 1); precondition(tennis.players.map(\.games) == [6, 6] && tennis.tiebreak)
        points(&tennis, 0, 6); points(&tennis, 1, 6)
        precondition(tennis.points(0) == "6" && tennis.points(1) == "6", "A tiebreak counts in ones")
        points(&tennis, 1, 2)
        precondition(tennis.players.map(\.sets) == [0, 1] && tennis.players.map(\.games) == [0, 0] && !tennis.tiebreak)
        precondition(tennis.standing(1) == "Sets 1 · Games 0")
        win(&tennis, 1, 5)
        win(&tennis, 1)
        precondition(tennis.winner == 1 && tennis.players.map(\.sets) == [0, 2] && tennis.standing(1) == "Won · Sets 2 · Games 6")

        // Volleyball counts sets; a removed winner leaves no winner, and the others keep theirs.
        var volley = ScoreGame(); volley.addPlayer(); volley.play(rules("volleyball"))
        points(&volley, 2, 25)
        precondition(volley.players.map(\.sets) == [0, 0, 1] && volley.standing(2) == "Sets 1" && volley.scores == [0, 0, 0])
        precondition(!volley.canTake(0) && volley.canTake(2))
        volley.rename(0, to: "Ann"); volley.removePlayer(0)
        precondition(!volley.canTake(1), "Players coming and going settle the last game")

        // Custom types are trimmed and kept in range; every type survives a save.
        let own = ScoreRules.custom(name: "  Cornhole  ", points: 21, winBy: 5, games: 0)
        precondition(own.name == "Cornhole" && own.points == 21 && own.winBy == 5 && own.games == 1 && !own.isPreset)
        precondition(own.detail == "First to 21, 5 clear." && rules("badminton").detail == "First to 21, 2 clear. Best of 3 games.")
        precondition(ScoreRules.custom(name: "Far", points: 7, winBy: 40, games: 1).winBy == 7, "A lead can't be more than the points")
        // Win by any lead: 5–3 and 6–4 aren't three clear; 7–4 is.
        var apart = ScoreGame(); apart.play(.custom(name: "Three clear", points: 5, winBy: 3, games: 1))
        points(&apart, 0, 3); points(&apart, 1, 3); points(&apart, 0, 2)
        precondition(apart.winner == nil && apart.scores == [5, 3])
        points(&apart, 1, 1); points(&apart, 0, 1); precondition(apart.winner == nil && apart.scores == [6, 4])
        points(&apart, 0, 1); precondition(apart.winner == 0 && apart.scores == [7, 4])
        precondition(ScoreRules.custom(name: " ", points: 0, winBy: 1, games: 2).name == "My game")
        var short = ScoreGame(); short.play(.custom(name: "Quick", points: 3, winBy: 1, games: 1))
        points(&short, 1, 3); precondition(short.winner == 1 && short.scores == [0, 3] && short.standing(1) == "Won")
        let kept = try! JSONDecoder().decode(ScoreGame.self, from: JSONEncoder().encode(short))
        precondition(kept == short && kept.winner == 1 && kept.canTake(1))
        precondition(try! JSONDecoder().decode([ScoreRules].self, from: JSONEncoder().encode(ScoreRules.presets + [own])) == ScoreRules.presets + [own])

        print("Score tests passed")
    }
}
