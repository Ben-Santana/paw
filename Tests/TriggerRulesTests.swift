// Isolated checks for what the trigger composer offers: one gesture, a combo, or either.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift \
//       Shared/ProfileIcon.swift Shared/SVGPath.swift Shared/LucideData.swift RunesIOS/Mappings/TriggerRules.swift \
//       Tests/TriggerRulesTests.swift -o /private/tmp/runes-trigger-tests && /private/tmp/runes-trigger-tests
import Foundation

@main
struct TriggerRulesTests {
    static func main() {
        let fingersAndSwipes: ([ComboStep]) -> [GestureKind] = { steps in
            ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
        }

        // One gesture only: Workouts and Cook.
        let one = TriggerRules.gesture(GestureKind.motions)
        precondition(!one.buildsCombos && one.maxSteps == 1)
        precondition(one.offered == Set(GestureKind.motions), "Releases and motion aren't offered on their own")
        precondition(one.canAppend(.holdIndex, to: []) && !one.canAppend(.releaseIndex, to: []))
        precondition(!one.canAppend(.tapIndex, to: [ComboStep(.holdIndex)]), "A second step can't be added")
        precondition(one.canReplace(0, with: .swipeUp, in: [ComboStep(.holdIndex)]))
        precondition(one.isValid([]) && one.isValid([ComboStep(.tapMiddle)]) && !one.isValid([ComboStep(.releaseIndex)]))
        precondition(!TriggerRules.gesture(GestureKind.motions, allowsNone: false).isValid([]))

        // A gesture or a combo: Score, where swipe up only exists inside a combo.
        let singles = GestureKind.motions.filter { $0 != .swipeUp }
        let either = TriggerRules.gestureOrCombo(singles, next: fingersAndSwipes, allowsNone: true)
        precondition(either.offered.contains(.releaseMiddle) && either.offered.contains(.swipeUp))
        precondition(!either.offered.contains(.rotation) && !either.offered.contains(.air), "Motion stays off the pad")
        precondition(either.canAppend(.swipeUp, to: []), "A combo may start with swipe up")
        precondition(either.problem([ComboStep(.swipeUp)]) != nil && !either.isValid([ComboStep(.swipeUp)]), "but it can't stand alone")
        precondition(either.isValid([ComboStep(.swipeUp), ComboStep(.tapIndex)]))
        precondition(either.isValid([ComboStep(.holdIndex)]) && either.isValid([]))
        precondition(!either.canAppend(.releaseIndex, to: [ComboStep(.tapIndex)]), "Nothing is held to release")
        precondition(either.canAppend(.releaseIndex, to: [ComboStep(.holdIndex), ComboStep(.tapMiddle)]))
        precondition(!either.canAppend(.holdIndex, to: [ComboStep(.holdIndex)]), "A finger can't be held twice")
        precondition(!either.isValid([ComboStep(.tapIndex), .rotation(.x)]), "A step the rules never offer isn't valid")
        let held = [ComboStep(.holdIndex), ComboStep(.tapMiddle), ComboStep(.releaseIndex)]
        precondition(either.canReplace(0, with: .holdMiddle, in: held), "A hold can be swapped for the other finger's")
        precondition(either.problem([ComboStep(.holdMiddle), ComboStep(.tapMiddle), ComboStep(.releaseIndex)]) != nil, "and the stranded release is named")
        precondition(!either.canReplace(1, with: .holdIndex, in: held), "The index finger is already down at step 2")
        let full = Array(repeating: ComboStep(.tapIndex), count: 8)
        precondition(!either.canAppend(.tapIndex, to: full) && either.isValid(full))

        // A mapping's combo: everything, two to eight steps.
        let combo = TriggerRules.combo
        precondition(combo.comboOnly && combo.offered == Set(GestureKind.allCases))
        precondition(!combo.isValid([]) && !combo.isValid([ComboStep(.tapIndex)]))
        precondition(combo.problem([ComboStep(.tapIndex)]) == "A combo needs at least two steps.")
        precondition(!combo.canAppend(.air, to: []), "An air shape needs a gesture before it")
        precondition(combo.canAppend(.air, to: [ComboStep(.tapIndex)]))
        precondition(!combo.canReplace(0, with: .air, in: [ComboStep(.tapIndex), ComboStep(.swipeUp)]))
        precondition(combo.isValid([ComboStep(.holdIndex), .rotation(.x, .right), ComboStep(.releaseIndex)]))

        // The line under the track: the hold, what happens during it, and the release.
        var line = TriggerRules.held(held)
        precondition(line.steps == [true, true, true] && line.bridges == [true, true, false])
        line = TriggerRules.held([.tapIndex, .holdMiddle, .swipeUp, .releaseMiddle, .tapIndex].steps)
        precondition(line.steps == [false, true, true, true, false] && line.bridges == [false, true, true, false, false])
        line = TriggerRules.held([.swipeUp, .holdIndex].steps)
        precondition(line.steps == [false, true] && line.bridges == [false, true], "A combo that ends held stays open")

        precondition(ComboRules.timeLabel(750) == "750 ms" && ComboRules.timeLabel(1000) == "1 s" && ComboRules.timeLabel(1500) == "1.5 s")

        print("Trigger rules tests passed")
    }
}
