import Foundation

/// One raw sample from the band, as received on the transport queue.
struct RawSample: Sendable {
    enum Kind: String, Sendable { case gyro, orientation, emg, gesture }
    let kind: Kind
    /// Phone uptime (seconds) when the packet was received.
    let uptime: TimeInterval
    let sequence: UInt64
    /// Band clock (microseconds, per the band's own clock domain).
    let timestamp: UInt64
    var values: [Double] = []
    /// EMG: 16 samples × 8 channels, sample-major.
    var emg: [UInt16] = []
    /// Gesture: finger, action, derived action, synthetic.
    var gesture: [UInt64] = []
}

/// Writes raw samples to disk while a set is recorded. `ingest` runs on the transport queue;
/// file writes happen on a private queue so Bluetooth handling never waits on the disk.
final class MotionRecorder: @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var gyro = 0, orientation = 0, emgBatches = 0, gestures = 0
        var gaps: [String: Int] = [:]
        var detectorReps = 0
        /// Peak-to-peak of each EMG channel in the latest batch, for the live meter.
        var emgLevel: [Double] = []
        var marks = 0
    }
    private struct Stream {
        let handle: FileHandle
        var buffer = Data()
    }
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "com.runes.ios.motionlab.writer")
    private var streams: [RawSample.Kind: Stream] = [:]
    private var events: Stream?
    private var counts = Counts()
    private var lastSequence: [RawSample.Kind: UInt64] = [:]
    private var detector: RepCounter?
    private static let flushBytes = 128 * 1024

    var isRecording: Bool { lock.withLock { !streams.isEmpty } }
    var snapshot: Counts { lock.withLock { counts } }

    func start(in folder: URL, exercise: Exercise?) throws {
        let files: [(RawSample.Kind, String, String)] = [
            (.gyro, "gyro.csv", "phone_uptime_s,seq,band_ts_us,x,y,z\n"),
            (.orientation, "orientation.csv", "phone_uptime_s,seq,band_ts_us,w,x,y,z\n"),
            (.emg, "emg.bin", ""),
            (.gesture, "gestures.csv", "phone_uptime_s,seq,band_ts_us,finger,action,derived,synthetic\n"),
        ]
        var opened: [RawSample.Kind: Stream] = [:]
        for (kind, name, header) in files {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)) else { throw BandError.storage("Could not create \(name).") }
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
            opened[kind] = Stream(handle: handle)
        }
        let eventsURL = folder.appendingPathComponent("events.csv")
        guard FileManager.default.createFile(atPath: eventsURL.path, contents: Data("phone_uptime_s,kind,detail\n".utf8)) else { throw BandError.storage("Could not create events.csv.") }
        let eventsHandle = try FileHandle(forWritingTo: eventsURL); try eventsHandle.seekToEnd()
        lock.withLock {
            streams = opened; events = Stream(handle: eventsHandle)
            counts = Counts(); lastSequence = [:]
            detector = exercise.flatMap { $0.detectsReps ? RepCounter(exercise: $0) : nil }
        }
        event("start", exercise.map { "detector=\($0.detectsReps)" } ?? "")
    }

    /// Flushes and closes every file. Returns the final counts.
    @discardableResult
    func stop() -> Counts {
        event("stop", "")
        let (open, eventStream, final) = lock.withLock { () -> ([Stream], Stream?, Counts) in
            let all = Array(streams.values), e = events
            streams = [:]; events = nil; detector = nil
            return (all, e, counts)
        }
        writer.sync {
            for stream in open + [eventStream].compactMap({ $0 }) {
                try? stream.handle.write(contentsOf: stream.buffer)
                try? stream.handle.close()
            }
        }
        return final
    }

    func event(_ kind: String, _ detail: String, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let clean = detail.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        lock.withLock {
            guard events != nil else { return }
            if kind == "mark" { counts.marks += 1 }
            events!.buffer.append(Data(String(format: "%.6f,%@,%@\n", uptime, kind, clean).utf8))
            flushEventsIfNeeded(force: true)
        }
    }

    func ingest(_ sample: RawSample) {
        lock.lock(); defer { lock.unlock() }
        guard var stream = streams[sample.kind] else { return }
        if let last = lastSequence[sample.kind], sample.sequence != last &+ 1 {
            counts.gaps[sample.kind.rawValue, default: 0] += 1
        }
        lastSequence[sample.kind] = sample.sequence
        let prefix = String(format: "%.6f,%llu,%llu", sample.uptime, sample.sequence, sample.timestamp)
        switch sample.kind {
        case .gyro:
            counts.gyro += 1
            stream.buffer.append(Data((prefix + "," + sample.values.map { String(Int($0)) }.joined(separator: ",") + "\n").utf8))
            feedDetector(orientation: false, sample)
        case .orientation:
            counts.orientation += 1
            stream.buffer.append(Data((prefix + "," + sample.values.map { String(format: "%.7f", $0) }.joined(separator: ",") + "\n").utf8))
            feedDetector(orientation: true, sample)
        case .gesture:
            counts.gestures += 1
            stream.buffer.append(Data((prefix + "," + sample.gesture.map(String.init).joined(separator: ",") + "\n").utf8))
        case .emg:
            // Binary record, little-endian: f64 phone uptime, u64 seq, u64 band ts, 128 × u16 (16 samples × 8 ch).
            counts.emgBatches += 1
            var record = Data(capacity: 280)
            var u = sample.uptime.bitPattern.littleEndian, s = sample.sequence.littleEndian, t = sample.timestamp.littleEndian
            withUnsafeBytes(of: &u) { record.append(contentsOf: $0) }
            withUnsafeBytes(of: &s) { record.append(contentsOf: $0) }
            withUnsafeBytes(of: &t) { record.append(contentsOf: $0) }
            for value in sample.emg { var v = value.littleEndian; withUnsafeBytes(of: &v) { record.append(contentsOf: $0) } }
            stream.buffer.append(record)
            if sample.emg.count == 128 {
                counts.emgLevel = (0..<8).map { ch in
                    let column = stride(from: ch, to: 128, by: 8).map { Double(sample.emg[$0]) }
                    return (column.max() ?? 0) - (column.min() ?? 0)
                }
            }
        }
        if stream.buffer.count >= Self.flushBytes {
            let chunk = stream.buffer, handle = stream.handle
            stream.buffer = Data()
            writer.async { try? handle.write(contentsOf: chunk) }
        }
        streams[sample.kind] = stream
    }

    /// Runs the shipping detector alongside, so the export shows exactly what it would have counted.
    private func feedDetector(orientation: Bool, _ sample: RawSample) {
        guard detector != nil else { return }
        let rep = orientation ? detector!.orientation(sample.values, at: sample.uptime) : detector!.gyroscope(sample.values, at: sample.uptime)
        guard rep else { return }
        counts.detectorReps += 1
        events?.buffer.append(Data(String(format: "%.6f,detector_rep,%d\n", sample.uptime, counts.detectorReps).utf8))
        flushEventsIfNeeded(force: false)
    }

    private func flushEventsIfNeeded(force: Bool) {
        guard var e = events, force || e.buffer.count > 4096 else { return }
        let chunk = e.buffer, handle = e.handle
        e.buffer = Data(); events = e
        writer.async { try? handle.write(contentsOf: chunk) }
    }
}
