import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if NeuralIOSApp.snapshotName != nil { return true }
        UNUserNotificationCenter.current().delegate = self
        // Instantiate during launch, including a Core Bluetooth restoration launch.
        _ = SessionController.shared
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
    func applicationDidBecomeActive(_ application: UIApplication) { lifecycle("foreground") }
    func applicationWillResignActive(_ application: UIApplication) { lifecycle("inactive") }
    func applicationDidEnterBackground(_ application: UIApplication) { lifecycle("background") }
    func applicationWillEnterForeground(_ application: UIApplication) { lifecycle("inactive") }
    private func lifecycle(_ state: String) {
        guard NeuralIOSApp.snapshotName == nil else { return }
        SessionController.shared.lifecycle(state)
    }
}

@main
struct NeuralIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG only: show one fixed screen for screenshots, without starting the session.
    static var snapshotName: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["NEURAL_SNAPSHOT"]
        #else
        nil
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let name = Self.snapshotName { SnapshotGallery(name: name) } else { live }
            #else
            live
            #endif
        }
    }

    private var live: some View {
        RootView(controller: .shared)
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: SessionController.shared.lifecycle("foreground")
                case .background: SessionController.shared.lifecycle("background")
                default: SessionController.shared.lifecycle("inactive")
                }
            }
    }
}
