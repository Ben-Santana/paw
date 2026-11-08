import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Instantiate during launch, including a Core Bluetooth restoration launch.
        UNUserNotificationCenter.current().delegate = self
        _ = SessionController.shared
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("neural.live-activity.expiry.") ? [.banner, .sound] : []
    }
    func applicationDidBecomeActive(_ application: UIApplication) { SessionController.shared.lifecycle("foreground") }
    func applicationWillResignActive(_ application: UIApplication) { SessionController.shared.lifecycle("inactive") }
    func applicationDidEnterBackground(_ application: UIApplication) { SessionController.shared.lifecycle("background") }
    func applicationWillEnterForeground(_ application: UIApplication) { SessionController.shared.lifecycle("inactive") }
}

@main
struct NeuralIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(controller: .shared)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: SessionController.shared.lifecycle("foreground")
                    case .background: SessionController.shared.lifecycle("background")
                    default: SessionController.shared.lifecycle("inactive")
                    }
                }
        }
    }
}
