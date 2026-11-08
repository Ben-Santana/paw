import Foundation
import ActivityKit

/// A minimal Lock Screen status. It does not affect background execution; the band pulse
/// subscription does that. No expiry reminders: iOS ends the activity when it chooses.
@MainActor
final class LiveActivityController {
    private var activity: Activity<BandActivityAttributes>?
    private var lastPhase: BandPhase?
    private var updateTask: Task<Void, Never>?

    init() {
        activity = Activity<BandActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    func start() {
        if let activity, activity.activityState == .active || activity.activityState == .stale { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: BandActivityAttributes(startedAt: Date()), content: content(.connecting), pushType: nil)
        lastPhase = .connecting
    }

    func update(_ snapshot: SessionSnapshot) {
        guard let activity else { return }
        guard snapshot.wantsConnection else { end(); return }
        let phase = BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase
        guard phase != lastPhase else { return }
        lastPhase = phase
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await activity.update(content(phase))
        }
    }

    private func content(_ phase: BandPhase) -> ActivityContent<BandActivityAttributes.ContentState> {
        ActivityContent(state: .init(status: phase.title, isConnected: phase == .connected), staleDate: Date().addingTimeInterval(60))
    }

    func end() {
        updateTask?.cancel()
        guard let previous = activity else { return }
        activity = nil; lastPhase = nil
        Task { await previous.end(content(.paused), dismissalPolicy: .immediate) }
    }
}
