import SwiftUI
import UIKit

// The Mac app's icons: Lucide (LucideData.swift) and its hand-drawn finger variants
// (mac_os_meta_band_app/src/MotionSettings.tsx, FingerIcon). Drawn from the same path
// data at the same 1.5 stroke in a 24×24 box, so they match the Mac exactly.

enum Lucide: String, CaseIterable, Sendable {
    case arrowLeft, arrowRight, arrowUp, arrowDown, rotate3d, move3d
    case house, briefcase, codeXml, music, gamepad2, camera, penTool, globe, star, heart, monitor, headphones
    case earth, layers, appWindow, list, bell, clipboardCopy, vibrate, hourglass
    case plus, chevronRight, chevronDown, check, x, clock3, workflow, hand, ellipsis, play, trash2, pencil, circle, circleDot, spline, copy
    case dumbbell, layoutGrid, skipForward, rotateCcw, square
    case settings, audioWaveform, calendarDays, bookOpen, search, timer, flame, trendingUp, activity

    var paths: [String] {
        switch self {
        case .arrowLeft: LucideData.arrowLeft
        case .arrowRight: LucideData.arrowRight
        case .arrowUp: LucideData.arrowUp
        case .arrowDown: LucideData.arrowDown
        case .rotate3d: LucideData.rotate3d
        case .move3d: LucideData.move3d
        case .house: LucideData.house
        case .briefcase: LucideData.briefcase
        case .codeXml: LucideData.codeXml
        case .music: LucideData.music
        case .gamepad2: LucideData.gamepad2
        case .camera: LucideData.camera
        case .penTool: LucideData.penTool
        case .globe: LucideData.globe
        case .star: LucideData.star
        case .heart: LucideData.heart
        case .monitor: LucideData.monitor
        case .headphones: LucideData.headphones
        case .earth: LucideData.earth
        case .layers: LucideData.layers
        case .appWindow: LucideData.appWindow
        case .list: LucideData.list
        case .bell: LucideData.bell
        case .clipboardCopy: LucideData.clipboardCopy
        case .vibrate: LucideData.vibrate
        case .hourglass: LucideData.hourglass
        case .plus: LucideData.plus
        case .chevronRight: LucideData.chevronRight
        case .chevronDown: LucideData.chevronDown
        case .check: LucideData.check
        case .x: LucideData.x
        case .clock3: LucideData.clock3
        case .workflow: LucideData.workflow
        case .hand: LucideData.hand
        case .ellipsis: LucideData.ellipsis
        case .play: LucideData.play
        case .trash2: LucideData.trash2
        case .pencil: LucideData.pencil
        case .circle: LucideData.circle
        case .circleDot: LucideData.circleDot
        case .spline: LucideData.spline
        case .copy: LucideData.copy
        case .dumbbell: LucideData.dumbbell
        case .layoutGrid: LucideData.layoutGrid
        case .skipForward: LucideData.skipForward
        case .rotateCcw: LucideData.rotateCcw
        case .square: LucideData.square
        case .settings: LucideData.settings
        case .audioWaveform: LucideData.audioWaveform
        case .calendarDays: LucideData.calendarDays
        case .bookOpen: LucideData.bookOpen
        case .search: LucideData.search
        case .timer: LucideData.timer
        case .flame: LucideData.flame
        case .trendingUp: LucideData.trendingUp
        case .activity: LucideData.activity
        }
    }
    /// Each Lucide element is its own SVG path, so a leading relative "m" starts from the origin.
    var path: Path {
        var combined = Path()
        for d in paths { combined.addPath(SVGPath.cached(d)) }
        return combined
    }

    /// Template image for places SwiftUI only accepts an `Image`, such as menu items.
    @MainActor func image(size: CGFloat = 20) -> Image {
        Image(uiImage: IconImages.render(key: "\(rawValue)-\(size)", size: CGSize(width: size, height: size)) {
            LucideIcon(self, size: size)
        })
    }
}

/// A Lucide icon at the Mac's stroke. `lineWidth` is in the icon's 24-unit box.
struct LucideIcon: View {
    let icon: Lucide
    var size: CGFloat = 20
    var lineWidth: CGFloat = 1.5
    init(_ icon: Lucide, size: CGFloat = 20, lineWidth: CGFloat = 1.5) { self.icon = icon; self.size = size; self.lineWidth = lineWidth }
    var body: some View {
        IconStroke(path: icon.path, lineWidth: lineWidth)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Strokes 24×24 path data scaled into the frame.
struct IconStroke: View {
    let path: Path
    var lineWidth: CGFloat = 1.5
    var box = CGSize(width: 24, height: 24)
    var fill = false
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            let shaped = path.applying(CGAffineTransform(scaleX: scale, y: scale))
            if fill { context.fill(shaped, with: .foreground) }
            context.stroke(shaped, with: .foreground, style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: Finger icon (Mac FingerIcon)

/// The brand hand with the index or middle finger raised. Hold fills it; a double tap
/// adds a second outline behind; a tap or release shows the knuckle ticks.
struct FingerIcon: View {
    enum Finger { case index, middle }
    let finger: Finger
    var hold = false
    var double = false
    var size: CGFloat = 20

    private static let indexOutline = "M6 14V4a2 2 0 0 1 4 0v6a2 2 0 0 1 4 0v1a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v1a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15Z"
    private static let middleOutline = "M6 14v-3a2 2 0 0 1 4 0V3a2 2 0 0 1 4 0v8a2 2 0 0 1 4 0v2a2 2 0 0 1 4 0v1a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15Z"
    private static let indexTicks = "M10 10v2m4-1v2m4 0v1"
    private static let middleTicks = "M10 11v2m4-2v2m4 0v1"

    var body: some View {
        let outline = SVGPath.cached(finger == .index ? Self.indexOutline : Self.middleOutline)
        let ticks = SVGPath.cached(finger == .index ? Self.indexTicks : Self.middleTicks)
        let box = CGSize(width: double ? 28 : 24, height: 24)
        Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            let t = CGAffineTransform(scaleX: scale, y: scale)
            let style = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
            let front = outline.applying(t)
            if double {
                // The second outline sits 4 units right, cut away wherever the front hand is.
                let back = outline.applying(CGAffineTransform(translationX: 4, y: 0).concatenating(t))
                context.drawLayer { inner in
                    inner.stroke(back, with: .foreground, style: style)
                    inner.blendMode = .destinationOut
                    inner.fill(front, with: .color(.black))
                    inner.stroke(front, with: .color(.black), style: StrokeStyle(lineWidth: 3.5 * scale, lineCap: .round, lineJoin: .round))
                }
            }
            if hold { context.fill(front, with: .foreground) }
            context.stroke(front, with: .foreground, style: style)
            if !hold { context.stroke(ticks.applying(t), with: .foreground, style: style) }
        }
        .frame(width: double ? size * 28 / 24 : size, height: size)
        .accessibilityHidden(true)
    }
}

/// The Mac's GestureIcon: fingers for taps, holds and releases; arrows for swipes;
/// Rotate3D and Move3D for motion.
struct GestureIcon: View {
    let gesture: GestureKind
    var size: CGFloat = 20
    var body: some View {
        switch gesture {
        case .tapIndex, .releaseIndex: FingerIcon(finger: .index, size: size)
        case .tapMiddle, .releaseMiddle: FingerIcon(finger: .middle, size: size)
        case .doubleTapIndex: FingerIcon(finger: .index, double: true, size: size)
        case .doubleTapMiddle: FingerIcon(finger: .middle, double: true, size: size)
        case .holdIndex: FingerIcon(finger: .index, hold: true, size: size)
        case .holdMiddle: FingerIcon(finger: .middle, hold: true, size: size)
        case .swipeUp: LucideIcon(.arrowUp, size: size, lineWidth: 1.4)
        case .swipeDown: LucideIcon(.arrowDown, size: size, lineWidth: 1.4)
        case .swipeLeft: LucideIcon(.arrowLeft, size: size, lineWidth: 1.4)
        case .swipeRight: LucideIcon(.arrowRight, size: size, lineWidth: 1.4)
        case .rotation: LucideIcon(.rotate3d, size: size, lineWidth: 1.4)
        case .movement: LucideIcon(.move3d, size: size, lineWidth: 1.4)
        case .air: LucideIcon(.spline, size: size, lineWidth: 1.4)
        }
    }
    @MainActor static func image(_ gesture: GestureKind, size: CGFloat = 20) -> Image {
        Image(uiImage: IconImages.render(key: "gesture-\(gesture.rawValue)-\(size)", size: CGSize(width: size * 28 / 24, height: size)) {
            GestureIcon(gesture: gesture, size: size)
        })
    }
}

/// Renders icon views into cached template images for menus.
@MainActor enum IconImages {
    private static var cache: [String: UIImage] = [:]
    static func render<V: View>(key: String, size: CGSize, _ view: () -> V) -> UIImage {
        if let image = cache[key] { return image }
        let renderer = ImageRenderer(content: view().foregroundStyle(.black).frame(width: size.width, height: size.height))
        renderer.scale = UIScreen.main.scale
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
    }
}

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
