import SwiftUI

// MARK: SVG path data

/// Parses SVG path data (all commands, including arcs) into a `Path`.
enum SVGPath {
    nonisolated(unsafe) private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func cached(_ d: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let path = cache[d] { return path }
        let path = parse(d)
        cache[d] = path
        return path
    }

    static func parse(_ d: String) -> Path {
        let path = CGMutablePath()
        var scanner = Tokens(Array(d.utf8))
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0
        while let next = scanner.command(previous: command) {
            command = next
            let relative = command >= 97
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var control: CGPoint?, quad: CGPoint?
            switch command | 0x20 {   // lowercase
            case UInt8(ascii: "m"):
                guard let p = point() else { return Path(path) }
                path.move(to: p); current = p; start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")   // further pairs are lines
            case UInt8(ascii: "l"):
                guard let p = point() else { return Path(path) }
                path.addLine(to: p); current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return Path(path) }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y); path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return Path(path) }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y); path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return Path(path) }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; control = c2
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return Path(path) }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: p, control1: c1, control2: c2); current = p; control = c2
            case UInt8(ascii: "q"):
                guard let c = point(), let p = point() else { return Path(path) }
                path.addQuadCurve(to: p, control: c); current = p; quad = c
            case UInt8(ascii: "t"):
                guard let p = point() else { return Path(path) }
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: p, control: c); current = p; quad = c
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return Path(path) }
                arc(path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep); current = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start
            default:
                return Path(path)
            }
            lastControl = control; lastQuad = quad
        }
        return Path(path)
    }

    /// SVG endpoint arc to Core Graphics (SVG implementation notes, F.6.5).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        // A unit circle mapped onto the ellipse. SVG's positive sweep is CG's increasing angle.
        let transform = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
        path.addArc(center: .zero, radius: 1, startAngle: start, endAngle: start + delta, clockwise: delta < 0, transform: transform)
    }

    private struct Tokens {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skip() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 { i += 1 }
        }
        private func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }

        /// The next command letter, or the previous one repeated when numbers follow.
        mutating func command(previous: UInt8) -> UInt8? {
            skip()
            guard i < bytes.count else { return nil }
            if isLetter(bytes[i]) && bytes[i] != UInt8(ascii: "e") && bytes[i] != UInt8(ascii: "E") { defer { i += 1 }; return bytes[i] }
            return previous == 0 ? nil : previous
        }
        mutating func flag() -> Bool? {
            skip()
            guard i < bytes.count, bytes[i] == 48 || bytes[i] == 49 else { return nil }
            defer { i += 1 }
            return bytes[i] == 49
        }
        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            var dot = false
            while i < bytes.count {
                let b = bytes[i]
                if (48...57).contains(b) { i += 1 }
                else if b == 46, !dot { dot = true; i += 1 }
                else if b == 101 || b == 69 {   // exponent
                    i += 1
                    if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                } else { break }
            }
            guard i > begin, let text = String(bytes: bytes[begin..<i], encoding: .ascii), let value = Double(text) else { i = begin; return nil }
            return CGFloat(value)
        }
    }
}
