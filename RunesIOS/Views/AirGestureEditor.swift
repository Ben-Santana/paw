import SwiftUI

/// Draws or records an air gesture's shape, like the Mac's AirGestureEditor: draw one stroke
/// with a finger, or act it out with the band. Saved as the Mac's 64-point normalized path.
struct AirGestureEditor: View {
    @ObservedObject var store: MappingStore
    let initial: AirShape?
    let onSave: (AirShape) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable { case draw = "Draw", band = "Use band" }
    private static let pad = CGSize(width: 400, height: 280)

    /// Pad coordinates (400 × 280).
    @State private var points: [CGPoint] = []
    @State private var name = ""
    @State private var minSimilarity = 75.0
    @State private var durationMs = 2000.0
    @State private var mode: Mode = .draw
    @State private var message = "Draw one continuous stroke. The dot marks where it starts."
    @State private var latest: (q: [Double], at: Date)?
    @State private var capture: (reference: [Double], points: [AirShape.Point], end: Date, last: Date)?
    @State private var now = Date()
    private let clock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var recording: Bool { capture != nil }
    private var fresh: Bool { latest.map { now.timeIntervalSince($0.at) < 0.5 } ?? false }
    private var shape: AirShape {
        AirShape(points: AirMatcher.normalize(points.map { [Double($0.x), Double($0.y)] }),
                 minSimilarity: Int(minSimilarity), durationMs: Int(durationMs),
                 name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(name.prefix(40)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Picker("Capture method", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).disabled(recording)
                    padView
                    HStack {
                        if mode == .band {
                            Button(recording ? "Stop · \(String(format: "%.1f", max(0, capture!.end.timeIntervalSince(now)))) s"
                                   : fresh ? "Start recording" : "Waiting for band…") { recording ? stop() : start() }
                                .disabled(!fresh && !recording)
                        } else {
                            Button("Clear drawing") { points = [] }.disabled(points.isEmpty)
                        }
                        Spacer()
                        Text("One continuous stroke").font(.caption).foregroundStyle(Color.muted)
                    }
                    .font(.bodyText)
                    Text(message).font(.caption).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading)
                    MappingGroup("Settings", caption: "The gesture before this step starts recording. Shapes that compete are compared after their windows close; the highest similarity above its minimum wins. Works best with your elbow still and forearm pointing forward.") {
                        TextField("Shape name (optional)", text: $name)
                            .font(.bodyText).padding(.horizontal, 14).frame(minHeight: 48)
                        RowDivider()
                        slider("Minimum similarity", value: $minSimilarity, range: 1...100, step: 1, text: "\(Int(minSimilarity))%")
                        RowDivider()
                        slider("Time to perform", value: $durationMs, range: 500...10_000, step: 100, text: String(format: "%.1f s", durationMs / 1000))
                    }
                    .disabled(recording)
                }
                .padding(16)
            }
            .background(Color.paper)
            .navigationTitle("Air gesture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(shape); dismiss() }.disabled(recording || !shape.isValid)
                }
            }
        }
        .onAppear {
            if let initial {
                points = display(initial.points); name = initial.name ?? ""
                minSimilarity = Double(initial.minSimilarity); durationMs = Double(initial.durationMs)
            }
        }
        .onChange(of: mode) { _, mode in
            message = mode == .draw ? "Draw one continuous stroke. The dot marks where it starts."
                                    : "Hold your forearm forward, palm down. Start recording, then act out the shape."
            listen(mode == .band)
        }
        .onDisappear { listen(false) }
        .onReceive(clock) { date in
            now = date
            guard let c = capture else { return }
            if date.timeIntervalSince(c.last) > 0.5 { interrupted() } else if date >= c.end { stop() }
        }
    }

    private var padView: some View {
        Canvas { context, size in
            let scale = size.width / Self.pad.width
            var path = Path()
            for (i, p) in points.enumerated() {
                let q = CGPoint(x: p.x * scale, y: p.y * scale)
                i == 0 ? path.move(to: q) : path.addLine(to: q)
            }
            context.stroke(path, with: .color(.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            if points.count > 1, let first = points.first {
                context.fill(Path(ellipseIn: CGRect(x: first.x * scale - 5, y: first.y * scale - 5, width: 10, height: 10)), with: .color(.ink))
            }
        }
        .aspectRatio(Self.pad.width / Self.pad.height, contentMode: .fit)
        .overlay {
            if points.count < 2 {
                Text(mode == .draw ? "Draw your shape here" : "Your motion appears here").font(.bodyText).foregroundStyle(Color.faint)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Metric.control)
            .strokeBorder(recording ? Color.ink : Color.rule, lineWidth: recording ? 1.5 : Metric.hairline))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
            guard mode == .draw, !recording else { return }
            // Each new touch starts a new stroke.
            if !drawing { drawing = true; points = [] }
            let scale = Self.pad.width / max(1, padWidth)
            let p = CGPoint(x: min(Self.pad.width, max(0, value.location.x * scale)),
                            y: min(Self.pad.height, max(0, value.location.y * scale)))
            if points.count < 4096 { points.append(p) }
        }.onEnded { _ in drawing = false })
        .background(GeometryReader { geo in Color.clear.preference(key: PadWidth.self, value: geo.size.width) })
        .onPreferenceChange(PadWidth.self) { padWidth = $0 }
        .accessibilityLabel("Air gesture drawing")
    }
    @State private var padWidth: CGFloat = 400
    @State private var drawing = false

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.bodyText); Spacer(); Text(text).font(.bodyText).foregroundStyle(Color.muted).monospacedDigit() }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// A saved normalized path, centered on the pad.
    private func display(_ normalized: [AirShape.Point]) -> [CGPoint] {
        AirMatcher.normalize(normalized).map { CGPoint(x: 200 + $0[0] * 240, y: 140 + $0[1] * 240) }
    }

    // MARK: Band recording

    private func listen(_ on: Bool) {
        if on {
            store.onOrientation = { q in sample(q) }
        } else {
            store.onOrientation = nil; capture = nil; latest = nil
        }
    }
    private func sample(_ q: [Double]) {
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard q.count == 4, q.allSatisfy(\.isFinite), norm > 1e-8 else { return }
        let unit = q.map { $0 / norm }, at = Date()
        latest = (unit, at)
        guard var c = capture else { return }
        if at.timeIntervalSince(c.last) > 0.5 { interrupted(); return }
        guard at <= c.end, c.points.count < 4096 else { return }
        c.points.append(AirMatcher.wristPoint(unit, reference: c.reference))
        c.last = at
        capture = c
        points = display(c.points)
    }
    private func start() {
        guard let q = latest, Date().timeIntervalSince(q.at) < 0.5 else { return }
        capture = (q.q, [], Date().addingTimeInterval(durationMs / 1000), Date())
        points = []
        message = "Recording your wrist motion…"
    }
    private func stop() {
        guard let c = capture else { return }
        capture = nil
        if c.points.count >= AirMatcher.minimumPoints, AirMatcher.pathLength(c.points) >= AirMatcher.minimumPath {
            points = display(c.points); message = "Recorded. Save this shape, or record again."
        } else {
            points = []; message = "Too little motion. Keep your elbow still and move your hand through a larger shape."
        }
    }
    private func interrupted() {
        capture = nil; points = []
        message = "Orientation interrupted. Please record again."
    }
}

private struct PadWidth: PreferenceKey {
    static let defaultValue: CGFloat = 400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
