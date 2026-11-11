import AVFoundation
import SwiftUI
import UIKit

// Capture: make a gesture, say it, and it is written down. The screen is an inbox of
// notes by day over one control, the circle: hold it to record, or tap it to record
// until the next tap. The band's gesture (a hold by default; any gesture or combo in
// settings) does the same. Pocket mode, in settings, keeps the microphone open so the
// band can record with the phone locked; while it is on, a line at the top says so. Drawn as a ledger, like Workouts.

struct CaptureScreen: View {
    @ObservedObject var store: CaptureStore
    @Binding var path: [AppRoute]
    @State private var showSettings = false
    @State private var appeared = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        CaptureView(notes: store.notes, controls: store.controls, recordingSince: store.recordingSince, listening: store.listening,
                    releaseEnds: store.endRelease != nil, problem: store.problem, arrived: store.arrived, meter: store.meter,
                    actions: CaptureActions(begin: store.begin, finish: store.finish,
                                            open: { path.append(.note($0)) }, delete: store.delete, resolve: resolve))
            .page()
            .navigationTitle("Capture").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                        .accessibilityLabel("Capture settings")
                }
            }
            .sheet(isPresented: $showSettings) { CaptureSettingsScreen(store: store) }
            // The band's gesture belongs to this screen while it can be seen.
            .onAppear { appeared = true; store.onScreen = scenePhase == .active; store.prepare() }
            .onDisappear { appeared = false; store.onScreen = false; if !store.listening { store.finish() } }
            .onChange(of: scenePhase) { _, phase in store.onScreen = appeared && phase == .active }
    }

    private func resolve(_ problem: CaptureStore.Problem) {
        if problem == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        else { store.dismissProblem() }
    }
}

struct CaptureActions {
    var begin: () -> Void = {}
    var finish: () -> Void = {}
    var open: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var resolve: (CaptureStore.Problem) -> Void = { _ in }
}

/// Capture as values and closures, so previews can show any state.
struct CaptureView: View {
    let notes: [CaptureNote]
    let controls: CaptureControls
    let recordingSince: Date?
    let listening: Bool
    /// True while a recording under way ends when a held finger lets go.
    var releaseEnds = false
    var problem: CaptureStore.Problem? = nil
    var arrived: String? = nil
    @ObservedObject var meter: CaptureMeter
    var actions = CaptureActions()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if listening {
                        PocketStatus(trigger: controls.trigger)
                        Hairline()
                    }
                    if let problem {
                        NoticeCard(sentence: problem.sentence, actionTitle: problem == .denied ? "Open Settings" : "OK") { actions.resolve(problem) }
                            .padding(.top, 16).transition(.opacity)
                    }
                    if notes.isEmpty { empty } else { inbox }
                }
                .padding(.horizontal, Metric.gutter).padding(.bottom, 24)
                .animation(.spring(duration: 0.45, bounce: 0.12), value: notes.map(\.id))
                .animation(.standard, value: problem)
            }
            .scrollBounceBehavior(.basedOnSize)
            Rule(inset: 0)
            RecordDock(recordingSince: recordingSince, trigger: controls.trigger, releaseEnds: releaseEnds, meter: meter,
                       begin: actions.begin, finish: actions.finish)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controls.trigger.holds ? "Hold, speak, let go." : "Say it, and it’s written down.").font(.display).tracking(-0.6)
            Text("\(controls.trigger.start) and say what’s on your mind. \(controls.trigger.holds ? "When you let go" : "Do it again"), and Runes writes it down, here on your phone.")
                .font(.bodyText).foregroundStyle(Color.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 36)
        .accessibilityElement(children: .combine)
    }

    private var inbox: some View {
        ForEach(Array(CaptureDay.group(notes).enumerated()), id: \.element.id) { section, day in
            Heading(day.title, count: day.notes.count).padding(.top, section == 0 ? 28 : 36)
            ForEach(Array(day.notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 { Hairline(delay: 0.03 * Double(index)) }
                Button { actions.open(note.id) } label: { NoteRow(note: note) }
                    .buttonStyle(PressRow())
                    .swipeToDelete { actions.delete(note.id) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

/// Shown over the notes while pocket mode is on, since the microphone is.
private struct PocketStatus: View {
    let trigger: CaptureTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PulseDot()
                Text("Pocket mode · listening").font(.label)
            }
            Text("\(trigger.start) anywhere to record, also with your phone locked. Turn it off in settings.")
                .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// Pocket mode: one switch, and exactly what it does.
private struct PocketRow: View {
    let listening: Bool
    let trigger: CaptureTrigger
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { listening }, set: set)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if listening { PulseDot().transition(.scale.combined(with: .opacity)) }
                    Text(listening ? "Listening" : "Listen from your pocket").font(.label)
                }
                Text(listening ? "\(trigger.start) anywhere to record, also with your phone locked. The microphone is on; nothing is kept until you do."
                     : "Record from the band with your phone locked. The microphone stays on while this is.")
                    .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            .animation(.standard, value: listening)
        }
        .toggleStyle(HairlineSwitch())
        .padding(.vertical, 14)
        .sensoryFeedback(.impact(weight: .light), trigger: listening)
    }
}

/// A switch in ink and hairline: an outline with an open knob when off, filled with the
/// knob in paper when on, so it reads in both appearances.
struct HairlineSwitch: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.ink : Color.clear)
                    Capsule().strokeBorder(configuration.isOn ? Color.ink : Color.faint, lineWidth: Metric.hairline)
                    Circle().fill(configuration.isOn ? Color.paper : Color.clear)
                        .overlay(Circle().strokeBorder(configuration.isOn ? Color.clear : Color.ink, lineWidth: Metric.hairline))
                        .frame(width: 22, height: 22).padding(4)
                }
                .frame(width: 52, height: 30)
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// One sentence and one action, like the home screen's issue card.
struct NoticeCard: View {
    let sentence: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(Color.ink).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(sentence).font(.bodyText).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
                .font(.label)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
        }
        .padding(.horizontal, Metric.inset).padding(.vertical, 12)
        .background(Color.soft, in: RoundedRectangle(cornerRadius: Metric.panel))
        .overlay(RoundedRectangle(cornerRadius: Metric.panel).strokeBorder(Color.rule, lineWidth: Metric.hairline))
    }
}

/// A note in the inbox: when, its first lines, its shape and length.
private struct NoteRow: View {
    let note: CaptureNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(note.at, format: .dateTime.hour().minute())
                .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                .frame(minWidth: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 9) {
                Text(note.summary).font(.bodyText).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
                    .foregroundStyle(note.hasWords ? Color.ink : Color.muted)
                    .breathing(note.state == .transcribing)
                    .contentTransition(.opacity)
                HStack(spacing: 10) {
                    Waveform(peaks: note.peaks, progress: 0, bars: 28).frame(width: 84, height: 12)
                    Text(CaptureRules.clock(note.duration)).font(.caption).monospacedDigit().foregroundStyle(Color.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 15).contentShape(Rectangle())
        .animation(.standard, value: note.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(note.at.formatted(date: .omitted, time: .shortened)). \(note.summary)")
        .accessibilityHint("Opens the note.")
    }
}

/// Fades gently in and out while something is being worked on.
private struct Breathing: ViewModifier {
    let active: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.45 : 1)
            .task(id: active) {
                guard active, !reduceMotion else { dim = false; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
private extension View {
    func breathing(_ active: Bool) -> some View { modifier(Breathing(active: active)) }
}

/// A recording as hairline bars, each as tall as that moment was loud. Bars before
/// `progress` are ink; the rest wait in the faint stroke.
struct Waveform: View {
    let peaks: [Float]
    var progress: Double
    var bars = CaptureRules.bars

    var body: some View {
        let heights = CaptureRules.waveform(peaks, bars: bars)
        Canvas { context, size in
            guard !heights.isEmpty else { return }
            let step = size.width / CGFloat(heights.count)
            let width = max(1, min(2, step * 0.45))
            for (index, height) in heights.enumerated() {
                let h = max(width, size.height * CGFloat(height))
                let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - h) / 2, width: width, height: h)
                let played = Double(index) + 0.5 <= progress * Double(heights.count)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(played ? Color.ink : Color.faint))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Recording

/// The circle and what it is doing. Hold it to record and let go to save; a tap starts a
/// recording that the next tap saves. The band's gesture does the same from anywhere on
/// this screen, and the circle shows it.
private struct RecordDock: View {
    let recordingSince: Date?
    let trigger: CaptureTrigger
    /// The recording under way was begun by a hold on the band and ends when it lets go.
    let releaseEnds: Bool
    @ObservedObject var meter: CaptureMeter
    let begin: () -> Void
    let finish: () -> Void

    @State private var pressedAt: Date?
    /// True when this press started the recording, rather than landing on one under way.
    @State private var startedHere = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { recordingSince != nil }

    var body: some View {
        VStack(spacing: 8) {
            status.frame(height: 44)
            ZStack {
                if recording, !reduceMotion {
                    // The voice, as rings: louder speech pushes them further out.
                    ForEach(0..<3, id: \.self) { ring in
                        Circle().stroke(Color.ink, lineWidth: Metric.hairline)
                            .frame(width: 84, height: 84)
                            .scaleEffect(1 + meter.level * (0.1 + 0.1 * Double(ring)) + 0.05 * Double(ring + 1))
                            .opacity(0.5 - 0.14 * Double(ring))
                    }
                    .animation(.spring(duration: 0.18, bounce: 0), value: meter.level)
                    .transition(.opacity)
                }
                Circle().fill(recording ? Color.ink : Color.paper)
                Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                LucideIcon(.mic, size: 28).foregroundStyle(recording ? Color.paper : Color.ink)
            }
            .frame(width: 84, height: 84)
            .scaleEffect(pressedAt != nil && !reduceMotion ? 0.94 : 1)
            .animation(.lively, value: pressedAt != nil)
            .animation(.standard, value: recording)
            .frame(width: 160, height: 128)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = Date()
                    startedHere = !recording
                    if !recording { begin() }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressedAt ?? Date())
                    pressedAt = nil
                    // A press on a recording under way saves it. A quick tap that started
                    // one leaves it running; a hold saves on release.
                    if !startedHere || held >= 0.35 { finish() }
                })
            .sensoryFeedback(trigger: recording) { _, now in now ? .impact(weight: .medium) : .success }
            .accessibilityElement()
            .accessibilityLabel(recording ? "Save recording" : "Record a note")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if recording { finish() } else { begin() } }
        }
        .padding(.top, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var status: some View {
        if let since = recordingSince {
            VStack(spacing: 2) {
                TimelineView(.periodic(from: since, by: 0.25)) { context in
                    Text(CaptureRules.clock(max(0, context.date.timeIntervalSince(since))))
                        .font(.geist(24, .medium, relativeTo: .title2)).monospacedDigit().contentTransition(.numericText())
                }
                Text((pressedAt != nil && startedHere) || releaseEnds ? "Let go to save" : trigger.holds ? "Tap to save" : "Tap, or make the gesture again, to save")
                    .font(.caption).foregroundStyle(Color.muted).contentTransition(.opacity)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(Array(trigger.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { LucideIcon(.chevronRight, size: 9).foregroundStyle(Color.faint) }
                        StepIcon(step: step, size: 16)
                    }
                }
                Text(trigger.holds ? "or hold the circle" : "or tap the circle").font(.caption)
            }
            .foregroundStyle(Color.muted)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(trigger.start), \(trigger.holds ? "or hold the circle" : "or tap the circle")")
        }
    }
}

// MARK: A note

struct NoteScreen: View {
    @ObservedObject var store: CaptureStore
    let noteID: String
    @State private var text = ""
    @State private var loaded = false
    @State private var confirmDelete = false
    @StateObject private var player = NotePlayer()
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let note = store.note(noteID) { content(note) }
            else { Text("This note was deleted.").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle("Note").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false }.font(.label) }
            } else if let note = store.note(noteID) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if note.hasWords {
                            menuItem("Copy", .copy) { UIPasteboard.general.string = note.text }
                            ShareLink(item: note.text) { Label { Text("Share") } icon: { Lucide.share.image(size: 18) } }
                        }
                        if note.state != .transcribing { menuItem("Write it down again", .rotateCcw) { store.transcribeAgain(noteID) } }
                        menuItem("Delete", .trash2, role: .destructive) { confirmDelete = true }
                    } label: {
                        LucideIcon(.ellipsis, size: 20).frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) { player.stop(); store.delete(noteID); dismiss() }
        } message: { Text("Its recording is deleted too.") }
        .onAppear { if !loaded, let note = store.note(noteID) { text = note.text; loaded = true } }
        .onDisappear { player.stop(); save() }
        .onChange(of: editing) { _, now in if !now { save() } }
        // Words that arrive while the note is open appear, unless it is being edited.
        .onChange(of: store.note(noteID)?.text) { _, new in if let new, !editing { text = new } }
    }

    private func save() { if store.note(noteID) != nil { store.setText(text.trimmingCharacters(in: .whitespacesAndNewlines), for: noteID) } }

    private func content(_ note: CaptureNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(note.at.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(.caption).foregroundStyle(Color.muted)
                VStack(alignment: .leading, spacing: 10) {
                    TextField(note.state == .transcribing ? "Writing it down…" : "No words yet. Type them here.", text: $text, axis: .vertical)
                        .font(.geist(20, relativeTo: .title3)).lineSpacing(6)
                        .focused($editing)
                        .accessibilityLabel("Note text")
                    FocusRule(active: editing)
                }
                PlayerBar(player: player, note: note, url: store.url(for: note))
                if note.state == .unavailable, !note.hasWords {
                    Note("This phone couldn’t put the recording into words. The recording is kept; you can type the note yourself.")
                } else if note.state == .pending {
                    Note("The words for this note are made the next time Runes is open on screen.")
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 16).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Play and pause, the recording's shape filling with ink as it plays, and the time.
/// Drag across the shape to move through it.
private struct PlayerBar: View {
    @ObservedObject var player: NotePlayer
    let note: CaptureNote
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { player.toggle(url) } label: {
                    ZStack {
                        Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                        LucideIcon(player.playing ? .pause : .play, size: 16).offset(x: player.playing ? 0 : 1)
                    }
                    .frame(width: 48, height: 48).contentShape(Circle())
                }
                .buttonStyle(Ripple())
                .accessibilityLabel(player.playing ? "Pause" : "Play recording")
                GeometryReader { geo in
                    Waveform(peaks: note.peaks, progress: player.progress)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            player.seek(url, to: min(1, max(0, value.location.x / max(1, geo.size.width))))
                        })
                }
                .frame(height: 32)
                Text(CaptureRules.clock(player.progress > 0 ? player.progress * note.duration : note.duration))
                    .font(.label).monospacedDigit().foregroundStyle(Color.muted)
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.vertical, 16)
            Rule(inset: 0)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.playing)
    }
}

/// Plays one note's recording.
@MainActor
final class NotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    /// 0 at the start (or stopped) → 1 at the end.
    @Published private(set) var progress = 0.0
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private static let holder = "capture.player"

    private func load(_ url: URL) -> AVAudioPlayer? {
        if let player { return player }
        guard let new = try? AVAudioPlayer(contentsOf: url) else { return nil }
        new.delegate = self
        player = new
        return new
    }

    func toggle(_ url: URL) {
        guard let player = load(url) else { return }
        if player.isPlaying { pause(); return }
        guard (try? AudioHub.activate(Self.holder)) != nil, player.play() else { return }
        playing = true
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func seek(_ url: URL, to fraction: Double) {
        guard let player = load(url) else { return }
        player.currentTime = fraction * player.duration
        progress = fraction
    }

    private func pause() {
        player?.pause()
        playing = false
        ticker?.invalidate(); ticker = nil
        AudioHub.release(Self.holder)
    }

    func stop() {
        guard player != nil else { return }
        pause()
        player = nil; progress = 0
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        progress = player.currentTime / player.duration
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.pause()
            self.progress = 0
        }
    }
}

// MARK: Settings

struct CaptureSettingsScreen: View {
    @ObservedObject var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    @State private var choosingTrigger = false

    private enum Microphone: String, CaseIterable { case phone = "iPhone", headset = "Headphones" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        PocketRow(listening: store.listening, trigger: store.controls.trigger, set: store.setListening)
                    } header: {
                        Heading("Pocket mode")
                    }
                    if let problem = store.problem, problem != .interrupted {
                        NoticeCard(sentence: problem.sentence, actionTitle: problem == .denied ? "Open Settings" : "OK") {
                            if problem == .denied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            else { store.dismissProblem() }
                        }
                    }
                    Block {
                        TriggerRow(title: "Record a note",
                                   detail: store.controls.trigger.holds ? "Records while you hold, and saves when you let go."
                                                                        : "Starts recording. Make it again to save.",
                                   steps: store.controls.trigger.steps) { choosingTrigger = true }
                    } header: {
                        Heading("Band gesture")
                    } footer: {
                        Note("Any gesture or a combo. While Capture is open or pocket mode is on, it belongs to Capture and mappings that use it are off. To record from every screen without reserving a gesture, give a mapping the “Record a Capture note” action instead.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.controls.headset ? Microphone.headset : .phone },
                                                            set: { store.setHeadset($0 == .headset) }),
                                         options: Microphone.allCases, title: \.rawValue)
                    } header: {
                        Heading("Microphone")
                    } footer: {
                        Note("The iPhone’s microphone leaves music in your headphones at full quality. Headphones hear you better from a pocket, but wireless ones drop to call quality for as long as the microphone is on.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.controls.feedback }, set: { store.setFeedback($0) }),
                                         options: CaptureFeedback.allCases, title: \.label)
                    } header: {
                        Heading("Feedback")
                    } footer: {
                        Note(store.controls.feedback == .buzz
                             ? "The phone buzzes once when recording starts and twice when it is saved, three times if it was too short to keep. Away from Runes, a notification says the same."
                             : "A tick when recording starts and a note when it is saved, so you know without looking. In pocket mode these are the only sign: the Lock Screen stays as it is.")
                    }
                    Note("Recordings and their words stay on this phone. They are put into words by iOS on the device, never sent anywhere.")
                    if !store.notes.isEmpty {
                        Button("Delete all notes") { clearing = true }.buttonStyle(.quiet)
                            .confirmationDialog("Delete all notes?", isPresented: $clearing, titleVisibility: .visible) {
                                Button("Delete \(store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes")", role: .destructive, action: store.deleteAll)
                            } message: { Text("Every note and its recording is deleted.") }
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Capture settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(isPresented: $choosingTrigger) { CaptureTriggerSheet(store: store) }
        }
        .tint(Color.ink)
    }
}

/// Chooses the gesture, or builds the combo, that records. One that ends with a finger
/// held records for as long as the hold; anything else starts and, made again, saves.
struct CaptureTriggerSheet: View {
    @ObservedObject var store: CaptureStore

    var body: some View {
        let current = store.controls.trigger
        TriggerSheet(title: "Record a note",
                     rules: .gestureOrCombo(CaptureTrigger.singleChoices, next: CaptureTrigger.comboChoices, allowsNone: false),
                     steps: current.steps, intervalMs: current.intervalMs,
                     feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                     note: { steps in
            CaptureTrigger(steps: steps).holds ? "Ends with a hold: the note records while you hold and saves when you let go."
                                               : "Make it to start recording, and again to save."
        }, save: { steps, interval in store.setTrigger(CaptureTrigger(steps: steps, intervalMs: interval)) })
    }
}

#if DEBUG
extension PreviewFixtures {
    static func peaks(_ seed: Int, count: Int = 112) -> [Float] {
        (0..<count).map { i in
            let x = Double(i + seed * 17)
            return Float(max(0.05, abs(sin(x * 0.31) * sin(x * 0.07 + Double(seed))) * (0.5 + 0.5 * abs(sin(x * 0.011)))))
        }
    }
    static var notes: [CaptureNote] {
        let now = Date()
        func note(_ minutesAgo: Double, _ seconds: Double, _ text: String, _ state: CaptureNote.State = .done) -> CaptureNote {
            CaptureNote(id: "note-\(Int(minutesAgo))", at: now.addingTimeInterval(-minutesAgo * 60), duration: seconds, text: text, state: state, file: "preview.m4a",
                        peaks: peaks(Int(minutesAgo)))
        }
        return [
            note(1, 6, "", .transcribing),
            note(34, 11, "Ask Maya whether the relay test can move to Thursday, and send her the locked-phone numbers first."),
            note(190, 4, "Oat milk, lemons, and the good olive oil."),
            note(60 * 26, 19, "Idea for the ring: let the pods lean toward the finger that tapped, then settle. It should feel like the band noticed you."),
            note(60 * 27, 8, "Call the landlord about the boiler before Friday."),
            note(60 * 75, 5, "", .unavailable),
        ]
    }
    @MainActor static func capture(recording: Bool = false, listening: Bool = false, empty: Bool = false, trigger: CaptureTrigger = .standard) -> CaptureStore {
        let store = CaptureStore(preview: empty ? [] : notes, recording: recording ? Date().addingTimeInterval(-7) : nil, listening: listening, level: recording ? 0.7 : 0)
        store.setTrigger(trigger)
        return store
    }
}

#Preview("Capture") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(), path: .constant([])) } }
#Preview("Capture · recording") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(recording: true, listening: true), path: .constant([])) } }
#Preview("Capture · empty") { NavigationStack { CaptureScreen(store: PreviewFixtures.capture(empty: true), path: .constant([])) } }
#Preview("Note") { NavigationStack { NoteScreen(store: PreviewFixtures.capture(), noteID: PreviewFixtures.notes[1].id) } }
#endif

private extension CaptureFeedback {
    var label: String {
        switch self {
        case .sounds: "Sounds"
        case .buzz: "Buzz"
        case .off: "Off"
        }
    }
}
