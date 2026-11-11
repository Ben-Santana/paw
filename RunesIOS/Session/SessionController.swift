import Foundation
import Combine
import SwiftUI
import UIKit
import CoreBluetooth
import UserNotifications

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var loginRequest: MetaLoginRequest?
    @Published private(set) var isSigningIn = false
    /// One plain sentence for a sign-in or import problem. Detail goes to the journal.
    @Published var uiError: String?
    @Published private(set) var relayStatus = "Pair a Mac test receiver to begin."
    @Published private(set) var bluetoothAuthorization = CBManager.authorization
    @Published private(set) var setupComplete: Bool
    private let relay = PhoneRelay()
    let gestures: AsyncStream<GestureEvent>
    private let eventContinuation: AsyncStream<GestureEvent>.Continuation
    private let core: SessionCore
    private let live = LiveActivityController()
    private var profileWatch: AnyCancellable?
    private var authTask: Task<Void, Never>?
    private var pairTasks: [UUID: Task<Void, Never>] = [:]
    private var loginContinuation: CheckedContinuation<URL, Error>?
    private var foreground = false
    private var bluetoothStarted = false
    private var retryTask: UIBackgroundTaskIdentifier = .invalid
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    private let holdHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let swipeHaptic = UIImpactFeedbackGenerator(style: .soft)
    private var motionDemand = (mappings: false, workout: false, lab: false)
    /// Gestures each running app has taken; mappings that use any of them are off meanwhile.
    private var reservations: [RunesApp: Set<GestureKind>] = [:]

    private init() {
        let stream = AsyncStream<GestureEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        gestures = stream.stream; eventContinuation = stream.continuation
        // Existing installs that already chose a band skip onboarding.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preferences.setupComplete) == nil, defaults.string(forKey: "selectedBand") != nil {
            defaults.set(true, forKey: Preferences.setupComplete)
        }
        setupComplete = defaults.bool(forKey: Preferences.setupComplete)
        core = SessionCore()
        core.onSnapshot = { [weak self] state in Task { @MainActor in self?.apply(state) } }
        core.onGesture = { [weak self] event in Task { @MainActor in self?.eventContinuation.yield(event) } }
        core.onBandGesture = { [weak self] gesture in Task { @MainActor in self?.react(to: gesture) } }
        core.onOwnership = { [weak self] step, session, attempt in Task { @MainActor in self?.performOwnership(step, session: session, attempt: attempt) } }
        core.onRetryWait = { [weak self] waiting in Task { @MainActor in self?.holdExecution(waiting) } }
        let session = core
        relay.onDemand = { [weak session] demand in
            session?.transport.perform { [weak session] in session?.setRelayDemand(demand) }
        }
        relay.onDiagnostic = { [weak session] message in
            session?.transport.perform { [weak session] in session?.recordRelayDiagnostic(message) }
        }
        relay.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.relayStatus = status
                self?.live.setMac(connected: status.hasPrefix("Connected"))
            }
        }
        core.onRelayReady = { [weak relay] in relay?.setReady($0) }
        // Rotation and movement are detected on the transport queue; only detected steps hop to the main actor.
        let motion = MotionBox()
        let feed = WorkoutStore.feed
        core.onMotion = { kind, values in
            let steps = kind == .orientation ? [motion.detector.orientation(values)].compactMap { $0 }
                      : kind == .gyro ? motion.detector.gyroscope(values) : []
            for step in steps { Task { @MainActor in MappingStore.shared.receive(step) } }
            // Air gestures trace the raw orientation.
            if kind == .orientation { Task { @MainActor in MappingStore.shared.orientation(values) } }
            // Workout reps are counted here too, from the same raw samples.
            if kind == .orientation || kind == .gyro,
               feed.ingest(orientation: kind == .orientation, values, at: ProcessInfo.processInfo.systemUptime) {
                Task { @MainActor in WorkoutStore.shared.rep() }
            }
        }
        // Combos and a running workout both ask for motion; the streams run while either does.
        MappingStore.shared.onMotionDemand = { [weak self] on in self?.motionDemand.mappings = on; self?.pushMotionDemand() }
        WorkoutStore.shared.onMotionDemand = { [weak self] on in self?.motionDemand.workout = on; self?.pushMotionDemand() }
        // Motion Lab: raw samples go straight to the recorder on the transport queue; EMG only while recording.
        let recorder = MotionLab.recorder
        core.onRaw = { recorder.ingest($0) }
        core.onEMGStatus = { text in Task { @MainActor in MotionLab.shared.emgStatus = text } }
        MotionLab.shared.onDemand = { [weak self] on in
            guard let self else { return }
            self.motionDemand.lab = on; self.pushMotionDemand()
            self.core.transport.perform { [weak core = self.core] in core?.setLocalEMG(on) }
        }
        WorkoutStore.shared.onActivity = { [weak self] state, alert in self?.live.show(workout: state, alert: alert) }
        ScoreStore.shared.onReserve = { [weak self] in self?.reserve($0, for: .score) }
        CookStore.shared.onReserve = { [weak self] in self?.reserve($0, for: .cook) }
        CookStore.shared.onActivity = { [weak self] state, alert in self?.live.show(cook: state, alert: alert) }
        CookStore.shared.onCue = { cue in
            let (voice, pitch): (SoundVoice, Double) = switch cue {
            case .step: (.tick, 392)
            case .start: (.pip, 523)
            case .pause: (.soft, 330)
            case .extend: (.pip, 659)
            case .stop: (.soft, 392)
            case .reset: (.tap, 262)
            case .select: (.tick, 523)
            case .ring: (.bell, 784)
            case .finish: (.resolve, 392)
            case .nothing: (.tap, 196)
            }
            ScoreAudio.shared.preview(voice, pitch: pitch, volume: 0.9)
        }
        CaptureStore.shared.onReserve = { [weak self] in self?.reserve($0, for: .capture) }
        // Capture plays its own cues while its microphone is open; these are the rest.
        CaptureStore.shared.onCue = { cue in
            let (voice, pitch): (SoundVoice, Double) = switch cue {
            case .start: (.pip, 659)
            case .saved: (.resolve, 523)
            case .discarded: (.tap, 196)
            }
            ScoreAudio.shared.preview(voice, pitch: pitch, volume: 0.6)
        }
        ScoreStore.shared.onActivity = { [weak self] state, alert in self?.live.show(score: state, alert: alert) }
        ScoreStore.shared.onCue = { ScoreAudio.shared.play($0, with: ScoreStore.shared.controls.sounds) }
        ScoreStore.shared.onLive = { ScoreAudio.shared.setLive($0) }
        profileWatch = MappingStore.shared.$library.map(\.active.icon).removeDuplicates()
            .sink { [weak self] icon in self?.live.setProfile(icon: icon) }
        core.onRelayEvent = { [weak relay] in relay?.forward($0) }
        MappingStore.shared.onBindings = { [weak relay] in relay?.setBindings($0) }
        WakeProbe.shared.start { [weak session] message in
            session?.transport.perform { [weak session] in session?.recordRelayDiagnostic(message) }
        }
        // Creating a Bluetooth manager shows the permission prompt, so on a fresh install
        // it waits for the onboarding step that explains it. Existing users and
        // restoration launches (permission already granted) start immediately.
        let decided = CBManager.authorization != .notDetermined
        core.start(bluetooth: false)
        if decided || setupComplete { startBluetooth() }
    }

    private func reserve(_ gestures: Set<GestureKind>, for app: RunesApp) {
        reservations[app] = gestures
        MappingStore.shared.reserve(reservations.values.reduce(into: Set()) { $0.formUnion($1) })
    }

    private func pushMotionDemand() {
        let on = motionDemand.mappings || motionDemand.workout || motionDemand.lab
        core.transport.perform { [weak core] in core?.setLocalMotion(on) }
    }

    // MARK: Bluetooth

    func startBluetooth() {
        guard !bluetoothStarted else { return }
        bluetoothStarted = true
        core.startBluetooth()
        relay.start()
    }
    private func apply(_ state: SessionSnapshot) {
        let previousBattery = snapshot.battery
        snapshot = state
        bluetoothAuthorization = CBManager.authorization
        // Auto-reconnect at launch never goes through connect(); start the activity here too.
        if foreground, state.wantsConnection { live.start() }
        live.update(state)
        if !state.wantsConnection {
            for task in pairTasks.values { task.cancel() }; pairTasks.removeAll()
        }
        if let level = state.battery, level != previousBattery { BatteryAlerts.observe(level) }
    }
    /// Runs gesture mappings, then one haptic per physical gesture; the end of a hold is silent.
    private func react(to gesture: BandGesture) {
        // Mappings and workouts run in the background too, so they come before the foreground check.
        // A running app's control gestures don't also run mappings: a workout, a live game,
        // a recipe being cooked, or Capture waiting for a hold.
        if !WorkoutStore.shared.consume(gesture), !ScoreStore.shared.consume(gesture),
           !CookStore.shared.consume(gesture), !CaptureStore.shared.consume(gesture) { MappingStore.shared.receive(gesture) }
        guard foreground, UserDefaults.standard.object(forKey: Preferences.haptics) as? Bool ?? true else { return }
        switch gesture.kind {
        case .tap, .doubleTap: tapHaptic.impactOccurred()
        case .holdBegan: holdHaptic.impactOccurred()
        case .swipe: swipeHaptic.impactOccurred(intensity: 0.8)
        case .holdEnded: break
        }
    }
    /// A timed retry must be able to fire even if iOS would otherwise suspend the app.
    private func holdExecution(_ waiting: Bool) {
        if waiting, retryTask == .invalid {
            retryTask = UIApplication.shared.beginBackgroundTask(withName: "Band reconnect") { [weak self] in self?.holdExecution(false) }
        } else if !waiting, retryTask != .invalid {
            UIApplication.shared.endBackgroundTask(retryTask); retryTask = .invalid
        }
    }

    // MARK: Lifecycle and actions

    func lifecycle(_ state: String) {
        foreground = state == "foreground"
        if foreground, snapshot.wantsConnection { live.start() }
        bluetoothAuthorization = CBManager.authorization
        core.transport.perform { [core] in core.lifecycle(state) }
    }
    func completeSetup() {
        setupComplete = true; UserDefaults.standard.set(true, forKey: Preferences.setupComplete)
    }
    func pairRelay(_ text: String) {
        do { relay.pair(try RelayWire.Invitation.parse(text)) }
        catch { journal("relay", error.localizedDescription); uiError = "That isn’t a Mac pairing code. Try scanning it again." }
    }
    func scan() { core.transport.perform { [core] in core.scan() } }
    func stopScan() { core.transport.perform { [core] in core.stopScan() } }
    func select(_ device: BandDevice) { core.transport.perform { [core] in core.select(device) } }
    func select(id: UUID) { core.transport.perform { [core] in core.select(id: id) } }
    func refreshIdentities() { core.transport.perform { [core] in core.refreshIdentityChoices() } }
    /// True when the selected band can connect with a saved identity, without signing in.
    var canConnectWithoutSignIn: Bool { snapshot.selected != nil && snapshot.identityChoices.contains { $0.eligible } }
    func connect(account: UUID? = nil, pending: Bool? = nil) {
        guard foreground else { return }
        uiError = nil; live.start()
        core.transport.perform { [core] in core.connect(account: account, pending: pending) }
    }
    func importIdentityQR(_ text: String, for id: UUID) {
        guard foreground, !isSigningIn, !snapshot.wantsConnection, snapshot.selected == id else { return }
        do {
            let identity = try IdentityTransfer.parse(text)
            uiError = nil; live.start()
            core.transport.perform { [core] in core.importIdentity(identity, for: id) }
        } catch { journal("import", error.localizedDescription); uiError = "That isn’t a Runes setup code from your Mac. Try again." }
    }
    func disconnect() {
        cancelSignIn(); live.end()
        for task in pairTasks.values { task.cancel() }; pairTasks.removeAll()
        core.transport.perform { [core] in core.disconnect() }
    }
    func forgetBand() {
        cancelSignIn(); live.end()
        setupComplete = false; UserDefaults.standard.set(false, forKey: Preferences.setupComplete)
        AccessoryPicker.shared.forgetAll()
        core.transport.perform { [core] in core.forget {} }
    }
    func perform(_ action: SessionIssue.Action) {
        switch action {
        case .reconnect: connect()
        case .openSettings: if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .setUpAgain: forgetBand()
        case .retryRelease: core.transport.perform { [core] in core.disconnect() }
        case .retrySignIn: enroll()
        }
    }
    func enroll() {
        guard foreground, snapshot.selected != nil, !isSigningIn else { return }
        isSigningIn = true; uiError = nil
        authTask = Task { [weak self] in
            guard let self else { return }
            let service = MetaService(); defer { service.close(); self.isSigningIn = false; self.authTask = nil }
            do {
                let released: Bool = await withCheckedContinuation { continuation in
                    self.core.transport.perform { [core = self.core] in
                        core.disconnect { confirmed in continuation.resume(returning: confirmed) }
                    }
                }
                try Task.checkCancellation()
                guard released else { throw BandError.transport("Local Bluetooth release was not confirmed. Retry disconnect before starting ownership setup.") }
                let request = try await service.prepareLogin(); try Task.checkCancellation()
                let callback = try await self.presentLogin(request)
                let session = try await service.finishLogin(callback, request: request); try Task.checkCancellation()
                guard self.foreground else { throw BandError.authentication("Return to Runes and sign in again to begin enrollment.") }
                self.live.start()
                self.core.transport.perform { [core = self.core] in core.beginEnrollment(session) }
            } catch {
                self.loginRequest = nil
                if !Task.isCancelled, (error as? BandError)?.errorDescription != BandError.cancelled.errorDescription {
                    self.journal("sign_in", error.localizedDescription)
                    self.uiError = SessionIssue.signInFailed.sentence
                }
            }
        }
    }
    private func presentLogin(_ request: MetaLoginRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in loginContinuation = continuation; loginRequest = request }
    }
    func loginCallback(_ url: URL) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil; loginRequest = nil; continuation.resume(returning: url)
    }
    func loginFailed() {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil; loginRequest = nil
        continuation.resume(throwing: BandError.authentication("Meta sign-in navigation failed. Try signing in again."))
    }
    func cancelSignIn() {
        authTask?.cancel()
        if let continuation = loginContinuation { loginContinuation = nil; continuation.resume(throwing: BandError.cancelled) }
        loginRequest = nil
    }
    func loginSheetDismissed() { if loginContinuation != nil { cancelSignIn() } }
    private func performOwnership(_ step: OwnershipStep, session: MetaSession, attempt: UUID) {
        let taskID = UUID()
        pairTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            let service = MetaService(); defer { service.close(); self.pairTasks[taskID] = nil }
            let result: Result<PairCompletion, Error>
            do { let completion = try await service.complete(step, session: session); try Task.checkCancellation(); result = .success(completion) }
            catch { result = .failure(error) }
            self.core.transport.perform { [core = self.core] in core.ownershipCompleted(result, attempt: attempt) }
        }
    }
    private func journal(_ kind: String, _ message: String) {
        core.transport.perform { [core] in core.note(kind, message) }
    }
    func exportJournal() async -> URL? {
        await withCheckedContinuation { continuation in
            core.transport.perform { [core] in core.exportJournal { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure: self.uiError = "The journal couldn’t be exported. Try again."; continuation.resume(returning: nil)
                    }
                }
            } }
        }
    }
    func clearJournal() { core.transport.perform { [core] in core.clearJournal() } }
}

/// Holds the motion detector; used only on the transport queue.
private final class MotionBox: @unchecked Sendable { var detector = MotionDetector() }

enum Preferences {
    static let setupComplete = "setupComplete"
    static let haptics = "hapticsOnGesture"
    static let batteryAlerts = "bandBatteryAlerts"
}

/// A local notification when the band runs low. It is checked whenever the band reports
/// its level, which also happens while the phone is locked.
enum BatteryAlerts {
    static let threshold = 20
    private static let alertedKey = "bandBatteryAlerted"

    @MainActor static func observe(_ level: Int) {
        let defaults = UserDefaults.standard
        if level >= threshold + 10 { defaults.set(false, forKey: alertedKey); return }
        guard level <= threshold, defaults.bool(forKey: Preferences.batteryAlerts), !defaults.bool(forKey: alertedKey) else { return }
        defaults.set(true, forKey: alertedKey)
        let content = UNMutableNotificationContent()
        content.title = "Band battery low"
        content.body = "Your band is at \(level)%. Charge it soon to keep using gestures."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "runes.battery.low", content: content, trigger: nil))
    }
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
