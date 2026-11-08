#if DEBUG
import SwiftUI

/// A playground for the ring's gesture reactions. Debug builds only; it feeds the view
/// directly and never touches the session or Bluetooth.
/// Open the "Ring lab" preview, or launch with NEURAL_SNAPSHOT=ring-lab (or ring-demo to autoplay).
struct RingLab: View {
    var autoplay = false
    @State private var gesture: BandGesture?
    @State private var serial = 0
    @State private var phase: BandPhase = .connected
    @State private var holding = false

    var body: some View {
        VStack(spacing: 16) {
            HairlineRing(phase: phase, gesture: gesture)
                .frame(maxWidth: 360)
            Text(gesture.map { $0.kind == .holdEnded ? "Released" : $0.title } ?? "Try a gesture")
                .font(.heading).contentTransition(.opacity)
            Picker("State", selection: $phase) {
                Text("Not set up").tag(BandPhase.notSetUp)
                Text("Connecting").tag(BandPhase.connecting)
                Text("Connected").tag(BandPhase.connected)
                Text("Attention").tag(BandPhase.attention)
            }
            .pickerStyle(.segmented)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button("Tap") { fire(.tap) }
                    Button("Double tap") { fire(.doubleTap) }
                    Button("Middle tap") { fire(.tap, finger: 3) }
                }
                GridRow {
                    Text(holding ? "Holding…" : "Hold")
                        .font(.label).frame(maxWidth: .infinity, minHeight: 48)
                        .background(holding ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
                        .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: 40, perform: {}) { pressing in
                            if pressing { holding = true; fire(.holdBegan) } else if holding { holding = false; fire(.holdEnded) }
                        }
                        .gridCellColumns(3)
                }
                GridRow {
                    Button("←") { fire(.swipe(.left), finger: 1) }
                    Button("↑") { fire(.swipe(.up), finger: 1) }
                    Button("→") { fire(.swipe(.right), finger: 1) }
                }
                GridRow {
                    Color.clear.frame(height: 1)
                    Button("↓") { fire(.swipe(.down), finger: 1) }
                    Color.clear.frame(height: 1)
                }
            }
            .buttonStyle(.secondary)
        }
        .padding(Metric.gutter)
        .page()
        .task {
            guard autoplay else { return }
            let script: [(BandGesture.Kind, UInt64, Double)] = [
                (.tap, 2, 1.6), (.doubleTap, 2, 1.8), (.holdBegan, 2, 1.8), (.holdEnded, 2, 1.6),
                (.swipe(.right), 1, 1.4), (.swipe(.left), 1, 1.4), (.swipe(.up), 1, 1.4), (.swipe(.down), 1, 1.6)]
            while !Task.isCancelled {
                for (kind, finger, wait) in script {
                    fire(kind, finger: finger)
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        }
    }

    private func fire(_ kind: BandGesture.Kind, finger: UInt64 = 2) {
        serial += 1
        gesture = BandGesture(id: serial, kind: kind, finger: finger, at: Date())
    }
}

#Preview("Ring lab") { RingLab() }
#Preview("Ring lab · dark") { RingLab().preferredColorScheme(.dark) }
#endif
