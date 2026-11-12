import Foundation

/// The Runes applications as the Home Screen widgets know them, and the `runes://app/<id>`
/// link that opens each one. Ids match `RunesApp` in the app.
enum AppLink: String, CaseIterable, Sendable {
    case workouts, score, cook, capture, reels

    static let scheme = "runes"

    var title: String {
        switch self {
        case .workouts: "Workouts"
        case .score: "Score"
        case .cook: "Cook"
        case .capture: "Capture"
        case .reels: "Reels"
        }
    }

    /// Lucide path data, the same icons the app's Applications list uses.
    var paths: [String] {
        switch self {
        case .workouts: LucideData.dumbbell
        case .score: LucideData.gamepad2
        case .cook: LucideData.chefHat
        case .capture: LucideData.mic
        case .reels: LucideData.video
        }
    }

    var url: URL { URL(string: "\(Self.scheme)://app/\(rawValue)")! }

    /// The app a `runes://app/<id>` link opens, or nil for any other link.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "app", let id = url.pathComponents.dropFirst().first else { return nil }
        self.init(rawValue: id)
    }
}
