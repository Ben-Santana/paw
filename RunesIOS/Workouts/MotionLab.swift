import Foundation
import UIKit

// Workout data: while a workout runs, every raw band sample (gyro, orientation, gestures and
// 8-channel EMG) is written to disk, with the workout's own events (set start, reps counted,
// set logged) on the same clock, so detectors can be tuned and built offline from real sessions.
// Nothing here changes how workouts count reps.

/// One logged set, as stored in meta.json.
struct LabSet: Codable, Hashable {
    var exerciseID: String
    var exerciseName: String
    var group: String
    var equipment: String
    var measure: String
    var primaryMuscles: [String]
    /// The shipping detector at recording time, e.g. "swing high=70 low=30"; nil when none.
    var detector: String?
    var label: String
    var target: Int
    var weight: Double?
    /// What the workout logged: reps (detector count, or the target when the band can't count),
    /// or seconds held.
    var logged: Int
    /// True when `logged` is the target because the band has no detector for this exercise.
    var assumed: Bool
    var loggedAt: Date

    init(_ log: SetLog) {
        let e = log.exercise
        exerciseID = e.id; exerciseName = e.name; group = e.group.rawValue; equipment = e.equipment.rawValue
        measure = e.measure.rawValue; primaryMuscles = e.primary.map(\.rawValue)
        detector = Self.detector(e)
        label = log.slot.label; target = log.slot.target; weight = log.slot.weight
        logged = log.reps; assumed = log.slot.assumed; loggedAt = log.at
    }

    static func detector(_ e: Exercise) -> String? {
        switch e.signal {
        case .swing(let high, let low)?: "swing high=\(high) low=\(low)"
        case .burst(let on, let off)?: "burst on=\(on) off=\(off)"
        case nil: nil
        }
    }
}

/// meta.json in each workout's folder.
struct LabMeta: Codable, Identifiable, Hashable {
    var id: String
    var workoutName: String
    var planID: String
    var workoutStarted: Date
    var bandHand: String?
    var weightUnit: String
    var startedAt: Date
    var endedAt: Date?
    var startUptime: Double
    var endUptime: Double?
    var gyroSamples = 0
    var orientationSamples = 0
    var emgBatches = 0
    var gestureEvents = 0
    var sequenceGaps: [String: Int] = [:]
    var sets: [LabSet] = []
    var emgStatus = ""
    /// Raw recording stopped at the time limit before the workout ended.
    var capped = false
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    /// False until the workout ends; stays false if the app quit mid-workout.
    var complete = false
    /// Folder size on disk; not saved.
    var bytes: Int64 = 0

    private enum CodingKeys: String, CodingKey {
        case id, workoutName, planID, workoutStarted, bandHand, weightUnit, startedAt, endedAt, startUptime, endUptime,
             gyroSamples, orientationSamples, emgBatches, gestureEvents, sequenceGaps, sets, emgStatus, capped, appVersion, complete
    }

    var duration: TimeInterval { (endUptime ?? ProcessInfo.processInfo.systemUptime) - startUptime }
}

/// What a running workout tells the recorder. Sent by `WorkoutStore`.
enum WorkoutTrace {
    case began(WorkoutRun)
    case event(String, String)
    case ended(WorkoutRun)
}

@MainActor
final class MotionLab: ObservableObject {
    static let shared = MotionLab()
    nonisolated static let recorder = MotionRecorder()
    private static let enabledKey = "runes.workoutdata.enabled"
    /// Raw recording stops after this long even if the workout is never ended.
    static let limit: TimeInterval = 3 * 3600

    struct Live: Equatable {
        var gyroHz = 0.0, orientationHz = 0.0, emgHz = 0.0
        var counts = MotionRecorder.Counts()
    }

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    @Published private(set) var recordings: [LabMeta] = []
    /// The workout being recorded.
    @Published private(set) var active: LabMeta?
    @Published private(set) var live = Live()
    @Published var emgStatus = "EMG turns on when a workout starts."
    @Published private(set) var problem: String?
    /// Asks the session for motion + EMG streams while true.
    var onDemand: ((Bool) -> Void)?
    private var ticker: Task<Void, Never>?

    let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkoutData", isDirectory: true)

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        reload()
    }

    func reload() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  var meta = try? decoder.decode(LabMeta.self, from: data) else { return nil }
            meta.bytes = Self.size(of: folder)
            return meta
        }
        .filter { $0.id != active?.id }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func trace(_ trace: WorkoutTrace, hand: Handedness?, unit: WeightUnit) {
        switch trace {
        case .began(let run): begin(run, hand: hand, unit: unit)
        case .event(let kind, let detail): if active != nil { Self.recorder.event(kind, detail) }
        case .ended(let run): finish(run)
        }
    }

    private func begin(_ run: WorkoutRun, hand: Handedness?, unit: WeightUnit) {
        if active != nil { stopRecording(capped: false) }
        guard enabled else { return }
        problem = nil
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        let slug = run.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let id = "\(stamp)_\(String(slug).prefix(40))"
        let meta = LabMeta(id: id, workoutName: run.name, planID: run.planID, workoutStarted: run.started,
                           bandHand: hand?.rawValue, weightUnit: unit.rawValue, startedAt: now, startUptime: uptime)
        do {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            // Written with the phone locked, so files must stay writable after first unlock.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try write(meta)
            try Self.recorder.start(in: folder, exercise: nil)
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
            return
        }
        active = meta
        Self.recorder.event("workout_start", "plan=\(run.planID) name=\(run.name) slots=\(run.remaining)")
        onDemand?(true)
        startTicker()
    }

    /// Ends the raw recording; the workout itself may carry on.
    private func stopRecording(capped: Bool) {
        guard var meta = active else { return }
        if capped { Self.recorder.event("capped", "time limit") }
        let counts = Self.recorder.stop()
        onDemand?(false)
        ticker?.cancel(); ticker = nil
        meta.endedAt = Date(); meta.endUptime = ProcessInfo.processInfo.systemUptime
        meta.gyroSamples = counts.gyro; meta.orientationSamples = counts.orientation
        meta.emgBatches = counts.emgBatches; meta.gestureEvents = counts.gestures
        meta.sequenceGaps = counts.gaps
        meta.emgStatus = emgStatus
        meta.capped = capped
        try? write(meta)
        active = nil
        reload()
    }

    /// Saves the workout's logged sets into its recording, even one stopped at the time limit.
    private func finish(_ run: WorkoutRun) {
        if active?.workoutStarted == run.started { Self.recorder.event("workout_end", "sets=\(run.logs.count)") }
        stopRecording(capped: false)
        guard var meta = recordings.first(where: { $0.workoutStarted == run.started }) else { return }
        meta.sets = run.logs.map(LabSet.init)
        meta.complete = true
        do { try write(meta) } catch { problem = "Could not save: \(error.localizedDescription)" }
        reload()
    }

    func delete(_ meta: LabMeta) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(meta.id)); reload()
    }

    func deleteAll() {
        for meta in recordings { try? FileManager.default.removeItem(at: root.appendingPathComponent(meta.id)) }
        reload()
    }

    var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }

    private static func size(of folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Zips every finished recording plus a README describing the formats.
    func export() async -> URL? {
        let root = self.root
        let skip = active?.id
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Self.readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let name = "WorkoutData-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))).zip"
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            // Copy finished recordings aside so a running workout's open files are never zipped.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutData-export", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where item.lastPathComponent != skip {
                    try FileManager.default.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
                }
            } catch { return nil }
            defer { try? FileManager.default.removeItem(at: staging) }
            var result: URL?, coordinatorError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinatorError) { zip in
                let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.copyItem(at: zip, to: target)) != nil { result = target }
            }
            return result
        }.value
    }

    private func write(_ meta: LabMeta) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: root.appendingPathComponent(meta.id).appendingPathComponent("meta.json"),
                                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func startTicker() {
        ticker?.cancel()
        live = Live()
        ticker = Task { [weak self] in
            var previous = MotionRecorder.Counts(), previousTime = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000))
                guard let self, !Task.isCancelled else { return }
                if let active = self.active, active.duration > Self.limit { self.stopRecording(capped: true); return }
                let counts = Self.recorder.snapshot, now = ProcessInfo.processInfo.systemUptime
                let dt = max(now - previousTime, 0.001)
                self.live = Live(gyroHz: Double(counts.gyro - previous.gyro) / dt,
                                 orientationHz: Double(counts.orientation - previous.orientation) / dt,
                                 emgHz: Double(counts.emgBatches - previous.emgBatches) * 16 / dt,
                                 counts: counts)
                previous = counts; previousTime = now
            }
        }
    }

    static let readme = """
    # Runes workout data export

    One folder per workout: `<timestamp>_<workout-name>/`. Recording runs from workout start to
    workout end (at most 3 hours), so rests between sets are included.

    ## meta.json
    Workout name and plan, band hand, weight unit, start/end (wall clock and phone uptime), sample
    counts, sequence gaps per stream, EMG status, and `sets`: every set the workout logged, with
    exercise, muscles, the shipping detector (`detector`, nil = none), target, weight, and `logged`
    (reps the detector counted, seconds held for timed exercises, or the target when `assumed`).
    `logged` is what the app counted, not hand-checked ground truth.
    `complete` false = the app quit before the workout ended (sets missing; the last ~128 KB per
    stream may be lost). `capped` true = raw recording stopped at the time limit.

    ## events.csv
    `phone_uptime_s, kind, detail` on the same clock as the samples:
    `workout_start`, `command` (start/stop/repeatLast/skip and the phase change), `set_start`
    (exercise, set, target, weight), `rep` (the shipping detector counted a rep; running count),
    `set_logged` (exercise, logged value), `workout_end`, `capped`, `stop`.

    ## gyro.csv
    `phone_uptime_s, seq, band_ts_us, x, y, z` — raw signed 16-bit gyroscope counts (scale uncalibrated).

    ## orientation.csv
    `phone_uptime_s, seq, band_ts_us, w, x, y, z` — orientation quaternion (axes uncalibrated).

    ## emg.bin
    Fixed 280-byte little-endian records:
    `f64 phone_uptime_s, u64 seq, u64 band_ts_us, u16[128]` — 16 samples × 8 channels,
    sample-major (sample0 ch0..ch7, sample1 ch0..ch7, …). 2048 Hz, 16-bit unsigned ADC counts.
    Python: `np.frombuffer(raw, dtype=[('t','<f8'),('seq','<u8'),('ts','<u8'),('emg','<u2',(16,8))])`

    ## gestures.csv
    `phone_uptime_s, seq, band_ts_us, finger, action, derived, synthetic` — the band's own gesture events.
    """
}
