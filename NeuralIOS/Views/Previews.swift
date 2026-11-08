#if DEBUG
import SwiftUI

/// Fixed interface states for SwiftUI previews and screenshots. These are view values only:
/// nothing here reaches the session, Bluetooth or the journal, and release builds omit it.
enum PreviewFixtures {
    static let mac = "Mac test relay connected"
    static let home: [(String, BandStatus)] = [
        ("not-set-up", BandStatus(phase: .notSetUp)),
        ("connecting", BandStatus(phase: .connecting, battery: 82, hand: .left, macLink: "Waiting for Mac test relay")),
        ("connected", BandStatus(phase: .connected, battery: 82, hand: .left, lastGesture: "Index tap", gestureCount: 14, macLink: mac)),
        ("attention", BandStatus(phase: .attention, issue: .bandNotNearby, battery: 64, hand: .left, macLink: mac)),
        ("pulse", BandStatus(phase: .connected, issue: .pulseMissing, battery: 31, hand: .right, lastGesture: "Middle double tap", gestureCount: 3, macLink: mac)),
    ]
    static let devices = [BandDevice(id: UUID(), name: "Meta Neural Band", rssi: -48), BandDevice(id: UUID(), name: "Meta Neural Band", rssi: -79)]
    static let onboarding: [(String, OnboardingStep, OnboardingContext)] = [
        ("welcome", .welcome, .init()),
        ("bluetooth", .bluetooth, .init()),
        ("pairing", .pairing, .init(bluetooth: .allowed)),
        ("pick", .pick, .init(bluetooth: .allowed, devices: devices, searching: true)),
        ("sign-in", .signIn, .init(bluetooth: .allowed)),
        ("test", .test, .init(bluetooth: .allowed, phase: .connected, heard: "Middle tap")),
        ("test-passed", .test, .init(bluetooth: .allowed, phase: .connected, testPassed: true)),
        ("done", .done, .init(bluetooth: .allowed, phase: .connected)),
    ]
    static func event(_ finger: UInt64, _ action: UInt64, _ derived: UInt64, _ sequence: UInt64, _ secondsAgo: Double) -> GestureEvent {
        GestureEvent(id: UUID(), sessionID: UUID(), fingerCode: finger, actionCode: action, derivedActionCode: derived, synthetic: false,
                     sequence: sequence, deviceTimestamp: 21_495_331 + sequence * 1000,
                     received: ReceiptContext(wallTime: Date().addingTimeInterval(-secondsAgo), uptime: 1000 - secondsAgo, applicationState: "foreground"))
    }
    static let events = [event(2, 0, 1, 15, 2), event(2, 2, 0, 9, 2.1), event(2, 0, 9, 14, 2.3), event(2, 1, 0, 8, 2.3), event(3, 0, 2, 13, 40)]
    static let advanced = AdvancedValues(relayStatus: mac, events: events, eventCount: 14, canImportMacSetup: false)
}

/// Renders one fixed screen by name; used for screenshots with NEURAL_SNAPSHOT=<name>.
struct SnapshotGallery: View {
    let name: String
    var body: some View {
        if let home = PreviewFixtures.home.first(where: { "home-\($0.0)" == name }) {
            HomeView(status: home.1)
        } else if let step = PreviewFixtures.onboarding.first(where: { "onboarding-\($0.0)" == name }) {
            OnboardingView(step: step.1, context: step.2)
        } else if name == "settings" {
            SettingsView(values: SettingsValues(battery: 82, hand: .left, version: "0.2.0 (2)")) { EmptyView() }
        } else if name == "advanced" {
            NavigationStack { AdvancedView(values: PreviewFixtures.advanced) }
        } else {
            Text("Unknown snapshot \(name)").page()
        }
    }
}

#Preview("Home · connected") { HomeView(status: PreviewFixtures.home[2].1) }
#Preview("Home · connecting") { HomeView(status: PreviewFixtures.home[1].1) }
#Preview("Home · needs attention") { HomeView(status: PreviewFixtures.home[3].1) }
#Preview("Home · not set up") { HomeView(status: PreviewFixtures.home[0].1) }
#Preview("Home · pulse warning, dark") { HomeView(status: PreviewFixtures.home[4].1).preferredColorScheme(.dark) }
#Preview("Onboarding · pick") { OnboardingView(step: .pick, context: PreviewFixtures.onboarding[3].2) }
#Preview("Onboarding · sign in") { OnboardingView(step: .signIn, context: PreviewFixtures.onboarding[4].2) }
#Preview("Onboarding · test") { OnboardingView(step: .test, context: PreviewFixtures.onboarding[5].2) }
#Preview("Settings") { SettingsView(values: SettingsValues(battery: 82, hand: .left)) { AdvancedView(values: PreviewFixtures.advanced) } }
#Preview("Advanced") { NavigationStack { AdvancedView(values: PreviewFixtures.advanced) } }
#Preview("Ring states") {
    VStack { ForEach([BandPhase.notSetUp, .connecting, .connected, .attention], id: \.title) { HairlineRing(phase: $0).frame(height: 150) } }.page()
}
#Preview("Large type") { HomeView(status: PreviewFixtures.home[2].1).dynamicTypeSize(.accessibility2) }
#endif
