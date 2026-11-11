import AudioToolbox
import AVFoundation
import Foundation
import UIKit
import UserNotifications

/// The sound for something Capture did, so it can be used without looking.
enum CaptureCue: Sendable { case start, saved, discarded }

/// The microphone level for the record control. Kept apart from the store so twenty
/// updates a second redraw one ring, not the whole list of notes.
@MainActor
final class CaptureMeter: ObservableObject {
    @Published var level = 0.0
}

/// Voice notes taken from the band. A chosen gesture or combo (`CaptureTrigger`) starts a
/// recording and making it again saves it; when it ends with a finger held, letting go
/// saves it instead. The note is then put into words on the phone. A mapping can do the
/// same from anywhere with the "Record a Capture note" action (`toggle`).
///
/// The trigger reaches Capture in two situations. With Capture on screen, the
/// microphone opens when it arrives. With the phone locked or Runes in the
/// background, iOS refuses to open it, so **pocket mode** opens it beforehand, while
/// Runes is on screen, and leaves it open: sound is discarded as it arrives (all but the
/// last second) until the trigger says to keep it. Pocket mode leaves the Live Activity
/// alone; the cues (sounds, or buzzes and notifications) say what happened.
@MainActor
final class CaptureStore: ObservableObject {
    static let shared = CaptureStore()
    private static let key = "runes.capture.v1"
    private static let holder = "capture"

    enum Problem: Equatable, Sendable {
        /// Microphone access was refused in Settings.
        case denied
        /// The phone has no microphone to give right now.
        case unavailable
        /// A call or another app took the microphone while in pocket mode, and iOS won't
        /// give it back until Runes is opened.
        case interrupted

        var sentence: String {
            switch self {
            case .denied: "Runes can’t use the microphone. Allow it in Settings."
            case .unavailable: "The microphone isn’t available right now."
            case .interrupted: "Something else used the microphone. Pocket mode is listening again now."
            }
        }
    }

    @Published private(set) var notes: [CaptureNote]
    @Published private(set) var controls: CaptureControls
    /// When the recording under way began; nil when none is.
    @Published private(set) var recordingSince: Date?
    /// Pocket mode: the microphone stays open so a hold records with the phone locked.
    @Published private(set) var listening = false
    @Published private(set) var problem: Problem?
    /// The note saved most recently in this session, so the list can show it arriving.
    @Published private(set) var arrived: String?
    /// The finger whose letting go saves the recording under way, when a hold began it.
    @Published private(set) var endRelease: GestureKind?
    let meter = CaptureMeter()

    /// Told which gestures Capture holds (none when it can't record).
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    var onCue: ((CaptureCue) -> Void)?
    /// True while the Capture screen is in front; the trigger then records without pocket mode.
    var onScreen = false { didSet { if onScreen != oldValue, !previewOnly { onReserve?(reservedNow) } } }

    var isRecording: Bool { recordingSince != nil }
    /// The trigger records when the screen is showing or pocket mode is on.
    private var armed: Bool { onScreen || listening }
    private var reservedNow: Set<GestureKind> { armed ? controls.reserved : [] }
    /// Decides when the trigger was made, combos and double-tap waits included.
    private var engine = MappingEngine()
    private var ticker: Timer?

    private let recorder = CaptureRecorder()
    private let folder: URL
    private var previewOnly = false
    private var limit: Task<Void, Never>?
    private var retried: Set<String> = []
    /// True when pocket mode lost the microphone in the background and must be reopened.
    private var broken = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controls = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CaptureControls.self, from: $0) } ?? CaptureControls()
        notes = (try? Data(contentsOf: folder.appendingPathComponent("notes.json"))).flatMap { try? JSONDecoder().decode([CaptureNote].self, from: $0) } ?? []
        // A note that was mid-transcription when Runes was closed is tried again, and so
        // is one that couldn't be put into words last time.
        let recent = Date().addingTimeInterval(-7 * 86_400)
        for index in notes.indices where notes[index].state == .transcribing
            || (notes[index].state == .unavailable && !notes[index].hasWords && notes[index].at > recent) {
            notes[index].state = .pending
        }
        engine.configure([controls.trigger.mapping])

        let meter = meter
        recorder.onLevel = { level in
            let value = CaptureRules.meter(level)
            Task { @MainActor in meter.level = value }
        }
        recorder.onRouteChange = { [weak self] in self?.routeChanged() }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorder.rebuild(); self?.reopen() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(true) }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(false) }
        }
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved, and the microphone is never opened.
    init(preview notes: [CaptureNote], recording: Date? = nil, listening: Bool = false, problem: Problem? = nil, level: Double = 0) {
        folder = FileManager.default.temporaryDirectory
        self.notes = notes; controls = CaptureControls(); recordingSince = recording; self.listening = listening; self.problem = problem
        meter.level = level
        previewOnly = true
    }
    #endif

    // MARK: Recording

    /// Asks for the microphone the first time, so the first hold isn't spent on a prompt.
    func prepare() {
        guard !previewOnly else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                problem = granted ? nil : .denied
            }
        case .denied: problem = .denied
        default: if problem == .denied { problem = nil }
        }
        retryPending()
    }

    /// Starts keeping sound. With pocket mode on, the microphone is already open and the
    /// last moment before the gesture is kept too.
    func begin() {
        guard !previewOnly, !isRecording, permitted() else { return }
        endRelease = nil
        do {
            try open()
            let id = UUID().uuidString.lowercased()
            try recorder.begin(to: folder.appendingPathComponent("\(id).m4a"), preroll: listening ? CaptureRules.preroll : 0)
        } catch {
            closeIfIdle()
            problem = UIApplication.shared.applicationState == .active ? .unavailable : problem
            return
        }
        problem = nil
        recordingSince = Date()
        cue(.start)
        limit?.cancel()
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CaptureRules.maximum))
            if !Task.isCancelled { self?.finish() }
        }
    }

    /// Stops and saves the recording. One too short to be a note is thrown away.
    func finish() {
        guard !previewOnly, isRecording else { return }
        limit?.cancel(); limit = nil
        let clip = recorder.end()
        recordingSince = nil
        endRelease = nil
        meter.level = 0
        closeIfIdle()
        guard let clip, clip.duration >= CaptureRules.minimum else {
            if let clip { try? FileManager.default.removeItem(at: clip.url) }
            cue(.discarded)
            return
        }
        let note = CaptureNote(id: clip.url.deletingPathExtension().lastPathComponent, at: Date().addingTimeInterval(-clip.duration),
                               duration: clip.duration, file: clip.url.lastPathComponent, peaks: CaptureRules.waveform(clip.peaks, bars: CaptureRules.bars * 2))
        notes.insert(note, at: 0)
        arrived = note.id
        persist()
        cue(.saved, duration: clip.duration)
        transcribe(note.id)
    }

    /// Takes the band's gestures that belong to the trigger while Capture can record, and
    /// watches for the finger that ends a recording begun with a hold. Returns false to
    /// let mappings handle the gesture.
    func consume(_ gesture: BandGesture) -> Bool {
        guard !previewOnly, let kind = GestureKind(gesture) else { return false }
        let ends = isRecording && kind == endRelease
        let mine = reservedNow.contains(kind)
        if mine {
            handle(engine.receive(kind, at: ProcessInfo.processInfo.systemUptime))
            if !engine.isIdle, ticker == nil {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            }
        }
        // Letting go saves it. When a mapping began the recording, the release is still
        // the mappings' to see.
        if ends { finish() }
        return mine
    }

    private func tick() {
        handle(engine.tick(at: ProcessInfo.processInfo.systemUptime))
        if engine.isIdle { ticker?.invalidate(); ticker = nil }
    }

    private func handle(_ events: [MappingEngine.Event]) {
        for event in events {
            guard case .fire = event, armed else { continue }
            toggle(endingOn: controls.trigger.release)
        }
    }

    /// Starts a recording, or saves the one under way. `release` is the finger whose
    /// letting go should save it, when the gesture that asked ends with that finger held.
    /// Also what the "Record a Capture note" mapping action runs.
    func toggle(endingOn release: GestureKind? = nil) {
        guard !previewOnly else { return }
        if isRecording { finish(); return }
        begin()
        if isRecording {
            endRelease = release
        } else if UIApplication.shared.applicationState != .active {
            // iOS won't open the microphone now; say how to make this work next time.
            let content = UNMutableNotificationContent()
            content.title = "Capture couldn’t start"
            content.body = "Turn on pocket mode in Capture to record while your phone is locked."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "capture.background", content: content, trigger: nil))
        }
    }

    private func configureEngine() {
        engine.configure([controls.trigger.mapping])
        ticker?.invalidate(); ticker = nil
    }

    /// Says what happened the chosen way. A sound plays through the microphone's engine
    /// when it is open, otherwise the app's.
    private func cue(_ cue: CaptureCue, duration: Double = 0) {
        switch controls.feedback {
        case .off: return
        case .buzz: buzz(cue, duration: duration)
        case .sounds:
            let (voice, pitch): (SoundVoice, Double) = switch cue {
            case .start: (.pip, 659)
            case .saved: (.resolve, 523)
            case .discarded: (.tap, 196)
            }
            if !recorder.play(SoundSynth.render(voice, frequency: pitch, rate: 44_100), volume: 0.6) { onCue?(cue) }
        }
    }

    /// Vibrates once to start, twice when saved, three times when too short to keep.
    /// Away from the screen a notification says the same; each replaces the last.
    private func buzz(_ cue: CaptureCue, duration: Double) {
        let count = switch cue { case .start: 1; case .saved: 2; case .discarded: 3 }
        for index in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55 * Double(index)) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
        let center = UNUserNotificationCenter.current()
        guard UIApplication.shared.applicationState != .active else {
            center.removeDeliveredNotifications(withIdentifiers: [Self.cueNotification])
            return
        }
        let content = UNMutableNotificationContent()
        switch cue {
        case .start: content.title = "Recording"; content.body = "Capture is keeping what you say."
        case .saved: content.title = "Note saved"; content.body = CaptureRules.clock(duration)
        case .discarded: content.title = "Too short to keep"; content.body = "Nothing was saved."
        }
        content.threadIdentifier = "capture"
        center.add(UNNotificationRequest(identifier: Self.cueNotification, content: content, trigger: nil))
    }
    private static let cueNotification = "capture.cue"

    private func permitted() -> Bool {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            if AVAudioApplication.shared.recordPermission == .denied { problem = .denied } else { prepare() }
            return false
        }
        return true
    }

    private var microphone: AudioHub.Microphone { controls.headset ? .headset : .phone }

    /// Opens the microphone if it isn't already. Refused in the background.
    private func open() throws {
        guard !recorder.isRunning else { return }
        AudioHub.setMicrophone(microphone)
        try AudioHub.activate(Self.holder)
        try recorder.start()
        if UIApplication.shared.applicationState == .background { AudioHub.setLongBuffers(true) }
    }

    /// Closes the microphone unless pocket mode or a recording needs it.
    private func closeIfIdle() {
        guard !listening, !isRecording else { return }
        recorder.stop()
        AudioHub.setLongBuffers(false)
        AudioHub.setMicrophone(nil)
        AudioHub.release(Self.holder)
    }

    // MARK: Pocket mode

    /// Turns pocket mode on or off. It can only be turned on with Runes on screen.
    func setListening(_ on: Bool) {
        guard !previewOnly, on != listening else { return }
        if on {
            guard permitted() else { return }
            do { try open() } catch { closeIfIdle(); problem = .unavailable; return }
            listening = true; broken = false; problem = nil
        } else {
            if isRecording { finish() }
            listening = false; broken = false
            if problem == .interrupted { problem = nil }
            closeIfIdle()
        }
        onReserve?(reservedNow)
    }

    private func interrupted(began: Bool) {
        guard listening || isRecording else { return }
        if began {
            // Keep what was said before the call or the other app cut in.
            if isRecording { finish() }
        } else {
            reopen()
        }
    }

    /// The hardware changed (headphones in or out, another sound starting): the engine
    /// may have stopped. A recording carries on when the microphone is unchanged;
    /// otherwise what was said so far is saved.
    private func routeChanged() {
        guard listening || isRecording else { return }
        do {
            if try recorder.restart() { return }
            finish()
            if listening { recorder.stop(); reopen() }
        } catch {
            if isRecording { finish() }
            if listening { recorder.stop(); reopen() }
        }
    }

    /// Opens the microphone again for pocket mode. iOS refuses this in the background;
    /// then the Lock Screen says so, and it happens when Runes is next opened.
    private func reopen() {
        guard listening, !recorder.isRunning else { return }
        do {
            try open()
            if broken { broken = false; problem = .interrupted }
        } catch {
            guard !broken else { return }
            broken = true
            let content = UNMutableNotificationContent()
            content.title = "Capture stopped listening"
            content.body = "Something else used the microphone. Open Runes to listen from your pocket again."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "capture.interrupted", content: content, trigger: nil))
        }
    }

    /// In the background nobody sees the meter, and an open microphone can take sound in
    /// larger, rarer chunks so the phone sleeps between them. Both come back on return.
    private func setBackground(_ on: Bool) {
        guard !previewOnly else { return }
        recorder.measuresLevel = !on
        if on { meter.level = 0 }
        AudioHub.setLongBuffers(on && recorder.isRunning)
    }

    private func woke() {
        guard !previewOnly else { return }
        if AVAudioApplication.shared.recordPermission == .granted, problem == .denied { problem = nil }
        reopen()
        retryPending()
    }

    func dismissProblem() { if problem != .denied { problem = nil } }

    // MARK: Words

    private func transcribe(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].state = .transcribing
        let url = folder.appendingPathComponent(notes[index].file)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Capture transcription")
        Task {
            var text = "", state = CaptureNote.State.done
            do { text = try await CaptureTranscriber.transcribe(url) }
            catch CaptureTranscriber.Failure.unsupported { state = .unavailable }
            catch {
                // In the background iOS may refuse; try once more when Runes is opened.
                // A failure with Runes open won't be cured by opening it.
                let open = UIApplication.shared.applicationState == .active
                state = open || retried.contains(id) ? .unavailable : .pending
                #if DEBUG
                NSLog("Capture transcription failed: %@", String(describing: error))
                #endif
            }
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index].text = text; notes[index].state = state
                persist()
            }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    /// Notes whose words couldn't be made earlier get one more try with Runes open.
    private func retryPending() {
        guard UIApplication.shared.applicationState == .active else { return }
        for note in notes where note.state == .pending && !retried.contains(note.id) {
            retried.insert(note.id)
            transcribe(note.id)
        }
    }

    func transcribeAgain(_ id: String) { retried.insert(id); transcribe(id) }

    // MARK: Notes

    func note(_ id: String) -> CaptureNote? { notes.first { $0.id == id } }
    func url(for note: CaptureNote) -> URL { folder.appendingPathComponent(note.file) }

    func setText(_ text: String, for id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        if notes[index].state != .transcribing { notes[index].state = .done }
        persist()
    }

    func delete(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(for: notes[index]))
        notes.remove(at: index)
        persist()
    }

    func deleteAll() {
        for note in notes { try? FileManager.default.removeItem(at: url(for: note)) }
        notes = []
        persist()
    }

    // MARK: Settings

    /// Chooses the gesture or combo that records.
    func setTrigger(_ trigger: CaptureTrigger) {
        guard trigger.isValid, trigger != controls.trigger else { return }
        if isRecording { finish() }
        controls.trigger = trigger
        configureEngine()
        saveControls()
        if !previewOnly { onReserve?(reservedNow) }
    }
    func setFeedback(_ feedback: CaptureFeedback) {
        controls.feedback = feedback
        saveControls()
        if feedback == .buzz {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
    }
    func setHeadset(_ on: Bool) {
        guard on != controls.headset else { return }
        controls.headset = on
        saveControls()
        // An open microphone moves to the new one; the route change restarts the engine.
        if recorder.isRunning { AudioHub.setMicrophone(microphone) }
    }

    private func saveControls() {
        guard !previewOnly, let data = try? JSONEncoder().encode(controls) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func persist() {
        guard !previewOnly, let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: folder.appendingPathComponent("notes.json"), options: .atomic)
    }
}
