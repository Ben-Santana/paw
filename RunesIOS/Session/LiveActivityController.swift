import Foundation
import ActivityKit

/// A minimal Lock Screen status. It does not affect background execution; the band pulse
/// subscription does that. No expiry reminders: iOS ends the activity when it chooses.
/// While a workout runs it shows the workout instead, so the phone can stay locked.
@MainActor
final class LiveActivityController {
    private var activity: Activity<BandActivityAttributes>?
    private var lastPhase: BandPhase?
    private var battery: Int?
    private var macConnected = false
    private var profileIcon: String?
    private var workout: WorkoutActivityState?
    private var score: ScoreActivityState?
    private var cook: CookActivityState?
    /// True while the regular mappings have the band though an app runs (`ControlSwitch`).
    private var regular = false
    private var bandWanted = false
    private var scoreTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var workoutTask: Task<Void, Never>?
    /// Rep counts update at most this often; set changes go out at once.
    private static let repInterval: Duration = .seconds(1)
    private var lastSent = ContinuousClock.now - .seconds(10)

    init() {
        activity = Activity<BandActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    func start() {
        if let activity, activity.activityState == .active || activity.activityState == .stale { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let phase = lastPhase ?? .connecting
        activity = try? Activity.request(attributes: BandActivityAttributes(startedAt: Date()), content: content(phase), pushType: nil)
        lastPhase = phase
    }

    func update(_ snapshot: SessionSnapshot) {
        bandWanted = snapshot.wantsConnection
        guard let activity else { return }
        // A recipe's timers stay on the Lock Screen without the band.
        guard snapshot.wantsConnection || cook != nil else { end(); return }
        let phase = BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase
        guard phase != lastPhase || snapshot.battery != battery else { return }
        lastPhase = phase; battery = snapshot.battery
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await activity.update(content(phase))
        }
    }

    /// Mac link on or off; pushes an update only when it changes.
    func setMac(connected: Bool) {
        guard connected != macConnected else { return }
        macConnected = connected
        guard let activity, let phase = lastPhase else { return }
        Task { await activity.update(content(phase)) }
    }

    /// The active profile's icon; pushes an update only when it changes.
    func setProfile(icon: String) {
        guard icon != profileIcon else { return }
        profileIcon = icon
        guard let activity, let phase = lastPhase else { return }
        Task { await activity.update(content(phase)) }
    }

    /// Shows a workout, or the band status again with nil. `alert` lights the Lock Screen
    /// with a sound, for a logged set. Rep-only changes are throttled to save the update budget.
    func show(workout state: WorkoutActivityState?, alert: String? = nil) {
        let repOnly = state != nil && workout != nil && alert == nil && state?.title == workout?.title
            && state?.detail == workout?.detail && state?.status == workout?.status
        workout = state
        if activity == nil, state != nil { start() }
        guard let activity else { return }
        let phase = lastPhase ?? .connected
        workoutTask?.cancel()
        let wait = repOnly ? max(.zero, Self.repInterval - (ContinuousClock.now - lastSent)) : .zero
        workoutTask = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            self.lastSent = .now
            if let alert {
                await activity.update(content(phase), alertConfiguration: AlertConfiguration(title: "Set logged", body: "\(alert)", sound: .default))
            } else {
                await activity.update(content(phase))
            }
        }
    }

    /// Shows a game's score, or the band status again with nil. `alert` lights the Lock Screen
    /// with a sound, for a change made from the band.
    func show(score state: ScoreActivityState?, alert: String? = nil) {
        score = state
        if activity == nil, state != nil { start() }
        guard let activity else { return }
        let phase = lastPhase ?? .connected
        scoreTask?.cancel()
        scoreTask = Task {
            guard !Task.isCancelled else { return }
            if let alert {
                await activity.update(content(phase), alertConfiguration: AlertConfiguration(title: "Score", body: "\(alert)", sound: .default))
            } else {
                await activity.update(content(phase))
            }
        }
    }

    /// Shows the recipe being cooked, or the band status again with nil.
    func show(cook state: CookActivityState?, alert: LiveAlert? = nil) { cook = state; push(alert) }

    /// While the regular mappings have the band, the running app steps aside here too: the
    /// activity shows the band status, as it does with no app running. The app's state is
    /// kept and comes back with its controls. `alert` is for a switch made with the phone locked.
    func show(regular on: Bool, alert: LiveAlert? = nil) {
        guard on != regular || alert != nil else { return }
        regular = on
        guard activity != nil else { return }
        push(alert)
    }

    /// Sends the current state; `alert` lights the Lock Screen with a sound.
    private func push(_ alert: LiveAlert?) {
        if activity == nil, cook != nil { start() }
        guard let activity else { return }
        // Nothing left to show and no band session to report: take it down.
        if cook == nil, workout == nil, score == nil, !bandWanted { end(); return }
        let phase = lastPhase ?? .connected
        Task {
            if let alert {
                await activity.update(content(phase), alertConfiguration: AlertConfiguration(title: "\(alert.title)", body: "\(alert.body)", sound: .default))
            } else {
                await activity.update(content(phase))
            }
        }
    }

    private func content(_ phase: BandPhase) -> ActivityContent<BandActivityAttributes.ContentState> {
        // A workout or a game can sit unchanged for a while; keep it from going stale too soon.
        // A simmering pot sits for longer still.
        let quiet: TimeInterval = cook != nil ? 4 * 3600 : workout != nil || score != nil ? 15 * 60 : 60
        return ActivityContent(state: .init(status: phase.title, isConnected: phase == .connected, battery: battery, macConnected: macConnected,
                                            profileIcon: profileIcon, workout: regular ? nil : workout, score: regular ? nil : score, cook: regular ? nil : cook),
                               staleDate: Date().addingTimeInterval(quiet))
    }

    func end() {
        updateTask?.cancel(); workoutTask?.cancel(); scoreTask?.cancel()
        guard let previous = activity else { return }
        activity = nil; lastPhase = nil; battery = nil
        Task { await previous.end(content(.paused), dismissalPolicy: .immediate) }
    }
}
