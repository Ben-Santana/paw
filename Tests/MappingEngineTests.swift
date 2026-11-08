// Isolated checks for gesture mappings and combos. No Bluetooth, UIKit or network.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift \
//       RunesIOS/Mappings/MappingEngine.swift //       Tests/MappingEngineTests.swift -o /private/tmp/runes-mapping-tests && /private/tmp/runes-mapping-tests
import Foundation

@main
struct MappingEngineTests {
    static let note = MappingAction.notify(title: "Runes", body: "x")

    static func single(_ kind: GestureKind) -> Mapping { Mapping(id: kind.rawValue, enabled: true, actions: [note]) }
    static func combo(_ id: String, _ steps: [GestureKind], _ ms: Int = 500) -> Mapping { combo(id, steps: steps.steps, ms) }
    static func combo(_ id: String, steps: [ComboStep], _ ms: Int = 500) -> Mapping {
        Mapping(id: "combo-\(id)", enabled: true, actions: [note], steps: steps, intervalMs: ms)
    }
    static func fired(_ events: [MappingEngine.Event]) -> [String] {
        events.compactMap { if case .fire(let id, _) = $0 { id } else { nil } }
    }
    /// Feeds (gesture, time) pairs, ticking until idle afterwards. Returns every fired mapping id.
    static func run(_ mappings: [Mapping], _ inputs: [(GestureKind, Double)], tickUntil end: Double = 10) -> [String] {
        run(mappings, steps: inputs.map { (ComboStep($0.0), $0.1) }, tickUntil: end)
    }
    static func run(_ mappings: [Mapping], steps inputs: [(ComboStep, Double)], tickUntil end: Double = 10) -> [String] {
        var engine = MappingEngine(mappings: mappings)
        var out: [String] = []
        var t = 0.0
        for (gesture, at) in inputs {
            while t + 0.05 < at { t += 0.05; out += fired(engine.tick(at: t)) }
            t = at; out += fired(engine.receive(gesture, at: at))
        }
        while t < end { t += 0.05; out += fired(engine.tick(at: t)) }
        precondition(engine.isIdle, "Engine settles")
        return out
    }

    static func main() {
        // 1. Model rules match the Mac.
        precondition(ComboRules.valid([.holdIndex, .swipeUp, .releaseIndex].steps))
        precondition(!ComboRules.valid([.releaseIndex, .tapIndex].steps), "A release needs a hold")
        precondition(!ComboRules.valid([.holdIndex, .holdIndex].steps), "A finger can't be held twice")
        precondition(!ComboRules.valid([.tapIndex].steps), "Combos need two steps")
        precondition(ComboRules.allowedNext(after: [.holdIndex].steps).contains(.releaseIndex))
        precondition(!ComboRules.allowedNext(after: [ComboStep]()).contains(.releaseMiddle))
        let profile = MappingProfile.new(name: "P")
        precondition(profile.gestures.map(\.id) == GestureKind.motions.map(\.rawValue), "Every motion has a row")
        let roundTrip = try! JSONDecoder().decode(MappingLibrary.self, from: JSONEncoder().encode(MappingLibrary(profiles: [profile], activeID: profile.id)))
        precondition(roundTrip.profiles == [profile], "Library round-trips through JSON")
        precondition(!Mapping(id: "tap-index", enabled: true, actions: [.openURL("")]).isLive, "Incomplete actions don't run")
        precondition(Mapping(id: "tap-index", enabled: true, actions: [.openURL("https://a.b"), .wait(ms: 200), .haptic(.light)]).isLive, "Linked actions run")

        // 2. Band gestures map to the Mac's gesture ids.
        let at = Date()
        precondition(GestureKind(BandGesture(id: 1, kind: .holdEnded, finger: 3, at: at)) == .releaseMiddle)
        precondition(GestureKind(BandGesture(id: 1, kind: .swipe(.left), finger: 0, at: at)) == .swipeLeft)
        precondition(GestureKind(BandGesture(id: 1, kind: .tap, finger: 1, at: at)) == nil, "Thumb taps aren't mapped")

        // 3. Single gestures run at once when nothing else could claim them.
        var engine = MappingEngine(mappings: [single(.swipeUp)])
        precondition(fired(engine.receive(.swipeUp, at: 0)) == ["swipe-up"], "Unshared gestures fire immediately")
        precondition(engine.isIdle)
        precondition(run([single(.swipeUp), Mapping(id: "swipe-down", enabled: false, actions: [note])], [(.swipeDown, 0)]).isEmpty, "Disabled mappings don't run")

        // 4. Single vs double tap.
        precondition(run([single(.tapIndex), single(.doubleTapIndex)], [(.tapIndex, 0), (.doubleTapIndex, 0.15)]) == ["double-tap-index"],
                     "A double tap doesn't also run the single tap")
        precondition(run([single(.tapIndex), single(.doubleTapIndex)], [(.tapIndex, 0)]) == ["tap-index"], "A lone tap runs after the window")
        var quick = MappingEngine(mappings: [single(.tapIndex)])
        precondition(fired(quick.receive(.tapIndex, at: 0)) == ["tap-index"], "Without a double tap mapping, taps don't wait")
        precondition(run([single(.tapIndex), single(.doubleTapIndex), single(.swipeUp)], [(.tapIndex, 0), (.swipeUp, 0.1)]) == ["tap-index", "swipe-up"],
                     "A waiting tap keeps its place before a later gesture")

        // 5. Combos.
        let upDown = combo("ud", [.swipeUp, .swipeDown])
        precondition(run([upDown], [(.swipeUp, 0), (.swipeDown, 0.3)]) == ["combo-ud"], "Combo completes in time")
        precondition(run([upDown], [(.swipeUp, 0), (.swipeDown, 0.8)]).isEmpty, "Combo times out")
        precondition(run([upDown, single(.swipeUp), single(.swipeDown)], [(.swipeUp, 0), (.swipeDown, 0.3)]) == ["combo-ud"],
                     "A completed combo owns its gestures")
        precondition(run([upDown, single(.swipeUp)], [(.swipeUp, 0)]) == ["swipe-up"], "A single runs once its combo gives up")
        precondition(run([upDown, single(.swipeUp), single(.swipeLeft)], [(.swipeUp, 0), (.swipeLeft, 0.2)]) == ["swipe-up", "swipe-left"],
                     "An unexpected gesture ends the attempt and both singles run in order")
        let long = combo("long", [.swipeUp, .swipeDown, .swipeLeft])
        precondition(run([upDown, long], [(.swipeUp, 0), (.swipeDown, 0.2), (.swipeLeft, 0.4)]) == ["combo-long"], "The longer combo wins")
        precondition(run([upDown, long], [(.swipeUp, 0), (.swipeDown, 0.2)]) == ["combo-ud"], "The shorter combo runs when the longer one gives up")

        // 6. Holds suspend the timer; early release fails.
        let held = combo("hold", [.holdIndex, .swipeRight, .releaseIndex], 300)
        precondition(run([held], [(.holdIndex, 0), (.swipeRight, 2.0), (.releaseIndex, 4.0)]) == ["combo-hold"], "No limit while held")
        precondition(run([held], [(.holdIndex, 0), (.releaseIndex, 0.1)]).isEmpty, "Releasing early ends the attempt")
        precondition(run([held, single(.holdIndex)], [(.holdIndex, 0), (.releaseIndex, 0.1)]) == ["hold-index"], "…and the hold runs on its own")

        // 7. Repeats of the same gesture as combo steps.
        let triple = combo("ttt", [.swipeUp, .swipeUp, .swipeUp])
        precondition(run([triple], [(.swipeUp, 0), (.swipeUp, 0.2), (.swipeUp, 0.4)]) == ["combo-ttt"], "Repeated steps")
        precondition(run([triple], [(.swipeUp, 0), (.swipeUp, 0.2), (.swipeUp, 0.4), (.swipeUp, 0.6)]) == ["combo-ttt"],
                     "A completed combo doesn't seed the next attempt")

        // 8. Motion steps (rotation, movement) as on the Mac.
        let legacy = try! JSONDecoder().decode([ComboStep].self, from: Data(#"["tap-index", {"gesture":"rotation","axis":"y","direction":"left"}, {"gesture":"movement","axis":"z"}]"#.utf8))
        precondition(legacy == [ComboStep(.tapIndex), .rotation(.y, .left), .movement(.z)], "Plain ids and Mac step objects both decode")
        precondition(String(data: try! JSONEncoder().encode(ComboStep(.swipeUp)), encoding: .utf8) == #"{"gesture":"swipe-up"}"#, "Steps save in the Mac's format")
        let twist = combo("twist", steps: [ComboStep(.holdIndex), .rotation(.x, .right), ComboStep(.releaseIndex)])
        precondition(MappingEngine(mappings: [twist]).wantsMotion && !MappingEngine(mappings: [upDown]).wantsMotion, "Motion streams only when a combo needs them")
        precondition(run([twist], steps: [(ComboStep(.holdIndex), 0), (.rotation(.x, .right), 1), (ComboStep(.releaseIndex), 1.5)]) == ["combo-twist"], "Rotation step")
        precondition(run([twist], steps: [(ComboStep(.holdIndex), 0), (.rotation(.x, .left), 1), (ComboStep(.releaseIndex), 1.5)]).isEmpty, "Wrong direction doesn't count")
        let anyWay = combo("any", steps: [ComboStep(.tapIndex), .rotation(.z)])
        precondition(run([anyWay], steps: [(ComboStep(.tapIndex), 0), (.rotation(.z, .left), 0.2)]) == ["combo-any"], "Either direction")
        precondition(run([twist], steps: [(ComboStep(.holdIndex), 0), (.movement(.y), 0.5), (.rotation(.y, .left), 0.6), (.rotation(.x, .right), 1), (ComboStep(.releaseIndex), 1.5)]) == ["combo-twist"],
                     "Incidental motion doesn't break a combo")
        let shake = combo("shake", steps: [.movement(.x), ComboStep(.swipeUp)])
        precondition(run([shake, single(.swipeUp)], steps: [(.movement(.x), 0), (ComboStep(.swipeUp), 0.3)]) == ["combo-shake"], "Movement step")
        precondition(run([single(.swipeUp)], steps: [(.movement(.x), 0), (ComboStep(.swipeUp), 0.1)]) == ["swipe-up"], "Motion nobody uses is ignored")

        var detector = MotionDetector()
        func turn(_ degrees: Double, _ axis: Int) -> [Double] {
            var q = [cos(degrees / 2 * .pi / 180), 0, 0, 0]; q[axis] = sin(degrees / 2 * .pi / 180); return q
        }
        precondition(detector.orientation([1, 0, 0, 0]) == nil, "First sample sets the origin")
        precondition(detector.orientation(turn(20, 1)) == nil, "Under 25° is not a rotation")
        precondition(detector.orientation(turn(30, 1)) == .rotation(.x, .right), "30° about x")
        precondition(detector.orientation(turn(30, 1)) == nil, "The rotation becomes the new origin")
        var other = MotionDetector(); _ = other.orientation([1, 0, 0, 0])
        precondition(other.orientation(turn(-30, 3)) == .rotation(.z, .left), "The other way about z")
        precondition(detector.gyroscope([90, 0, 0]) == [.movement(.x)], "Movement above 80")
        precondition(detector.gyroscope([60, 0, 0]).isEmpty, "Still moving until it drops below 30")
        precondition(detector.gyroscope([10, -95, 0]) == [.movement(.y)])
        precondition(detector.gyroscope([85, 0, 0]) == [.movement(.x)], "Re-armed after settling")

        airChecks()
        print("Mapping checks passed: Mac gesture ids, combo rules, single/double tap, combo ownership, timing, holds, linked actions, rotation and movement steps, air gestures.")
    }

    // Ported from the Mac's tests/test_air_gestures.py.
    static let shape: [[Double]] = [[0, 0], [0.3, 0], [0.3, 0.1], [0.2, 0.1], [0.2, 0.4]]
    static let line: [[Double]] = [[0, 0], [0.3, 0]]
    static func air(_ points: [[Double]] = shape, _ ms: Int = 1000, _ minimum: Int = 75) -> ComboStep {
        .airShape(AirShape(points: points, minSimilarity: minimum, durationMs: ms))
    }
    static func airCombo(_ id: String, _ step: ComboStep = air(), tail: [ComboStep] = []) -> Mapping {
        combo(id, steps: [ComboStep(.doubleTapIndex), step] + tail)
    }
    /// A unit quaternion taking +Y to [x, sqrt(1-x²-y²), -y].
    static func pointing(_ x: Double, _ y: Double) -> [Double] {
        let forward = (1 - x * x - y * y).squareRoot(), w = ((1 + forward) / 2).squareRoot()
        return [w, -y / (2 * w), 0, -x / (2 * w)]
    }
    /// Arms with a double tap at 0, traces `points` over `duration`, then ticks to `end`.
    static func perform(_ mappings: [Mapping], _ points: [[Double]] = shape, duration: Double = 0.98, arm: Bool = true,
                        orient: Bool = true, interrupt: ComboStep? = nil, end: Double = 1.1, then extra: [(ComboStep, Double)] = []) -> [String] {
        var engine = MappingEngine(mappings: mappings)
        var out: [String] = []
        var t = 0.0
        if orient { engine.orientation(pointing(0, 0), at: 0) }
        if arm { out += fired(engine.receive(.doubleTapIndex, at: 0)) }
        for i in 0...40 {
            let u = Double(i) / 40 * Double(points.count - 1)
            let j = min(Int(u), points.count - 2), f = u - Double(j)
            let x = points[j][0] + f * (points[j + 1][0] - points[j][0]), y = points[j][1] + f * (points[j + 1][1] - points[j][1])
            t += duration / 41
            engine.orientation(pointing(x, y), at: t)
            out += fired(engine.tick(at: t))
        }
        if let interrupt { out += fired(engine.receive(interrupt, at: t + 0.01)) }
        while t < end { t += 0.05; out += fired(engine.tick(at: min(t, end))) }
        for (step, at) in extra { out += fired(engine.receive(step, at: at)) }
        for _ in 0..<40 { t += 0.05; out += fired(engine.tick(at: max(t, extra.last?.1 ?? 0))) }
        return out
    }

    static func airChecks() {
        precondition(AirMatcher.similarity(shape, shape) == 100)
        precondition(AirMatcher.similarity(shape, line)! < 75)
        precondition(AirMatcher.similarity(shape, shape.reversed())! < 75)
        for angle in [-100.0, -37, 0, 37, 100] {
            let c = cos(angle * .pi / 180), s = sin(angle * .pi / 180)
            precondition(AirMatcher.similarity(shape, shape.map { [2 * ($0[0] * c - $0[1] * s) + 8, 2 * ($0[0] * s + $0[1] * c) - 5] }) == 100, "Rotated \(angle)°")
        }
        precondition(AirMatcher.similarity(shape, [[0, 0], [0, 0]]) == nil)
        precondition(AirMatcher.wristPoint([1, 0, 0, 0], reference: [1, 0, 0, 0]) == [0, 0])

        precondition(ComboRules.valid(airCombo("a").steps!))
        precondition(!ComboRules.valid([air(), ComboStep(.tapIndex)]), "Air can't come first")
        precondition(!ComboRules.valid([ComboStep(.tapIndex), air(), air()]), "Two air steps can't be in a row")
        precondition(!ComboRules.valid([ComboStep(.tapIndex), air([[0, 0], [0, 0]])]))
        precondition(!ComboRules.valid([ComboStep(.tapIndex), air(shape, 10_001)]))
        precondition(!ComboRules.valid([ComboStep(.tapIndex), air(shape, 1000, 0)]))
        precondition(!ComboRules.allowedNext(after: []).contains(.air) && ComboRules.allowedNext(after: [ComboStep(.tapIndex)]).contains(.air))
        let json = try! JSONEncoder().encode(air())
        precondition(try! JSONDecoder().decode(ComboStep.self, from: json) == air(), "Air steps round-trip in the Mac's format")
        precondition(String(data: json, encoding: .utf8)!.contains("\"minSimilarity\":75"))

        precondition(perform([airCombo("a")]) == ["combo-a"], "Matched shape fires after its window")
        precondition(perform([airCombo("a")], arm: false).isEmpty, "No recording without the preceding gesture")
        precondition(perform([airCombo("a")], orient: false).isEmpty, "No orientation reference, no match")
        precondition(perform([airCombo("a")], line).isEmpty, "Below minimum similarity")
        precondition(perform([airCombo("a")], [[0, 0], [0, 0]]).isEmpty, "No motion")
        precondition(perform([airCombo("a")], duration: 0.2).isEmpty, "Orientation stopped mid-window")
        precondition(perform([airCombo("a")], duration: 0.2, interrupt: ComboStep(.tapMiddle)).isEmpty, "Finger input cancels the capture")
        for order in [false, true] {
            let entries = [airCombo("line", air(line, 1000, 1)), airCombo("shape")]
            precondition(perform(order ? entries.reversed() : entries) == ["combo-shape"], "Highest similarity wins")
        }
        precondition(perform([airCombo("line", air(line, 2000, 1)), airCombo("shape")], end: 2.1) == ["combo-shape"],
                     "A longer competing window is waited for")
        precondition(perform([airCombo("a", tail: [ComboStep(.tapMiddle)])], then: [(ComboStep(.tapMiddle), 1.2)]) == ["combo-a"],
                     "A step after air uses the normal combo timing")
        precondition(perform([airCombo("a"), single(.doubleTapIndex)], line) == ["double-tap-index"],
                     "A failed air step frees its preceding gesture")
    }
}
