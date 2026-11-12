import Foundation

struct WristFrame {
    var handBlend = 0.0
    var lift = 0.0
    var turn = -0.46
    var pulse = 0.0
    var fromHand = 0.0
    var toHand = 0.0
    var distance = 0.0
    var velocity = 0.0
}

struct WristMotion {
    static let orbitDuration = 2.05
    static let landingDuration = 0.35
    static let pulseDuration = 0.45
    static let idleAngularSpeed = Double.pi / 6
    private static var idleSpeed: Double { idleAngularSpeed * WristFlow.radius }
    private var origin = WristFrame()
    private var started: Date?
    private var restingSince: Date?
    private var spinDirection = 1.0
    private var landing: Date?
    private var landingOrigin = WristFrame()
    private var targetHand = 0.0
    private var startDistance = 0.0
    private var startingSpeed = 0.0
    private var speed = 0.0
    private let ramp = 0.12
    var active: Bool { started != nil }

    mutating func begin(left: Bool, at date: Date) {
        origin = frame(at: date)
        targetHand = left ? 1 : 0
        let sameWrist = origin.handBlend == targetHand
        let arrivalDirection = left ? -1.0 : 1.0
        let departureDirection = arrivalDirection * (sameWrist ? 1 : -1)
        startingSpeed = restingSince == nil ? 0 : Self.idleSpeed * spinDirection / departureDirection
        spinDirection = arrivalDirection
        startDistance = WristFlow.start(angle: origin.turn, left: sameWrist ? !left : left) - 2 * WristFlow.spacing
        let length = (sameWrist ? 0 : WristFlow.length) + 10 * WristFlow.spacing
        let rampDistance = ramp * (1 - exp(-Self.orbitDuration / ramp))
        speed = (length - startDistance - startingSpeed * rampDistance) / (Self.orbitDuration - rampDistance)
        started = date
        landing = nil
    }

    mutating func confirm(at date: Date) -> TimeInterval {
        guard let started, landing == nil else { return 0 }
        let arrival = max(date, started.addingTimeInterval(Self.orbitDuration))
        landingOrigin = frame(at: arrival)
        landing = arrival
        return arrival.timeIntervalSince(date)
    }

    /// Seconds after `begin` at which each bead reaches the wrist it is flying to, first
    /// bead first. Empty when the orbit stays on one wrist.
    func arrivals() -> [TimeInterval] {
        guard started != nil, origin.handBlend != targetHand else { return [] }
        return (0..<8).map { bead in
            let target = WristFlow.length + Double(bead) * WristFlow.spacing
            var low = 0.0, high = Self.orbitDuration
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if orbitDistance(middle) < target { low = middle } else { high = middle }
            }
            return high
        }
    }

    private func orbitDistance(_ elapsed: Double) -> Double {
        startDistance + speed * elapsed + (startingSpeed - speed) * ramp * (1 - exp(-elapsed / ramp))
    }

    mutating func rest(left: Bool?, at date: Date) {
        let current = frame(at: date)
        origin = WristFrame(handBlend: left.map { $0 ? 1 : 0 } ?? origin.handBlend, turn: current.turn)
        started = nil
        restingSince = date
        landing = nil
    }

    /// A size pulse over `u` 0…1: quick to swell, slower to ease back, 0 at both ends.
    static func swell(_ u: Double) -> Double {
        let t = min(1, max(0, u))
        return pow(sin(.pi * pow(t, 0.7)), 2)
    }

    func frame(at date: Date) -> WristFrame {
        guard let started else {
            var result = origin
            if let restingSince {
                result.turn += spinDirection * Self.idleAngularSpeed * max(0, date.timeIntervalSince(restingSince))
            }
            return result
        }
        let elapsed = max(0, date.timeIntervalSince(started))
        var result = WristFrame(fromHand: origin.handBlend, toHand: targetHand)
        if let landing, date >= landing {
            let time = max(0, date.timeIntervalSince(landing))
            let u = min(1, time / Self.landingDuration)
            let idleSpeed = Self.idleSpeed
            let excess = landingOrigin.velocity - idleSpeed
            result.distance = landingOrigin.distance + idleSpeed * time + excess * Self.landingDuration * (u - pow(u, 3) + pow(u, 4) / 2)
            result.velocity = idleSpeed + excess * (1 - 3 * u * u + 2 * u * u * u)
            result.lift = landingOrigin.lift * (1 - u) * (1 - u)
            let age = time - Self.landingDuration
            result.pulse = age >= 0 && age < Self.pulseDuration ? Self.swell(age / Self.pulseDuration) : 0
        } else {
            let decay = exp(-elapsed / ramp)
            result.distance = orbitDistance(elapsed)
            result.velocity = speed + (startingSpeed - speed) * decay
            result.lift = 1 - decay
        }
        let length = origin.handBlend == targetHand ? 0 : WristFlow.length
        let progress = min(1, max(0, (result.distance - startDistance) / (length + 7 * WristFlow.spacing - startDistance)))
        result.handBlend = origin.handBlend + (targetHand - origin.handBlend) * progress * progress * (3 - 2 * progress)
        result.turn = WristFlow.angle(distance: result.distance - length, to: targetHand, arriving: true)
        return result
    }
}
