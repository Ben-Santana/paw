import Foundation

/// What a trigger may be made of, wherever one is chosen: a mapping's combo, a Score action,
/// Capture's gesture, a Workouts or Cook command. One gesture, a combo, or either; the
/// composer (`Views/Design/TriggerComposer.swift`) only offers what these allow.
struct TriggerRules {
    /// Gestures that may stand alone. Empty when only combos are built.
    var singles: [GestureKind] = []
    /// The steps that may follow the ones chosen so far. Nil when only one gesture is chosen.
    var next: (([ComboStep]) -> [GestureKind])? = nil
    /// Whether nothing at all is an answer.
    var allowsNone = false

    /// One gesture, or none.
    static func gesture(_ singles: [GestureKind], allowsNone: Bool = true) -> TriggerRules {
        TriggerRules(singles: singles, allowsNone: allowsNone)
    }
    /// One gesture, or a combo of the steps `next` allows.
    static func gestureOrCombo(_ singles: [GestureKind], next: @escaping ([ComboStep]) -> [GestureKind], allowsNone: Bool) -> TriggerRules {
        TriggerRules(singles: singles, next: next, allowsNone: allowsNone)
    }
    /// A mapping's combo: two to eight steps of any kind.
    static let combo = TriggerRules(next: ComboRules.allowedNext)

    var buildsCombos: Bool { next != nil }
    var comboOnly: Bool { singles.isEmpty }
    var maxSteps: Int { buildsCombos ? ComboRules.steps.upperBound : 1 }

    /// Every gesture that can appear at all, so the pad knows which keys to draw.
    var offered: Set<GestureKind> {
        var all = Set(singles)
        if let next {
            // Nothing held, then both fingers held: between them every step is allowed once.
            all.formUnion(next([]))
            all.formUnion(next([ComboStep(.holdIndex), ComboStep(.holdMiddle)]))
        }
        return all
    }

    /// Whether `kind` may be added after `steps`.
    func canAppend(_ kind: GestureKind, to steps: [ComboStep]) -> Bool {
        guard steps.count < maxSteps else { return false }
        guard let next else { return singles.contains(kind) }
        if steps.isEmpty, singles.contains(kind) { return true }
        return next(steps).contains(kind)
    }

    /// Whether `kind` may take the place of step `index`. Only the steps before it decide;
    /// what it breaks later is said by `problem`, so a hold can be swapped for the other finger's.
    func canReplace(_ index: Int, with kind: GestureKind, in steps: [ComboStep]) -> Bool {
        guard steps.indices.contains(index) else { return false }
        if steps.count == 1, singles.contains(kind) { return true }
        guard let next else { return false }
        let before = Array(steps.prefix(index))
        // An air shape can't follow another, or come right before one.
        if kind.isAir, steps.indices.contains(index + 1), steps[index + 1].gesture.isAir { return false }
        return next(before).contains(kind)
    }

    /// Why these steps can't be saved yet, as one sentence. Nil for nothing chosen.
    func problem(_ steps: [ComboStep]) -> String? {
        guard let first = steps.first else { return nil }
        if steps.count == 1 {
            if singles.contains(first.gesture) { return nil }
            if comboOnly { return ComboRules.problem(steps) }
            return buildsCombos ? "\(first.gesture.name) only works here inside a combo. Add a step after it."
                                : "\(first.gesture.name) can’t be used here."
        }
        guard let next else { return "Choose one gesture." }
        if let problem = ComboRules.problem(steps) { return problem }
        for index in steps.indices where !next(Array(steps.prefix(index))).contains(steps[index].gesture) {
            return "\(steps[index].name) can’t be step \(index + 1) here."
        }
        return nil
    }

    func isValid(_ steps: [ComboStep]) -> Bool {
        steps.isEmpty ? allowsNone : problem(steps) == nil
    }

    /// Which steps are made with a finger down: the hold, everything until its release, and
    /// the release. `bridges[i]` says the finger is still down between step `i` and the next.
    static func held(_ steps: [ComboStep]) -> (steps: [Bool], bridges: [Bool]) {
        var down = Set<String>()
        var covered: [Bool] = [], bridges: [Bool] = []
        for step in steps.map(\.gesture) {
            let before = !down.isEmpty
            if let finger = step.finger {
                if step.isHold { down.insert(finger) }
                if step.isRelease { down.remove(finger) }
            }
            covered.append(before || !down.isEmpty)
            bridges.append(!down.isEmpty)
        }
        return (covered, bridges)
    }
}

extension ComboRules {
    /// "750 ms", "1 s", "1.5 s".
    static func timeLabel(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: ms % 1000 == 0 ? "%.0f s" : "%.1f s", Double(ms) / 1000)
    }
}
