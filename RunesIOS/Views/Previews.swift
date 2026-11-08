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
    @MainActor static var mappings: MappingStore {
        var main = MappingProfile(id: "main", name: "Main", icon: "home", mappings: [
            Mapping(id: "tap-index", enabled: true, actions: [.runShortcut("Play/Pause")]),
            Mapping(id: "double-tap-index", enabled: true, actions: [.apiCall(method: .POST, url: "https://hooks.example.com/lights", headers: [:], body: "{}", timeoutMs: 10_000), .wait(ms: 500), .haptic(.success)]),
            Mapping(id: "swipe-right", enabled: true, actions: [.moveProfile(.down)]),
            Mapping(id: "swipe-up", enabled: false, actions: [.openURL("music://")]),
            Mapping(id: "combo-a", enabled: true, actions: [.notify(title: "Runes", body: "Focus on")], steps: [ComboStep(.holdIndex), .rotation(.x, .right), ComboStep(.releaseIndex)], intervalMs: 750, name: "Focus"),
            Mapping(id: "combo-b", enabled: true, actions: [.copyText("On my way")], steps: [.tapMiddle, .doubleTapIndex, .swipeLeft].steps, intervalMs: 500),
        ]).normalized()
        main.name = "Main"
        let work = MappingProfile(id: "work", name: "Work", icon: "work", mappings: []).normalized()
        return MappingStore(preview: MappingLibrary(profiles: [main, work], activeID: "main"),
                            recent: [.init(id: 1, gesture: .tapIndex, ranMapping: true), .init(id: 2, step: .movement(.y)), .init(id: 3, gesture: .holdIndex, ranMapping: true), .init(id: 4, gesture: .swipeUp, ranMapping: true), .init(id: 5, gesture: .releaseIndex, ranMapping: true)])
    }
    static let advanced = AdvancedValues(relayStatus: mac, events: events, eventCount: 14, canImportMacSetup: false)
}

extension PreviewFixtures {
    /// A workout two sets in, counting the third or waiting for it.
    @MainActor static func workouts(running: Bool, counting: Bool = true) -> WorkoutStore {
        var run = WorkoutRun(plan: WorkoutPlan.sample)
        run.apply(.start); for _ in 0..<12 { run.rep() }; run.apply(.stop)
        run.apply(.start); for _ in 0..<10 { run.rep() }; run.apply(.stop)
        if counting { run.apply(.start); for _ in 0..<7 { run.rep() } }
        // Push today, legs three days ago, pull six days ago, and older weeks for the journal.
        func done(_ plan: WorkoutPlan, daysAgo: Int, bump: Double = 0) -> WorkoutRecord {
            let start = Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 3_600)
            var r = WorkoutRun(plan: plan, at: start)
            var t = start
            while r.phase != .finished {
                r.apply(.start, at: t); t.addTimeInterval(45); r.apply(.stop, at: t); t.addTimeInterval(90)
            }
            var record = WorkoutRecord(name: plan.name, planID: plan.id, started: start, ended: t, sets: r.logs)
            record.sets = record.sets.map { var log = $0; log.slot.weight = (log.slot.weight ?? 20) + bump; return log }
            return record
        }
        let split = WorkoutPlan.starterSplit
        var history: [WorkoutRecord] = [done(split[0], daysAgo: 0, bump: 10), done(split[2], daysAgo: 3, bump: 10), done(split[1], daysAgo: 6, bump: 7.5)]
        for week in 1...5 { history.append(done(split[week % 3], daysAgo: 6 + week * 7, bump: 10 - Double(week) * 2.5)) }
        return WorkoutStore(preview: split + [WorkoutPlan.sample], run: running ? run : nil, history: history)
    }
}

/// Renders one fixed screen by name; used for screenshots with RUNES_SNAPSHOT=<name>.
struct SnapshotGallery: View {
    let name: String
    var body: some View {
        if let home = PreviewFixtures.home.first(where: { "home-\($0.0)" == name }) {
            HomeView(status: home.1)
        } else if let step = PreviewFixtures.onboarding.first(where: { "onboarding-\($0.0)" == name }) {
            OnboardingView(step: step.1, context: step.2)
        } else if name == "ring-lab" || name == "ring-demo" {
            RingLab(autoplay: name == "ring-demo")
        } else if name == "settings" {
            SettingsView(values: SettingsValues(battery: 82, hand: .left, version: "0.2.0 (2)")) { EmptyView() }
        } else if name == "mappings" {
            MappingsScreen(store: PreviewFixtures.mappings)
        } else if name == "applications" {
            ApplicationsScreen(workouts: PreviewFixtures.workouts(running: false))
        } else if name == "workouts" {
            NavigationStack { WorkoutsScreen(store: PreviewFixtures.workouts(running: false), path: .constant([])) }
        } else if name == "exercise-picker" {
            ExercisePicker(selected: .bicepCurl) { _ in }
        } else if name == "workout-settings" {
            WorkoutSettingsScreen(store: PreviewFixtures.workouts(running: false))
        } else if name == "workout-editor" {
            NavigationStack { WorkoutEditor(store: PreviewFixtures.workouts(running: false), planID: WorkoutPlan.starterSplit[2].id) }
        } else if name == "workout-active" || name == "workout-waiting" {
            NavigationStack { ActiveWorkoutScreen(store: PreviewFixtures.workouts(running: true, counting: name == "workout-active")) }
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
#Preview("Mappings") { MappingsScreen(store: PreviewFixtures.mappings) }
#Preview("Advanced") { NavigationStack { AdvancedView(values: PreviewFixtures.advanced) } }
#Preview("Ring states") {
    VStack { ForEach([BandPhase.notSetUp, .connecting, .connected, .attention], id: \.title) { HairlineRing(phase: $0).frame(height: 150) } }.page()
}
#Preview("Large type") { HomeView(status: PreviewFixtures.home[2].1).dynamicTypeSize(.accessibility2) }
#endif
#Preview("Settings – Mac paired") {
    SettingsView(values: SettingsValues(battery: 82, hand: .left,
                                        macs: [MacLinks.Mac(id: UUID(), name: "Studio", state: .connected),
                                               MacLinks.Mac(id: UUID(), name: "MacBook Air", state: .notNearby)])) { EmptyView() }
}
