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

        print("Session policy checks passed: per-stream gesture sequences, unlimited reconnect for ordinary errors, plain interface wording, status mapping.")
    }
}
