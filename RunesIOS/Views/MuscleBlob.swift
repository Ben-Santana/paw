import SwiftUI

// The muscle blob: one soft ink shape in a hairline ring, with the body's groups around it. The blob
// reaches toward each group when it's trained and draws back over a week, so its outline is the shape
// of your week: lopsided when you skip something, round and full when everything's been worked. It
// breathes while you watch, and squishes toward a group when you touch it. Tapping a group opens its
// growth rings: one ring per week, thicker for more sets, oldest at the heart.

/// The groups around the ring, clockwise from the top.
enum BlobLayout {
    static let groups: [ExerciseGroup] = [.chest, .shoulders, .arms, .legs, .core, .back]
    /// Each group's angle, clockwise from the top, in radians.
    static func angle(_ index: Int) -> Double { Double(index) / Double(groups.count) * 2 * .pi }
    /// How much a group pulls on the outline `delta` radians away: 1 straight at it, fading to the sides.
    static func reach(_ delta: Double) -> Double { exp(3 * (cos(delta) - 1)) }
    /// The pull at a group's own angle when every group is full, so a full week makes a round blob.
    static let fullPull: Double = (0..<groups.count).reduce(0) { $0 + reach(angle($1)) }
}

/// A list of levels that SwiftUI can animate between.
struct Levels: VectorArithmetic {
    var values: [Double]

    static var zero: Levels { Levels(values: []) }
    private static func combine(_ a: Levels, _ b: Levels, _ f: (Double, Double) -> Double) -> Levels {
        let n = max(a.values.count, b.values.count)
        return Levels(values: (0..<n).map { f($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
    }
    static func + (a: Levels, b: Levels) -> Levels { combine(a, b, +) }
    static func - (a: Levels, b: Levels) -> Levels { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    subscript(_ i: Int) -> Double { i < values.count ? values[i] : 0 }
}

/// The blob's outline. `levels` are 0…1 per group; `time` drives the breathing; `poke` bulges it
/// toward `pokeAngle` for a moment after a touch.
struct BlobShape: Shape {
    var levels: Levels
    var poke: Double
    let pokeAngle: Double
    let time: Double
    /// The ring the blob grows into.
    let radius: CGFloat

    var animatableData: AnimatablePair<Levels, Double> {
        get { AnimatablePair(levels, poke) }
        set { levels = newValue.first; poke = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = BlobLayout.groups.count
        let t = time
        let breath = 1 + 0.02 * sin(t * 1.2)
        var p = Path()
        let steps = 180
        for k in 0..<steps {
            let th = Double(k) / Double(steps) * 2 * .pi
            var pull = 0.0
            for i in 0..<n { pull += levels[i] * BlobLayout.reach(th - BlobLayout.angle(i)) }
            let wobble = 0.018 * sin(3 * th + t * 0.7) + 0.012 * sin(4 * th - t * 0.5) + 0.006 * sin(7 * th + t * 1.1)
            let bulge = poke * 0.1 * BlobLayout.reach(th - pokeAngle)
            let r = radius * CGFloat((0.32 + 0.6 * min(1, pull / BlobLayout.fullPull) + wobble + bulge) * breath)
            let pt = CGPoint(x: c.x + r * CGFloat(sin(th)), y: c.y - r * CGFloat(cos(th)))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// How fresh each group is, as a blob. `open` is called with the tapped group.
struct MuscleBlob: View {
    let freshness: [Muscle: Double]
    let daysSince: (ExerciseGroup) -> Int?
    let open: (ExerciseGroup) -> Void
    @State private var shown = false
    @State private var poke = 0.0
    @State private var pokeAngle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each group is as fresh as its freshest muscle.
    private var levels: Levels {
        Levels(values: BlobLayout.groups.map { g in shown ? g.muscles.map { freshness[$0] ?? 0 }.max() ?? 0 : 0 })
    }

    var body: some View {
        GeometryReader { geo in
            let radius = max(40, min(geo.size.width / 2 - 64, geo.size.height / 2 - 30))
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().stroke(Color.rule, lineWidth: Metric.hairline).frame(width: radius * 2, height: radius * 2)
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
                    BlobShape(levels: levels, poke: poke, pokeAngle: pokeAngle, time: time, radius: radius)
                        .fill(RadialGradient(colors: [Color.ink, Color.ink.opacity(0.78)], center: .center,
                                             startRadius: 0, endRadius: radius))
                }
                .contentShape(Circle().size(width: radius * 2, height: radius * 2)
                    .offset(x: center.x - radius, y: center.y - radius))
                .gesture(SpatialTapGesture().onEnded { value in
                    let dx = Double(value.location.x - center.x), dy = Double(value.location.y - center.y)
                    let th = atan2(dx, -dy)
                    let step = 2 * Double.pi / Double(BlobLayout.groups.count)
                    let i = (Int((th / step).rounded()) % BlobLayout.groups.count + BlobLayout.groups.count) % BlobLayout.groups.count
                    touch(i)
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
                ForEach(Array(BlobLayout.groups.enumerated()), id: \.element) { i, group in
                    label(group, index: i, radius: radius + 12)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(reduceMotion ? nil : .spring(duration: 1.1, bounce: 0.35), value: freshness)
        .sensoryFeedback(.impact(weight: .light), trigger: pokeAngle)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.spring(duration: 1.4, bounce: 0.4).delay(0.1)) { shown = true } }
        }
    }

    /// Squish toward a group, then open it.
    private func touch(_ index: Int) {
        let group = BlobLayout.groups[index]
        if reduceMotion { open(group); return }
        pokeAngle = BlobLayout.angle(index)
        poke = 1
        withAnimation(.spring(duration: 0.6, bounce: 0.6)) { poke = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { open(group) }
    }

    private func label(_ group: ExerciseGroup, index: Int, radius: CGFloat) -> some View {
        let th = BlobLayout.angle(index)
        let s = sin(th), c = cos(th)
        let on = (daysSince(group) ?? 99) < 7
        return Button { touch(index) } label: {
            Text(group.name)
                .font(.label)
                .foregroundStyle(on ? Color.ink : Color.muted)
                .fixedSize()
                .padding(.vertical, 10).padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(HorizontalAlignment.center) { d in d.width * (0.5 - 0.5 * s) }
        .alignmentGuide(VerticalAlignment.center) { d in d.height * (0.5 + 0.5 * c) }
        .offset(x: radius * s, y: -radius * c)
        .accessibilityValue(status(group))
        .accessibilityHint("Shows weekly history")
    }

    private var summary: String {
        let trained = BlobLayout.groups.filter { (daysSince($0) ?? 99) < 7 }.map(\.name)
        return trained.isEmpty ? "Nothing trained this week" : "Trained this week: " + trained.joined(separator: ", ")
    }

    private func status(_ group: ExerciseGroup) -> String {
        switch daysSince(group) {
        case nil: "Not trained yet"
        case 0?: "Trained today"
        case 1?: "Trained yesterday"
        case let d?: "Trained \(d) days ago"
        }
    }
}

// MARK: Growth rings

/// One group's weeks as tree rings: the oldest week at the heart, this week on the bark. A ring is
/// as thick as the sets that week; an idle week is a single dark line.
struct GrowthRings: View {
    /// Sets per week, oldest first.
    let weeks: [Double]
    /// Varies the wobble so each muscle's rings look like its own tree.
    let seed: Int
    @State private var grown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RingsDrawing(weeks: weeks, seed: seed, grown: grown)
            .aspectRatio(1, contentMode: .fit)
            .onAppear {
                if reduceMotion { grown = 1 } else { withAnimation(.easeOut(duration: 0.9)) { grown = 1 } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Growth rings, one per week")
            .accessibilityValue(weeks.map { $0.formatted(.number.precision(.fractionLength(0...1))) }.joined(separator: ", ") + " sets, oldest first")
    }
}

/// The rings themselves; `grown` runs 0…1 as the weeks are laid down from the heart out.
private struct RingsDrawing: View, Animatable {
    let weeks: [Double]
    let seed: Int
    var grown: Double
    var animatableData: Double {
        get { grown }
        set { grown = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = (min(size.width, size.height) / 2 - 2) / 1.02
            let heart = maxR * 0.08
            let idle: CGFloat = 1.5
            // Thickness follows the square root of the sets, so one huge week can't swamp the rest.
            let total = weeks.reduce(0) { $0 + $1.squareRoot() }
            let free = max(0, maxR - heart - idle * CGFloat(weeks.count))
            let perSet = total > 0 ? free / CGFloat(total) : 0
            let peak = max(1, weeks.max() ?? 1)
            let shownCount = Double(weeks.count) * grown

            context.fill(ring(c, heart, 0), with: .color(Color.ink.opacity(0.5)))
            var r = heart
            for (i, sets) in weeks.enumerated() {
                let growth = max(0, min(1, shownCount - Double(i)))
                guard growth > 0 else { break }
                let outer = r + (idle + perSet * CGFloat(sets.squareRoot())) * CGFloat(growth)
                // Earlywood: a pale band, darker for a busier week.
                var band = ring(c, outer, i)
                band.addPath(ring(c, r, i - 1))
                context.fill(band, with: .color(Color.ink.opacity(0.04 + 0.16 * sets / peak)), style: FillStyle(eoFill: true))
                // Latewood: the line that closes the week.
                let last = i == weeks.count - 1
                context.stroke(ring(c, outer, i), with: .color(Color.ink.opacity(last ? 0.9 : 0.45)),
                               lineWidth: last ? 1.5 : 0.75)
                r = outer
            }
        }
    }

    /// A gently uneven circle; the wobble grows with the radius, so the heart stays round.
    private func ring(_ c: CGPoint, _ radius: CGFloat, _ index: Int) -> Path {
        var p = Path()
        let steps = 144
        let a = Double(seed % 97) / 97 * .pi * 2, b = Double(seed % 61) / 61 * .pi * 2
        let drift = Double(index) * 0.35
        for k in 0...steps {
            let t = Double(k) / Double(steps) * .pi * 2
            let wobble = 1 + 0.009 * sin(3 * t + a + drift) + 0.006 * sin(5 * t + b - drift) + 0.003 * sin(9 * t + a)
            let rr = radius * CGFloat(wobble)
            let pt = CGPoint(x: c.x + rr * CGFloat(cos(t)), y: c.y + rr * CGFloat(sin(t)))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// A group's history: its growth rings and a sentence on the trend.
struct MuscleHistorySheet: View {
    let title: String
    let weeks: [Double]
    let daysSince: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text(trend).font(.bodyText).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    HStack(spacing: 0) {
                        stat(sets(weeks.last ?? 0), "This week")
                        Rectangle().fill(Color.rule).frame(width: Metric.hairline, height: 36)
                        stat(sets(average(4, skippingThisWeek: true)), "4-week average")
                        Rectangle().fill(Color.rule).frame(width: Metric.hairline, height: 36)
                        stat(last, "Last trained")
                    }
                    GrowthRings(weeks: weeks, seed: title.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) } & 0xFFFF)
                        .frame(maxWidth: 300)
                    Text("Each ring is a week, oldest at the centre. Thicker rings mean more sets; second-hand sets count half.")
                        .font(.caption).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.heading).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func sets(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0...1))) }

    private func average(_ count: Int, skippingThisWeek: Bool) -> Double {
        let pool = skippingThisWeek ? weeks.dropLast() : weeks[...]
        let slice = pool.suffix(count)
        return slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
    }

    private var last: String {
        switch daysSince {
        case nil: "—"
        case 0?: "Today"
        case 1?: "1 day"
        case let d?: "\(d) days"
        }
    }

    private var trend: String {
        let total = weeks.reduce(0, +)
        guard total > 0 else { return "No sets yet. Its first ring starts with the first set." }
        let now = weeks.last ?? 0, before = average(4, skippingThisWeek: true)
        let active = weeks.filter { $0 > 0 }.count
        if before == 0 { return now > 0 ? "Back this week after a break." : "Trained in \(active) of the last \(weeks.count) weeks." }
        let change = (now - before) / before
        if change >= 1 { return "More than double your usual week." }
        if change >= 0.15 { return "Ahead of your usual week by \(Int((change * 100).rounded()))%." }
        if change <= -0.15 && now > 0 { return "Behind your usual week so far." }
        if now == 0 { return "Nothing yet this week. Usually \(sets(before)) sets." }
        return "Right on your usual pace."
    }
}
