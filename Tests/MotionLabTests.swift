// Isolated checks for the Motion Lab recorder and EMG decoding.
//
//     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift \
//       RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift Shared/ProfileIcon.swift Shared/LucideData.swift \
//       Shared/SVGPath.swift RunesIOS/Workouts/ExerciseCatalog.swift RunesIOS/Workouts/WorkoutModel.swift RunesIOS/Protocol/EMG.swift RunesIOS/Workouts/MotionRecorder.swift Tests/MotionLabTests.swift -o /private/tmp/runes-motionlab-tests && /private/tmp/runes-motionlab-tests
import Foundation

@main
struct MotionLabTests {
    static func turn(_ degrees: Double) -> [Double] {
        let half = degrees * .pi / 360
        return [cos(half), sin(half), 0, 0]
    }

    static func main() throws {
        // EMG decode: little-endian u16, sample-major.
        var bytes = Data()
        for i in 0..<128 { bytes.append(UInt8(i & 0xff)); bytes.append(UInt8(i >> 8 | 0x10)) }
        let values = EMG.decode(bytes)
        precondition(values.count == 128 && values[0] == 0x1000 && values[9] == 0x1009, "EMG is little-endian")

        // EMG configuration: accepts only the known layout; a refusal is a value, not a throw.
        func config(_ v: [UInt64], status: UInt64 = 1) -> Data {
            let inner = PB.field(1, v[0]) + PB.field(2, v[1]) + PB.field(4, v[2]) + PB.field(5, v[3]) + PB.field(10, v[4])
            return PB.field(1, 7) + PB.field(2, status) + PB.field(6, PB.field(42, inner))
        }
        if case .failure = EMG.configuration(config([2048, 8, 16, 16, 0])) { preconditionFailure("Known layout accepted") }
        if case .success = EMG.configuration(config([1000, 8, 16, 16, 0])) { preconditionFailure("Other rates rejected") }
        if case .success = EMG.configuration(config([2048, 8, 16, 16, 0], status: 0)) { preconditionFailure("Refusal reported") }
        if case .success = EMG.configuration(Data([0xff])) { preconditionFailure("Garbage reported, not thrown") }

        // Recorder: writes every stream, counts gaps, and runs the shipping detector alongside.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("motionlab-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = MotionRecorder()
        recorder.ingest(RawSample(kind: .gyro, uptime: 0, sequence: 0, timestamp: 0, values: [1, 2, 3]))
        precondition(recorder.snapshot.gyro == 0, "Nothing is kept before start")
        try recorder.start(in: folder, exercise: .bicepCurl)
        precondition(recorder.isRecording)
        var t = 100.0, seq: UInt64 = 1
        for _ in 0..<3 {
            for angle in [0.0, 80, 10] {
                recorder.ingest(RawSample(kind: .orientation, uptime: t, sequence: seq, timestamp: seq * 10_000, values: turn(angle)))
                t += 1; seq += 1
            }
        }
        recorder.ingest(RawSample(kind: .gyro, uptime: t, sequence: 1, timestamp: 1, values: [-5, 6, 7]))
        recorder.ingest(RawSample(kind: .gyro, uptime: t, sequence: 3, timestamp: 2, values: [1, 1, 1]))
        recorder.ingest(RawSample(kind: .emg, uptime: 1.5, sequence: 42, timestamp: 99, emg: values))
        recorder.ingest(RawSample(kind: .gesture, uptime: 2, sequence: 5, timestamp: 6, gesture: [1, 2, 3, 0]))
        recorder.event("mark", "bottom, of rep")
        let counts = recorder.stop()
        precondition(!recorder.isRecording)
        precondition(counts.orientation == 9 && counts.gyro == 2 && counts.emgBatches == 1 && counts.gestures == 1 && counts.marks == 1)
        precondition(counts.detectorReps == 3, "Curl detector counted \(counts.detectorReps), expected 3")
        precondition(counts.gaps["gyro"] == 1 && counts.gaps["orientation"] == nil, "Gaps are per stream")
        precondition(counts.emgLevel.count == 8)

        let gyro = try String(contentsOf: folder.appendingPathComponent("gyro.csv"), encoding: .utf8).split(separator: "\n")
        precondition(gyro.count == 3 && gyro[1].hasSuffix(",-5,6,7"), "gyro.csv: \(gyro)")
        let orientation = try String(contentsOf: folder.appendingPathComponent("orientation.csv"), encoding: .utf8).split(separator: "\n")
        precondition(orientation.count == 10)
        let events = try String(contentsOf: folder.appendingPathComponent("events.csv"), encoding: .utf8)
        precondition(events.components(separatedBy: "detector_rep").count == 4 && events.contains(",mark,bottom; of rep") && events.contains(",stop,"))

        let emg = try Data(contentsOf: folder.appendingPathComponent("emg.bin"))
        precondition(emg.count == 280, "One 280-byte EMG record")
        let uptime = emg.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self))) }
        let sequence = emg.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        let first = emg.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt16.self)) }
        let last = emg.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 278, as: UInt16.self)) }
        precondition(uptime == 1.5 && sequence == 42 && first == values[0] && last == values[127])

        // A second recording starts clean.
        try recorder.start(in: folder, exercise: nil)
        precondition(recorder.snapshot == MotionRecorder.Counts())
        recorder.stop()
        print("MotionLab tests passed")
    }
}
