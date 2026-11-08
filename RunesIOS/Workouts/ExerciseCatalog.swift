import Foundation

// The exercise catalog: every movement the Workouts app knows, the muscles it trains, and
// whether the band can count its reps. Most can't (the band only sees the forearm's
// orientation and gyroscope), so those log the set's target when it stops, or its time.

/// A muscle on the body map.
enum Muscle: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case chest, shoulders, biceps, triceps, forearms, abs, obliques, traps, lats, lowerBack, glutes, quads, hamstrings, calves

    var id: String { rawValue }
    var name: String {
        switch self {
        case .chest: "Chest"
        case .shoulders: "Shoulders"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .abs: "Abs"
        case .obliques: "Obliques"
        case .traps: "Traps"
        case .lats: "Upper back"
        case .lowerBack: "Lower back"
        case .glutes: "Glutes"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .calves: "Calves"
        }
    }
}

/// The picker's filter tabs, and each exercise's icon.
enum ExerciseGroup: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case chest, back, shoulders, arms, legs, core, cardio

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    /// Highlighted on the group's small body icon.
    var muscles: Set<Muscle> {
        switch self {
        case .chest: [.chest]
        case .back: [.lats, .traps, .lowerBack]
        case .shoulders: [.shoulders]
        case .arms: [.biceps, .triceps, .forearms]
        case .legs: [.quads, .hamstrings, .glutes, .calves]
        case .core: [.abs, .obliques]
        case .cardio: []
        }
    }
}

enum Equipment: String, Codable, Sendable, Hashable {
    case barbell, dumbbell, cable, machine, bodyweight, kettlebell, other
    var name: String { rawValue.capitalized }
}

/// Whether a set is counted in reps or held for time.
enum Measure: String, Codable, Sendable, Hashable { case reps, seconds }

struct Exercise: Hashable, Identifiable, Sendable {
    /// How the band detects reps.
    enum Signal: Sendable, Equatable, Hashable {
        /// A rep is the forearm turning more than `high`° away from the set's starting
        /// orientation, after first coming back within `low`°.
        case swing(high: Double, low: Double)
        /// A rep is the gyroscope's magnitude rising above `on`, after first falling below `off`.
        case burst(on: Double, off: Double)
    }

    let id: String
    let name: String
    let group: ExerciseGroup
    let primary: [Muscle]
    let secondary: [Muscle]
    let equipment: Equipment
    var measure: Measure = .reps
    /// nil: the band can't count this one.
    var signal: Signal? = nil

    var detectsReps: Bool { signal != nil }
    /// Shortest time between two reps, so a wobble at the top isn't a second rep.
    var minimumRepInterval: TimeInterval {
        if case .burst = signal { return 0.3 }
        return 0.6
    }
    var detail: String {
        let how = detectsReps ? "Counts reps" : measure == .seconds ? "Timed" : "Logs target reps"
        return "\(equipment.name) · \(how)"
    }

    static func == (a: Exercise, b: Exercise) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Saved as its id. An id this build doesn't know decodes as an unlisted exercise, so old data survives.
extension Exercise: Codable {
    init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        self = Exercise.byID[id] ?? Exercise(id: id, name: id, group: .arms, primary: [], secondary: [], equipment: .other)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

extension Exercise {
    private static func e(_ id: String, _ name: String, _ group: ExerciseGroup, _ primary: [Muscle], _ secondary: [Muscle] = [],
                          _ equipment: Equipment, _ measure: Measure = .reps, _ signal: Signal? = nil) -> Exercise {
        Exercise(id: id, name: name, group: group, primary: primary, secondary: secondary, equipment: equipment, measure: measure, signal: signal)
    }
    private static let curl = Signal.swing(high: 70, low: 30)
    private static let row = Signal.swing(high: 35, low: 15)

    /// Most popular first. The picker keeps this order inside every tab.
    static let all: [Exercise] = [
        e("benchPress", "Bench press", .chest, [.chest], [.triceps, .shoulders], .barbell),
        e("backSquat", "Back squat", .legs, [.quads, .glutes], [.hamstrings, .lowerBack], .barbell),
        e("deadlift", "Deadlift", .back, [.hamstrings, .glutes, .lowerBack], [.lats, .traps, .forearms], .barbell),
        e("overheadPress", "Overhead press", .shoulders, [.shoulders], [.triceps, .traps], .barbell),
        e("pullUp", "Pull-up", .back, [.lats], [.biceps, .forearms], .bodyweight),
        e("bicepCurl", "Bicep curl", .arms, [.biceps], [.forearms], .dumbbell, .reps, curl),
        e("pushUp", "Push-up", .chest, [.chest], [.triceps, .shoulders, .abs], .bodyweight),
        e("bentOverRow", "Bent-over row", .back, [.lats], [.biceps, .traps, .lowerBack], .barbell, .reps, row),
        e("latPulldown", "Lat pulldown", .back, [.lats], [.biceps], .cable),
        e("legPress", "Leg press", .legs, [.quads], [.glutes, .hamstrings], .machine),
        e("lateralRaise", "Lateral raise", .shoulders, [.shoulders], [.traps], .dumbbell, .reps, .swing(high: 45, low: 20)),
        e("plank", "Plank", .core, [.abs], [.obliques, .shoulders], .bodyweight, .seconds),
        e("inclineBenchPress", "Incline bench press", .chest, [.chest], [.shoulders, .triceps], .barbell),
        e("romanianDeadlift", "Romanian deadlift", .legs, [.hamstrings, .glutes], [.lowerBack], .barbell),
        e("dumbbellBenchPress", "Dumbbell bench press", .chest, [.chest], [.triceps, .shoulders], .dumbbell),
        e("tricepPushdown", "Tricep pushdown", .arms, [.triceps], [], .cable, .reps, .swing(high: 45, low: 20)),
        e("hammerCurl", "Hammer curl", .arms, [.biceps, .forearms], [], .dumbbell, .reps, curl),
        e("lunge", "Lunge", .legs, [.quads, .glutes], [.hamstrings, .calves], .dumbbell),
        e("legExtension", "Leg extension", .legs, [.quads], [], .machine),
        e("legCurl", "Leg curl", .legs, [.hamstrings], [.calves], .machine),
        e("seatedCableRow", "Seated cable row", .back, [.lats], [.biceps, .traps], .cable, .reps, row),
        e("dip", "Dip", .chest, [.chest, .triceps], [.shoulders], .bodyweight),
        e("crunch", "Crunch", .core, [.abs], [], .bodyweight),
        e("hipThrust", "Hip thrust", .legs, [.glutes], [.hamstrings], .barbell),
        e("calfRaise", "Standing calf raise", .legs, [.calves], [], .machine),
        e("dumbbellShoulderPress", "Dumbbell shoulder press", .shoulders, [.shoulders], [.triceps], .dumbbell),
        e("chinUp", "Chin-up", .back, [.lats, .biceps], [.forearms], .bodyweight),
        e("dumbbellRow", "One-arm dumbbell row", .back, [.lats], [.biceps, .traps], .dumbbell, .reps, row),
        e("overheadExtension", "Overhead extension", .arms, [.triceps], [], .dumbbell, .reps, .swing(high: 65, low: 30)),
        e("skullCrusher", "Skull crusher", .arms, [.triceps], [], .barbell, .reps, .swing(high: 65, low: 30)),
        e("cableFly", "Cable fly", .chest, [.chest], [.shoulders], .cable),
        e("facePull", "Face pull", .shoulders, [.shoulders, .traps], [.lats], .cable, .reps, .swing(high: 40, low: 18)),
        e("frontRaise", "Front raise", .shoulders, [.shoulders], [], .dumbbell, .reps, .swing(high: 55, low: 25)),
        e("bulgarianSplitSquat", "Bulgarian split squat", .legs, [.quads, .glutes], [.hamstrings], .dumbbell),
        e("gobletSquat", "Goblet squat", .legs, [.quads, .glutes], [.abs], .kettlebell),
        e("inclineDumbbellPress", "Incline dumbbell press", .chest, [.chest], [.shoulders, .triceps], .dumbbell),
        e("dumbbellFly", "Dumbbell fly", .chest, [.chest], [.shoulders], .dumbbell),
        e("preacherCurl", "Preacher curl", .arms, [.biceps], [], .barbell, .reps, curl),
        e("hangingLegRaise", "Hanging leg raise", .core, [.abs], [.obliques, .forearms], .bodyweight),
        e("russianTwist", "Russian twist", .core, [.obliques], [.abs], .bodyweight),
        e("shrug", "Shrug", .back, [.traps], [.forearms], .dumbbell),
        e("reverseFly", "Reverse fly", .shoulders, [.shoulders], [.traps, .lats], .dumbbell, .reps, .swing(high: 40, low: 18)),
        e("arnoldPress", "Arnold press", .shoulders, [.shoulders], [.triceps], .dumbbell),
        e("frontSquat", "Front squat", .legs, [.quads], [.glutes, .abs], .barbell),
        e("hackSquat", "Hack squat", .legs, [.quads], [.glutes], .machine),
        e("sumoDeadlift", "Sumo deadlift", .legs, [.glutes, .quads, .hamstrings], [.lowerBack, .traps], .barbell),
        e("kettlebellSwing", "Kettlebell swing", .legs, [.glutes, .hamstrings], [.lowerBack, .shoulders], .kettlebell, .reps, .swing(high: 70, low: 30)),
        e("burpee", "Burpee", .cardio, [.quads, .chest], [.shoulders, .abs], .bodyweight),
        e("mountainClimber", "Mountain climber", .cardio, [.abs], [.shoulders, .quads], .bodyweight, .seconds),
        e("jumpingJacks", "Jumping jacks", .cardio, [.shoulders, .calves], [.quads], .bodyweight, .reps, .swing(high: 90, low: 35)),
        e("concentrationCurl", "Concentration curl", .arms, [.biceps], [], .dumbbell, .reps, curl),
        e("cableCurl", "Cable curl", .arms, [.biceps], [.forearms], .cable, .reps, curl),
        e("tricepKickback", "Tricep kickback", .arms, [.triceps], [], .dumbbell, .reps, .swing(high: 55, low: 25)),
        e("closeGripBench", "Close-grip bench press", .arms, [.triceps], [.chest, .shoulders], .barbell),
        e("pecDeck", "Pec deck", .chest, [.chest], [], .machine),
        e("machineChestPress", "Machine chest press", .chest, [.chest], [.triceps], .machine),
        e("tBarRow", "T-bar row", .back, [.lats], [.traps, .biceps], .barbell),
        e("uprightRow", "Upright row", .shoulders, [.shoulders, .traps], [.biceps], .barbell, .reps, .swing(high: 45, low: 20)),
        e("stepUp", "Step-up", .legs, [.quads, .glutes], [.calves], .dumbbell),
        e("walkingLunge", "Walking lunge", .legs, [.quads, .glutes], [.hamstrings], .dumbbell),
        e("gluteBridge", "Glute bridge", .legs, [.glutes], [.hamstrings], .bodyweight),
        e("sitUp", "Sit-up", .core, [.abs], [.obliques], .bodyweight),
        e("bicycleCrunch", "Bicycle crunch", .core, [.obliques, .abs], [], .bodyweight),
        e("sidePlank", "Side plank", .core, [.obliques], [.abs, .shoulders], .bodyweight, .seconds),
        e("deadBug", "Dead bug", .core, [.abs], [.obliques], .bodyweight),
        e("abWheel", "Ab wheel rollout", .core, [.abs], [.lats, .shoulders], .other),
        e("cableCrunch", "Cable crunch", .core, [.abs], [.obliques], .cable),
        e("hyperextension", "Back extension", .back, [.lowerBack], [.glutes, .hamstrings], .bodyweight),
        e("goodMorning", "Good morning", .legs, [.hamstrings, .lowerBack], [.glutes], .barbell),
        e("seatedCalfRaise", "Seated calf raise", .legs, [.calves], [], .machine),
        e("hipAbduction", "Hip abduction", .legs, [.glutes], [], .machine),
        e("hipAdduction", "Hip adduction", .legs, [.quads], [], .machine),
        e("cableLateralRaise", "Cable lateral raise", .shoulders, [.shoulders], [], .cable, .reps, .swing(high: 45, low: 20)),
        e("reverseCurl", "Reverse curl", .arms, [.forearms, .biceps], [], .barbell, .reps, curl),
        e("wristCurl", "Wrist curl", .arms, [.forearms], [], .dumbbell, .reps, .swing(high: 35, low: 15)),
        e("reverseWristCurl", "Reverse wrist curl", .arms, [.forearms], [], .dumbbell, .reps, .swing(high: 35, low: 15)),
        e("farmerCarry", "Farmer’s carry", .back, [.forearms, .traps], [.abs, .glutes], .dumbbell, .seconds),
        e("deadHang", "Dead hang", .back, [.forearms, .lats], [.shoulders], .bodyweight, .seconds),
        e("wallSit", "Wall sit", .legs, [.quads], [.glutes], .bodyweight, .seconds),
        e("boxJump", "Box jump", .legs, [.quads, .glutes, .calves], [], .other),
        e("jumpSquat", "Jump squat", .legs, [.quads, .glutes], [.calves], .bodyweight),
        e("pistolSquat", "Pistol squat", .legs, [.quads, .glutes], [.abs], .bodyweight),
        e("nordicCurl", "Nordic curl", .legs, [.hamstrings], [], .bodyweight),
        e("invertedRow", "Inverted row", .back, [.lats], [.biceps, .traps], .bodyweight),
        e("diamondPushUp", "Diamond push-up", .arms, [.triceps], [.chest], .bodyweight),
        e("pikePushUp", "Pike push-up", .shoulders, [.shoulders], [.triceps], .bodyweight),
        e("declineBenchPress", "Decline bench press", .chest, [.chest], [.triceps], .barbell),
        e("landminePress", "Landmine press", .shoulders, [.shoulders, .chest], [.triceps], .barbell),
        e("machineShoulderPress", "Machine shoulder press", .shoulders, [.shoulders], [.triceps], .machine),
        e("straightArmPulldown", "Straight-arm pulldown", .back, [.lats], [.triceps], .cable),
        e("pullover", "Dumbbell pullover", .chest, [.chest, .lats], [.triceps], .dumbbell),
        e("rackPull", "Rack pull", .back, [.lowerBack, .traps], [.glutes, .hamstrings], .barbell),
        e("powerClean", "Power clean", .legs, [.glutes, .hamstrings, .traps], [.quads, .shoulders], .barbell),
        e("thruster", "Thruster", .legs, [.quads, .shoulders], [.glutes, .triceps], .barbell),
        e("turkishGetUp", "Turkish get-up", .core, [.shoulders, .abs], [.glutes], .kettlebell),
        e("battleRopes", "Battle ropes", .cardio, [.shoulders], [.forearms, .abs], .other, .reps, .burst(on: 150, off: 50)),
        e("punches", "Punches", .cardio, [.shoulders], [.triceps, .obliques], .bodyweight, .reps, .burst(on: 180, off: 60)),
        e("rowingMachine", "Rowing machine", .cardio, [.lats, .quads], [.biceps, .hamstrings], .machine, .seconds),
        e("jumpRope", "Jump rope", .cardio, [.calves], [.shoulders, .forearms], .other, .seconds),
        e("sledPush", "Sled push", .cardio, [.quads, .glutes], [.calves, .shoulders], .other, .seconds),
        e("hollowHold", "Hollow hold", .core, [.abs], [], .bodyweight, .seconds),
        e("vUp", "V-up", .core, [.abs], [.obliques], .bodyweight),
        e("legRaise", "Lying leg raise", .core, [.abs], [], .bodyweight),
        e("flutterKicks", "Flutter kicks", .core, [.abs], [.quads], .bodyweight, .seconds),
        e("zottmanCurl", "Zottman curl", .arms, [.biceps, .forearms], [], .dumbbell, .reps, curl),
        e("spiderCurl", "Spider curl", .arms, [.biceps], [], .dumbbell, .reps, curl),
        e("inclineCurl", "Incline dumbbell curl", .arms, [.biceps], [], .dumbbell, .reps, curl),
        e("benchDip", "Bench dip", .arms, [.triceps], [.shoulders], .bodyweight),
        e("cableKickback", "Cable glute kickback", .legs, [.glutes], [.hamstrings], .cable),
        e("singleLegRDL", "Single-leg Romanian deadlift", .legs, [.hamstrings, .glutes], [.lowerBack], .dumbbell),
        e("sissySquat", "Sissy squat", .legs, [.quads], [], .bodyweight),
        e("tibialisRaise", "Tibialis raise", .legs, [.calves], [], .bodyweight),
    ]

    static let byID: [String: Exercise] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    static var allCases: [Exercise] { all }

    static let bicepCurl = byID["bicepCurl"]!
    static let hammerCurl = byID["hammerCurl"]!
    static let lateralRaise = byID["lateralRaise"]!
    static let overheadExtension = byID["overheadExtension"]!
    static let punches = byID["punches"]!
    static let plank = byID["plank"]!
    static let benchPress = byID["benchPress"]!
}
