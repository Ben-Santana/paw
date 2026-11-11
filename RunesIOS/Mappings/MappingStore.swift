import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Owns the saved profiles, feeds band gestures to `MappingEngine` and runs the actions.
/// Gestures arrive here whether Runes is on screen or the phone is locked; actions that
/// need the screen (opening apps, copying, haptics) are skipped while in the background.
@MainActor
final class MappingStore: ObservableObject {
    static let shared = MappingStore()
    private static let key = "runes.mappings.v1"

    @Published private(set) var library: MappingLibrary
    /// The last few gestures, newest last, for the live strip.
    @Published private(set) var recent: [RecentGesture] = []
    /// Mapping that most recently ran, for a brief highlight.
    @Published private(set) var lastFired: (id: String, at: Date)?
    /// While true (an editor is listening for steps), gestures are shown but no actions run,
    /// and running apps don't get them either.
    @Published var paused = false

    struct RecentGesture: Identifiable, Equatable {
        let id: Int; let step: ComboStep; var ranMapping = false
        init(id: Int, step: ComboStep, ranMapping: Bool = false) { self.id = id; self.step = step; self.ranMapping = ranMapping }
        init(id: Int, gesture: GestureKind, ranMapping: Bool = false) { self.init(id: id, step: ComboStep(gesture), ranMapping: ranMapping) }
        var gesture: GestureKind { step.gesture }
    }
    /// Gestures a running app has taken (a live Score game). Mappings that use one are off
    /// until it gives them back; nothing about them is changed or saved.
    @Published private(set) var reserved: Set<GestureKind> = []
    func reserve(_ gestures: Set<GestureKind>) {
        guard gestures != reserved else { return }
        reserved = gestures
        configureEngine()
    }
    func isSuspended(_ mapping: Mapping) -> Bool { mapping.uses(reserved) }
    private func configureEngine() {
        let wanted = motionWanted
        engine.configure(library.active.mappings.filter { !$0.uses(reserved) })
        if motionWanted != wanted { onMotionDemand?(motionWanted) }
        stopTickerIfIdle()
    }

    /// Told whether any live combo needs the band's motion streams. Set by the session.
    var onMotionDemand: ((Bool) -> Void)? { didSet { onMotionDemand?(motionWanted) } }
    /// Set while the air gesture editor records from the band; receives each orientation sample.
    var onOrientation: (([Double]) -> Void)? {
        didSet { if (oldValue == nil) != (onOrientation == nil) { onMotionDemand?(motionWanted) } }
    }
    private var motionWanted: Bool { engine.wantsMotion || onOrientation != nil }

    private var engine = MappingEngine()
    private var ticker: Timer?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private init() {
        var saved = MappingLibrary.initial
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(MappingLibrary.self, from: data) { saved = decoded.normalized() }
        library = saved
        engine.configure(saved.active.mappings)
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview: MappingLibrary, recent: [RecentGesture] = []) {
        library = preview.normalized(); self.recent = recent; previewOnly = true
    }
    #endif
    private var previewOnly = false

    var active: MappingProfile { library.active }

    // MARK: Editing

    func update(_ change: (inout MappingLibrary) -> Void) {
        var next = library
        change(&next)
        library = next.normalized()
        save()
    }
    func save(_ mapping: Mapping) {
        update { lib in
            guard let p = lib.profiles.firstIndex(where: { $0.id == lib.activeID }) else { return }
            if let i = lib.profiles[p].mappings.firstIndex(where: { $0.id == mapping.id }) { lib.profiles[p].mappings[i] = mapping }
            else { lib.profiles[p].mappings.append(mapping) }
        }
    }
    func remove(mappingID: String) {
        update { lib in
            guard let p = lib.profiles.firstIndex(where: { $0.id == lib.activeID }) else { return }
            if let kind = GestureKind(rawValue: mappingID) {
                if let i = lib.profiles[p].mappings.firstIndex(where: { $0.id == mappingID }) { lib.profiles[p].mappings[i] = .gesture(kind) }
            } else { lib.profiles[p].mappings.removeAll { $0.id == mappingID } }
        }
    }
    func moveCombos(from source: IndexSet, to destination: Int) {
        update { lib in
            guard let p = lib.profiles.firstIndex(where: { $0.id == lib.activeID }) else { return }
            var combos = lib.profiles[p].combos
            combos.move(fromOffsets: source, toOffset: destination)
            lib.profiles[p].mappings = lib.profiles[p].gestures + combos
        }
    }
    func selectProfile(_ id: String) { update { $0.activeID = id } }
    func addProfile(name: String, icon: String) {
        update { lib in
            let profile = MappingProfile.new(name: name, icon: icon)
            lib.profiles.append(profile); lib.activeID = profile.id
        }
    }
    func renameProfile(_ id: String, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !trimmed.isEmpty else { return }
        update { lib in if let i = lib.profiles.firstIndex(where: { $0.id == id }) { lib.profiles[i].name = trimmed } }
    }
    func setIcon(_ id: String, _ icon: String) {
        update { lib in if let i = lib.profiles.firstIndex(where: { $0.id == id }) { lib.profiles[i].icon = icon } }
    }
    func duplicateProfile(_ id: String) {
        update { lib in
            guard let source = lib.profiles.first(where: { $0.id == id }) else { return }
            var copy = source; copy.id = UUID().uuidString.lowercased(); copy.name = String("\(source.name) copy".prefix(32))
            copy.mappings = copy.mappings.map { m in
                var m = m; if m.isCombo { m.id = "combo-\(UUID().uuidString.lowercased())" }; return m
            }
            lib.profiles.append(copy); lib.activeID = copy.id
        }
    }
    func deleteProfile(_ id: String) {
        guard library.profiles.count > 1 else { return }
        update { lib in
            guard let i = lib.profiles.firstIndex(where: { $0.id == id }) else { return }
            lib.profiles.remove(at: i)
            if lib.activeID == id { lib.activeID = lib.profiles[min(i, lib.profiles.count - 1)].id }
        }
    }

    /// Every profile's assigned gestures and combos, for the paired Mac.
    var onBindings: (([RelayWire.Binding]) -> Void)? { didSet { onBindings?(bindings) } }

    var bindings: [RelayWire.Binding] {
        library.profiles.flatMap { profile in
            profile.mappings.filter { $0.enabled && $0.hasActions }.map { m in
                RelayWire.Binding(trigger: m.trigger, profile: profile.name,
                                  action: m.actions.map { $0.label(profiles: library.profiles) }.joined(separator: " → "))
            }
        }
    }

    private func save() {
        onBindings?(bindings)
        configureEngine()
        guard !previewOnly, let data = try? JSONEncoder().encode(library) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: Gestures

    func receive(_ gesture: BandGesture) {
        guard let kind = GestureKind(gesture) else { return }
        receive(ComboStep(kind))
    }
    /// A tap, swipe or hold from the band, or a rotation or movement from `MotionDetector`.
    func receive(_ step: ComboStep) {
        guard !previewOnly else { return }
        handle(engine.receive(step, at: ProcessInfo.processInfo.systemUptime))
        if !engine.isIdle, ticker == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }
    /// The band's orientation quaternion, for air gestures.
    func orientation(_ q: [Double]) {
        guard !previewOnly else { return }
        onOrientation?(q)
        engine.orientation(q, at: ProcessInfo.processInfo.systemUptime)
    }
    private func tick() {
        handle(engine.tick(at: ProcessInfo.processInfo.systemUptime))
        stopTickerIfIdle()
    }
    private func stopTickerIfIdle() {
        if engine.isIdle { ticker?.invalidate(); ticker = nil }
    }

    private func handle(_ events: [MappingEngine.Event]) {
        for event in events {
            switch event {
            case .input(let input):
                recent = Array((recent + [RecentGesture(id: input.id, step: input.step)]).suffix(5))
            case .fire(let id, let inputs):
                guard let mapping = active.mappings.first(where: { $0.id == id }) else { continue }
                recent = recent.map { r in var r = r; if inputs.contains(r.id) { r.ranMapping = true }; return r }
                lastFired = (id, Date())
                if !paused { run(mapping.actions, from: mapping) }
            case .comboFailed:
                break
            }
        }
    }

    // MARK: Actions

    /// Runs linked actions in order. Each waits for the previous one (an API call, a wait).
    /// `mapping` is the gesture or combo that set them off, when one did.
    func run(_ actions: [MappingAction], from mapping: Mapping? = nil) {
        Task { @MainActor in
            for action in actions { await perform(action, from: mapping) }
        }
    }

    private var foreground: Bool { UIApplication.shared.applicationState == .active }

    private func perform(_ action: MappingAction, from mapping: Mapping?) async {
        if action.kind.needsForeground && !foreground { return }
        switch action {
        case .openURL(let text):
            if let url = URL(string: text.trimmingCharacters(in: .whitespaces)) { _ = await UIApplication.shared.open(url) }
        case .runShortcut(let name):
            var components = URLComponents(string: "shortcuts://run-shortcut")!
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            if let url = components.url { _ = await UIApplication.shared.open(url) }
        case .apiCall(let method, let text, let headers, let body, let timeoutMs):
            guard let url = URL(string: text) else { return }
            var request = URLRequest(url: url, timeoutInterval: Double(timeoutMs) / 1000)
            request.httpMethod = method.rawValue
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if method != .GET, !body.isEmpty { request.httpBody = Data(body.utf8) }
            // A locked phone may suspend Runes mid-request; ask for time to finish.
            let task = UIApplication.shared.beginBackgroundTask(withName: "Mapping API call")
            _ = try? await session.data(for: request)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        case .notify(let title, let body):
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "Runes" : title
            content.body = body
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        case .copyText(let text):
            UIPasteboard.general.string = text
        case .haptic(let style):
            switch style {
            case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        case .wait(let ms):
            try? await Task.sleep(for: .milliseconds(ms))
        case .changeProfile(let id):
            if library.profiles.contains(where: { $0.id == id }) { selectProfile(id) }
        case .spotify(let command):
            let task = UIApplication.shared.beginBackgroundTask(withName: "Spotify")
            do { try await SpotifyClient.shared.perform(command) } catch {
                // Silent failures are confusing when the phone is in a pocket; say why once.
                let content = UNMutableNotificationContent()
                content.title = "Spotify"
                content.body = error.localizedDescription
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "spotify-error", content: content, trigger: nil))
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        case .capture:
            // A gesture that ends with a finger held records until that finger lets go.
            CaptureStore.shared.toggle(endingOn: mapping?.endingRelease)
        case .moveProfile(let direction):
            guard let i = library.profiles.firstIndex(where: { $0.id == library.activeID }) else { return }
            let next = max(0, min(library.profiles.count - 1, i + (direction == .up ? -1 : 1)))
            selectProfile(library.profiles[next].id)
        }
    }

    /// Notifications need permission once; asked when someone adds a notification action.
    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
