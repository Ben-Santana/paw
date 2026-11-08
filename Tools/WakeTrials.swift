import Foundation

/// Timed gesture prompts for the locked-phone wake test. Holds no Bluetooth state.
struct WakeTrials {
    enum Action: Equatable { case prompt(Int), missed(Int), finished }
    struct Result: Equatable {
        let index: Int
        let dueAfter: TimeInterval
        /// Prompt to first gesture received on the Mac. Nil means no gesture arrived in the window.
        let latency: TimeInterval?
    }

    let schedule: [TimeInterval]
    let window: TimeInterval
    private(set) var results: [Result] = []
    private var startedAt: Date?
    private var next = 0
    private var active: (index: Int, promptedAt: Date)?

    var isRunning: Bool { startedAt != nil }

    init(schedule: [TimeInterval], window: TimeInterval) {
        self.schedule = schedule
        self.window = window
    }

    mutating func start(at date: Date) {
        startedAt = date
        results = []
        next = 0
        active = nil
    }

    mutating func cancel() {
        startedAt = nil
        active = nil
    }

    mutating func tick(now: Date) -> [Action] {
        guard let startedAt else { return [] }
        var actions: [Action] = []
        while true {
            if let current = active {
                guard now.timeIntervalSince(current.promptedAt) >= window else { return actions }
                results.append(Result(index: current.index, dueAfter: schedule[current.index], latency: nil))
                actions.append(.missed(current.index))
                active = nil
            }
            guard next < schedule.count else {
                self.startedAt = nil
                actions.append(.finished)
                return actions
            }
            let due = startedAt.addingTimeInterval(schedule[next])
            guard now >= due else { return actions }
            active = (next, due)
            actions.append(.prompt(next))
            next += 1
        }
    }

    mutating func gesture(at date: Date) -> Result? {
        guard let current = active else { return nil }
        let result = Result(index: current.index, dueAfter: schedule[current.index],
                            latency: date.timeIntervalSince(current.promptedAt))
        results.append(result)
        active = nil
        return result
    }

    /// Phone clock minus Mac clock, assuming the two halves of the round trip are equal.
    static func clockOffset(sent: Date, phone: Date, received: Date) -> TimeInterval {
        phone.timeIntervalSince(sent) - received.timeIntervalSince(sent) / 2
    }
}
