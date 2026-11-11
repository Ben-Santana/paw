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
    private static let mask = SVGPath.cached("M6 14V6a2 2 0 0 1 4 0V4a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v2" + LucideData.hand[3].dropFirst(5) + "Z M8.5 21.2H17.5V25.7Q13 26.2 8.5 25.7Z")
    private static let outline = (LucideData.hand + ["M8.5 21.2V25.7Q13 26.2 17.5 25.7V21.2"]).map(SVGPath.cached)
    private static let contours = ["M8.7 15.1c2 .3 3 1.6 3.2 3.7", "M11.1 13.9c2.1-.8 4.7-.8 6.7-.1"].map(SVGPath.cached)

    private var cameraSweep: Double {
        guard moving, state.fromHand != state.toHand else { return 0 }
        let progress = (state.handBlend - state.fromHand) / (state.toHand - state.fromHand)
        return sin(.pi * min(1, max(0, progress)))
    }

    private var introduction: Double {
        let t = min(1, max(0, (entrance - 0.12) / 0.88))
        return t * t * t * (10 - 15 * t + 6 * t * t)
    }

    var body: some View {
        Canvas { canvas, size in
            func smooth(_ value: Double) -> Double {
                let t = min(1, max(0, value))
                return t * t * (3 - 2 * t)
            }
            let spacing = min(82, size.width * 0.22)
            let sceneScale = spacing / WristFlow.handOffset
            let camera = WristCamera(width: size.width, scale: sceneScale,
                                     sweep: cameraSweep, direction: state.toHand - state.fromHand)
            let energy = moving ? max(state.lift, state.pulse) : 0
            func focusShift(_ hand: Double) -> Double {
                let emphasis = hand * state.handBlend + (1 - hand) * (1 - state.handBlend)
                return (2 * hand - 1) * 14 * emphasis
            }
            let pods = (0..<8).map { index in
                let distance = state.distance - Double(index) * WristFlow.spacing
                let angle = moving
                    ? WristFlow.angle(distance: distance, to: state.toHand, arriving: true)
                    : state.turn + Double(index) * .pi / 4
                let rest = WristFlow.circle(hand: state.handBlend, angle: angle)
                let introAngle = angle - (1 - introduction) * .pi / 3
                let openingRadius = RingGeometry.radius * (1.18 + 0.12 * smooth(entrance / 0.3))
                let opening = SIMD3(cos(introAngle) * openingRadius, 54, sin(introAngle) * openingRadius)
                var destination = moving
                    ? WristFlow.point(distance: distance, from: state.fromHand, to: state.toHand)
                    : rest
                let travel = min(1, max(0, distance / WristFlow.length))
                let hand = moving ? state.fromHand + (state.toHand - state.fromHand) * smooth(travel) : state.handBlend
                destination.x += focusShift(hand)
                let middle = SIMD3(cos(angle) * RingGeometry.radius, -6, sin(angle) * RingGeometry.radius)
                let settled = middle + (destination - middle) * focus
                let world = opening + (settled - opening) * introduction
                let projected = camera.project(world)
                let r = (7.2 + 2.8 * (1 - introduction) + 0.6 * state.lift) * projected.scale
                return (body: CGRect(x: projected.point.x - r, y: projected.point.y - r, width: r * 2, height: r * 2),
                        shadow: camera.floorRing(at: world, radius: 8 + state.lift * 3),
                        depth: projected.depth, front: world.z >= 0)
            }.sorted { $0.depth < $1.depth }

            for pod in pods {
                canvas.stroke(pod.shadow, with: .color(.faint.opacity(0.28 * introduction)), lineWidth: 0.75)
            }
            func ball(_ body: CGRect, in context: inout GraphicsContext) {
                if energy > 0.01 {
                    context.stroke(Path(ellipseIn: body.insetBy(dx: -2, dy: -2)),
                                 with: .color(.wristGlow.opacity(energy * 0.5)), lineWidth: 1.2)
                }
                RingGeometry.drawBall(in: &context, body: body, stroke: confirmed ? .ink : .muted,
                                      lineWidth: 1, charge: state.pulse * 0.35)
            }
            for pod in pods where !pod.front { ball(pod.body, in: &canvas) }
            for left in [true, false] {
                let appear = smooth((entrance - 0.2) / 0.75)
                func project(_ point: CGPoint) -> CGPoint {
                    camera.project(SIMD3((left ? -WristFlow.handOffset : WristFlow.handOffset) + focusShift(left ? 1 : 0) * focus + (point.x - 13) * (left ? -5.2 : 5.2),
                                         6 + ((23.5 - point.y) * 5.2 - 8 * (1 - appear)) / cos(0.32), 0)).point
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
                for path in Self.contours {
                    hand.stroke(path.trimmedPath(from: 0, to: appear).projected(project), with: .color(.ink.opacity(opacity * 0.3)),
                                style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                }
            }
            for pod in pods where pod.front { ball(pod.body, in: &canvas) }
        }
        .frame(height: 270)
        .accessibilityHidden(true)
    }
}

private struct WristCamera {
    let width: Double
    let scale: Double
    let sweep: Double
    let direction: Double

    func project(_ position: SIMD3<Double>) -> (point: CGPoint, scale: Double, depth: Double) {
        let yaw = direction * 0.16 * sweep
        let pitch = 0.32 + 0.06 * sweep
        let x = position.x * cos(yaw) + position.z * sin(yaw)
        let z = position.z * cos(yaw) - position.x * sin(yaw)
        let y = position.y * cos(pitch) - z * sin(pitch)
        let depth = position.y * sin(pitch) + z * cos(pitch)
        let perspective = 1 + position.z / 600 + sweep * (depth - position.z) / 900
        return (CGPoint(x: width / 2 + x * scale * perspective, y: 182 - y * perspective), perspective, depth)
    }

    func floorRing(at position: SIMD3<Double>, radius: Double) -> Path {
        let floor = SIMD3(position.x + 3, -52, position.z)
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
