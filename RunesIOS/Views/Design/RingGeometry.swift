import SwiftUI

enum RingGeometry {
    static let radius = 49.0
    static let ballRadius = 12.0
    static let elevation = 0.5

    struct Pod {
        let index: Int
        let x: Double
        let y: Double
        let z: Double
    }

    static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let s = 1 / 2.0.squareRoot()
        return CGPoint(x: (x - y) * s, y: (x + y) * s * sin(elevation) - z * cos(elevation))
    }

    static func pods(rotation: Double, radius: Double) -> [Pod] {
        (0..<8).map { i in
            let a = Double(i) * .pi / 4 + rotation
            return Pod(index: i, x: cos(a) * radius, y: sin(a) * radius, z: 8 + cos(a) * 3)
        }
        .sorted { ($0.x + $0.y) < ($1.x + $1.y) }
    }

    static func ball(_ x: Double, _ y: Double, _ z: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = project(x, y, z + ballRadius).applying(transform)
        let r = ballRadius * transform.a
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    static func shadow(_ x: Double, _ y: Double, lift: Double, _ transform: CGAffineTransform) -> CGRect {
        let center = project(x, y, 6).applying(transform)
        let r = ballRadius * transform.a * max(0.45, 0.8 - lift / 60)
        return CGRect(x: center.x - r, y: center.y - r * sin(elevation), width: r * 2, height: r * 2 * sin(elevation))
    }

    static func drawBall(in canvas: inout GraphicsContext, body: CGRect, stroke: Color, lineWidth: Double, charge: Double) {
        canvas.fill(Path(ellipseIn: body), with: .color(.paper))
        canvas.stroke(Path(ellipseIn: body), with: .color(stroke), lineWidth: lineWidth)
        let dot = body.insetBy(dx: body.width * 0.34, dy: body.height * 0.34).offsetBy(dx: 0, dy: -body.height * 0.06)
        if charge > 0.01 { canvas.fill(Path(ellipseIn: dot), with: .color(.ink.opacity(charge))) }
    }
}
