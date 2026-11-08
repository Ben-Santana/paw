import SwiftUI

// A hairline figure, front and back, with each muscle outlined. A muscle fills with ink when a
// set trains it and fades by a seventh each day after, back to an outline after a week.
//
// The figure is drawn in a 200 × 420 box from point lists for the right side of the body,
// mirrored for the left, and joined with smooth Catmull–Rom curves.

enum BodySide: Sendable { case front, back }

enum BodyFigure {
    static let box = CGSize(width: 200, height: 420)
    typealias Poly = [CGPoint]
    private static func p(_ list: [(CGFloat, CGFloat)]) -> Poly { list.map { CGPoint(x: $0.0, y: $0.1) } }

    /// From the neck down the right side and back up the inside of the leg to the crotch.
    static let outlineRight = p([(109, 46), (111, 60), (124, 66), (138, 72), (150, 80), (155, 96), (157, 120), (159, 146),
                                 (163, 176), (164, 206), (166, 224), (162, 238), (154, 236), (153, 214), (150, 186), (145, 158),
                                 (140, 132), (136, 110), (133, 118), (130, 150), (127, 186), (133, 210), (137, 240), (137, 270),
                                 (132, 306), (131, 320), (135, 346), (130, 372), (124, 394), (130, 406), (118, 412), (110, 402),
                                 (109, 376), (106, 346), (105, 320), (104, 286), (102, 254), (100, 246)])
    static let head = CGRect(x: 83, y: 8, width: 34, height: 44)

    static func regions(_ side: BodySide) -> [(Muscle, Poly)] {
        switch side {
        case .front: [
            (.traps, p([(110, 58), (124, 68), (112, 72)])),
            (.shoulders, p([(124, 70), (140, 73), (151, 84), (153, 100), (146, 110), (138, 102), (130, 86)])),
            (.chest, p([(102, 80), (122, 74), (132, 88), (134, 104), (124, 116), (108, 118), (102, 112)])),
            (.biceps, p([(138, 108), (148, 114), (153, 132), (149, 146), (143, 146), (139, 128)])),
            (.forearms, p([(147, 156), (157, 156), (161, 184), (159, 206), (153, 206), (149, 182)])),
            (.abs, p([(102, 122), (116, 122), (118, 150), (116, 182), (108, 200), (102, 204)])),
            (.obliques, p([(120, 122), (129, 128), (128, 160), (124, 188), (119, 182), (121, 150)])),
            (.quads, p([(110, 234), (130, 226), (135, 262), (130, 300), (118, 306), (110, 290), (106, 262)])),
            (.calves, p([(112, 324), (128, 322), (131, 346), (123, 378), (115, 372), (110, 346)])),
        ]
        case .back: [
            (.traps, p([(100, 52), (112, 58), (134, 72), (116, 84), (106, 118), (100, 124)])),
            (.shoulders, p([(126, 72), (140, 73), (151, 84), (153, 100), (146, 110), (136, 98)])),
            (.lats, p([(117, 88), (133, 98), (133, 126), (126, 158), (110, 150), (105, 128), (109, 112)])),
            (.triceps, p([(139, 108), (149, 114), (154, 134), (149, 148), (143, 146), (139, 126)])),
            (.forearms, p([(147, 156), (157, 156), (161, 184), (159, 206), (153, 206), (149, 182)])),
            (.lowerBack, p([(102, 158), (114, 156), (121, 182), (112, 198), (102, 200)])),
            (.glutes, p([(102, 208), (122, 204), (134, 220), (133, 246), (116, 252), (102, 244)])),
            (.hamstrings, p([(108, 260), (130, 256), (133, 290), (127, 308), (115, 306), (106, 284)])),
            (.calves, p([(110, 320), (128, 318), (133, 344), (124, 370), (114, 368), (108, 344)])),
        ]
        }
    }

    /// Inner detail lines: the abs' segments.
    static func details(_ side: BodySide) -> [Poly] {
        side == .front ? [p([(103, 140), (116, 140)]), p([(103, 158), (117, 158)]), p([(103, 176), (116, 176)])] : []
    }

    static func mirrored(_ poly: Poly) -> Poly { poly.map { CGPoint(x: box.width - $0.x, y: $0.y) } }

    /// How much corners round off: 0 is straight segments, 1 a full Catmull–Rom curve.
    static let tension: CGFloat = 0.22

    /// A taut curve through the points: nearly straight segments with slightly eased corners.
    static func spline(_ pts: Poly, closed: Bool) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        if pts.count == 2 { path.move(to: pts[0]); path.addLine(to: pts[1]); return path }
        let n = pts.count
        func at(_ i: Int) -> CGPoint { closed ? pts[(i % n + n) % n] : pts[min(max(i, 0), n - 1)] }
        path.move(to: pts[0])
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            let k = tension / 6
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * k, y: p1.y + (p2.y - p0.y) * k)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * k, y: p2.y - (p3.y - p1.y) * k)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    static var outline: Path {
        let left = Array(mirrored(outlineRight).reversed().dropFirst())
        return spline(outlineRight + left, closed: true)
    }

    static func region(_ poly: Poly) -> Path {
        var path = spline(poly, closed: true)
        path.addPath(spline(mirrored(poly), closed: true))
        return path
    }
}

/// Paths in the figure's box, scaled to fit the frame.
struct FigureShape: Shape {
    let make: () -> Path
    func path(in rect: CGRect) -> Path {
        let box = BodyFigure.box
        let scale = min(rect.width / box.width, rect.height / box.height)
        let dx = rect.minX + (rect.width - box.width * scale) / 2, dy = rect.minY + (rect.height - box.height * scale) / 2
        return make().applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy)))
    }
}

/// One side of the body.
struct BodyFigureView: View {
    let side: BodySide
    /// 0…1 per muscle.
    let level: (Muscle) -> Double
    var lineWidth: CGFloat = Metric.hairline
    var detailed = true

    var body: some View {
        ZStack {
            FigureShape { BodyFigure.outline }.stroke(Color.faint, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .miter))
            FigureShape { Path(ellipseIn: BodyFigure.head) }.stroke(Color.faint, lineWidth: lineWidth)
            ForEach(Array(BodyFigure.regions(side).enumerated()), id: \.offset) { _, entry in
                let shape = FigureShape { BodyFigure.region(entry.1) }
                let value = level(entry.0)
                shape.fill(Color.ink.opacity(value))
                shape.stroke(value > 0.5 ? Color.ink : Color.muted.opacity(0.7), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .miter))
            }
            if detailed {
                ForEach(Array(BodyFigure.details(side).enumerated()), id: \.offset) { _, poly in
                    FigureShape { BodyFigure.region(poly) }.stroke(Color.muted.opacity(0.5), lineWidth: lineWidth)
                }
            }
        }
        .aspectRatio(BodyFigure.box.width / BodyFigure.box.height, contentMode: .fit)
    }
}

/// Front and back side by side, with how fresh each muscle is.
struct BodyMapView: View {
    let freshness: [Muscle: Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            figure(.front, "Front")
            figure(.back, "Back")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: freshness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Muscles trained this week")
        .accessibilityValue(summary)
    }

    private func figure(_ side: BodySide, _ title: String) -> some View {
        VStack(spacing: 8) {
            BodyFigureView(side: side, level: { freshness[$0] ?? 0 })
            Text(title).font(.caption).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        let trained = Muscle.allCases.filter { (freshness[$0] ?? 0) > 0 }.map(\.name)
        return trained.isEmpty ? "None" : trained.joined(separator: ", ")
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
                let muscles = group.muscles
                let side: BodySide = group == .back ? .back : .front
                // Crop to the part of the body the group lives on, so the icon reads at small sizes.
                let crop = group == .legs ? CGRect(x: 52, y: 196, width: 96, height: 220) : CGRect(x: 36, y: 40, width: 128, height: 180)
                let scale = size / max(crop.width, crop.height)
                BodyFigureView(side: side, level: { muscles.contains($0) ? 1 : 0 }, lineWidth: 0.8, detailed: false)
                    .frame(width: BodyFigure.box.width * scale, height: BodyFigure.box.height * scale)
                    .offset(x: (BodyFigure.box.width / 2 - crop.midX) * scale, y: (BodyFigure.box.height / 2 - crop.midY) * scale)
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
