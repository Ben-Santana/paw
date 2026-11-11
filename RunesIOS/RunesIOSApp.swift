import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Lets `OrientationLock` know how the phone is held while the interface is upright.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if RunesIOSApp.snapshotName != nil { return true }
        UNUserNotificationCenter.current().delegate = self
        // Instantiate during launch, including a Core Bluetooth restoration launch.
        _ = SessionController.shared
        return true
    }
    /// A scene delegate of our own, so widget links arrive whatever is on screen: SwiftUI's
    /// `onOpenURL` only reaches the frontmost presentation, not `RootView` under a cover.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LinkSceneDelegate.self
        return configuration
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The cooking screen shows and sounds a finished timer itself.
        if CookStore.isTimer(notification.request.identifier), await CookStore.shared.onScreen { return [] }
        return [.banner]
    }
    /// Runes is a portrait app; one screen (Score) turns. See `OrientationLock`.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.allowed
    }
    func applicationDidBecomeActive(_ application: UIApplication) { lifecycle("foreground") }
    func applicationWillResignActive(_ application: UIApplication) { lifecycle("inactive") }
    func applicationDidEnterBackground(_ application: UIApplication) { lifecycle("background") }
    func applicationWillEnterForeground(_ application: UIApplication) { lifecycle("inactive") }
    private func lifecycle(_ state: String) {
        guard RunesIOSApp.snapshotName == nil else { return }
        SessionController.shared.lifecycle(state)
    }
}

/// Hands `runes://app/<id>` links (from the Home Screen widgets) to `AppLinkRouter`.
final class LinkSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        for context in connectionOptions.urlContexts { AppLinkRouter.shared.open(url: context.url) }
    }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { AppLinkRouter.shared.open(url: context.url) }
    }
}

/// The app a widget link asked for, until `RootView` shows it.
@MainActor
final class AppLinkRouter: ObservableObject {
    static let shared = AppLinkRouter()
    @Published var pending: RunesApp?

    func open(url: URL) {
        if let link = AppLink(url: url), let app = RunesApp(rawValue: link.rawValue) { pending = app }
    }
}

/// Which way the interface may face. Portrait everywhere, except while a screen that asks
/// for more is showing; leaving it turns the interface back upright.
@MainActor
enum OrientationLock {
    private(set) static var allowed: UIInterfaceOrientationMask = .portrait

    /// The landscape the phone is being held in, if any. The interface turns the opposite
    /// way to the device.
    private static var heldSideways: UIInterfaceOrientationMask? {
        switch UIDevice.current.orientation {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    static func set(_ mask: UIInterfaceOrientationMask) {
        guard mask != allowed else { return }
        allowed = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if mask == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            } else if let held = heldSideways, mask.contains(held) {
                // Opened with the phone already on its side: turn now, not at the next tilt.
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: held))
            }
        }
    }
}

@main
struct RunesIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG only: show one fixed screen for screenshots, without starting the session.
    static var snapshotName: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["RUNES_SNAPSHOT"]
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
