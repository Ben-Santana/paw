// Isolated checks for reconnect, sequence and wording rules. No Core Bluetooth, Keychain or network.
import Foundation

@main
struct SessionPolicyTests {
    static func main() {
        // 1. Gesture sequences: the band keeps separate raw and derived counters.
        // This is the interleaving recorded on 2026-11-08 (raw 0,1,2… / derived 0,1,2,3…).
        let recorded: [(seq: UInt64, action: UInt64, derived: UInt64)] = [
            (0, 1, 0), (0, 0, 9), (1, 2, 0), (1, 0, 4), (2, 0, 1), (2, 1, 0), (3, 0, 9), (3, 2, 0), (4, 0, 4), (5, 0, 1),
            (4, 1, 0), (6, 0, 9), (5, 2, 0), (7, 0, 4), (8, 0, 1), (9, 0, 2)]
        var tracker = SequenceTracker()
        for packet in recorded {
            let stream: GestureStream = packet.action != 0 ? .raw : .derived
            precondition(tracker.gap(packet.seq, stream: stream) == nil, "Interleaved streams must not be reported as gaps")
        }
        precondition(tracker.gap(12, stream: .derived) == 9, "A real gap on one stream is still reported")
        precondition(tracker.gap(7, stream: .raw) == 5, "Raw stream gap is reported against the raw counter")
        tracker.reset()
        precondition(tracker.gap(100, stream: .raw) == nil, "A new connection starts fresh")
        precondition(tracker.gap(0, stream: .raw) == 100, "Wrap is a discontinuity unless it follows 0xffffffff")
        var wrap = SequenceTracker(); _ = wrap.gap(0xffffffff, stream: .raw)
        precondition(wrap.gap(0, stream: .raw) == nil, "32-bit wrap is continuous")

        // 2. Reconnect never gives up on ordinary errors.
        for error in [BandError.transport("lost"), .wire("bad frame"), .storage("locked"), .cancelled] {
            precondition(!ConnectionRetryPolicy.stopsAutoConnect(error), "\(error) must keep auto-connect on")
        }
        for error in [BandError.authentication("rejected"), .pairing("bond mismatch"),
                      .bluetooth(domain: "CBErrorDomain", code: 14, description: "Peer removed pairing information", fallback: "Failed")] {
            precondition(ConnectionRetryPolicy.stopsAutoConnect(error), "\(error) needs the person")
        }
        precondition(!ConnectionRetryPolicy.stopsAutoConnect(.bluetooth(domain: "CBErrorDomain", code: 6, description: "Timeout", fallback: "Failed")))
        precondition(ConnectionRetryPolicy.backoff(failures: 1) == 1)
        precondition(ConnectionRetryPolicy.backoff(failures: 5) == 16)
        for failures in 1...1_000 {
            let delay = ConnectionRetryPolicy.backoff(failures: failures)
            precondition(delay >= 1 && delay <= ConnectionRetryPolicy.ceiling, "Backoff stays bounded and never stops")
        }

        // 3. Interface wording: one plain sentence and one action, no protocol vocabulary.
        let banned = ["l2cap", "psm", "gatt", "uuid", "fingerprint", "compatibility", "enroll", "identity", "cberror", "protocol", "feb8", "fd5f"]
        for issue in SessionIssue.allCases {
            let words = (issue.sentence + " " + issue.actionTitle).lowercased()
            for word in banned { precondition(!words.contains(word), "\(issue) mentions \(word)") }
            precondition(issue.sentence.count <= 60, "\(issue) sentence is short")
        }
        precondition(SessionIssue.from(.transport("x")) == .bandNotNearby)
        precondition(SessionIssue.from(.pairing("x")).action == .setUpAgain)
        for message in ["Band authentication timed out at trust. Retry in the foreground.",
                        "Band rejected host identity (result 0x3001043, channel 2). Check the selected public host fingerprint."] {
            var failed = SessionSnapshot()
            failed.selected = UUID(); failed.state = .failed
            failed.issue = SessionIssue.from(.authentication(message))
            let status = BandStatus(failed, setupComplete: true, relayStatus: nil)
            precondition(status.phase == .attention)
            precondition(status.issue?.action == .reconnect, "The error card and main ring must retry without forgetting the band")
            precondition(status.issue?.actionTitle == "Try again")
        }
        for phase in [BandPhase.notSetUp, .paused, .connecting, .connected, .attention] {
            for word in banned { precondition(!phase.title.lowercased().contains(word)) }
        }

        // 4. Status mapping.
        var snapshot = SessionSnapshot()
        precondition(BandStatus(snapshot, setupComplete: false, relayStatus: nil).phase == .notSetUp)
        snapshot.selected = UUID()
        precondition(BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase == .paused)
        snapshot.wantsConnection = true; snapshot.state = .reconnecting
        precondition(BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase == .connecting)
        snapshot.issue = .bandNotNearby
        precondition(BandStatus(snapshot, setupComplete: true, relayStatus: nil).phase == .attention)
        snapshot.state = .streaming; snapshot.issue = .pulseMissing
        let streaming = BandStatus(snapshot, setupComplete: true, relayStatus: "Connected to Ben’s MacBook")
        precondition(streaming.phase == .connected && streaming.issue == .pulseMissing, "Pulse warning is gentle")
        precondition(streaming.macLink == "Connected to Ben’s MacBook")

        // 5. One reaction per physical gesture, from the patterns in the 2026-11-08 journal.
        var clock = 100.0, rawSeq: UInt64 = 0, derivedSeq: UInt64 = 0
        func packet(_ finger: UInt64, raw: UInt64 = 0, derived: UInt64 = 0, after gap: Double = 0.0001) -> GestureEvent {
            clock += gap
            let sequence: UInt64
            if raw != 0 { rawSeq += 1; sequence = rawSeq } else { derivedSeq += 1; sequence = derivedSeq }
            return GestureEvent(id: UUID(), sessionID: UUID(), fingerCode: finger, actionCode: raw, derivedActionCode: derived,
                                synthetic: false, sequence: sequence, deviceTimestamp: UInt64(clock * 1_000_000),
                                received: ReceiptContext(wallTime: Date(), uptime: clock, applicationState: "foreground"))
        }
        func tapPackets(_ finger: UInt64, double: Bool = false) -> [GestureEvent] {
            var out = [packet(finger, raw: 1, after: 0.3), packet(finger, derived: 9), packet(finger, raw: 2, after: 0.12),
                       packet(finger, derived: 4), packet(finger, derived: 1)]
            if double { out.append(packet(finger, derived: 2, after: 0.004)) }
            return out
        }
        func run(_ packets: [GestureEvent]) -> [BandGesture] {
            var interpreter = GestureInterpreter(), out: [BandGesture] = []
            for event in packets {
                out += interpreter.flush(now: event.received.uptime)
                out += interpreter.feed(event)
            }
            return out + interpreter.flush(now: .infinity)
        }
        let tap = run(tapPackets(2))
        precondition(tap.map(\.kind) == [.tap], "Five tap packets make one tap: \(tap.map(\.kind))")
        let double = run(tapPackets(2) + tapPackets(2, double: true))
        precondition(double.map(\.kind) == [.tap, .doubleTap], "A double tap is the first tap, then one upgrade: \(double.map(\.kind))")
        precondition(double.filter(\.isNewGesture).count == 1, "A double tap counts as one gesture")
        let hold = run([packet(2, raw: 1, after: 0.3), packet(2, derived: 9), packet(2, derived: 3, after: 0.31),
                        packet(2, raw: 2, after: 1.2), packet(2, derived: 4), packet(2, derived: 10)])
        precondition(hold.map(\.kind) == [.holdBegan, .holdEnded], "A hold reacts at its start and ends once: \(hold.map(\.kind))")
        precondition(hold.filter(\.isNewGesture).count == 1)
        for (raw, derived, direction) in [(UInt64(9), UInt64(8), SwipeDirection.right), (8, 7, .left), (6, 5, .up), (7, 6, .down)] {
            let swipe = run([packet(1, raw: raw, after: 0.5), packet(1, derived: derived)])
            precondition(swipe.map(\.kind) == [.swipe(direction)], "Swipe \(direction) is one gesture")
        }
        let mixed = run(tapPackets(2) + tapPackets(3) + [packet(1, raw: 9, after: 0.5), packet(1, derived: 8)])
        precondition(mixed.map(\.title) == ["Index tap", "Middle tap", "Swipe right"])
        var repeated = GestureInterpreter()
        let swipePacket = packet(1, derived: 8, after: 0.5)
        precondition(repeated.feed(swipePacket).count == 1 && repeated.feed(swipePacket).isEmpty, "A repeated packet does not react twice")
        var rawOnly = GestureInterpreter()
        precondition(rawOnly.feed(packet(2, raw: 3, after: 0.5)).isEmpty && rawOnly.hasPending)
        precondition(rawOnly.flush(now: clock + 0.05).map(\.kind) == [.tap], "Raw-only bands still react, after the settle")

        print("Session policy checks passed: per-stream gesture sequences, unlimited reconnect for ordinary errors, plain interface wording, status mapping, one reaction per physical gesture.")
    }
}
