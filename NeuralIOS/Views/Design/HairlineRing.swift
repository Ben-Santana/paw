import SwiftUI

/// The Mac app's "Hairline" band: eight rounded electrode pods looping around the wrist,
/// drawn as isometric hairline prisms. Same geometry as public/hairline/band.js
/// (camera azimuth 45°, elevation 0.5 rad, pods 26 units wide on a radius of 49).
///
/// - Not set up: faint pods at rest.
/// - Connecting: a single lift travels slowly around the ring.
/// - Connected: ink pods with a very slow breath.
/// - Needs attention: muted pods, the front pod sunk and drawn in ink.
/// - Gesture: the pods ripple outward from the front, with a fading hairline on the wrist.
/// Reduce Motion: no travel or ripple; states change in place and a gesture flashes the ring.
struct HairlineRing: View {
    var phase: BandPhase
    /// Changes whenever a gesture arrives.
    var pulse: Int = 0
    /// Draw one pod raised and in ink, to point at it (onboarding).
    var emphasis: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rippleStart: Date?
    @State private var previous: BandPhase?
    @State private var phaseChangedAt = Date.distantPast

    private static let rippleDuration = 0.9
    private static let blend = 0.45

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isAnimating)) { context in
            Canvas { canvas, size in
                draw(in: &canvas, size: size, now: context.date)
            }
        }
        .aspectRatio(1.25, contentMode: .fit)
        .onChange(of: pulse) { _, _ in
            let start = Date()
            rippleStart = start
            Task {
                try? await Task.sleep(for: .seconds(reduceMotion ? 0.25 : Self.rippleDuration))
                if rippleStart == start { rippleStart = nil }
            }
        }
        .onChange(of: phase) { old, _ in
            previous = old; phaseChangedAt = Date()
            Task { try? await Task.sleep(for: .seconds(Self.blend)); previous = nil }
        }
        .accessibilityHidden(true)
    }

    private var isAnimating: Bool {
        if reduceMotion { return false }
        return phase == .connecting || phase == .connected || rippleStart != nil || previous != nil || emphasis != nil
    }

    // MARK: Geometry

    private struct Pod { let index: Int; let x: Double; let y: Double; let z: Double; let angle: Double }

    private static let pods: [Pod] = (0..<8).map { i in
        let a = Double(i) * .pi / 4
        return Pod(index: i, x: cos(a) * 49, y: sin(a) * 49, z: 8 + cos(a) * 3, angle: a)
    }.sorted { ($0.x + $0.y) < ($1.x + $1.y) }

    /// The pod nearest the viewer; ripples start here.
    private static let front = 1

    private static let elevation = 0.5
    private static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let s = 1 / 2.0.squareRoot()
        return CGPoint(x: (x - y) * s, y: (x + y) * s * sin(elevation) - z * cos(elevation))
    }

    /// Points around a rounded square in the band's plane.
    private static func outline(_ cx: Double, _ cy: Double, half: Double, corner: Double) -> [(Double, Double)] {
        var points: [(Double, Double)] = []
        let inner = half - corner
        for (qx, qy, start) in [(1.0, 1.0, 0.0), (-1.0, 1.0, 0.5), (-1.0, -1.0, 1.0), (1.0, -1.0, 1.5)] {
            for step in 0...5 {
                let a = (start + Double(step) / 10) * .pi
                points.append((cx + qx * inner + cos(a) * corner, cy + qy * inner + sin(a) * corner))
            }
        }
        return points
    }

    private static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }; lower.append(p) }
        for p in sorted.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }; upper.append(p) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func polygon(_ points: [CGPoint], _ transform: CGAffineTransform) -> Path {
        var path = Path(); path.addLines(points.map { $0.applying(transform) }); path.closeSubpath(); return path
    }

    // MARK: Motion

    private func lifts(for phase: BandPhase, at t: Double) -> [Int: Double] {
        var lift: [Int: Double] = [:]
        for pod in Self.pods {
            var value = 0.0
            switch phase {
            case .connecting where !reduceMotion:
                let head = t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 2 * .pi
                value = 9 * pow(max(0, cos(pod.angle - head)), 6)
            case .connecting:
                value = pod.index.isMultiple(of: 2) ? 3 : 0
            case .connected where !reduceMotion:
                value = 1.2 * (1 + sin(t * 2 * .pi / 5 + pod.angle)) / 2
            case .attention:
                value = pod.index == Self.front ? -4 : 0
            default: break
            }
            if pod.index == emphasis { value = reduceMotion ? 10 : 8 + 2 * sin(t * 2 * .pi / 1.6) }
            lift[pod.index] = value
        }
        return lift
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        var lift = lifts(for: phase, at: t)
        if let previous, !reduceMotion {
            let k = min(1, now.timeIntervalSince(phaseChangedAt) / Self.blend)
            let eased = 1 - pow(1 - k, 3)
            let old = lifts(for: previous, at: t)
            for key in lift.keys { lift[key] = (old[key] ?? 0) * (1 - eased) + (lift[key] ?? 0) * eased }
        }
        var ripple: Double?
        if let rippleStart { ripple = now.timeIntervalSince(rippleStart) }
        if let r = ripple, !reduceMotion {
            let k = r / Self.rippleDuration
            for pod in Self.pods {
                let d = Double(min(abs(pod.index - Self.front), 8 - abs(pod.index - Self.front)))
                lift[pod.index, default: 0] += 11 * exp(-pow((r * 11 - d) / 0.9, 2)) * max(0, 1 - k)
            }
        }

        // Fit the resting ring, with headroom for lifts.
        let extent = 49.0 + 13
        let corners = [Self.project(-extent, extent, 0), Self.project(extent, -extent, 0),
                       Self.project(-extent, -extent, 0), Self.project(extent, extent, 0),
                       Self.project(-extent, -extent, 34)]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let scale = min(size.width / (maxX - minX), size.height / (maxY - minY)) * 0.9
        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)
        let line = max(0.75, min(1.25, scale * 0.45))

        // The wrist ripple sits on the band's plane, behind the pods.
        if let r = ripple, !reduceMotion, r < Self.rippleDuration {
            let k = r / Self.rippleDuration
            let radius = 58 + 26 * (1 - pow(1 - k, 2))
            let points = (0..<64).map { i -> CGPoint in
                let a = Double(i) / 64 * 2 * .pi
                return Self.project(cos(a) * radius, sin(a) * radius, 6)
            }
            canvas.stroke(Self.polygon(points, transform), with: .color(.ink.opacity(0.45 * (1 - k))), lineWidth: line)
        }

        let flash = reduceMotion && ripple != nil
        for pod in Self.pods {
            let z = pod.z + (lift[pod.index] ?? 0)
            let emphasised = pod.index == emphasis || (phase == .attention && pod.index == Self.front)
            let raised = (lift[pod.index] ?? 0) > 4
            let stroke: Color = flash || emphasised || raised ? .ink : strokeColor
            drawPrism(&canvas, pod.x, pod.y, half: 13, corner: 7, from: z, to: z + 13, stroke: stroke, line: line, transform: transform)
            drawPrism(&canvas, pod.x, pod.y, half: 7, corner: 4, from: z + 13, to: z + 15, stroke: stroke.opacity(0.8), line: line, transform: transform)
        }
    }

    private var strokeColor: Color {
        switch phase {
        case .notSetUp: return .faint
        case .connected: return .ink.opacity(0.7)
        default: return .muted.opacity(0.75)
        }
    }

    private func drawPrism(_ canvas: inout GraphicsContext, _ x: Double, _ y: Double, half: Double, corner: Double,
                           from z0: Double, to z1: Double, stroke: Color, line: CGFloat, transform: CGAffineTransform) {
        let ring = Self.outline(x, y, half: half, corner: corner)
        let bottom = ring.map { Self.project($0.0, $0.1, z0) }
        let top = ring.map { Self.project($0.0, $0.1, z1) }
        let silhouette = Self.polygon(Self.hull(bottom + top), transform)
        canvas.fill(silhouette, with: .color(.paper))
        canvas.stroke(silhouette, with: .color(stroke), style: StrokeStyle(lineWidth: line, lineJoin: .round))
        canvas.stroke(Self.polygon(top, transform), with: .color(stroke.opacity(0.55)), style: StrokeStyle(lineWidth: line * 0.8, lineJoin: .round))
    }
}
