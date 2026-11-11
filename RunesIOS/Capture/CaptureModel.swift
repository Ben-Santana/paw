import Foundation

// Capture: make a gesture (by default, hold a finger), say the thought, and it is written
// down. Each note keeps its sound and, once it has been transcribed on the phone, its words. These are the values; the microphone is
// CaptureRecorder, the words CaptureTranscriber, and CaptureStore ties them to the band.
// Foundation only, so it is tested without the app (Tests/CaptureTests.swift).

struct CaptureNote: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        /// Being put into words now.
        case transcribing
        /// Has its words (possibly none, when nothing was said).
        case done
        /// Couldn't be transcribed where it was recorded; tried again when Runes is opened.
        case pending
        /// This phone can't transcribe the language it is set to.
        case unavailable
    }

    var id = UUID().uuidString.lowercased()
    var at: Date
    /// Seconds of sound.
    var duration: Double
    var text = ""
    var state = State.transcribing
    /// The sound file's name in Capture's folder.
    var file: String
    /// The loudest moment of each slice of the recording, 0...1, for the waveform.
    var peaks: [Float] = []

    /// What a row shows: the words, or what is happening to them.
    var summary: String {
        if !text.isEmpty { return text }
        switch state {
        case .transcribing: return "Writing it down…"
        case .pending: return "Voice note. Its words arrive when you open Runes."
        case .unavailable: return "Voice note"
        case .done: return "Nothing was said"
        }
    }
    var hasWords: Bool { !text.isEmpty }
}

/// What starts a recording from the band: one gesture, or a combo of two to eight finger
/// and swipe steps. Making it again saves the recording. When it ends with a finger held
/// (a hold on its own, or a combo whose last step is one), the recording lasts as long as
/// the hold and saves when the finger lets go.
struct CaptureTrigger: Codable, Hashable, Sendable {
    var steps: [ComboStep]
    var intervalMs = ComboRules.defaultTime

    static func gesture(_ kind: GestureKind) -> CaptureTrigger { CaptureTrigger(steps: [ComboStep(kind)]) }
    /// Hold your index finger, speak, let go.
    static let standard = gesture(.holdIndex)

    var isCombo: Bool { steps.count > 1 }
    /// The gesture when this is a single one.
    var gesture: GestureKind? { isCombo ? nil : steps.first?.gesture }
    /// "Double tap index", "Swipe up, then tap and hold index".
    var name: String {
        steps.enumerated().map { $0.offset == 0 ? $0.element.name : $0.element.name.lowercased() }.joined(separator: ", then ")
    }

    /// Gestures a trigger may use on its own. Releases only make sense inside a combo.
    static let singleChoices = GestureKind.motions
    /// Steps a combo may use: finger gestures and swipes. Motion and air gestures would
    /// keep the band's motion streams on for as long as Capture waits.
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] {
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }

    var isValid: Bool {
        if let gesture { return Self.singleChoices.contains(gesture) }
        return ComboRules.valid(steps) && ComboRules.times.contains(intervalMs)
            && steps.allSatisfy { !$0.gesture.isMotion && !$0.gesture.isAir }
    }

    /// The finger letting go, when the trigger ends with that finger held. That release
    /// saves the recording; without one, making the trigger again does.
    var release: GestureKind? { steps.last?.gesture.release }
    var holds: Bool { release != nil }

    /// The gestures Capture takes while it waits for the trigger; mappings that use one
    /// are off meanwhile. A double tap arrives after the tap that began it and a hold
    /// ends with a release, so those are taken with them.
    var reserved: Set<GestureKind> {
        var gestures = Set(steps.map(\.gesture))
        if gestures.contains(.doubleTapIndex) { gestures.insert(.tapIndex) }
        if gestures.contains(.doubleTapMiddle) { gestures.insert(.tapMiddle) }
        if gestures.contains(.holdIndex) { gestures.insert(.releaseIndex) }
        if gestures.contains(.holdMiddle) { gestures.insert(.releaseMiddle) }
        return gestures
    }

    static let comboID = "capture:record"
    /// The trigger as a mapping, for a `MappingEngine` that only decides when it was made.
    /// A single gesture's mapping must be named after it; the placeholder action never runs.
    var mapping: Mapping {
        if let gesture { return Mapping(id: gesture.rawValue, enabled: true, actions: [.haptic(.light)]) }
        return Mapping(id: Self.comboID, enabled: true, actions: [.haptic(.light)], steps: steps, intervalMs: intervalMs)
    }

    /// How to start, as the beginning of a sentence: "Hold your index finger", "Double tap index".
    var start: String {
        switch gesture {
        case .holdIndex: "Hold your index finger"
        case .holdMiddle: "Hold your middle finger"
        default: name
        }
    }
    /// How to save, as the end of one: "let go", "do it again".
    var stop: String { holds ? "let go" : "do it again" }
}

/// How Capture records: what starts it from the band, its sounds and its microphone.
struct CaptureControls: Codable, Hashable, Sendable {
    var trigger = CaptureTrigger.standard
    /// A tick when recording starts and a note when it is saved, to do it without looking.
    var sounds = true
    /// Record with the headphones' microphone instead of the phone's.
    var headset = false

    /// The gestures Capture takes while it can record; mappings that use them are off.
    var reserved: Set<GestureKind> { trigger.reserved }

    private enum Keys: String, CodingKey { case trigger, hold, sounds, headset }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let saved = try? c.decode(CaptureTrigger.self, forKey: .trigger), saved.isValid {
            trigger = saved
        } else if let hold = try? c.decode(GestureKind.self, forKey: .hold), hold.isHold {
            // Settings saved when only a hold could record.
            trigger = .gesture(hold)
        }
        sounds = (try? c.decode(Bool.self, forKey: .sounds)) ?? true
        headset = (try? c.decode(Bool.self, forKey: .headset)) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(sounds, forKey: .sounds)
        try c.encode(headset, forKey: .headset)
    }
}

enum CaptureRules {
    /// A hold shorter than this was a slip, not a note.
    static let minimum = 0.6
    /// A hold whose release never arrives (the band went out of range) stops here.
    static let maximum = 300.0
    /// Sound kept from just before the hold was recognised, so the first word isn't cut.
    static let preroll = 0.8
    /// Bars in a note's waveform.
    static let bars = 56

    /// "0:07", "12:30".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The first words of a note, for the Lock Screen.
    static func snippet(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? line.prefix(limit).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Any number of peaks as `bars` bars, each the loudest of its share, scaled so the
    /// loudest bar is full height and silence still shows as a dot.
    static func waveform(_ peaks: [Float], bars: Int = bars) -> [Float] {
        guard bars > 0 else { return [] }
        guard !peaks.isEmpty else { return Array(repeating: 0.04, count: bars) }
        var result: [Float] = []
        for bar in 0..<bars {
            let from = bar * peaks.count / bars, to = max(from + 1, (bar + 1) * peaks.count / bars)
            result.append(peaks[min(from, peaks.count - 1)..<min(to, peaks.count)].max() ?? 0)
        }
        let top = max(result.max() ?? 0, 0.02)
        return result.map { max(0.04, min(1, $0 / top)) }
    }

    /// A microphone level (0...1 linear) as something to draw: quiet speech still moves it.
    static func meter(_ level: Float) -> Double {
        guard level > 0.0005 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// Notes grouped by the day they were taken, newest first.
struct CaptureDay: Identifiable, Hashable, Sendable {
    var id: String { title }
    var title: String
    var notes: [CaptureNote]

    static func group(_ notes: [CaptureNote], now: Date = Date(), calendar: Calendar = .current) -> [CaptureDay] {
        let today = calendar.startOfDay(for: now)
        var days: [CaptureDay] = []
        var starts: [Date] = []
        for note in notes.sorted(by: { $0.at > $1.at }) {
            let start = calendar.startOfDay(for: note.at)
            if let index = starts.firstIndex(of: start) { days[index].notes.append(note); continue }
            let ago = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            let title: String
            switch ago {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = start.formatted(.dateTime.weekday(.wide))
            default: title = start.formatted(.dateTime.day().month(.wide))
            }
            starts.append(start); days.append(CaptureDay(title: title, notes: [note]))
        }
        return days
    }

    /// Notes taken on the same day as `now`.
    static func today(_ notes: [CaptureNote], now: Date = Date(), calendar: Calendar = .current) -> Int {
        notes.filter { calendar.isDate($0.at, inSameDayAs: now) }.count
    }
}
