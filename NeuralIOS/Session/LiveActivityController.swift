import Foundation
import ActivityKit
import UserNotifications

@MainActor
final class LiveActivityController {
    static let reminderPrefix = "neural.live-activity.expiry."
    private static let lifetime: TimeInterval = 8 * 60 * 60
    private static let reminderLead: TimeInterval = 15 * 60

    private var activity: Activity<BandActivityAttributes>?
    private var lastStatus: String?
    private var updateTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private(set) var message: String?
    var onChange: (() -> Void)?

    init() {
        if let existing = Activity<BandActivityAttributes>.activities.first(where: Self.isActive) {
            adopt(existing, requestReminderPermission: false)
        }
    }

    private static func isActive(_ activity: Activity<BandActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    func canRenew(at date: Date) -> Bool {
        guard let activity, Self.isActive(activity) else { return true }
        return activity.attributes.startedAt.addingTimeInterval(Self.lifetime - Self.reminderLead) <= date
    }

    func start() {
        if let activity, Self.isActive(activity) { return }
        replace(with: .connecting)
    }

    func renew(_ state: SessionState) {
        guard canRenew(at: Date()) else { return }
        replace(with: state)
    }

    private func replace(with state: SessionState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities are disabled in Settings."
            onChange?()
            return
        }
        do {
            let replacement = try Activity.request(attributes: BandActivityAttributes(startedAt: Date()),
                                                   content: content(for: state), pushType: nil)
            let previous = activity
            message = nil
            adopt(replacement, requestReminderPermission: true)
            if let previous { retire(previous) }
            lastStatus = state.rawValue
        } catch {
            message = "Could not start the Live Activity. Try again."
            onChange?()
        }
    }

    private func content(for state: SessionState) -> ActivityContent<BandActivityAttributes.ContentState> {
        ActivityContent(state: .init(status: state.title, isConnected: state == .streaming),
                        staleDate: Date().addingTimeInterval(60))
    }

    private func adopt(_ activity: Activity<BandActivityAttributes>, requestReminderPermission: Bool) {
        updateTask?.cancel()
        stateTask?.cancel()
        reminderTask?.cancel()
        self.activity = activity
        lastStatus = nil
        stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == activity.id else { return }
                if state == .ended || state == .dismissed {
                    self.removeReminder(for: activity)
                    self.reminderTask?.cancel()
                    self.activity = nil
                    self.lastStatus = nil
                    self.onChange?()
                    return
                }
            }
        }
        reminderTask = Task { [weak self] in
            await self?.scheduleReminder(for: activity, requestPermission: requestReminderPermission)
        }
        onChange?()
    }

    private func scheduleReminder(for activity: Activity<BandActivityAttributes>, requestPermission: Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if requestPermission, settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            return
        }
        guard !Task.isCancelled, self.activity?.id == activity.id, Self.isActive(activity) else { return }
        let time = activity.attributes.startedAt.addingTimeInterval(Self.lifetime - Self.reminderLead)
        let delay = time.timeIntervalSinceNow
        guard delay > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Neural Live Activity"
        content.body = "Your Live Activity is ending soon. Open Neural to renew it in Diagnostics."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.reminderPrefix + activity.id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        do {
            try await center.add(request)
            if Task.isCancelled || self.activity?.id != activity.id { removeReminder(for: activity) }
        } catch {
            guard !Task.isCancelled, self.activity?.id == activity.id else { return }
            message = "Could not schedule the Live Activity reminder."
            onChange?()
        }
    }

    private func removeReminder(for activity: Activity<BandActivityAttributes>) {
        let id = Self.reminderPrefix + activity.id
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    func update(_ state: SessionState, desired: Bool) {
        guard let activity else { return }
        guard desired else { end(); return }
        guard Self.isActive(activity), lastStatus != state.rawValue else { return }
        lastStatus = state.rawValue
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await activity.update(content(for: state))
        }
    }

    private func retire(_ activity: Activity<BandActivityAttributes>) {
        removeReminder(for: activity)
        Task { await activity.end(content(for: .disconnected), dismissalPolicy: .immediate) }
    }

    func end() {
        updateTask?.cancel()
        stateTask?.cancel()
        reminderTask?.cancel()
        guard let previous = activity else { return }
        activity = nil
        lastStatus = nil
        retire(previous)
        onChange?()
    }
}
