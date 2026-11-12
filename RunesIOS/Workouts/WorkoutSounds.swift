import Foundation

/// The moments of a running workout that can play a sound.
enum WorkoutCue: String, CaseIterable, Identifiable, Sendable {
    case start, rep, target, setDone, workoutDone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Set started"
        case .rep: "Each rep"
        case .target: "Target reached"
        case .setDone: "Set finished"
        case .workoutDone: "Workout finished"
        }
    }

    var detail: String {
        switch self {
        case .start: "When a set begins, or restarts."
        case .rep: "Every rep the band counts. Off unless you choose one."
        case .target: "When the count reaches the set’s target, or a hold reaches its time."
        case .setDone: "When a set is logged."
        case .workoutDone: "After the last set, instead of the set sound."
        }
    }

    /// The cue a command's change to a run plays, if any.
    static func after(_ command: WorkoutCommand, from old: WorkoutRun, to new: WorkoutRun, logged: SetLog?) -> WorkoutCue? {
        if new.phase == .finished, old.phase != .finished { return .workoutDone }
        if logged != nil { return .setDone }
        if new.phase == .counting, old.phase != .counting || command == .repeatLast { return .start }
        return nil
    }

    /// The cue for a rep just counted: the target when it is reached, otherwise a rep.
    static func afterRep(_ run: WorkoutRun) -> WorkoutCue? {
        guard run.phase == .counting, let slot = run.current, slot.exercise.measure == .reps else { return nil }
        return run.reps == slot.target ? .target : .rep
    }
}

/// Which sound each workout moment plays, from the Mac's library. Nil plays nothing.
struct WorkoutSounds: Codable, Hashable, Sendable {
    static let standard: [WorkoutCue: SoundVoice] = [.start: .lift, .target: .coin, .setDone: .resolve, .workoutDone: .bells]

    var on = true
    /// 0...1.
    var volume = 0.8
    var start: SoundVoice? = standard[.start]
    /// Optional: off by default, since it plays every couple of seconds.
    var rep: SoundVoice? = nil
    var target: SoundVoice? = standard[.target]
    var setDone: SoundVoice? = standard[.setDone]
    var workoutDone: SoundVoice? = standard[.workoutDone]

    subscript(cue: WorkoutCue) -> SoundVoice? {
        get {
            switch cue {
            case .start: start
            case .rep: rep
            case .target: target
            case .setDone: setDone
            case .workoutDone: workoutDone
            }
        }
        set {
            switch cue {
            case .start: start = newValue
            case .rep: rep = newValue
            case .target: target = newValue
            case .setDone: setDone = newValue
            case .workoutDone: workoutDone = newValue
            }
        }
    }

    private enum Keys: String, CodingKey { case on, volume, start, rep, target, setDone, workoutDone }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        on = (try? c.decode(Bool.self, forKey: .on)) ?? true
        volume = min(1, max(0, (try? c.decode(Double.self, forKey: .volume)) ?? 0.8))
        // A missing key gets the default; null is a chosen "None".
        func value(_ key: Keys, _ fallback: SoundVoice?) -> SoundVoice? {
            guard c.contains(key) else { return fallback }
            if (try? c.decodeNil(forKey: key)) == true { return nil }
            return (try? c.decode(SoundVoice.self, forKey: key)) ?? fallback
        }
        start = value(.start, Self.standard[.start])
        rep = value(.rep, nil)
        target = value(.target, Self.standard[.target])
        setDone = value(.setDone, Self.standard[.setDone])
        workoutDone = value(.workoutDone, Self.standard[.workoutDone])
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(on, forKey: .on)
        try c.encode(volume, forKey: .volume)
        // Null when None, so it isn't read back as the default.
        try c.encode(start, forKey: .start)
        try c.encode(rep, forKey: .rep)
        try c.encode(target, forKey: .target)
        try c.encode(setDone, forKey: .setDone)
        try c.encode(workoutDone, forKey: .workoutDone)
    }
}
