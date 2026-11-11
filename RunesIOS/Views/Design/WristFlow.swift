import Foundation

enum WristFlow {
    static let radius = 40.0
    static let spacing = 2 * Double.pi * radius / 8
    static let handOffset = 77.0
    private struct Sample {
        let distance: Double
        let point: SIMD3<Double>
    }
    // Arc-length samples keep the beads equally spaced through the bends.
    private static let bridge: [Sample] = {
        var samples = [Sample(distance: 0, point: bridgePoint(0))]
        for index in 1...256 {
            let point = bridgePoint(Double(index) / 256)
            let previous = samples.last!
            let delta = point - previous.point
            samples.append(Sample(distance: previous.distance + sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z), point: point))
        }
        return samples
    }()
    static var length: Double { bridge.last!.distance }

    static func start(angle: Double, left: Bool) -> Double {
        let step = Double.pi / 4
        let gap = ((left ? 1.0 : -1.0) * ((left ? .pi : 0) - angle)).truncatingRemainder(dividingBy: step)
        return -(gap < 0 ? gap + step : gap) * radius
    }

    static func circle(hand: Double, angle: Double) -> SIMD3<Double> {
        SIMD3((1 - 2 * hand) * handOffset + cos(angle) * radius, 6, sin(angle) * radius)
    }

    static func angle(distance: Double, to hand: Double, arriving: Bool) -> Double {
        let spin = hand == 1 ? 1.0 : -1.0
        return arriving ? (hand == 1 ? 0 : .pi) - spin * distance / radius
            : (hand == 1 ? .pi : 0) + spin * distance / radius
    }

    static func point(distance: Double, from: Double, to: Double) -> SIMD3<Double> {
        if from == to { return circle(hand: to, angle: angle(distance: distance, to: to, arriving: true)) }
        let bridgeLength = length
        if distance < 0 { return circle(hand: from, angle: angle(distance: distance, to: to, arriving: false)) }
        if distance >= bridgeLength {
            return circle(hand: to, angle: angle(distance: distance - bridgeLength, to: to, arriving: true))
        }
        var low = 0, high = bridge.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if bridge[middle].distance < distance { low = middle } else { high = middle }
        }
        let a = bridge[low], b = bridge[high]
        var point = a.point + (b.point - a.point) * ((distance - a.distance) / (b.distance - a.distance))
        if to == 0 { point.x = -point.x }
        return point
    }

    private static func bridgePoint(_ t: Double) -> SIMD3<Double> {
        let across = t * t * (3 - 2 * t)
        let wave = sin(2 * .pi * t)
        return SIMD3((handOffset - radius) * (1 - 2 * across),
                     6 + 24 * wave * sin(.pi * t), -32 * wave)
    }
}
