import Foundation

// A recipe being cooked: which step is showing, which of the step's timers is selected,
// the timers started so far, and the ingredients ticked off. Pure value types, so they
// are tested without a band or a clock (Tests/CookTests.swift); every method that
// depends on the time takes it.

/// What the band (or a button) can do while cooking.
enum CookCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case next, previous, timer, addMinute, reset, timerDown, timerUp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: "Next step"
        case .previous: "Previous step"
        case .timer: "Start or pause the timer"
        case .addMinute: "Add a minute"
        case .reset: "Reset the timer"
        case .timerDown: "Next timer"
        case .timerUp: "Previous timer"
        }
    }
    var detail: String {
        switch self {
        case .next: "After the last step, finishes the recipe."
        case .previous: "Goes back a step."
        case .timer: "Starts the selected timer, pauses it, and starts it again. When a timer rings, stops it."
        case .addMinute: "Gives the selected timer another minute, also after it rang."
        case .reset: "Puts the selected timer back to its full time, not running."
        case .timerDown: "On a step with more than one time, selects the next."
        case .timerUp: "On a step with more than one time, selects the one before."
        }
    }
}

/// Which gesture does what while cooking.
struct CookControls: Codable, Hashable, Sendable {
    var gestures: [CookCommand: GestureKind]

    /// Side swipes turn the page and up and down move between a step's timers, as on
    /// screen. The index finger runs the selected timer. Double taps, because one pinch
    /// happens by itself when hands are busy with a knife or a pan.
    static let standard = CookControls(gestures: [
        .next: .swipeRight, .previous: .swipeLeft, .timer: .doubleTapIndex, .addMinute: .doubleTapMiddle,
        .reset: .holdMiddle, .timerDown: .swipeDown, .timerUp: .swipeUp,
    ])
    static let choices = GestureKind.motions

    func gesture(for command: CookCommand) -> GestureKind? { gestures[command] }
    func command(for gesture: GestureKind) -> CookCommand? {
        CookCommand.allCases.first { gestures[$0] == gesture }
    }
    /// Assigns a gesture; a command that already had it takes this command's old one.
    mutating func set(_ gesture: GestureKind?, for command: CookCommand) {
        if let gesture, let other = self.command(for: gesture), other != command { gestures[other] = gestures[command] }
        gestures[command] = gesture
    }

    /// The gestures cooking takes; mappings that use one are off until it ends. A double
    /// tap arrives after the tap that began it and a hold ends with a release, so those
    /// are taken with them.
    var reserved: Set<GestureKind> {
        var set = Set(gestures.values)
        if set.contains(.doubleTapIndex) { set.insert(.tapIndex) }
        if set.contains(.doubleTapMiddle) { set.insert(.tapMiddle) }
        if set.contains(.holdIndex) { set.insert(.releaseIndex) }
        if set.contains(.holdMiddle) { set.insert(.releaseMiddle) }
        return set
    }

    private enum Keys: String, CodingKey { case gestures, version }
    /// 2 added reset and moving between a step's timers.
    private static let version = 2

    init(gestures: [CookCommand: GestureKind]) { self.gestures = gestures }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        gestures = try c.decode([CookCommand: GestureKind].self, forKey: .gestures)
        // Settings saved before a command existed get its usual gesture, if it is free.
        // After that, "None" is a choice and stays.
        if ((try? c.decode(Int.self, forKey: .version)) ?? 1) < 2 {
            for command in [CookCommand.reset, .timerDown, .timerUp] where gestures[command] == nil {
                if let usual = Self.standard.gestures[command], self.command(for: usual) == nil { gestures[command] = usual }
            }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(gestures, forKey: .gestures)
        try c.encode(Self.version, forKey: .version)
    }
}

/// A timer started from a step. It runs from the moment it is started to `end`, unless
/// it is paused; after `end` it rings until it is stopped.
struct CookTimer: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString.lowercased()
    /// The step it belongs to and which of the step's times it is.
    var step: Int
    var slot: Int
    /// "Simmer", or "Step 3" when the step doesn't say.
    var label: String
    var total: Int
    var end: Date
    /// Set when a ringing timer is stopped.
    var stopped = false
    /// Seconds left while paused; nil while it runs. `end` means nothing while paused.
    var paused: Int? = nil

    var isPaused: Bool { paused != nil }
    func remaining(at now: Date) -> Int { paused ?? max(0, Int(end.timeIntervalSince(now).rounded(.up))) }
    func isRunning(at now: Date) -> Bool { paused == nil && end > now }
    func isRinging(at now: Date) -> Bool { paused == nil && end <= now && !stopped }
    /// Running, paused or ringing: anything still worth watching.
    var isLive: Bool { !stopped }
    /// 0 just started → 1 finished.
    func progress(at now: Date) -> Double {
        guard total > 0 else { return 1 }
        let left = paused.map(Double.init) ?? end.timeIntervalSince(now)
        return min(1, max(0, 1 - left / Double(total)))
    }
}

/// What a command did, for the sound and the Lock Screen.
enum CookEvent: Equatable, Sendable {
    case step(Int)
    case finished
    case started(CookTimer)
    case paused(CookTimer)
    case resumed(CookTimer)
    case stopped
    case extended(CookTimer)
    case reset
    /// Another of the step's timers was selected; carries its position.
    case selected(Int)
}

struct CookSession: Codable, Equatable, Sendable {
    var recipe: Recipe
    private(set) var step = 0
    private(set) var timers: [CookTimer] = []
    /// Ingredients ticked off, by position.
    private(set) var ready: Set<Int> = []
    private(set) var finished = false
    var started: Date
    /// Which of the current step's times is selected; nil is the first.
    private var chosen: Int? = nil

    init(recipe: Recipe, at now: Date = Date()) { self.recipe = recipe; started = now }

    var count: Int { recipe.steps.count }
    var text: String { recipe.steps.indices.contains(step) ? recipe.steps[step] : "" }
    var isLast: Bool { step >= count - 1 }
    var durations: [StepDuration] { recipe.durations(step: step) }

    /// The one of the current step's times that commands act on. Timers are started,
    /// paused, reset and given a minute one at a time; this says which.
    var slot: Int {
        let last = durations.count - 1
        return last < 0 ? 0 : min(max(chosen ?? 0, 0), last)
    }
    /// The selected time's timer, once it has been started.
    var selectedTimer: CookTimer? { durations.isEmpty ? nil : timer(step: step, slot: slot) }

    func timer(step: Int, slot: Int) -> CookTimer? { timers.last { $0.step == step && $0.slot == slot } }
    func running(at now: Date) -> [CookTimer] { timers.filter { $0.isRunning(at: now) }.sorted { $0.end < $1.end } }
    func ringing(at now: Date) -> [CookTimer] { timers.filter { $0.isRinging(at: now) } }
    /// Timers still counting, paused or ringing, the one with least time left first:
    /// the ones worth showing everywhere.
    func live(at now: Date) -> [CookTimer] {
        timers.filter(\.isLive).sorted { ($0.remaining(at: now), $0.step, $0.slot) < ($1.remaining(at: now), $1.step, $1.slot) }
    }
    /// The next moment something rings, for a wake-up.
    func nextEnd(after now: Date) -> Date? { timers.filter { $0.isRunning(at: now) }.map(\.end).min() }

    @discardableResult
    mutating func apply(_ command: CookCommand, at now: Date = Date()) -> CookEvent? {
        switch command {
        case .next:
            guard !finished else { return nil }
            if isLast { finished = true; return .finished }
            step += 1; chosen = nil
            return .step(step)
        case .previous:
            if finished { finished = false; return .step(step) }
            guard step > 0 else { return nil }
            step -= 1; chosen = nil
            return .step(step)
        case .timer:
            // A ringing timer is the urgent thing, whichever step is showing.
            if !ringing(at: now).isEmpty { stopRinging(at: now); return .stopped }
            guard !finished, !durations.isEmpty else { return nil }
            return toggle(step: step, slot: slot, at: now)
        case .addMinute:
            guard let index = extendable(at: now) else { return nil }
            return addMinute(to: timers[index].id, at: now).map(CookEvent.extended)
        case .reset:
            guard !finished, let timer = selectedTimer else { return nil }
            cancel(timer.id)
            return .reset
        case .timerDown, .timerUp:
            let count = durations.count
            guard !finished, count > 1 else { return nil }
            // Round and round, so two timers swap with either swipe.
            chosen = (slot + (command == .timerDown ? 1 : -1) + count) % count
            return .selected(slot)
        }
    }

    /// The timer another minute goes to: one that is ringing, else the selected one if
    /// it is counting or paused, else the one with least time left.
    private func extendable(at now: Date) -> Int? {
        if let ringing = timers.lastIndex(where: { $0.isRinging(at: now) }) { return ringing }
        if let selected = selectedTimer, selected.isLive, !finished { return timers.firstIndex { $0.id == selected.id } }
        return live(at: now).first.flatMap { soonest in timers.firstIndex { $0.id == soonest.id } }
    }

    /// Another minute for one timer. A timer that already rang starts again with a minute.
    @discardableResult
    mutating func addMinute(to id: String, at now: Date = Date()) -> CookTimer? {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        if let left = timers[index].paused {
            timers[index].paused = left + 60
            timers[index].total += 60
        } else {
            let rang = !timers[index].isRunning(at: now)
            timers[index].end = max(timers[index].end, now).addingTimeInterval(60)
            timers[index].total = rang ? 60 : timers[index].total + 60
            timers[index].stopped = false
        }
        return timers[index]
    }

    /// The main button for one of a step's times: start it, pause it, start it again, or
    /// stop it ringing. One that rang and was stopped starts afresh.
    @discardableResult
    mutating func toggle(step: Int, slot: Int, at now: Date = Date()) -> CookEvent? {
        guard let existing = timer(step: step, slot: slot), let index = timers.firstIndex(where: { $0.id == existing.id }),
              existing.isLive else {
            return start(step: step, slot: slot, at: now).map(CookEvent.started)
        }
        if existing.isRinging(at: now) {
            timers[index].stopped = true
            return .stopped
        }
        if let left = existing.paused {
            timers[index].paused = nil
            timers[index].end = now.addingTimeInterval(Double(left))
            return .resumed(timers[index])
        }
        timers[index].paused = existing.remaining(at: now)
        return .paused(timers[index])
    }

    /// Starts one of a step's times from the top. Starting it again replaces the earlier one.
    @discardableResult
    mutating func start(step: Int, slot: Int, at now: Date = Date()) -> CookTimer? {
        let durations = recipe.durations(step: step)
        guard durations.indices.contains(slot) else { return nil }
        timers.removeAll { $0.step == step && $0.slot == slot }
        let duration = durations[slot]
        let timer = CookTimer(step: step, slot: slot, label: duration.label ?? "Step \(step + 1)", total: duration.seconds,
                              end: now.addingTimeInterval(Double(duration.seconds)))
        timers.append(timer)
        return timer
    }

    /// Puts a time back as it was before it was started.
    mutating func reset(step: Int, slot: Int) { timers.removeAll { $0.step == step && $0.slot == slot } }

    mutating func cancel(_ id: String) { timers.removeAll { $0.id == id } }

    mutating func stopRinging(at now: Date = Date()) {
        for index in timers.indices where timers[index].isRinging(at: now) { timers[index].stopped = true }
    }

    /// Selects one of the current step's times.
    mutating func select(slot: Int) {
        guard durations.indices.contains(slot) else { return }
        chosen = slot
    }

    /// Shows a step, with one of its times selected.
    mutating func go(to index: Int, slot: Int? = nil) {
        guard recipe.steps.indices.contains(index) else { return }
        step = index; finished = false; chosen = slot
    }

    mutating func toggle(ingredient index: Int) {
        guard recipe.ingredients.indices.contains(index) else { return }
        if ready.contains(index) { ready.remove(index) } else { ready.insert(index) }
    }

    /// "Step 3 of 8".
    var position: String { finished ? "Done" : "Step \(step + 1) of \(count)" }
}
