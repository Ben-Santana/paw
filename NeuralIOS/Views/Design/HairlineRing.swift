import SwiftUI

/// The Mac app's "Hairline" band, simplified: eight hairline balls looping around the wrist,
/// on the same isometric camera as public/hairline/band.js (azimuth 45°, elevation 0.5 rad,
/// radius 49). A faint shadow on the wrist plane shows how high each ball is lifted.
///
/// States: faint at rest (not set up), a lift travelling round (connecting), ink with a
/// slow breath (connected), muted with the front pod sunk (needs attention).
///
/// Gestures, one reaction each:
/// - Tap: a damped shockwave from the pod under that finger, the ring kicks outward and
///   two hairline ripples spread over the wrist plane.
/// - Double tap: two stacked shockwaves and a flash of the contact pads.
/// - Hold: the ring levitates and charges (pads fill with ink, a wave orbits, an arc sweeps
///   the wrist plane); on release the pods drop with a bounce and a wide ripple.
/// - Swipe left/right: the ring spins one pod-step that way with a motion trail.
/// - Swipe up/down: a wave rolls front-to-back, or the pods sink back-to-front.
/// Reduce Motion: no movement; gestures flash the ring and a hold fills the pads.
struct HairlineRing: View {
    var phase: BandPhase
    /// The latest physical gesture; the ring reacts once per new `id`.
    var gesture: BandGesture? = nil
    /// Draw one pod raised and in ink, to point at it (onboarding).
    var emphasis: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var effects: [Effect] = []
    @State private var hold: Hold?
    @State private var previous: BandPhase?
    @State private var phaseChangedAt = Date.distantPast

    private struct Effect: Equatable {
        enum Kind: Equatable { case tap, doubleTap, release, swipe(SwipeDirection) }
        let kind: Kind
        let origin: Int
        let start: Date
        var duration: Double {
            switch kind { case .tap: 1.2; case .doubleTap: 1.5; case .release: 1.2; case .swipe: 1.0 }
        }
    }
    private struct Hold: Equatable { let start: Date; var end: Date?; let origin: Int }

    private static let blend = 0.45
    private static let longestHold: TimeInterval = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !isAnimating)) { context in
            Canvas { canvas, size in
                draw(in: &canvas, size: size, now: context.date)
            }
        }
        .aspectRatio(1.25, contentMode: .fit)
        .onChange(of: gesture?.id) { _, _ in if let gesture { react(to: gesture) } }
        .onChange(of: phase) { old, _ in
            previous = old; phaseChangedAt = Date()
            Task { try? await Task.sleep(for: .seconds(Self.blend)); previous = nil }
        }
        .accessibilityHidden(true)
    }

    private var isAnimating: Bool {
        if !effects.isEmpty || hold != nil { return true }
        if reduceMotion { return false }
        return phase == .connecting || phase == .connected || previous != nil || emphasis != nil
    }

    // MARK: Reacting

    /// The pod under each finger: index at the front, middle beside it, thumb opposite.
    private static func origin(for finger: UInt64) -> Int {
        switch finger { case 3: return 2; case 1: return 0; default: return front }
    }

    private func react(to gesture: BandGesture) {
        let now = Date(), origin = Self.origin(for: gesture.finger)
        switch gesture.kind {
        case .tap: add(Effect(kind: .tap, origin: origin, start: now))
        case .doubleTap: add(Effect(kind: .doubleTap, origin: origin, start: now))
        case .swipe(let direction): add(Effect(kind: .swipe(direction), origin: origin, start: now))
        case .holdBegan:
            let started = Hold(start: now, end: nil, origin: origin)
            hold = started
            Task {
                // A lost link can swallow the release; never hover forever.
                try? await Task.sleep(for: .seconds(Self.longestHold))
                if hold == started { end(hold: now.addingTimeInterval(Self.longestHold)) }
            }
        case .holdEnded:
            end(hold: now)
        }
    }

    private func end(hold at: Date) {
        guard var current = hold, current.end == nil else { return }
        current.end = at; hold = current
        add(Effect(kind: .release, origin: current.origin, start: at))
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            if hold == current { hold = nil }
        }
    }

    private func add(_ effect: Effect) {
        effects.append(effect)
        Task {
            try? await Task.sleep(for: .seconds(effect.duration))
            effects.removeAll { $0 == effect }
        }
    }

    // MARK: Geometry

    private static let radius = 49.0
    /// The pod nearest the viewer.
    private static let front = 1
    private static let elevation = 0.5

    private static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let s = 1 / 2.0.squareRoot()
        return CGPoint(x: (x - y) * s, y: (x + y) * s * sin(elevation) - z * cos(elevation))
    }

    private static func polygon(_ points: [CGPoint], _ transform: CGAffineTransform, closed: Bool = true) -> Path {
        var path = Path(); path.addLines(points.map { $0.applying(transform) }); if closed { path.closeSubpath() }; return path
    }

    private static func circle(radius: Double, z: Double, from: Double = 0, to: Double = 2 * .pi, _ transform: CGAffineTransform) -> Path {
        let steps = max(8, Int(72 * (to - from) / (2 * .pi)))
        let points = (0...steps).map { i -> CGPoint in
            let a = from + (to - from) * Double(i) / Double(steps)
            return project(cos(a) * radius, sin(a) * radius, z)
        }
        return polygon(points, transform, closed: to - from >= 2 * .pi - 0.001)
    }

    private static func steps(_ a: Int, _ b: Int) -> Double { Double(min(abs(a - b), 8 - abs(a - b))) }
    private static func easeInOut(_ x: Double) -> Double { let k = min(1, max(0, x)); return k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2 }
    /// A damped bounce that starts upward: 0 at τ=0, peaks near 0.1 s, settles by ~0.8 s.
    private static func bounce(_ tau: Double, frequency: Double = 2.6, decay: Double = 5.5) -> Double {
        tau <= 0 ? 0 : exp(-decay * tau) * sin(2 * .pi * frequency * tau)
    }

    // MARK: Motion

    private func stateLift(_ phase: BandPhase, index: Int, angle: Double, t: Double) -> Double {
        var value = 0.0
        switch phase {
        case .connecting where !reduceMotion:
            let head = t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 2 * .pi
            value = 9 * pow(max(0, cos(angle - head)), 6)
        case .connecting:
            value = index.isMultiple(of: 2) ? 3 : 0
        case .connected where !reduceMotion:
            value = 1.2 * (1 + sin(t * 2 * .pi / 5 + angle)) / 2
        case .attention:
            value = index == Self.front ? -4 : 0
        default: break
        }
        if index == emphasis { value = reduceMotion ? 10 : 8 + 2 * sin(t * 2 * .pi / 1.6) }
        return value
    }

    /// How charged the hold is, 0…1, including its fall after release.
    private func holdLevel(at now: Date) -> Double {
        guard let hold else { return 0 }
        let held = (hold.end ?? now).timeIntervalSince(hold.start)
        let charged = 1 - exp(-4 * max(0, held))
        guard let end = hold.end else { return charged }
        return charged * exp(-9 * max(0, now.timeIntervalSince(end)))
    }

    private struct Frame {
        var rotation = 0.0
        var trail: Double?
        var radiusKick = 0.0
        var lift = [Double](repeating: 0, count: 8)
        var glow = [Double](repeating: 0, count: 8)
        var flash = 0.0
        var ripples: [(radius: Double, alpha: Double, width: Double)] = []
        var arc: (sweep: Double, alpha: Double)?
    }

    private func frame(at now: Date) -> Frame {
        var f = Frame()
        let t = now.timeIntervalSinceReferenceDate
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4
            var value = stateLift(phase, index: i, angle: angle, t: t)
            if let previous, !reduceMotion {
                let k = min(1, now.timeIntervalSince(phaseChangedAt) / Self.blend)
                let eased = 1 - pow(1 - k, 3)
                value = stateLift(previous, index: i, angle: angle, t: t) * (1 - eased) + value * eased
            }
            f.lift[i] = value
        }

        // Hold: levitate, orbit and charge.
        let level = holdLevel(at: now)
        if level > 0.001 {
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                f.glow[i] = max(f.glow[i], 0.85 * level)
                if !reduceMotion { f.lift[i] += 11 * level + 2.5 * level * sin(2 * angle - t * 5) }
            }
            if let hold, !reduceMotion {
                let held = (hold.end ?? now).timeIntervalSince(hold.start)
                let fade = hold.end.map { max(0, 1 - now.timeIntervalSince($0) / 0.3) } ?? 1
                // The charge arc starts under the holding finger and closes in 1.2 s.
                f.arc = (sweep: min(1, held / 1.2) * 2 * .pi, alpha: 0.6 * fade)
            }
        }

        for effect in effects {
            let tau = now.timeIntervalSince(effect.start)
            guard tau >= 0, tau < effect.duration else { continue }
            if reduceMotion { f.flash = max(f.flash, tau < 0.35 ? 1 : 0); continue }
            switch effect.kind {
            case .tap, .doubleTap:
                let double = effect.kind == .doubleTap
                for (k, delay, strength) in double ? [(0, 0.0, 0.8), (1, 0.13, 1.2)] : [(0, 0.0, 1.0)] {
                    let local = tau - delay
                    guard local > 0 else { continue }
                    for i in 0..<8 {
                        let d = Self.steps(i, effect.origin)
                        f.lift[i] += 9 * strength * Self.bounce(local - d * 0.045)
                    }
                    f.radiusKick += 5 * strength * exp(-8 * local) * (1 - exp(-40 * local))
                    for echo in 0..<2 {
                        let r = local - Double(echo) * 0.12
                        guard r > 0, r < 0.9 else { continue }
                        let p = 1 - pow(1 - r / 0.9, 2)
                        f.ripples.append((radius: 58 + 42 * p, alpha: (1 - r / 0.9) * (echo == 0 ? 0.55 : 0.3) * strength, width: k == 1 ? 1.3 : 1))
                    }
                }
                if double {
                    let pads = tau < 0.13 ? 0 : max(0, 1 - (tau - 0.13) / 0.45)
                    for i in 0..<8 { f.glow[i] = max(f.glow[i], 0.9 * pads) }
                }
            case .release:
                for i in 0..<8 { f.lift[i] += -4 * Self.bounce(tau - Self.steps(i, effect.origin) * 0.02, frequency: 2.2, decay: 4.5) }
                if tau < 1.0 {
                    let p = 1 - pow(1 - tau, 3)
                    f.ripples.append((radius: 56 + 60 * p, alpha: 0.5 * (1 - tau), width: 1.2))
                }
            case .swipe(let direction):
                let p = min(1, tau / 0.55)
                switch direction {
                case .left, .right:
                    // Increasing angle moves the front pod left on screen.
                    let sign = direction == .left ? 1.0 : -1.0
                    let eased = Self.easeInOut(p)
                    f.rotation += sign * .pi / 4 * eased
                    let lagged = Self.easeInOut(max(0, (tau - 0.07) / 0.55))
                    if p < 1 { f.trail = sign * .pi / 4 * lagged }
                    for i in 0..<8 { f.lift[i] += 5 * sin(.pi * eased) }
                case .up, .down:
                    for i in 0..<8 {
                        let angle = Double(i) * .pi / 4
                        let depth = sin(angle + .pi / 4)   // +1 front, −1 back
                        let up = direction == .up
                        let wave = up ? 1.5 - 3 * p : -1.5 + 3 * p
                        let shape = exp(-pow(depth - wave, 2) / 0.22) * (1 - 0.4 * p)
                        f.lift[i] += (up ? 11 : -7) * shape
                    }
                }
            }
        }
        return f
    }

    // MARK: Drawing

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let f = frame(at: now)

        // Fit the resting ring, with headroom for lifts and ripples.
        let extent = Self.radius + 13
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

        // The wrist plane, behind the pods.
        for ripple in f.ripples {
            canvas.stroke(Self.circle(radius: ripple.radius, z: 6, transform), with: .color(.ink.opacity(ripple.alpha)), lineWidth: line * ripple.width)
        }
        if let arc = f.arc, let hold {
            let start = Double(hold.origin) * .pi / 4
            canvas.stroke(Self.circle(radius: 74, z: 6, from: start, to: start + arc.sweep, transform),
                          with: .color(.ink.opacity(arc.alpha)), style: StrokeStyle(lineWidth: line * 1.2, lineCap: .round))
            canvas.stroke(Self.circle(radius: 74, z: 6, transform), with: .color(.ink.opacity(arc.alpha * 0.18)), lineWidth: line)
        }

        // Motion trail for a spin: faint pods where the ring just was.
        if let trail = f.trail {
            for pod in pods(rotation: trail, radius: Self.radius) {
                let ghost = ball(pod.x, pod.y, pod.z + f.lift[pod.index] * 0.6, transform)
                canvas.stroke(Path(ellipseIn: ghost), with: .color(.ink.opacity(0.18)), lineWidth: line * 0.8)
            }
        }

        let radius = Self.radius + f.radiusKick
        let placed = pods(rotation: f.rotation, radius: radius)
        // Shadows first, so no ball is drawn under another ball's shadow.
        for pod in placed {
            let lift = max(0, f.lift[pod.index])
            let shadow = Self.shadow(pod.x, pod.y, lift: lift, transform)
            canvas.stroke(Path(ellipseIn: shadow), with: .color(strokeColor.opacity(0.35 * max(0.25, 1 - lift / 20))), lineWidth: line * 0.7)
        }
        for pod in placed {
            let lift = f.lift[pod.index], glow = f.glow[pod.index]
            let emphasised = pod.index == emphasis || (phase == .attention && pod.index == Self.front)
            let energised = f.flash > 0 || emphasised || lift > 4 || glow > 0.2
            let stroke: Color = energised ? .ink : strokeColor
            let body = ball(pod.x, pod.y, pod.z + lift, transform)
            canvas.fill(Path(ellipseIn: body), with: .color(.paper))
            canvas.stroke(Path(ellipseIn: body), with: .color(stroke), lineWidth: line)
            // A dot that appears and fills with ink as the ball charges (hold, double tap).
            let fill = max(glow, f.flash * 0.7)
            let dot = body.insetBy(dx: body.width * 0.34, dy: body.height * 0.34).offsetBy(dx: 0, dy: -body.height * 0.06)
            if fill > 0.01 { canvas.fill(Path(ellipseIn: dot), with: .color(.ink.opacity(fill))) }
        }
    }

    private static let ballRadius = 12.0

    /// A ball's outline on screen. A sphere projects to a circle under this camera.
    private func ball(_ x: Double, _ y: Double, _ z: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = Self.project(x, y, z + Self.ballRadius).applying(transform)
        let r = Self.ballRadius * transform.a
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    /// The ball's shadow on the wrist plane, shrinking as it lifts.
    private static func shadow(_ x: Double, _ y: Double, lift: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = project(x, y, 6).applying(transform)
        let r = ballRadius * transform.a * max(0.45, 0.8 - lift / 60)
        return CGRect(x: center.x - r, y: center.y - r * sin(elevation), width: r * 2, height: r * 2 * sin(elevation))
    }

    private struct PlacedPod { let index: Int; let x: Double; let y: Double; let z: Double }

    /// Pods in painter's order (back to front) after rotating the ring.
    private func pods(rotation: Double, radius: Double) -> [PlacedPod] {
        (0..<8).map { i in
            let a = Double(i) * .pi / 4 + rotation
            return PlacedPod(index: i, x: cos(a) * radius, y: sin(a) * radius, z: 8 + cos(a) * 3)
        }
        .sorted { ($0.x + $0.y) < ($1.x + $1.y) }
    }

    private var strokeColor: Color {
        switch phase {
        case .notSetUp: return .faint
        case .connected: return .ink.opacity(0.7)
        default: return .muted.opacity(0.75)
        }
    }
}
