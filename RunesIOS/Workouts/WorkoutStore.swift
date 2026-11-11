import Foundation
import UIKit

/// The split (each day a `WorkoutPlan`), the global control gestures, the journal, and the running workout.
/// While a workout runs, its control gestures are taken here instead of running mappings,
/// and reps come from `feed`, which the session fills from the band's motion streams.
/// Everything works with the phone locked: the Live Activity carries the state.
@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()
    /// Counted on the transport queue; see `SessionController`.
    nonisolated static let feed = RepFeed()
    private static let key = "runes.workouts.v1"
    private static let historyLimit = 1000

    struct Saved: Codable {
        var plans: [WorkoutPlan]
        var controls: WorkoutControls
        var sensitivity: RepSensitivity
        var history: [WorkoutRecord]
        var unit: WeightUnit = .kg

        init(plans: [WorkoutPlan], controls: WorkoutControls, sensitivity: RepSensitivity, history: [WorkoutRecord], unit: WeightUnit) {
            self.plans = plans; self.controls = controls; self.sensitivity = sensitivity; self.history = history; self.unit = unit
        }
        /// Data saved before the split and units existed still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plans = try c.decodeIfPresent([WorkoutPlan].self, forKey: .plans) ?? WorkoutPlan.starterSplit
            controls = try c.decodeIfPresent(WorkoutControls.self, forKey: .controls) ?? .standard
            sensitivity = try c.decodeIfPresent(RepSensitivity.self, forKey: .sensitivity) ?? .normal
            history = try c.decodeIfPresent([WorkoutRecord].self, forKey: .history) ?? []
            unit = try c.decodeIfPresent(WeightUnit.self, forKey: .unit) ?? .kg
        }
    }

    @Published private(set) var plans: [WorkoutPlan]
    @Published private(set) var controls: WorkoutControls { didSet { controlsChanged() } }
    @Published private(set) var sensitivity: RepSensitivity
    @Published private(set) var history: [WorkoutRecord]
    @Published private(set) var unit: WeightUnit
    @Published private(set) var run: WorkoutRun? {
        didSet { if (oldValue == nil) != (run == nil), !previewOnly { onReserve?(reservedNow) } }
    }

    /// Told which gestures a running workout holds (none when nothing runs), so mappings
    /// that use them turn off for as long as it does.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    private var reservedNow: Set<GestureKind> {
        run == nil || yielded ? [] : controls.reserved.union(SwitchControls.reserved(switchMapping))
    }
    /// The switch-controls combo, while this is the app the band switches to and from and
    /// its controls are selected. Set by `ControlSwitch`.
    var switchMapping: Mapping? { didSet { if switchMapping != oldValue { controlsChanged() } } }
    /// True while the regular mappings have the band though a workout runs. Reps still count.
    var yielded = false { didSet { if yielded != oldValue, !previewOnly { onReserve?(reservedNow) } } }
    /// Decides which command a band gesture completes, combos included.
    private let decider = TriggerDecider()
    /// Told whether a workout needs the band's motion streams. Set by the session.
    var onMotionDemand: ((Bool) -> Void)? { didSet { onMotionDemand?(run != nil) } }
    /// Shows the workout on the Live Activity (nil restores band status); the string is an alert.
    var onActivity: ((WorkoutActivityState?, String?) -> Void)?

    private var previewOnly = false

    private init() {
        var saved = Saved(plans: WorkoutPlan.starterSplit, controls: .standard, sensitivity: .normal, history: [], unit: .kg)
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded }
        plans = saved.plans.map { $0.normalized() }
        controls = saved.controls; sensitivity = saved.sensitivity; history = saved.history; unit = saved.unit
        decider.onFire = { [weak self] id in
            guard let self, self.run != nil else { return }
            if id == SwitchControls.mappingID { ControlSwitch.shared.toggle(); return }
            guard let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        decider.configure(controls.mappings)
    }

    private func controlsChanged() {
        guard !previewOnly else { return }
        decider.configure(SwitchControls.adding(switchMapping, to: controls.mappings))
        onReserve?(reservedNow)
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview plans: [WorkoutPlan], run: WorkoutRun? = nil, history: [WorkoutRecord] = []) {
        self.plans = plans; controls = .standard; sensitivity = .normal; self.history = history; self.run = run; unit = .kg
        previewOnly = true
    }
    #endif

    // MARK: Editing

    func save(_ plan: WorkoutPlan) {
        let plan = plan.normalized()
        if let i = plans.firstIndex(where: { $0.id == plan.id }) { plans[i] = plan } else { plans.append(plan) }
        persist()
    }
    func delete(planID: String) { plans.removeAll { $0.id == planID }; persist() }
    func delete(at offsets: IndexSet) { plans.remove(atOffsets: offsets); persist() }
    func duplicate(planID: String) {
        guard let source = plans.first(where: { $0.id == planID }) else { return }
        var copy = source
        copy.id = UUID().uuidString.lowercased(); copy.name = "\(source.name) copy"
        copy.items = copy.items.map { var item = $0; item.id = UUID().uuidString.lowercased(); return item }
        save(copy)
    }
    func setTrigger(_ trigger: CommandTrigger?, for command: WorkoutCommand) { controls.setTrigger(trigger, for: command); persist() }
    func setSensitivity(_ value: RepSensitivity) { sensitivity = value; persist() }
    func setUnit(_ value: WeightUnit) { unit = value; persist() }
    func clearHistory() { history = []; persist() }
    func deleteRecord(_ id: String) { history.removeAll { $0.id == id }; persist() }
    func move(planFrom source: IndexSet, to destination: Int) { plans.move(fromOffsets: source, toOffset: destination); persist() }

    // MARK: Reading

    /// The split day after the one done most recently, or the first.
    var upNext: WorkoutPlan? {
        guard let last = history.first, let i = plans.firstIndex(where: { $0.id == last.planID || $0.name == last.name }) else { return plans.first }
        return plans[(i + 1) % plans.count]
    }

    /// Every logged set, newest first, including the running workout's.
    var allSets: [SetLog] { (run?.logs.reversed() ?? []) + history.flatMap { $0.sets.reversed() } }

    /// 1 for a muscle trained today, fading by a seventh each day after, 0 after a week.
    /// Muscles a set only works second-hand count half.
    func freshness(now: Date = Date()) -> [Muscle: Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var result: [Muscle: Double] = [:]
        for log in allSets {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: log.at), to: today).day ?? 0
            guard days < 7 else { continue }
            let value = max(0, 1 - Double(days) / 7)
            for m in log.exercise.primary { result[m] = max(result[m] ?? 0, value) }
            for m in log.exercise.secondary { result[m] = max(result[m] ?? 0, value * 0.5) }
        }
        return result
    }

    /// Sets that trained a muscle in each calendar week, oldest first, ending with this week.
    /// Sets that only work it second-hand count half.
    func weeklySets(_ muscle: Muscle, weeks: Int = 12, now: Date = Date()) -> [Double] {
        weeklySets(of: [muscle], weeks: weeks, now: now)
    }

    /// The same for a group: a set counts once if it trains any of the muscles first-hand.
    func weeklySets(of muscles: Set<Muscle>, weeks: Int = 12, now: Date = Date()) -> [Double] {
        let calendar = Calendar.current
        guard weeks > 0, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var result = Array(repeating: 0.0, count: weeks)
        for log in allSets {
            let weight = log.exercise.primary.contains(where: muscles.contains) ? 1
                : log.exercise.secondary.contains(where: muscles.contains) ? 0.5 : 0
            guard weight > 0, let start = calendar.dateInterval(of: .weekOfYear, for: log.at)?.start,
                  let ago = calendar.dateComponents([.weekOfYear], from: start, to: thisWeek).weekOfYear,
                  (0..<weeks).contains(ago) else { continue }
            result[weeks - 1 - ago] += weight
        }
        return result
    }

    /// Days since a muscle was last trained first-hand, nil if never.
    func daysSince(_ muscle: Muscle, now: Date = Date()) -> Int? { daysSince(of: [muscle], now: now) }

    /// Days since any of the muscles was last trained first-hand, nil if never.
    func daysSince(of muscles: Set<Muscle>, now: Date = Date()) -> Int? {
        guard let log = allSets.first(where: { $0.exercise.primary.contains(where: muscles.contains) }) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: log.at), to: calendar.startOfDay(for: now)).day
    }

    func weightText(_ weight: Double?) -> String? {
        guard let weight, weight > 0 else { return nil }
        let number = weight.rounded() == weight ? String(Int(weight)) : String(format: "%.1f", weight)
        return "\(number) \(unit.title)"
    }

    private func persist() {
        guard !previewOnly else { return }
        let saved = Saved(plans: plans, controls: controls, sensitivity: sensitivity, history: history, unit: unit)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Running

    func start(_ plan: WorkoutPlan) {
        if run != nil { end() }
        let next = WorkoutRun(plan: plan.normalized())
        guard next.phase != .finished else { return }
        run = next
        onMotionDemand?(true)
        changed()
    }

    /// Ends the workout, keeping any logged sets in history.
    func end() {
        guard let finished = run else { return }
        run = nil
        Self.feed.count(nil, sensitivity: sensitivity)
        onMotionDemand?(false)
        record(finished)
        onActivity?(nil, nil)
    }

    func perform(_ command: WorkoutCommand) {
        guard var current = run else { return }
        let logged = current.apply(command)
        run = current
        changed(alert: logged.map { "\($0.slot.exercise.name), \($0.slot.label.lowercased()): \(Self.value($0))" })
    }

    /// Takes a band gesture that is one of the workout controls while a workout runs.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard run != nil, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }

    /// Takes a rotation or movement from the band's motion while a workout runs and one
    /// of its combos uses it. Returns false to let mappings have it.
    func consume(_ step: ComboStep) -> Bool {
        guard run != nil, reservedNow.contains(step.gesture) else { return false }
        decider.receive(step)
        return true
    }

    /// The band's orientation, for air steps in a workout's combos.
    func orientation(_ q: [Double]) {
        if run != nil, controls.usesMotion { decider.orientation(q) }
    }

    /// A rep counted from the band's motion.
    func rep() {
        guard var current = run, current.phase == .counting else { return }
        current.rep()
        run = current
        changed()
    }

    private func changed(alert: String? = nil) {
        guard let run else { return }
        // Entering a set, or restarting one, starts a fresh count; anything else stops it.
        if run.phase == .counting {
            if run.reps == 0 { Self.feed.count(run.current?.exercise, sensitivity: sensitivity) }
        } else {
            Self.feed.count(nil, sensitivity: sensitivity)
        }
        if run.phase == .finished { record(run) }
        guard !previewOnly else { return }
        onActivity?(activityState(run), alert)
    }

    /// Saves a run's sets to history when it finishes or is ended. A run that carries on
    /// after finishing (repeat last set) updates its own entry.
    private func record(_ run: WorkoutRun) {
        guard !run.logs.isEmpty else { return }
        let entry = WorkoutRecord(name: run.name, planID: run.planID, started: run.started, ended: Date(), sets: run.logs)
        if let i = history.firstIndex(where: { $0.started == run.started && $0.name == run.name }) {
            history[i].sets = entry.sets; history[i].ended = entry.ended
        } else {
            history.insert(entry, at: 0)
            history = Array(history.prefix(Self.historyLimit))
        }
        persist()
    }

    // MARK: Text

    static func reps(_ n: Int) -> String { n == 1 ? "1 rep" : "\(n) reps" }
    static func target(_ slot: WorkoutSlot) -> String { slot.exercise.measure == .seconds ? "\(slot.target) s" : reps(slot.target) }
    static func value(_ log: SetLog) -> String { log.exercise.measure == .seconds ? "\(log.reps) s" : reps(log.reps) }

    func activityState(_ run: WorkoutRun) -> WorkoutActivityState {
        let last = run.last.map { "Last: \($0.slot.exercise.name), set \($0.slot.set): \(Self.value($0))" }
        guard let slot = run.current else {
            let total = run.logs.filter { $0.exercise.measure == .reps }.reduce(0) { $0 + $1.reps }
            return WorkoutActivityState(title: "Workout done", detail: "\(run.logs.count) sets · \(Self.reps(total))",
                                        status: "Saved to history", isCounting: false, reps: 0, last: last, next: nil, finished: true)
        }
        let status: String
        switch run.phase {
        case .counting:
            let doing = slot.assumed ? "In progress" : "Counting"
            status = controls.trigger(for: .stop).map { "\(doing) · \($0.name.lowercased()) to stop" } ?? doing
        default:
            status = controls.trigger(for: .start).map { "\($0.name) to start" } ?? "Waiting to start"
        }
        let next = run.next.map { "Next: \($0.exercise.name), \($0.label.lowercased())" } ?? "Last set"
        return WorkoutActivityState(title: slot.exercise.name, detail: "\(slot.label) · \(Self.target(slot))",
                                    status: status, isCounting: run.phase == .counting, reps: run.reps,
                                    last: last, next: next, finished: false, group: slot.exercise.group)
    }
}
