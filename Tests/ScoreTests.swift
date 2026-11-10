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
        precondition(SoundVoice.allCases.count == 32)
        for voice in SoundVoice.allCases {
            let samples = SoundSynth.render(voice)
            let loudest = samples.map(abs).max() ?? 0
            precondition(samples.count > 1000 && abs(loudest - SoundSynth.peak) < 0.001, "\(voice) renders")
            precondition(samples.allSatisfy(\.isFinite))
        }
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

        print("Score tests passed")
    }
}
