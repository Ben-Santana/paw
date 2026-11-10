import Foundation
import UIKit

// Motion Lab: records every raw band sample during a set, labelled with the exercise and the
// reps actually done, so detectors can be tuned and new ones built from real data offline.
// Nothing here changes how workouts count reps.

/// What a recording is of: a catalog exercise, or a free-form name.
struct LabTarget: Hashable, Identifiable {
    let id: String
    let name: String
    let exercise: Exercise?
    init(_ exercise: Exercise) { id = exercise.id; name = exercise.name; self.exercise = exercise }
    init(custom name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "Other movement" : trimmed
        id = "custom:" + self.name.lowercased().replacingOccurrences(of: " ", with: "-")
        exercise = nil
    }
}

/// meta.json in each recording folder.
struct LabMeta: Codable, Identifiable, Hashable {
    var id: String
    var exerciseID: String
    var exerciseName: String
    var group: String?
    var equipment: String?
    var measure: String?
    var primaryMuscles: [String] = []
    /// The shipping detector at recording time, e.g. "swing high=70 low=30"; nil when none.
    var detector: String?
    var bandHand: String?
    var startedAt: Date
    var endedAt: Date?
    var startUptime: Double
    var endUptime: Double?
    var gyroSamples = 0
    var orientationSamples = 0
    var emgBatches = 0
    var gestureEvents = 0
    var sequenceGaps: [String: Int] = [:]
    var marks = 0
    var detectorReps: Int?
    /// Ground truth entered after the set.
    var actualReps: Int?
    var heldSeconds: Int?
    var weight = ""
    /// "moving", "still" or "both": did the arm wearing the band do the movement?
    var bandArm = "moving"
    var notes = ""
    var emgStatus = ""
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    var saved = false

    var duration: TimeInterval { (endUptime ?? startUptime) - startUptime }
}

@MainActor
final class MotionLab: ObservableObject {
    static let shared = MotionLab()
    nonisolated static let recorder = MotionRecorder()

    struct Live: Equatable {
        var gyroHz = 0.0, orientationHz = 0.0, emgHz = 0.0
        var counts = MotionRecorder.Counts()
    }

    @Published private(set) var recordings: [LabMeta] = []
    /// The set being recorded.
    @Published private(set) var active: LabMeta?
    /// A finished set waiting for its rep count.
    @Published var draft: LabMeta?
    @Published private(set) var live = Live()
    @Published var emgStatus = "EMG turns on when a recording starts."
    @Published private(set) var problem: String?
    /// Asks the session for motion + EMG streams while true.
    var onDemand: ((Bool) -> Void)?
    private var ticker: Task<Void, Never>?

    let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MotionLab", isDirectory: true)

    private init() { reload() }

    func reload() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(LabMeta.self, from: data)
        }
        .filter { $0.id != active?.id && $0.id != draft?.id }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func recordings(for target: LabTarget) -> [LabMeta] { recordings.filter { $0.exerciseID == target.id } }

    func start(_ target: LabTarget, hand: Handedness?) {
        guard active == nil, draft == nil else { return }
        problem = nil
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        let id = "\(stamp)_\(target.id.replacingOccurrences(of: ":", with: "-"))"
        var meta = LabMeta(id: id, exerciseID: target.id, exerciseName: target.name, startedAt: now, startUptime: uptime)
        if let e = target.exercise {
            meta.group = e.group.rawValue; meta.equipment = e.equipment.rawValue; meta.measure = e.measure.rawValue
            meta.primaryMuscles = e.primary.map(\.rawValue)
            switch e.signal {
            case .swing(let high, let low)?: meta.detector = "swing high=\(high) low=\(low)"
            case .burst(let on, let off)?: meta.detector = "burst on=\(on) off=\(off)"
            case nil: meta.detector = nil
            }
        }
        meta.bandHand = hand?.rawValue
        do {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(meta)
            try Self.recorder.start(in: folder, exercise: target.exercise)
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
            return
        }
        active = meta
        UIApplication.shared.isIdleTimerDisabled = true
        onDemand?(true)
        startTicker()
    }

    func mark() { Self.recorder.event("mark", "") }

    func stop() {
        guard var meta = active else { return }
        let counts = Self.recorder.stop()
        onDemand?(false)
        ticker?.cancel(); ticker = nil
        UIApplication.shared.isIdleTimerDisabled = false
        meta.endedAt = Date(); meta.endUptime = ProcessInfo.processInfo.systemUptime
        meta.gyroSamples = counts.gyro; meta.orientationSamples = counts.orientation
        meta.emgBatches = counts.emgBatches; meta.gestureEvents = counts.gestures
        meta.sequenceGaps = counts.gaps; meta.marks = counts.marks
        meta.detectorReps = meta.detector == nil ? nil : counts.detectorReps
        meta.emgStatus = emgStatus
        if meta.measure == Measure.seconds.rawValue { meta.heldSeconds = Int(meta.duration.rounded()) }
        else { meta.actualReps = meta.detectorReps ?? 10 }
        try? write(meta)
        active = nil; draft = meta
    }

    func save(_ meta: LabMeta) {
        var meta = meta; meta.saved = true
        do { try write(meta) } catch { problem = "Could not save: \(error.localizedDescription)" }
        draft = nil; reload()
    }

    func discardDraft() {
        if let draft { try? FileManager.default.removeItem(at: root.appendingPathComponent(draft.id)) }
        draft = nil; reload()
    }

    func delete(_ meta: LabMeta) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(meta.id)); reload()
    }

    func deleteAll() {
        guard active == nil else { return }
        for meta in recordings { try? FileManager.default.removeItem(at: root.appendingPathComponent(meta.id)) }
        reload()
    }

    var totalBytes: Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Zips every saved recording plus a README describing the formats.
    func export() async -> URL? {
        guard active == nil else { return nil }
        let root = self.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Self.readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let name = "MotionLab-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))).zip"
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            var result: URL?, coordinatorError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinatorError) { zip in
                let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.copyItem(at: zip, to: target)) != nil { result = target }
            }
            return result
        }.value
    }

    private func write(_ meta: LabMeta) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: root.appendingPathComponent(meta.id).appendingPathComponent("meta.json"), options: .atomic)
    }

    private func startTicker() {
        ticker?.cancel()
        live = Live()
        ticker = Task { [weak self] in
            var previous = MotionRecorder.Counts(), previousTime = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
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
    # Runes Motion Lab export

    One folder per recorded set: `<timestamp>_<exerciseID>/`.

    ## meta.json
    Exercise, the shipping detector at the time (`detector`, nil = none), band hand, start/end
    (wall clock and phone uptime), sample counts, sequence gaps per stream, the detector's rep count
    (`detectorReps`), and ground truth entered after the set: `actualReps` or `heldSeconds`,
    `weight`, `bandArm` (moving / still / both), `notes`. `saved` false = app quit before labelling.

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

    ## events.csv
    `phone_uptime_s, kind, detail` — `start`, `stop`, `mark` (user tapped Mark), `detector_rep` (the
    shipping detector counted a rep at this moment).
    """
}
