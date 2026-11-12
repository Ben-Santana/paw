// swiftc RunesIOS/Views/Design/WristFlow.swift RunesIOS/Views/Design/WristMotion.swift Tests/WristMotionTests.swift -o /tmp/wrist-motion-tests
import Foundation

@main
struct WristMotionTests {
    static func main() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.000001) {
            precondition(abs(a - b) <= tolerance, "Expected \(a) to match \(b)")
        }
        func length(_ value: SIMD3<Double>) -> Double {
            sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        }
        func positions(_ frame: WristFrame, moving: Bool) -> [SIMD3<Double>] {
            (0..<8).map { index in
                moving ? WristFlow.point(distance: frame.distance - Double(index) * WristFlow.spacing, from: frame.fromHand, to: frame.toHand)
                    : WristFlow.circle(hand: frame.handBlend, angle: frame.turn + Double(index) * .pi / 4)
            }
        }
        func sameRing(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) {
            for point in a { precondition(b.map { length($0 - point) }.min()! < 0.00001) }
        }
        func beginWithoutJump(_ motion: inout WristMotion, left: Bool, at date: Date) {
            let step = 0.000001
            let earlier = positions(motion.frame(at: date.addingTimeInterval(-step)), moving: false)
            let idle = positions(motion.frame(at: date), moving: false)
            motion.begin(left: left, at: date)
            let departing = positions(motion.frame(at: date), moving: true)
            let later = positions(motion.frame(at: date.addingTimeInterval(step)), moving: true)
            sameRing(idle, departing)
            for index in departing.indices {
                let nearest = idle.indices.min { length(idle[$0] - departing[index]) < length(idle[$1] - departing[index]) }!
                let before = (idle[nearest] - earlier[nearest]) / step
                let after = (later[index] - departing[index]) / step
                precondition(length(before - after) < 0.01, "Bead velocity jumped when motion began")
            }
        }
        for firstLeft in [true, false] {
            var motion = WristMotion()
            motion.rest(left: firstLeft, at: start)
            var time = start.addingTimeInterval(1)
            for left in [firstLeft, !firstLeft, firstLeft] {
                beginWithoutJump(&motion, left: left, at: time)
                let reply = time.addingTimeInterval(0.1)
                let wait = motion.confirm(at: reply)
                let end = reply.addingTimeInterval(wait + WristMotion.landingDuration + WristMotion.pulseDuration)
                motion.rest(left: left, at: end)
                time = end.addingTimeInterval(0.7)
            }
        }
        for left in [true, false] {
            for angle in [0.0, 0.23, 1.8, 9.0] {
                let hand = left ? 0.0 : 1.0
                let offset = WristFlow.start(angle: angle, left: left)
                let source = WristFrame(handBlend: hand, turn: angle)
                let departing = WristFrame(fromHand: hand, toHand: 1 - hand, distance: offset)
                sameRing(positions(source, moving: false), positions(departing, moving: true))
            }
            for boundary in [0.0, WristFlow.length] {
                let h = 0.001
                func point(_ d: Double) -> SIMD3<Double> { WristFlow.point(distance: d, from: left ? 0 : 1, to: left ? 1 : 0) }
                let before = (point(boundary) - point(boundary - h)) / h
                let after = (point(boundary + h) - point(boundary)) / h
                precondition(length(before - after) < 0.02, "Path tangent changed at wrist")
            }
            for delay in [0.0, 0.01, 0.2, 1.35, 5.0] {
                var motion = WristMotion()
                motion.rest(left: !left, at: start)
                let resting = motion.frame(at: start)
                motion.begin(left: left, at: start)
                sameRing(positions(resting, moving: false), positions(motion.frame(at: start), moving: true))
                let reply = start.addingTimeInterval(delay)
                let before = motion.frame(at: reply)
                let wait = motion.confirm(at: reply)
                let after = motion.frame(at: reply)
                near(before.distance, after.distance)
                near(before.velocity, after.velocity)
                let arrival = reply.addingTimeInterval(wait)
                let approaching = motion.frame(at: arrival.addingTimeInterval(-0.000001))
                let arriving = motion.frame(at: arrival)
                near(approaching.distance, arriving.distance, 0.001)
                near(approaching.velocity, arriving.velocity, 0.001)
                precondition(arriving.distance - 7 * WristFlow.spacing > WristFlow.length)
                for fraction in [0.0, 0.3, 0.9] {
                    let time = arrival.addingTimeInterval(WristMotion.landingDuration * fraction)
                    let a = motion.frame(at: time), b = motion.frame(at: time.addingTimeInterval(0.000001))
                    near((b.distance - a.distance) / 0.000001, a.velocity, 0.002)
                }
                let end = arrival.addingTimeInterval(WristMotion.landingDuration + WristMotion.pulseDuration)
                let settled = motion.frame(at: end)
                near(settled.velocity, WristMotion.idleAngularSpeed * WristFlow.radius)
                near(settled.pulse, 0)
                motion.rest(left: left, at: end)
                sameRing(positions(settled, moving: true), positions(motion.frame(at: end), moving: false))
                let later = motion.frame(at: end.addingTimeInterval(0.1))
                let direction = left ? -1.0 : 1.0
                near(later.turn - settled.turn, direction * WristMotion.idleAngularSpeed * 0.1)
                precondition(!motion.active)
            }
        }
        for left in [true, false] {
            var motion = WristMotion()
            motion.rest(left: left, at: start)
            let before = motion.frame(at: start.addingTimeInterval(1))
            near(before.turn - motion.frame(at: start).turn, WristMotion.idleAngularSpeed)
            motion.begin(left: left, at: start.addingTimeInterval(1))
            sameRing(positions(before, moving: false), positions(motion.frame(at: start.addingTimeInterval(1)), moving: true))
            _ = motion.confirm(at: start.addingTimeInterval(1.1))
            let end = start.addingTimeInterval(1 + WristMotion.orbitDuration + WristMotion.landingDuration + WristMotion.pulseDuration)
            let beforeRest = motion.frame(at: end)
            let angularSpeed = (beforeRest.turn - motion.frame(at: end.addingTimeInterval(-0.001)).turn) / 0.001
            motion.rest(left: left, at: end)
            near((motion.frame(at: end.addingTimeInterval(0.001)).turn - beforeRest.turn) / 0.001, angularSpeed, 0.00001)
        }
        for left in [true, false] {
            let from = left ? 0.0 : 1.0, to = 1 - from
            let inner = WristFlow.handOffset - WristFlow.radius
            let departure = WristFlow.point(distance: 0, from: from, to: to)
            let arrival = WristFlow.point(distance: WristFlow.length, from: from, to: to)
            near(departure.x, left ? inner : -inner)
            near(arrival.x, left ? -inner : inner)
            var above = false, below = false
            for distance in stride(from: 0.0, through: WristFlow.length, by: 0.5) {
                let point = WristFlow.point(distance: distance, from: from, to: to)
                precondition(abs(point.x) <= inner + 0.000001, "Flow left the inner gap")
                above = above || point.y > 10
                below = below || point.y < 2
            }
            precondition(above && below, "Flow lost its S curve")
        }
        for distance in stride(from: -200.0, through: WristFlow.length + 240, by: 0.5) {
            let a = WristFlow.point(distance: distance, from: 0, to: 1)
            let b = WristFlow.point(distance: distance + 0.5, from: 0, to: 1)
            near(length(b - a), 0.5, 0.001)
        }
        for hand in [0.0, 1.0] {
            for distance in stride(from: -100.0, through: 400, by: 10) {
                let point = WristFlow.point(distance: distance, from: hand, to: hand)
                near(point.y, 6)
                near(length(point - SIMD3((1 - 2 * hand) * WristFlow.handOffset, 6, 0)), WristFlow.radius)
            }
        }
        for left in [true, false] {
            var motion = WristMotion()
            motion.rest(left: !left, at: start)
            motion.begin(left: left, at: start.addingTimeInterval(0.4))
            let arrivals = motion.arrivals()
            precondition(arrivals.count == 8 && arrivals == arrivals.sorted())
            precondition(arrivals[0] > 0 && arrivals[7] < WristMotion.orbitDuration)
            for (bead, time) in arrivals.enumerated() {
                let frame = motion.frame(at: start.addingTimeInterval(0.4 + time))
                near(frame.distance - Double(bead) * WristFlow.spacing, WristFlow.length, 0.001)
            }
            // The other wrist is fully chosen as the last bead lands.
            near(motion.frame(at: start.addingTimeInterval(0.4 + arrivals[7])).handBlend, left ? 1 : 0, 0.001)
            print("Arrivals toward the \(left ? "left" : "right"): \(arrivals.map { String(format: "%.2f", $0) }.joined(separator: " "))")
            motion.rest(left: left, at: start.addingTimeInterval(4))
            motion.begin(left: left, at: start.addingTimeInterval(5))
            precondition(motion.arrivals().isEmpty, "Staying on one wrist has no arrivals")
        }
        var waiting = WristMotion()
        precondition(waiting.arrivals().isEmpty)
        waiting.begin(left: true, at: start)
        precondition(waiting.frame(at: start.addingTimeInterval(5)).velocity > 0)
        near(waiting.frame(at: start.addingTimeInterval(5)).pulse, 0)
        waiting.rest(left: nil, at: start.addingTimeInterval(0.6))
        precondition(!waiting.active)
        near(waiting.frame(at: start.addingTimeInterval(6)).handBlend, 0)
        near(waiting.frame(at: start.addingTimeInterval(6)).velocity, 0)
        print("Wrist flow: path speed, tangent joins, both directions, replies, arrivals, continuous idle orbit and cancellation passed.")
    }
}
