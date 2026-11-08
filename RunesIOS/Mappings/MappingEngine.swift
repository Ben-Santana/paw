import Foundation

/// Decides which mapping each gesture runs. A port of the Mac app's `ShortcutEngine`
/// (python/shortcuts.py):
///
/// - A gesture that no live combo uses runs its own mapping at once.
/// - A gesture that a combo uses waits until every combo that could still claim it has
///   finished or failed. A completed combo owns its gestures, so their single mappings don't run.
/// - Between steps a combo allows `intervalMs`; while a hold from the combo is still down there
///   is no limit. Releasing a hold early, or any other gesture, ends the attempt.
/// - Rotation and movement only count when they are a combo's next step. Other motion
///   neither breaks an attempt nor extends its timer, since a hand is rarely still.
/// - An air step starts recording the wrist's path when the gesture before it is made, and is
///   judged when its own `durationMs` window closes (not `intervalMs`). Air steps that share
///   earlier gestures wait for each other's windows; the highest similarity above its minimum wins.
///   Any finger gesture during the window, or an orientation gap over 0.5 s, fails it.
/// - A single tap waits briefly when a double tap on the same finger is mapped, so a double tap
///   doesn't also run the single tap.
///
/// Pure value type with an injected clock, so it is tested without a band.
struct MappingEngine: Sendable {
    /// How long a single tap waits for a possible double tap.
    static let doubleTapWindow: TimeInterval = 0.3

    struct Input: Equatable, Sendable { let id: Int; let step: ComboStep; let at: TimeInterval }
    enum Event: Equatable, Sendable {
        /// A gesture the engine accepted, for the live strip. Motion only appears when a combo used it.
        case input(Input)
        /// Run this mapping's actions.
        case fire(mappingID: String, inputIDs: [Int])
        case comboFailed(mappingID: String, reason: String)
    }

    private struct Candidate: Sendable { var next: Int; var at: TimeInterval; var inputs: [Int] }
    private struct CaptureKey: Hashable, Comparable, Sendable {
        let mappingID: String; let index: Int; let inputs: [Int]
        static func < (a: Self, b: Self) -> Bool {
            (a.mappingID, a.index, a.inputs.first ?? 0) < (b.mappingID, b.index, b.inputs.first ?? 0)
        }
    }
    private struct Capture: Sendable {
        let start: TimeInterval, end: TimeInterval
        let reference: [Double]?
        var points: [AirShape.Point] = []
        var last: TimeInterval
        var invalid: Bool
    }
    /// How long orientation may pause before a capture is broken.
    static let orientationGap: TimeInterval = 0.5

    private var singles: [GestureKind: String] = [:]
    private var combos: [String: (steps: [ComboStep], interval: TimeInterval)] = [:]
    private var comboGestures: Set<GestureKind> = []
    private var awaitsDoubleTap: Set<GestureKind> = []
    private var progress: [String: [Candidate]] = [:]
    /// Gestures and completed combos waiting for longer combos to give up.
    private var deferred: [(mappingID: String, inputs: Set<Int>)] = []
    private var pendingTaps: [GestureKind: TimeInterval] = [:]
    private var captures: [CaptureKey: Capture] = [:]
    private var orientation: [Double]?
    private var orientationAt: TimeInterval = -.infinity
    private var sequence = 0
    private var events: [Event] = []

    init(mappings: [Mapping] = []) { configure(mappings) }

    mutating func configure(_ mappings: [Mapping]) {
        singles = [:]; combos = [:]
        for mapping in mappings where mapping.isLive {
            if let steps = mapping.steps { combos[mapping.id] = (steps, Double(mapping.intervalMs ?? ComboRules.defaultTime) / 1000) }
            else if let motion = mapping.motion { singles[motion] = mapping.id }
        }
        comboGestures = Set(combos.values.flatMap { $0.steps.map(\.gesture) })
        let used = Set(singles.keys).union(comboGestures)
        awaitsDoubleTap = Set([GestureKind.tapIndex, .tapMiddle].filter { $0.doubleTap.map(used.contains) ?? false })
        reset()
    }

    mutating func reset() { progress = [:]; deferred = []; pendingTaps = [:]; captures = [:] }

    var isIdle: Bool { pendingTaps.isEmpty && deferred.isEmpty && progress.values.allSatisfy(\.isEmpty) }
    /// Whether any live combo has a rotation or movement step.
    var wantsMotion: Bool { comboGestures.contains(.rotation) || comboGestures.contains(.movement) || comboGestures.contains(.air) }
    /// Whether an air step is recording right now.
    var isCapturingAir: Bool { !captures.isEmpty }

    /// The band's orientation quaternion (w, x, y, z), for air steps.
    mutating func orientation(_ q: [Double], at now: TimeInterval) {
        guard q.count == 4, q.allSatisfy(\.isFinite) else { return }
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-8 else { return }
        let current = q.map { $0 / norm }
        orientation = current; orientationAt = now
        for key in captures.keys {
            guard var c = captures[key], !c.invalid, now <= c.end, c.points.count < 4096, let reference = c.reference else { continue }
            if now - c.last > Self.orientationGap { c.invalid = true }
            c.points.append(AirMatcher.wristPoint(current, reference: reference))
            c.last = now
            captures[key] = c
        }
    }

    // MARK: Input

    mutating func receive(_ gesture: GestureKind, at now: TimeInterval) -> [Event] {
        receive(ComboStep(gesture), at: now)
    }

    mutating func receive(_ input: ComboStep, at now: TimeInterval) -> [Event] {
        let gesture = input.gesture
        // A second tap on the same finger turns the waiting tap into this double tap.
        if gesture == .doubleTapIndex { pendingTaps[.tapIndex] = nil }
        if gesture == .doubleTapMiddle { pendingTaps[.tapMiddle] = nil }
        // Anything else proves the waiting taps were single taps, and they happened first.
        for (tap, at) in pendingTaps.sorted(by: { $0.value < $1.value }) {
            pendingTaps[tap] = nil
            recognize(ComboStep(tap), at: at)
        }
        if awaitsDoubleTap.contains(gesture) { pendingTaps[gesture] = now }
        else { recognize(input, at: now) }
        syncCaptures(at: now)
        return drain()
    }

    /// Call while not idle: releases waiting taps and expires combos that ran out of time.
    mutating func tick(at now: TimeInterval) -> [Event] {
        for (tap, at) in pendingTaps.sorted(by: { $0.value < $1.value }) where now - at >= Self.doubleTapWindow {
            pendingTaps[tap] = nil
            recognize(ComboStep(tap), at: at)
        }
        // A waiting tap may still belong to a combo step that was in time.
        let slack = pendingTaps.isEmpty ? 0 : Self.doubleTapWindow
        for (id, candidates) in progress {
            guard let combo = combos[id] else { continue }
            progress[id] = candidates.filter { c in
                // An air step keeps its own window.
                if combo.steps[c.next].gesture.isAir || held(combo.steps, before: c.next) || now - slack - c.at <= combo.interval { return true }
                events.append(.comboFailed(mappingID: id, reason: "Timed out"))
                return false
            }
        }
        resolve()
        syncCaptures(at: now)
        finishCaptures(at: now)
        syncCaptures(at: now)
        return drain()
    }

    private mutating func drain() -> [Event] { defer { events = [] }; return events }

    private func held(_ steps: [ComboStep], before index: Int) -> Bool {
        !(ComboRules.activeHolds(Array(steps.prefix(index))) ?? []).isEmpty
    }

    private mutating func recognize(_ input: ComboStep, at now: TimeInterval) {
        let gesture = input.gesture
        if gesture.isMotion {
            // Motion only matters when it starts or advances an attempt.
            let relevant = combos.contains { id, combo in
                combo.steps[0].matches(input) || (progress[id] ?? []).contains { c in
                    combo.steps[c.next].matches(input) && now >= c.at && (held(combo.steps, before: c.next) || now - c.at <= combo.interval)
                }
            }
            guard relevant else { return }
        }
        sequence += 1
        let id = sequence
        events.append(.input(Input(id: id, step: input, at: now)))
        // Wait for the combos before deciding who owns a gesture a combo uses.
        if comboGestures.contains(gesture), singles[gesture] != nil { deferred.append((gesture.rawValue, [id])) }
        advance(input, id: id, at: now)
        // Earlier gestures this one freed run first, keeping physical order.
        resolve()
        if !comboGestures.contains(gesture), let mapping = singles[gesture] {
            events.append(.fire(mappingID: mapping, inputIDs: [id]))
        }
    }

    private mutating func advance(_ input: ComboStep, id inputID: Int, at now: TimeInterval) {
        let gesture = input.gesture
        for (id, combo) in combos {
            let steps = combo.steps
            var live: [Candidate] = []
            for c in progress[id] ?? [] {
                if gesture.isMotion, !steps[c.next].matches(input) {
                    // Incidental motion neither breaks a combo nor extends its timer.
                    live.append(c); continue
                }
                let holds = ComboRules.activeHolds(Array(steps.prefix(c.next))) ?? []
                if gesture.isRelease, gesture != steps[c.next].gesture {
                    // An early release ends only attempts that need that finger held.
                    if let finger = gesture.finger, holds.contains(finger) {
                        events.append(.comboFailed(mappingID: id, reason: "Released early"))
                    } else { live.append(c) }
                    continue
                }
                let inTime = now >= c.at && (!holds.isEmpty || now - c.at <= combo.interval)
                if inTime, steps[c.next].matches(input) {
                    if c.next + 1 == steps.count { deferred.append((id, Set(c.inputs + [inputID]))) }
                    else { live.append(Candidate(next: c.next + 1, at: now, inputs: c.inputs + [inputID])) }
                } else {
                    events.append(.comboFailed(mappingID: id, reason: inTime ? "Unexpected gesture" : "Timed out"))
                }
            }
            if steps[0].matches(input) { live.append(Candidate(next: 1, at: now, inputs: [inputID])) }
            progress[id] = live
        }
    }

    /// Runs whatever is no longer waiting on a longer combo. Larger completed combos win.
    private mutating func resolve() {
        let actions = deferred
        deferred = []
        var consumed = Set<Int>()
        for action in actions {
            if !action.inputs.isDisjoint(with: consumed) { continue }
            if actions.contains(where: { action.inputs.isStrictSubset(of: $0.inputs) }) { continue }
            let blocked = progress.contains { id, candidates in
                candidates.contains { action.inputs.isSubset(of: Set($0.inputs)) && (combos[id]?.steps.count ?? 0) > action.inputs.count }
            }
            if blocked { deferred.append(action); continue }
            events.append(.fire(mappingID: action.mappingID, inputIDs: action.inputs.sorted()))
            guard combos[action.mappingID] != nil else { continue }
            consumed.formUnion(action.inputs)
            // A completed combo's gestures can't seed or continue another attempt.
            for (id, candidates) in progress {
                progress[id] = candidates.filter { c in
                    if action.inputs.isDisjoint(with: c.inputs) { return true }
                    events.append(.comboFailed(mappingID: id, reason: "Gestures used by another combo"))
                    return false
                }
            }
        }
        if !consumed.isEmpty { deferred.removeAll { !$0.inputs.isDisjoint(with: consumed) } }
    }
}

extension MappingEngine {
    /// Starts a capture for each attempt now waiting on an air step, and drops captures
    /// whose attempt ended.
    fileprivate mutating func syncCaptures(at now: TimeInterval) {
        var live: [CaptureKey: Capture] = [:]
        for (id, candidates) in progress {
            guard let steps = combos[id]?.steps else { continue }
            for c in candidates where steps[c.next].gesture.isAir {
                let key = CaptureKey(mappingID: id, index: c.next, inputs: c.inputs)
                live[key] = captures[key] ?? Capture(
                    start: now, end: now + Double(steps[c.next].air?.durationMs ?? 0) / 1000,
                    reference: orientation, last: now,
                    invalid: orientation == nil || now - orientationAt > Self.orientationGap)
            }
        }
        captures = live
    }

    /// Judges air steps whose windows have closed. Steps that share earlier gestures compete:
    /// all their windows must close, then the best score at or above its minimum wins.
    fileprivate mutating func finishCaptures(at now: TimeInterval) {
        var remaining = Set(captures.keys)
        var groups: [Set<CaptureKey>] = []
        while let seed = remaining.popFirst() {
            var group: Set<CaptureKey> = [seed]
            var inputs = Set(seed.inputs)
            while true {
                let linked = remaining.filter { !inputs.isDisjoint(with: $0.inputs) }
                if linked.isEmpty { break }
                group.formUnion(linked); remaining.subtract(linked)
                for key in linked { inputs.formUnion(key.inputs) }
            }
            groups.append(group)
        }
        for group in groups {
            if group.contains(where: { now < (captures[$0]?.end ?? 0) }) { continue }
            var ranked: [(score: Int, key: CaptureKey)] = []
            for key in group {
                guard let c = captures[key], !c.invalid, c.end - c.last <= Self.orientationGap,
                      c.points.count >= AirMatcher.minimumPoints, AirMatcher.pathLength(c.points) >= AirMatcher.minimumPath,
                      let shape = combos[key.mappingID]?.steps[key.index].air,
                      let score = AirMatcher.similarity(shape.points, c.points), score >= shape.minSimilarity else { continue }
                ranked.append((score, key))
            }
            // A stable id breaks exact ties, never dictionary order.
            let winner = ranked.min { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }?.key
            sequence += 1
            let inputID = sequence
            if let winner, let step = combos[winner.mappingID]?.steps[winner.index] {
                events.append(.input(Input(id: inputID, step: step, at: now)))
            }
            for key in group.sorted() {
                captures[key] = nil
                progress[key.mappingID] = (progress[key.mappingID] ?? []).filter { !($0.next == key.index && $0.inputs == key.inputs) }
                guard key == winner, let steps = combos[key.mappingID]?.steps else {
                    events.append(.comboFailed(mappingID: key.mappingID, reason: winner == nil
                        ? "Air gesture below minimum similarity or orientation interrupted" : "Another air gesture matched better"))
                    continue
                }
                let matched = key.inputs + [inputID]
                if key.index + 1 == steps.count { deferred.append((key.mappingID, Set(matched))) }
                else { progress[key.mappingID, default: []].append(Candidate(next: key.index + 1, at: now, inputs: matched)) }
            }
        }
        resolve()
    }
}

/// Turns the band's orientation and gyroscope samples into rotation and movement steps,
/// with the Mac's thresholds (python/shortcuts.py `ingest`):
/// - Rotation: more than 25° about one axis of the band's own frame since the last rotation.
/// - Movement: gyroscope above 80 on an axis; that axis re-arms once it drops below 30.
struct MotionDetector: Sendable {
    static let rotationThreshold = 25.0 * .pi / 180
    static let movementOn = 80.0, movementOff = 30.0

    private var origin: [Double]?
    private var moving: Set<Axis> = []

    mutating func reset() { origin = nil; moving = [] }

    /// `q` is the band's quaternion in w, x, y, z order.
    mutating func orientation(_ q: [Double]) -> ComboStep? {
        guard q.count == 4, q.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-8 else { return nil }
        let current = q.map { $0 / norm }
        guard let o = origin else { origin = current; return nil }
        let (w, x, y, z) = (o[0], o[1], o[2], o[3])
        let (a, b, c, d) = (current[0], current[1], current[2], current[3])
        // Relative rotation from the origin, conj(origin) * current.
        let relative = [w*a + x*b + y*c + z*d, w*b - x*a - y*d + z*c, w*c + x*d - y*a - z*b, w*d - x*c + y*b - z*a]
        let scalar = abs(relative[0])
        for (axis, value) in zip(Axis.allCases, relative[1...]) where 2 * atan2(abs(value), scalar) > Self.rotationThreshold {
            origin = current
            let positive = value * (relative[0] >= 0 ? 1 : -1) > 0
            return .rotation(axis, positive ? .right : .left)
        }
        return nil
    }

    mutating func gyroscope(_ values: [Double]) -> [ComboStep] {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return [] }
        var out: [ComboStep] = []
        for (axis, value) in zip(Axis.allCases, values) {
            if abs(value) < Self.movementOff { moving.remove(axis) }
            else if abs(value) > Self.movementOn, !moving.contains(axis) { moving.insert(axis); out.append(.movement(axis)) }
        }
        return out
    }
}
