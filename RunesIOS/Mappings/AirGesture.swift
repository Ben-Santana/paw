import Foundation

/// A drawn shape the wrist traces in the air, as a combo step. A port of the Mac app's
/// python/air_gestures.py and src/airGesture.ts, saved in the same format:
/// `{"points": [[x, y], …], "minSimilarity": 75, "durationMs": 2000, "name": "…"}`.
struct AirShape: Codable, Hashable, Sendable {
    typealias Point = [Double]
    var points: [Point]
    /// 1–100; a performed shape must score at least this.
    var minSimilarity: Int
    /// 500–10 000 ms: how long the shape has to be performed after the preceding gesture.
    var durationMs: Int
    var name: String?

    static let similarityRange = 1...100
    static let durationRange = 500...10_000

    init(points: [Point], minSimilarity: Int = 75, durationMs: Int = 2000, name: String? = nil) {
        self.points = points; self.minSimilarity = minSimilarity; self.durationMs = durationMs; self.name = name
    }

    var isValid: Bool {
        guard Self.similarityRange.contains(minSimilarity), Self.durationRange.contains(durationMs),
              (2...4096).contains(points.count),
              points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return false }
        let first = points[0]
        return points.contains { hypot($0[0] - first[0], $0[1] - first[1]) > 1e-6 }
    }
}

/// Translation- and scale-invariant, order-preserving shape matching (DTW with a ±8 band)
/// with a ±100° rotation search. Results match the Mac's matcher.
enum AirMatcher {
    typealias Point = AirShape.Point
    static let samples = 64
    /// A performance needs this many orientation samples and this much path to be compared.
    static let minimumPoints = 10
    static let minimumPath = 0.067

    /// The band's forward axis, relative to where it pointed when recording began, projected to 2D.
    /// `q` and `reference` are unit quaternions in w, x, y, z order.
    static func wristPoint(_ q: [Double], reference: [Double]) -> Point {
        let (w, x, y, z) = (reference[0], reference[1], reference[2], reference[3])
        let (a, b, c, d) = (q[0], q[1], q[2], q[3])
        // conjugate(reference) * q, then rotate the forward [0, 1, 0] vector.
        let rw = w*a + x*b + y*c + z*d, rx = w*b - x*a - y*d + z*c
        let ry = w*c + x*d - y*a - z*b, rz = w*d - x*c + y*b - z*a
        return [2 * (rx*ry - rw*rz), -2 * (ry*rz + rw*rx)]
    }

    static func pathLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a[0] - b[0], a[1] - b[1]) }

    /// Centered on the mean and scaled so the larger side of the bounding box is 1.
    static func fit(_ points: [Point]) -> [Point] {
        guard !points.isEmpty else { return [] }
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1[0] } / n, cy = points.reduce(0) { $0 + $1[1] } / n
        let xs = points.map { $0[0] }, ys = points.map { $0[1] }
        let scale = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        guard scale > 1e-12 else { return [] }
        return points.map { [($0[0] - cx) / scale, ($0[1] - cy) / scale] }
    }

    /// 64 points evenly spaced along the path, then fitted. Empty when there's no motion.
    static func normalize(_ points: [Point]) -> [Point] {
        let total = pathLength(points)
        guard points.count >= 2, total >= 1e-6 else { return [] }
        var distances = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { distances.append(distances.last! + distance(a, b)) }
        var sampled: [Point] = []
        var j = 1
        for i in 0..<samples {
            let target = Double(i) * total / Double(samples - 1)
            while j < points.count - 1, distances[j] < target { j += 1 }
            let span = distances[j] - distances[j - 1]
            let t = (target - distances[j - 1]) / (span == 0 ? 1 : span)
            let a = points[j - 1], b = points[j]
            sampled.append([a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])])
        }
        return fit(sampled)
    }

    /// 0–100, or nil when either path has no motion.
    static func similarity(_ target: [Point], _ actual: [Point]) -> Int? {
        let a = normalize(target), b = normalize(actual)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        let n = samples
        var best = Double.infinity
        var previous = [Double](repeating: .infinity, count: n + 1)
        var row = previous
        for degrees in -100...100 {
            let radians = Double(degrees) * .pi / 180
            let c = cos(radians), s = sin(radians)
            let rotated = fit(b.map { [$0[0] * c - $0[1] * s, $0[0] * s + $0[1] * c] })
            guard rotated.count == n else { continue }
            previous = [Double](repeating: .infinity, count: n + 1); previous[0] = 0
            for i in 1...n {
                for k in 0...n { row[k] = .infinity }
                for j in max(1, i - 8)...min(n, i + 8) {
                    row[j] = distance(a[i - 1], rotated[j - 1]) + min(previous[j - 1], previous[j], row[j - 1])
                }
                swap(&previous, &row)
            }
            best = min(best, previous[n] / Double(n))
        }
        return Int((100 * exp(-5 * best) + 0.5).rounded(.down))
    }
}
