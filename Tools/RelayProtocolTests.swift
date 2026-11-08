import Foundation

@main
struct RelayProtocolTests {
    static func main() throws {
        let key = Data(repeating: 7, count: 32)
        let challenges = Data(repeating: 9, count: 64)
        var phone = try RelayWire.Cipher(key: key, challenge: challenges, isPhone: true)
        var mac = try RelayWire.Cipher(key: key, challenge: challenges, isPhone: false)
        let hello = try phone.seal(.hello)
        var framer = RelayWire.Framer()
        var received: [Data] = []
        for byte in hello { received += try framer.append(Data([byte])) }
        precondition(received.count == 1)
        guard case .hello = try mac.open(received[0]) else { preconditionFailure("Expected hello") }
        expectFailure { _ = try mac.open(received[0]) }
        var otherLink = try RelayWire.Cipher(key: key, challenge: Data(repeating: 8, count: 64), isPhone: false)
        expectFailure { _ = try otherLink.open(received[0]) }
        var wrongDirection = try RelayWire.Cipher(key: key, challenge: challenges, isPhone: true)
        expectFailure { _ = try wrongDirection.open(received[0]) }

        let demand = try mac.seal(.demand(.motion))
        guard case .demand(let requested) = try phone.open(Data(demand.dropFirst(2))), requested == .motion else {
            preconditionFailure("Expected motion demand")
        }
        let original = RelayWire.Event(kind: .gyro, sequence: .max, timestamp: .max - 1,
                                       phoneUptime: 100, phoneTime: Date(timeIntervalSince1970: 1),
                                       values: [-32768, 0, 32767])
        let sample = try phone.seal(.event(original))
        var bad = Data(sample.dropFirst(2))
        bad[bad.count - 1] ^= 1
        expectFailure { _ = try mac.open(bad) }
        guard case .event(let decoded) = try mac.open(Data(sample.dropFirst(2))),
              decoded.sequence == original.sequence, decoded.timestamp == original.timestamp,
              decoded.values == original.values else { preconditionFailure("Motion round trip failed") }

        let beat = try mac.seal(.heartbeat(.init(sequence: 41, macTime: Date(timeIntervalSince1970: 2))))
        guard case .heartbeat(let heartbeat) = try phone.open(Data(beat.dropFirst(2))), heartbeat.sequence == 41 else {
            preconditionFailure("Heartbeat round trip failed")
        }
        let ack = try phone.seal(.heartbeatAck(.init(sequence: 41, phoneTime: Date(timeIntervalSince1970: 3),
                                                     applicationState: "background", bandState: "streaming",
                                                     bandDataAge: nil, suspensionGaps: 2, longestGap: 9.5,
                                                     batteryLevel: 0.5, lowPowerMode: false)))
        guard case .heartbeatAck(let reply) = try mac.open(Data(ack.dropFirst(2))), reply.sequence == 41,
              reply.bandDataAge == nil, reply.suspensionGaps == 2, reply.longestGap == 9.5 else {
            preconditionFailure("Heartbeat acknowledgement round trip failed")
        }
        checkWakeTrials()

        var malformed = RelayWire.Framer()
        expectFailure { _ = try malformed.append(Data([0, 0])) }
        expectFailure { _ = try RelayWire.frame(Data(repeating: 0, count: RelayWire.maxFrame + 1)) }
        let now = Date()
        let expired = RelayWire.Invitation(key: key, expires: now)
        let qr = String(decoding: try JSONEncoder().encode(expired), as: UTF8.self)
        expectFailure { _ = try RelayWire.Invitation.parse(qr, now: now) }

        let flags = try Fields(BandProtocol.streamFlags(gyro: true, orientation: true))
        let emg = try flags.integer(2), gesture = try flags.integer(3)
        let gyro = try flags.integer(6), orientation = try flags.integer(8)
        precondition(emg == 0 && gesture == 1 && gyro == 1 && orientation == 1)
        precondition(BandProtocol.gyro(Data([0, 128, 0, 0, 255, 127])) == [-32768, 0, 32767])
        let quaternion = try BandProtocol.orientation(Data([0, 0, 128, 63, 0, 0, 0, 191, 0, 0, 0, 0, 0, 0, 128, 62]))
        precondition(quaternion == [1, -0.5, 0, 0.25])
        expectFailure { _ = try BandProtocol.orientation(Data([0, 0, 128, 127] + Array(repeating: 0, count: 12))) }
        print("BLE relay protocol and band motion checks passed")
    }

    private static func checkWakeTrials() {
        let start = Date(timeIntervalSince1970: 1000)
        var trials = WakeTrials(schedule: [60, 300], window: 30)
        precondition(trials.tick(now: start).isEmpty, "An unstarted run must not prompt")
        trials.start(at: start)
        precondition(trials.tick(now: start.addingTimeInterval(59)).isEmpty)
        precondition(trials.gesture(at: start.addingTimeInterval(59)) == nil, "A gesture outside a prompt is not a trial")
        precondition(trials.tick(now: start.addingTimeInterval(60)) == [.prompt(0)])
        precondition(trials.tick(now: start.addingTimeInterval(61)).isEmpty, "A prompt fires once")
        let hit = trials.gesture(at: start.addingTimeInterval(60.75))
        precondition(hit?.index == 0 && hit?.latency == 0.75)
        precondition(trials.gesture(at: start.addingTimeInterval(61)) == nil, "Only the first gesture counts")
        precondition(trials.tick(now: start.addingTimeInterval(300)) == [.prompt(1)])
        precondition(trials.tick(now: start.addingTimeInterval(330)) == [.missed(1), .finished])
        precondition(trials.tick(now: start.addingTimeInterval(400)).isEmpty, "A finished run stays quiet")
        precondition(trials.results.map(\.latency) == [0.75, nil])

        var answered = WakeTrials(schedule: [10], window: 5)
        answered.start(at: start)
        _ = answered.tick(now: start.addingTimeInterval(10))
        _ = answered.gesture(at: start.addingTimeInterval(11))
        precondition(answered.tick(now: start.addingTimeInterval(12)) == [.finished], "Answering the last prompt ends the run")

        // A suspended Mac can overshoot several deadlines; each trial still resolves in order.
        var late = WakeTrials(schedule: [10, 20], window: 5)
        late.start(at: start)
        precondition(late.tick(now: start.addingTimeInterval(100)) == [.prompt(0), .missed(0), .prompt(1), .missed(1), .finished])

        let offset = WakeTrials.clockOffset(sent: Date(timeIntervalSince1970: 10), phone: Date(timeIntervalSince1970: 15.1),
                                            received: Date(timeIntervalSince1970: 10.2))
        precondition(abs(offset - 5) < 0.0001, "Phone clock offset uses the round-trip midpoint")
    }

    private static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected error")
        } catch {}
    }
}
