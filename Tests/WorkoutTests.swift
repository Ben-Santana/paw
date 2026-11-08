// Isolated checks for workouts: the run's set flow, control gestures and rep counting.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Workouts/ExerciseCatalog.swift RunesIOS/Workouts/WorkoutModel.swift \
//       Tests/WorkoutTests.swift -o /private/tmp/runes-workout-tests && /private/tmp/runes-workout-tests
import Foundation

@main
struct WorkoutTests {
    /// A quaternion turned `degrees` about the x axis.
    static func turn(_ degrees: Double) -> [Double] {
        let half = degrees * .pi / 360
        return [cos(half), sin(half), 0, 0]
    }

    static func main() {
        // Set flow: wait → count → log → next set waits again.
        let plan = WorkoutPlan(name: "Arms", items: [WorkoutItem(exercise: .bicepCurl, sets: 2, reps: 10),
                                                    WorkoutItem(exercise: .lateralRaise, sets: 1, reps: 8)])
        var run = WorkoutRun(plan: plan)
        precondition(run.slots.count == 3 && run.phase == .waiting)
        run.rep(); precondition(run.reps == 0, "Reps before the start gesture don't count")
        precondition(run.apply(.stop) == nil && run.phase == .waiting, "Stop does nothing while waiting")
        run.apply(.start); run.rep(); run.rep(); run.rep()
        let log = run.apply(.stop)
        precondition(log?.reps == 3 && log?.slot.set == 1, "Stop logs the set")
        precondition(run.phase == .waiting && run.current?.set == 2 && run.reps == 0, "Moves to set 2 and waits")
        precondition(run.next?.exercise == .lateralRaise)

        // Repeat last set inserts it again before the next one.
        run.apply(.repeatLast)
        precondition(run.current?.set == 1 && run.current?.isRepeat == true && run.slots.count == 4)
        run.apply(.start); run.rep(); run.apply(.stop)
        precondition(run.current?.set == 2 && run.logs.count == 2)

        // Repeat while counting restarts the count.
        run.apply(.start); run.rep(); run.rep(); run.apply(.repeatLast)
        precondition(run.phase == .counting && run.reps == 0, "Repeat restarts the current set")

        // Skip, while counting or waiting, moves on without logging.
        run.apply(.skip)
        precondition(run.logs.count == 2 && run.current?.exercise == .lateralRaise && run.phase == .waiting)
        run.apply(.skip)
        precondition(run.phase == .finished && run.current == nil, "Skipping the last set finishes")
        run.apply(.start); precondition(run.phase == .finished)
        run.apply(.repeatLast)
        precondition(run.phase == .waiting && run.current?.set == 1, "A finished workout can repeat its last set")

        // Controls: one gesture per command; reassigning swaps.
        var controls = WorkoutControls.standard
        precondition(controls.command(for: .doubleTapIndex) == .start)
        controls.set(.doubleTapMiddle, for: .start)
        precondition(controls.gesture(for: .start) == .doubleTapMiddle && controls.gesture(for: .stop) == .doubleTapIndex, "Swapped")
        let decoded = try! JSONDecoder().decode(WorkoutControls.self, from: JSONEncoder().encode(controls))
        precondition(decoded == controls, "Controls round-trip")

        // Swing counting: a rep is a turn past the high threshold after settling under the low one.
        var curl = RepCounter(exercise: .bicepCurl)
        precondition(!curl.orientation(turn(0), at: 0), "First sample sets the start")
        var reps = 0, t = 0.0
        for cycle in 0..<5 {
            for angle in Array(stride(from: 0.0, through: 100, by: 10)) + Array(stride(from: 100.0, through: 0, by: -10)) {
                t += 0.05; if curl.orientation(turn(angle), at: t) { reps += 1 }
            }
            _ = cycle
        }
        precondition(reps == 5, "Five curls, got \(reps)")
        var partial = RepCounter(exercise: .bicepCurl); _ = partial.orientation(turn(0), at: 0)
        precondition(![50.0, 60, 40, 60].enumerated().contains { partial.orientation(turn($1), at: Double($0)) }, "Half reps don't count")
        var wobble = RepCounter(exercise: .bicepCurl); _ = wobble.orientation(turn(0), at: 0)
        precondition(wobble.orientation(turn(80), at: 1))
        precondition(!wobble.orientation(turn(20), at: 1.1) && !wobble.orientation(turn(80), at: 1.2), "Too soon after a rep")
        var gentle = RepCounter(exercise: .bicepCurl, sensitivity: .high); _ = gentle.orientation(turn(0), at: 0)
        precondition(gentle.orientation(turn(60), at: 1), "High sensitivity needs less movement")

        // Burst counting for punches, from the gyroscope.
        var punches = RepCounter(exercise: .punches)
        let samples: [[Double]] = [[10, 0, 0], [150, 120, 0], [20, 0, 0], [0, 200, 0], [190, 0, 0], [10, 10, 0]]
        let counted = samples.enumerated().filter { punches.gyroscope($1, at: Double($0) * 0.4) }.count
        precondition(counted == 2, "Two punches, got \(counted)")
        precondition(!punches.orientation(turn(90), at: 10), "Punches ignore orientation")

        // The feed only counts while a set is active.
        let feed = RepFeed()
        precondition(!feed.ingest(orientation: true, turn(0), at: 0))
        feed.count(.bicepCurl, sensitivity: .normal)
        _ = feed.ingest(orientation: true, turn(0), at: 0)
        precondition(feed.ingest(orientation: true, turn(90), at: 1))
        feed.count(nil, sensitivity: .normal)
        precondition(!feed.isCounting)

        // Exercises the band can't count log their target; timed ones log how long the set ran.
        let start = Date(timeIntervalSince1970: 1000)
        var mixed = WorkoutRun(plan: WorkoutPlan(name: "Mixed", items: [WorkoutItem(exercise: .benchPress, sets: 1, reps: 8, weight: 60),
                                                                         WorkoutItem(exercise: .plank, sets: 1, reps: 45)]), at: start)
        mixed.apply(.start, at: start); mixed.rep()
        let bench = mixed.apply(.stop, at: start.addingTimeInterval(30))
        precondition(bench?.reps == 8 && bench?.weight == 60, "Bench logs its target and weight, got \(String(describing: bench?.reps))")
        mixed.apply(.start, at: start.addingTimeInterval(60))
        let plank = mixed.apply(.stop, at: start.addingTimeInterval(112))
        precondition(plank?.reps == 52, "Plank logs 52 s, got \(String(describing: plank?.reps))")
        precondition(!RepFeed().isCounting)
        let feed2 = RepFeed(); feed2.count(.benchPress, sensitivity: .normal)
        precondition(!feed2.isCounting, "No counter for an exercise the band can't follow")

        // The catalog: unique ids, every exercise trains something, ids survive a round trip, unknown ids still decode.
        precondition(Set(Exercise.all.map(\.id)).count == Exercise.all.count, "Duplicate exercise id")
        precondition(Exercise.all.allSatisfy { !$0.primary.isEmpty })
        let item = try! JSONDecoder().decode(WorkoutItem.self, from: JSONEncoder().encode(WorkoutItem(exercise: .hammerCurl, sets: 2, reps: 9)))
        precondition(item.exercise == .hammerCurl && item.exercise.detectsReps && item.weight == nil)
        let unknown = try! JSONDecoder().decode([Exercise].self, from: Data(#"["somethingNew"]"#.utf8))
        precondition(unknown[0].id == "somethingNew" && !unknown[0].detectsReps)
        print("Exercise catalog: \(Exercise.all.count) exercises, \(Exercise.all.filter(\.detectsReps).count) counted by the band.")

        print("Workout checks passed: set flow, repeat and skip, control gestures, swing and burst rep counting.")
    }
}
