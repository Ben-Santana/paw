import ActivityKit
import Foundation
import SwiftUI

struct BandActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var isConnected: Bool
        /// Band battery 0–100, shown as a ring; nil until the band reports it.
        var battery: Int? = nil
        /// Whether a paired Mac is linked right now.
        var macConnected: Bool = false
        /// Icon key of the active mapping profile (ProfileIcon.swift); the Runes mark when nil.
        var profileIcon: String? = nil
        /// Present while a workout runs; the Lock Screen then shows it instead of the band status.
        var workout: WorkoutActivityState? = nil
        /// Present while a game is being scored; shown when no workout is running.
        var score: ScoreActivityState? = nil
    }
    let startedAt: Date
}

/// The players of a game being scored from the band.
struct ScoreActivityState: Codable, Hashable {
    var names: [String]
    var scores: [Int]
    /// Each player's index into `ScoreTint`.
    var tints: [Int] = []
    /// The player the band changes, when there are more than two.
    var selected: Int? = nil
}

/// The players' colours, each with the ink that reads on it. Score is the one place Runes
/// uses colour, so players can be told apart at a glance.
enum ScoreTint {
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    /// Vermilion, cobalt, lime, lilac, amber, teal.
    private static let fills: [UInt32] = [0xFF5234, 0x2C4BFF, 0xC9F53A, 0xB79AFF, 0xFFC83D, 0x12C9AC]
    private static let inks: [UInt32] = [0x1F0600, 0xF3F5FF, 0x141A00, 0x150A33, 0x211500, 0x00201B]
    static func fill(_ tint: Int) -> Color { rgb(fills[abs(tint) % fills.count]) }
    static func ink(_ tint: Int) -> Color { rgb(inks[abs(tint) % inks.count]) }
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
    /// The current exercise's group, drawn as its muscle glyph; nil once the workout is done.
    var group: ExerciseGroup? = nil
}
