import SwiftUI

// A minimal mannequin, front and back: a floating round head, one straight line from shoulder to
// foot on each side, tapered arms, drawn as a single outline. Each muscle is a rounded patch that fills with ink when a set
// trains it and fades by a seventh each day after, back to empty after a week.
//
// The figure is drawn in a 200 × 420 box. Patches on the right are mirrored to the left.

enum BodyFigure {
    static let box = GlyphFigure.box
    static let center = box.width / 2

    static func mirrored(_ p: CGPoint) -> CGPoint { CGPoint(x: box.width - p.x, y: p.y) }
    static func mirrored(_ r: CGRect) -> CGRect { CGRect(x: box.width - r.maxX, y: r.minY, width: r.width, height: r.height) }
    static func mirrored(_ path: Path) -> Path {
        path.applying(CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: box.width, y: 0)))
    }
    /// A right-side path plus its mirror.
    static func pair(_ path: Path) -> Path { var p = path; p.addPath(mirrored(path)); return p }

    static func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
    }
    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path { ellipse(c.x - r, c.y - r, r * 2, r * 2) }
    static func poly(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); p.closeSubpath(); return p }

    static let head = CGRect(x: 79, y: 30, width: 42, height: 42)

    /// The whole body below the head as one outline: a smooth curve from the collar over the shoulder
    /// and down the outside of the arm, round the hand, up the inside of the arm to the armpit, then one
    /// straight line from the armpit to the outside of the foot. The left side mirrors the right.
    static var torso: Path {
        func m(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.width - x, y: y) }
        var p = Path()
        p.move(to: CGPoint(x: 100, y: 86))
        // Right side, top to bottom.
        p.addCurve(to: CGPoint(x: 162, y: 126), control1: CGPoint(x: 138, y: 86), control2: CGPoint(x: 162, y: 96))
        p.addLine(to: CGPoint(x: 162, y: 244))
        p.addQuadCurve(to: CGPoint(x: 144, y: 244), control: CGPoint(x: 153, y: 256))
        p.addLine(to: CGPoint(x: 144, y: 150))
        p.addLine(to: CGPoint(x: 126, y: 404))
        p.addQuadCurve(to: CGPoint(x: 106, y: 404), control: CGPoint(x: 116, y: 411))
        p.addLine(to: CGPoint(x: 101.5, y: 250))
        p.addQuadCurve(to: CGPoint(x: 98.5, y: 250), control: CGPoint(x: 100, y: 246))
        // Left side, bottom to top (the mirror of the right).
        p.addLine(to: m(106, 404))
        p.addQuadCurve(to: m(126, 404), control: m(116, 411))
        p.addLine(to: m(144, 150))
        p.addLine(to: m(144, 244))
        p.addQuadCurve(to: m(162, 244), control: m(153, 256))
        p.addLine(to: m(162, 126))
        p.addCurve(to: CGPoint(x: 100, y: 86), control1: m(162, 96), control2: m(138, 86))
        p.closeSubpath()
        return p
    }

    /// Every body part, each filled on its own (so overlaps never cancel out).
    static var parts: [Path] { [torso, Path(ellipseIn: head)] }

    /// The whole body as one outline (the head floats free).
    static let silhouette: Path = parts.dropFirst().reduce(parts[0]) { $0.union($1) }

    /// Muscle patches, laid out to tile the outline with thin gaps between them. Each is clipped to
    /// the body, so its outer edges can run past the outline. Right-side patches are paired with
    /// their mirror; patches that cross the centre line stand alone.
    static func regions(_ side: BodySide) -> [(Muscle, Path)] {
        func r(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ radius: CGFloat = 5) -> Path {
            Path(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerRadius: radius)
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let shoulders = pair(r(141, 78, 180, 150, 0))
        let upperArm = pair(r(141, 153, 180, 196, 0)), forearm = pair(r(141, 199, 180, 262, 0))
        let calves = pair(r(102, 334, 150, 420, 0))
        switch side {
        case .front: return [
            (.traps, pair(r(103, 78, 138, 96, 0))),
            (.shoulders, shoulders),
            (.chest, r(59, 99, 141, 140, 8)),
            (.biceps, upperArm),
            (.forearms, forearm),
            (.abs, r(87, 143, 113, 247, 6)),
            (.obliques, pair(poly([pt(116, 143), pt(146, 143), pt(140, 247), pt(116, 247)]))),
            (.quads, pair(r(102, 250, 150, 331, 0))),
            (.calves, calves),
        ]
        case .back: return [
            (.traps, poly([pt(100, 78), pt(138, 78), pt(138, 96), pt(100, 148), pt(62, 96), pt(62, 78)])),
            (.shoulders, shoulders),
            (.lats, pair(poly([pt(141, 99), pt(146, 150), pt(141, 196), pt(103, 196), pt(103, 152)]))),
            (.triceps, upperArm),
            (.forearms, forearm),
            (.lowerBack, r(59, 199, 141, 247, 6)),
            (.glutes, pair(r(102, 250, 150, 290, 0))),
            (.hamstrings, pair(r(102, 293, 150, 331, 0))),
            (.calves, calves),
        ]
        }
    }

}

/// One side of the body.
struct BodyFigureView: View {
    let side: BodySide
    /// 0…1 per muscle.
    let level: (Muscle) -> Double
    var lineWidth: CGFloat = Metric.hairline

    var body: some View {
        let outline = FigureShape { BodyFigure.silhouette }
        ZStack {
            outline.fill(Color.ink.opacity(0.04))
            // Trained muscles light up in ink, softly brighter at the top.
            ForEach(Array(BodyFigure.regions(side).enumerated()), id: \.offset) { _, entry in
                let amount = level(entry.0)
                FigureShape { entry.1 }
                    .fill(LinearGradient(colors: [Color.ink.opacity(amount), Color.ink.opacity(amount * 0.8)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .clipShape(outline)
            outline.stroke(Color.ink.opacity(0.45), lineWidth: lineWidth)
        }
        .aspectRatio(BodyFigure.box.width / BodyFigure.box.height, contentMode: .fit)
    }
}

/// A small figure with one group's muscles filled: the icon for an exercise group.
struct MuscleGlyph: View {
    let group: ExerciseGroup
    var size: CGFloat = 28

    var body: some View {
        Group {
            if group == .cardio {
                LucideIcon(.activity, size: size * 0.7)
            } else {
                MuscleFigureGlyph(group: group, size: size, ink: .ink, outline: .faint, idle: Color.muted.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
