import SwiftUI

struct WristArtwork: View, Animatable {
    let state: WristFrame
    var confirmed = true
    var moving = false
    var entrance = 1.0
    var focus = 1.0
    var animatableData: Double {
        get { focus }
        set { focus = newValue }
    }
    /// How far the chosen hand leans toward the other, in scene units.
    static let focusLean = 14.0
    private static let mask = SVGPath.cached("M6 14V6a2 2 0 0 1 4 0V4a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v2" + LucideData.hand[3].dropFirst(5) + "Z M8.5 21.2H17.5V25.7Q13 26.2 8.5 25.7Z")
    private static let outline = LucideData.hand.map(SVGPath.cached)
    private static let wrist = ["M8.5 21.2V25.7", "M17.5 21.2V25.7"].map(SVGPath.cached)
    private static let contours = ["M8.7 15.1c2 .3 3 1.6 3.2 3.7", "M11.1 13.9c2.1-.8 4.7-.8 6.7-.1"].map(SVGPath.cached)

    /// The entrance: the hands draw first, then the beads fade in and rise into place on
    /// the chosen hand, one after another around the ring.
    private static let handsEnd = 0.55
    private func beadIntroduction(_ index: Int) -> Double {
        let start = 0.5 + Double(index) * 0.03
        let t = min(1, max(0, (entrance - start) / (1 - 7 * 0.03 - 0.5)))
        return t * t * t * (10 - 15 * t + 6 * t * t)
    }
    /// How far below its place a bead starts, in scene units.
    private static let riseDepth = 18.0

    var body: some View {
        Canvas { canvas, size in
            func smooth(_ value: Double) -> Double {
                let t = min(1, max(0, value))
                return t * t * (3 - 2 * t)
            }
            let spacing = min(82, size.width * 0.22)
            let sceneScale = spacing / WristFlow.handOffset
            let camera = WristCamera(width: size.width, scale: sceneScale)
            let energy = moving ? state.lift : 0
            // Settling (or a nudge) swells every bead and lets it ease back.
            let swell = 1 + 0.3 * state.pulse
            func focusShift(_ hand: Double) -> Double {
                let emphasis = hand * state.handBlend + (1 - hand) * (1 - state.handBlend)
                return (2 * hand - 1) * Self.focusLean * emphasis
            }
            let pods = (0..<8).map { index in
                let introduction = beadIntroduction(index)
                let distance = state.distance - Double(index) * WristFlow.spacing
                let angle = moving
                    ? WristFlow.angle(distance: distance, to: state.toHand, arriving: true)
                    : state.turn + Double(index) * .pi / 4
                let rest = WristFlow.circle(hand: state.handBlend, angle: angle)
                var destination = moving
                    ? WristFlow.point(distance: distance, from: state.fromHand, to: state.toHand)
                    : rest
                let travel = min(1, max(0, distance / WristFlow.length))
                let hand = moving ? state.fromHand + (state.toHand - state.fromHand) * smooth(travel) : state.handBlend
                destination.x += focusShift(hand)
                let middle = SIMD3(cos(angle) * RingGeometry.radius, -6, sin(angle) * RingGeometry.radius)
                let settled = middle + (destination - middle) * focus
                let world = settled - SIMD3(0, Self.riseDepth * (1 - introduction), 0)
                let projected = camera.project(world)
                let r = (7.2 + 0.6 * state.lift) * swell * projected.scale
                return (body: CGRect(x: projected.point.x - r, y: projected.point.y - r, width: r * 2, height: r * 2),
                        shadow: camera.floorRing(at: world, radius: (6.2 + state.lift * 2.5) * swell),
                        depth: projected.depth, front: world.z >= 0, opacity: introduction)
            }.sorted { $0.depth < $1.depth }

            for pod in pods {
                // A soft contact shadow straight under each bead, spreading and fading as it lifts.
                canvas.fill(pod.shadow, with: .color(.faint.opacity(0.22 * pod.opacity * (1 - 0.45 * state.lift))))
            }
            func ball(_ body: CGRect, opacity: Double, in canvas: inout GraphicsContext) {
                guard opacity > 0.001 else { return }
                var context = canvas
                context.opacity = opacity
                if energy > 0.01 {
                    context.stroke(Path(ellipseIn: body.insetBy(dx: -2, dy: -2)),
                                 with: .color(.ink.opacity(energy * 0.35)), lineWidth: 1.2)
                }
                RingGeometry.drawBall(in: &context, body: body, stroke: confirmed ? .ink : .muted,
                                      lineWidth: 1, charge: 0)
            }
            for pod in pods where !pod.front { ball(pod.body, opacity: pod.opacity, in: &canvas) }
            for left in [true, false] {
                let appear = smooth(entrance / Self.handsEnd)
                func project(_ point: CGPoint) -> CGPoint {
                    camera.project(SIMD3((left ? -WristFlow.handOffset : WristFlow.handOffset) + focusShift(left ? 1 : 0) * focus + (point.x - 13) * (left ? -5.2 : 5.2),
                                         6 + ((23.5 - point.y) * 5.2 - 8 * (1 - appear)) / cos(WristCamera.pitch), 0)).point
                }
                var hand = canvas
                hand.opacity = appear
                hand.fill(Self.mask.projected(project), with: .color(.paper))
                let emphasis = left ? state.handBlend : 1 - state.handBlend
                let opacity = 0.8 * (1 - focus) + (0.18 + 0.82 * emphasis) * focus
                for path in Self.outline {
                    hand.stroke(path.trimmedPath(from: 0, to: appear).projected(project), with: .color(.ink.opacity(opacity)),
                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
                let fade = Gradient(colors: [.ink.opacity(opacity), .ink.opacity(0)])
                for path in Self.wrist {
                    hand.stroke(path.trimmedPath(from: 0, to: appear).projected(project),
                                with: .linearGradient(fade, startPoint: project(CGPoint(x: 13, y: 21.2)),
                                                      endPoint: project(CGPoint(x: 13, y: 25.7))),
                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
                for path in Self.contours {
                    hand.stroke(path.trimmedPath(from: 0, to: appear).projected(project), with: .color(.ink.opacity(opacity * 0.3)),
                                style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                }
            }
            for pod in pods where pod.front { ball(pod.body, opacity: pod.opacity, in: &canvas) }
        }
        .frame(height: 270)
        .accessibilityHidden(true)
    }
}

/// A fixed view from slightly above; it never turns, so the hands hold still while the beads fly.
private struct WristCamera {
    static let pitch = 0.32
    let width: Double
    let scale: Double

    func project(_ position: SIMD3<Double>) -> (point: CGPoint, scale: Double, depth: Double) {
        let y = position.y * cos(Self.pitch) - position.z * sin(Self.pitch)
        let depth = position.y * sin(Self.pitch) + position.z * cos(Self.pitch)
        let perspective = 1 + position.z / 600
        return (CGPoint(x: width / 2 + position.x * scale * perspective, y: 182 - y * perspective), perspective, depth)
    }

    func floorRing(at position: SIMD3<Double>, radius: Double) -> Path {
        let floor = SIMD3(position.x, -5, position.z)
        let center = project(floor).point
        let side = project(floor + SIMD3(radius, 0, 0)).point
        let back = project(floor + SIMD3(0, -sin(0.08) * radius, cos(0.08) * radius)).point
        return Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)).applying(
            CGAffineTransform(a: side.x - center.x, b: side.y - center.y,
                              c: back.x - center.x, d: back.y - center.y, tx: center.x, ty: center.y))
    }
}

private extension Path {
    func projected(_ point: (CGPoint) -> CGPoint) -> Path {
        var result = Path()
        forEach { element in
            switch element {
            case .move(let p): result.move(to: point(p))
            case .line(let p): result.addLine(to: point(p))
            case .quadCurve(let p, let c): result.addQuadCurve(to: point(p), control: point(c))
            case .curve(let p, let c1, let c2): result.addCurve(to: point(p), control1: point(c1), control2: point(c2))
            case .closeSubpath: result.closeSubpath()
            }
        }
        return result
    }
}
