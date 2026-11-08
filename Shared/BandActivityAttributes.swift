import ActivityKit
import Foundation

struct BandActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var isConnected: Bool
        /// Band battery 0–100, shown as a ring; nil until the band reports it.
        var battery: Int? = nil
        /// Whether a paired Mac is linked right now.
        var macConnected: Bool = false
        /// Present while a workout runs; the Lock Screen then shows it instead of the band status.
        var workout: WorkoutActivityState? = nil
    }
    let startedAt: Date
}

/// Ready-to-show workout text, written by the app so the widget only lays it out.
struct WorkoutActivityState: Codable, Hashable {
    /// Exercise for the current set, or "Workout done".
    var title: String
    /// "Set 2 of 3 · 12 reps".
    var detail: String
    /// "Double tap index to start" or "Counting".
    var status: String
    var isCounting: Bool
    /// Reps so far in the set being counted.
    var reps: Int
    /// "Bicep curl, set 1: 12 reps".
    var last: String?
    /// "Next: Lateral raise, set 1 of 3".
    var next: String?
    var finished: Bool
}
