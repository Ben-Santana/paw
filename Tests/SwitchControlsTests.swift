// Isolated checks for the switch-controls combo: what it may be, and how it sits in an
// app's or the mappings' engine. No Bluetooth, UIKit or network.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift RunesIOS/Mappings/TriggerRules.swift \
//       RunesIOS/Mappings/CommandTrigger.swift RunesIOS/Mappings/MappingEngine.swift RunesIOS/Mappings/SwitchControls.swift \
//       Tests/SwitchControlsTests.swift -o /private/tmp/runes-switch-tests && /private/tmp/runes-switch-tests
import Foundation

@main
struct SwitchControlsTests {
    static func fired(_ events: [MappingEngine.Event]) -> [String] {
        events.compactMap { if case .fire(let id, _) = $0 { id } else { nil } }
    }
    /// Feeds (gesture, time) pairs, ticking until idle afterwards. Returns every fired mapping id.
    static func run(_ mappings: [Mapping], _ inputs: [(GestureKind, Double)]) -> [String] {
        var engine = MappingEngine(mappings: mappings)
        var out: [String] = []
        var t = 0.0
        for (gesture, at) in inputs {
            while t + 0.05 < at { t += 0.05; out += fired(engine.tick(at: t)) }
            t = at; out += fired(engine.receive(gesture, at: at))
        }
        while t < 10 { t += 0.05; out += fired(engine.tick(at: t)) }
        precondition(engine.isIdle, "Engine settles")
        return out
    }

    static func main() {
        let combo = SwitchCombo(steps: [.holdMiddle, .swipeUp].steps)

        // 1. Always a combo of finger and swipe steps.
        precondition(SwitchControls.isValid(combo))
        precondition(!SwitchControls.isValid(nil) && SwitchControls.mapping(nil) == nil, "Nothing set means no switch")
        precondition(!SwitchControls.isValid(SwitchCombo(steps: [.swipeUp].steps)), "One gesture would take its row from every profile")
        precondition(!SwitchControls.isValid(SwitchCombo(steps: [ComboStep(.tapIndex), .rotation(.x)])), "Motion would keep the sensors on")
        precondition(!SwitchControls.isValid(SwitchCombo(steps: [.releaseIndex, .tapIndex].steps)), "A release needs a hold")
        precondition(!SwitchControls.isValid(SwitchCombo(steps: combo.steps, intervalMs: 123)), "Only the Mappings timing choices")
        precondition(SwitchControls.rules.comboOnly && SwitchControls.rules.allowsNone)
        precondition(!SwitchControls.rules.offered.contains(.rotation) && !SwitchControls.rules.offered.contains(.air))

        // 2. As a mapping it has its own id, and takes its gestures' partners with it.
        let switcher = SwitchControls.mapping(combo)!
        precondition(switcher.id == SwitchControls.mappingID && switcher.isLive)
        precondition(SwitchControls.reserved(switcher) == [.holdMiddle, .releaseMiddle, .swipeUp])
        precondition(SwitchControls.reserved(nil).isEmpty)
        precondition(SwitchControls.reserved(SwitchControls.mapping(SwitchCombo(steps: [.doubleTapIndex, .swipeLeft].steps)))
                     == [.doubleTapIndex, .tapIndex, .swipeLeft])

        // 3. Cook's defaults with the switch among them: the combo switches and nothing else
        //    runs, though hold middle (reset) and swipe up (previous timer) are Cook's too.
        let cook: [CookLike: CommandTrigger] = [.next: .gesture(.swipeRight), .reset: .gesture(.holdMiddle), .timerUp: .gesture(.swipeUp),
                                                .timer: .gesture(.doubleTapIndex)]
        let app = SwitchControls.adding(switcher, to: cook.mappings(prefix: "cook:"))
        precondition(run(app, [(.holdMiddle, 0), (.swipeUp, 0.3)]) == [SwitchControls.mappingID])
        // Cook's own gestures still work, the ones the combo starts with after its wait.
        precondition(run(app, [(.swipeRight, 0)]) == ["swipe-right"])
        precondition(run(app, [(.holdMiddle, 0), (.releaseMiddle, 2)]) == ["hold-middle"], "A hold on its own is still reset")
        precondition(run(app, [(.swipeUp, 0)]) == ["swipe-up"])

        // 4. Regular side: the same combo among a profile's mappings.
        let note = MappingAction.notify(title: "Runes", body: "x")
        let profile = [Mapping(id: "swipe-up", enabled: true, actions: [note]),
                       Mapping(id: "combo-a", enabled: true, actions: [note], steps: [.holdMiddle, .swipeDown].steps, intervalMs: 500)]
        let regular = SwitchControls.adding(switcher, to: profile)
        precondition(run(regular, [(.holdMiddle, 0), (.swipeUp, 0.3)]) == [SwitchControls.mappingID])
        precondition(run(regular, [(.holdMiddle, 0), (.swipeDown, 0.3)]) == ["combo-a"], "A combo that starts the same way still runs")
        precondition(run(regular, [(.swipeUp, 0)]) == ["swipe-up"])

        // 5. Anything made of exactly the same steps gives way, so the switch can always be made.
        let twin = Mapping(id: "combo-twin", enabled: true, actions: [note], steps: combo.steps, intervalMs: 500)
        let both = SwitchControls.adding(switcher, to: profile + [twin])
        precondition(!both.contains { $0.id == "combo-twin" } && both.last?.id == SwitchControls.mappingID)
        precondition(run(both, [(.holdMiddle, 0), (.swipeUp, 0.3)]) == [SwitchControls.mappingID])
        precondition(SwitchControls.adding(nil, to: profile + [twin]).count == 3, "With no switch nothing is taken out")

        // 6. Saved beside the profiles: libraries from before it existed load, and it survives a round trip.
        let old = #"{"profiles":[{"id":"main","name":"Main","icon":"home","mappings":[]}],"activeID":"main"}"#
        var library = try! JSONDecoder().decode(MappingLibrary.self, from: Data(old.utf8)).normalized()
        precondition(library.switchControls == nil)
        library.switchControls = combo
        library.profiles.append(.new(name: "Gym"))
        library.activeID = library.profiles[1].id
        let again = try! JSONDecoder().decode(MappingLibrary.self, from: JSONEncoder().encode(library)).normalized()
        precondition(again.switchControls == combo && again.profiles.count == 2, "Not part of any profile")

        print("SwitchControlsTests passed")
    }
}

/// Stands in for an app's commands.
enum CookLike: String { case next, reset, timerUp, timer }
