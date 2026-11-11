import Foundation

// Workouts: a split of training days (exercises × sets), global control gestures, and the
// state machine for a running workout. Reps come from the band's motion for the exercises it
// can count (ExerciseCatalog.swift); the rest log their target, or their time.
// Everything here is a pure value type so it is tested without a band.
// Everything here is a pure value type so it is tested without a band.

/// Scales every exercise's thresholds. Detection is not yet tuned on a real band.
enum RepSensitivity: String, Codable, CaseIterable, Sendable {
    case low, normal, high
    var title: String { rawValue.capitalized }
    /// Multiplier for thresholds: higher sensitivity needs less movement.
    var scale: Double { switch self { case .low: 1.2; case .normal: 1; case .high: 0.8 } }
}

enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case kg, lb
    var title: String { rawValue }
    var step: Double { self == .kg ? 2.5 : 5 }
}

/// One exercise in a split day, done for `sets` sets of `reps` reps (seconds for a timed one),
/// optionally at `weight` in the store's unit.
struct WorkoutItem: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var exercise: Exercise
    var sets: Int
    var reps: Int
    var weight: Double? = nil

    init(exercise: Exercise, sets: Int, reps: Int, weight: Double? = nil) {
        self.exercise = exercise; self.sets = sets; self.reps = reps; self.weight = weight
    }

    static let setRange = 1...10, repRange = 1...100, secondRange = 5...600, weightRange = 0.0...1000.0
    static func defaultTarget(_ exercise: Exercise) -> Int { exercise.measure == .seconds ? 30 : 10 }
    var targetRange: ClosedRange<Int> { exercise.measure == .seconds ? Self.secondRange : Self.repRange }
}

/// One day of the split: a named list of exercises.
struct WorkoutPlan: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var items: [WorkoutItem]

    var setCount: Int { items.reduce(0) { $0 + $1.sets } }
    var summary: String {
        let exercises = items.count == 1 ? "1 exercise" : "\(items.count) exercises"
        return "\(exercises) · \(setCount == 1 ? "1 set" : "\(setCount) sets")"
    }

    /// Every muscle this day trains first-hand.
    var muscles: Set<Muscle> { Set(items.flatMap(\.exercise.primary)) }

    static func new(_ index: Int) -> WorkoutPlan {
        WorkoutPlan(name: "Day \(index)", items: [])
    }
    static let sample = WorkoutPlan(name: "Arms", items: [
        WorkoutItem(exercise: .bicepCurl, sets: 3, reps: 12),
        WorkoutItem(exercise: .lateralRaise, sets: 3, reps: 10),
        WorkoutItem(exercise: .overheadExtension, sets: 2, reps: 12),
    ])
    private static func day(_ name: String, _ items: [(String, Int, Int)]) -> WorkoutPlan {
        WorkoutPlan(name: name, items: items.compactMap { id, sets, reps in
            Exercise.byID[id].map { WorkoutItem(exercise: $0, sets: sets, reps: reps) }
        })
    }
    /// A push / pull / legs split for a first launch.
    static let starterSplit: [WorkoutPlan] = [
        day("Push", [("benchPress", 4, 8), ("dumbbellShoulderPress", 3, 10), ("inclineDumbbellPress", 3, 10),
                     ("lateralRaise", 3, 12), ("tricepPushdown", 3, 12), ("overheadExtension", 2, 12)]),
        day("Pull", [("pullUp", 4, 8), ("bentOverRow", 3, 10), ("latPulldown", 3, 10),
                     ("facePull", 3, 15), ("bicepCurl", 3, 12), ("hammerCurl", 2, 12)]),
        day("Legs", [("backSquat", 4, 6), ("romanianDeadlift", 3, 8), ("legPress", 3, 12),
                     ("legCurl", 3, 12), ("calfRaise", 4, 15), ("plank", 3, 45)]),
    ]

    /// Trimmed name, sets and reps within range.
    func normalized() -> WorkoutPlan {
        var plan = self
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        plan.name = trimmed.isEmpty ? "Workout" : trimmed
        plan.items = items.map { item in
            var item = item
            item.sets = min(max(item.sets, WorkoutItem.setRange.lowerBound), WorkoutItem.setRange.upperBound)
            item.reps = min(max(item.reps, item.targetRange.lowerBound), item.targetRange.upperBound)
            if let w = item.weight { item.weight = w > 0 ? min(w, WorkoutItem.weightRange.upperBound) : nil }
            return item
        }
        return plan
    }
}

/// What the global workout gestures do.
enum WorkoutCommand: String, Codable, CaseIterable, Sendable {
    case start, stop, repeatLast, skip

    var title: String {
        switch self {
        case .start: "Start set"
        case .stop: "Stop set"
        case .repeatLast: "Repeat last set"
        case .skip: "Skip set"
        }
    }
    var detail: String {
        switch self {
        case .start: "Begins the set. Reps are counted for exercises the band can follow."
        case .stop: "Logs the set and moves to the next one."
        case .repeatLast: "Does the set you just finished again. While counting, restarts the set."
        case .skip: "Moves on without logging."
        }
    }
}

/// A gesture or a combo per command, the same for every workout.
struct WorkoutControls: Codable, Hashable, Sendable {
    var triggers: [WorkoutCommand: CommandTrigger]

    static let standard = WorkoutControls(gestures: [
        .start: .doubleTapIndex, .stop: .doubleTapMiddle, .repeatLast: .swipeLeft, .skip: .swipeRight,
    ])
    /// Gestures a command may use on its own. Releases only exist inside combos.
    static let choices = CommandTrigger.singleChoices
    private static let mappingPrefix = "workout:"

    init(triggers: [WorkoutCommand: CommandTrigger]) { self.triggers = triggers }
    init(gestures: [WorkoutCommand: GestureKind]) { triggers = gestures.mapValues(CommandTrigger.gesture) }

    func trigger(for command: WorkoutCommand) -> CommandTrigger? { triggers[command] }
    /// The command's gesture, when it is a single one.
    func gesture(for command: WorkoutCommand) -> GestureKind? { triggers[command]?.gesture }
    func command(for gesture: GestureKind) -> WorkoutCommand? {
        WorkoutCommand.allCases.first { triggers[$0]?.gesture == gesture }
    }
    /// Assigns a trigger; a command that already had it takes this command's old one.
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: WorkoutCommand) { triggers.assign(trigger, to: command) }
    mutating func set(_ gesture: GestureKind?, for command: WorkoutCommand) { setTrigger(gesture.map(CommandTrigger.gesture), for: command) }

    /// The gestures a running workout takes; mappings that use one are off until it ends.
    var reserved: Set<GestureKind> { triggers.reserved }
    /// The triggers as mappings, for the engine that decides which one was made.
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    var usesMotion: Bool { triggers.usesMotion }
    func command(forMapping id: String) -> WorkoutCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }

    private enum Keys: String, CodingKey { case gestures, triggers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let saved = try c.decodeIfPresent([String: CommandTrigger].self, forKey: .triggers) {
            triggers = Dictionary(saved: saved)
        } else {
            // Saved before a command could take a combo: one gesture each.
            triggers = try c.decode([WorkoutCommand: GestureKind].self, forKey: .gestures).mapValues(CommandTrigger.gesture)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
    }
}

/// A set to do, in the order the run goes through them.
struct WorkoutSlot: Codable, Hashable, Sendable {
    var exercise: Exercise
    var set: Int
    var of: Int
    var target: Int
    var weight: Double? = nil
    var isRepeat = false

    /// The value a set logs when the band can't count it.
    var assumed: Bool { !exercise.detectsReps }
    var unit: String { exercise.measure == .seconds ? "s" : (target == 1 ? "rep" : "reps") }

    var label: String { isRepeat ? "Set \(set) of \(of), again" : "Set \(set) of \(of)" }
}

/// A finished set.
struct SetLog: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var slot: WorkoutSlot
    /// Reps, or seconds for a timed exercise.
    var reps: Int
    var at: Date

    var exercise: Exercise { slot.exercise }
    var weight: Double? { slot.weight }
}

/// A workout that was done, for history.
struct WorkoutRecord: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    var name: String
    /// The split day it ran; nil for workouts saved before the split.
    var planID: String? = nil
    var started: Date
    var ended: Date
    var sets: [SetLog]

    var totalReps: Int { sets.filter { $0.exercise.measure == .reps }.reduce(0) { $0 + $1.reps } }
    /// Weight × reps over every weighted set.
    var volume: Double { sets.reduce(0) { $0 + ($1.weight ?? 0) * Double($1.exercise.measure == .reps ? $1.reps : 0) } }
    var muscles: Set<Muscle> { Set(sets.flatMap(\.exercise.primary)) }
}

/// A running workout: waits for the start gesture, counts a set, logs it on the stop gesture,
/// then waits again for the next set.
struct WorkoutRun: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case waiting, counting, finished }

    let planID: String
    let name: String
    let started: Date
    private(set) var slots: [WorkoutSlot]
    private(set) var index = 0
    private(set) var phase: Phase
    private(set) var reps = 0
    private(set) var logs: [SetLog] = []
    /// When the current set began.
    private(set) var setStarted: Date?

    init(plan: WorkoutPlan, at now: Date = Date()) {
        planID = plan.id; name = plan.name; started = now
        slots = plan.items.flatMap { item in
            (1...max(1, item.sets)).map { WorkoutSlot(exercise: item.exercise, set: $0, of: item.sets, target: item.reps, weight: item.weight) }
        }
        phase = slots.isEmpty ? .finished : .waiting
    }

    var current: WorkoutSlot? { slots.indices.contains(index) ? slots[index] : nil }
    var next: WorkoutSlot? { slots.indices.contains(index + 1) ? slots[index + 1] : nil }
    var last: SetLog? { logs.last }
    var remaining: Int { max(0, slots.count - index) }

    /// Applies a command. Returns the set it logged, if any.
    @discardableResult
    mutating func apply(_ command: WorkoutCommand, at now: Date = Date()) -> SetLog? {
        switch (command, phase) {
        case (.start, .waiting):
            phase = .counting; reps = 0; setStarted = now
        case (.stop, .counting):
            guard let slot = current else { return nil }
            // A timed exercise logs how long it was held; one the band can't count logs its target.
            let value: Int
            if slot.exercise.measure == .seconds { value = max(1, Int(now.timeIntervalSince(setStarted ?? now).rounded())) }
            else if slot.assumed { value = slot.target }
            else { value = reps }
            let log = SetLog(slot: slot, reps: value, at: now)
            logs.append(log)
            advance()
            return log
        case (.repeatLast, .counting):
            reps = 0; setStarted = now
        case (.repeatLast, .waiting), (.repeatLast, .finished):
            guard var again = last?.slot else { return nil }
            again.isRepeat = true
            slots.insert(again, at: index)
            phase = .waiting
        case (.skip, .waiting), (.skip, .counting):
            advance()
        default:
            break
        }
        return nil
    }

    /// A rep from the counter; ignored unless a set is being counted.
    mutating func rep() { if phase == .counting { reps += 1 } }

    private mutating func advance() {
        index += 1; reps = 0; setStarted = nil
        phase = index < slots.count ? .waiting : .finished
    }
}

/// Counts reps from orientation (w, x, y, z) and gyroscope (x, y, z) samples.
struct RepCounter: Sendable {
    let exercise: Exercise
    let scale: Double
    private var origin: [Double]?
    private var armed = true
    private var lastRep: TimeInterval = -.infinity

    init(exercise: Exercise, sensitivity: RepSensitivity = .normal) {
        self.exercise = exercise; scale = sensitivity.scale
    }

    /// Returns true when this sample completes a rep.
    mutating func orientation(_ q: [Double], at now: TimeInterval) -> Bool {
        guard case .swing(let high, let low)? = exercise.signal, q.count == 4, q.allSatisfy(\.isFinite) else { return false }
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-8 else { return false }
        let current = q.map { $0 / norm }
        guard let o = origin else { origin = current; return false }
        let dot = min(1, abs(zip(o, current).reduce(0) { $0 + $1.0 * $1.1 }))
        let degrees = 2 * acos(dot) * 180 / .pi
        return crossed(degrees, on: high * scale, off: low * scale, at: now)
    }

    mutating func gyroscope(_ values: [Double], at now: TimeInterval) -> Bool {
        guard case .burst(let on, let off)? = exercise.signal, values.count == 3, values.allSatisfy(\.isFinite) else { return false }
        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return crossed(magnitude, on: on * scale, off: off * scale, at: now)
    }

    private mutating func crossed(_ value: Double, on: Double, off: Double, at now: TimeInterval) -> Bool {
        if value < off { armed = true; return false }
        guard armed, value > on, now - lastRep >= exercise.minimumRepInterval else { return false }
        armed = false; lastRep = now
        return true
    }
}

/// Feeds motion samples to the active set's counter on the transport queue, so only
/// counted reps cross to the main actor.
final class RepFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: RepCounter?

    /// Starts a fresh count, or stops counting with nil.
    func count(_ exercise: Exercise?, sensitivity: RepSensitivity) {
        lock.withLock { counter = exercise.flatMap { $0.detectsReps ? RepCounter(exercise: $0, sensitivity: sensitivity) : nil } }
    }
    var isCounting: Bool { lock.withLock { counter != nil } }

    /// `orientation` true for a quaternion, false for a gyroscope sample. True when a rep completed.
    func ingest(orientation: Bool, _ values: [Double], at now: TimeInterval) -> Bool {
        lock.withLock {
            guard counter != nil else { return false }
            return orientation ? counter!.orientation(values, at: now) : counter!.gyroscope(values, at: now)
        }
    }
}
