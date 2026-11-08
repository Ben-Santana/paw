import ActivityKit
import Foundation

struct BandActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var isConnected: Bool
    }
    let startedAt: Date
}
