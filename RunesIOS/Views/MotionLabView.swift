import SwiftUI

/// Settings → Workout data. Every workout records the band's raw streams (gyroscope,
/// orientation, gestures, 8-channel EMG) with its sets; this lists them and exports one zip.
struct MotionLabScreen: View {
    @ObservedObject private var lab = MotionLab.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var exported: URL?
    @State private var exporting = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PanelGroup("Recording", caption: "While a workout runs, Runes saves every raw band sample, EMG included, alongside your sets. Just do your workouts as usual. Recording stops when you end the workout, or after 3 hours.") {
                    Toggle(isOn: $lab.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Record during workouts").font(.bodyText)
                            Text("About 120 MB per hour, mostly EMG.").font(.caption).foregroundStyle(Color.muted)
                        }
                    }
                    .padding(.horizontal, Metric.inset).padding(.vertical, 10)
                    .disabled(lab.active != nil)
                    Rule()
                    ValueRow("Band") { Text(controller.snapshot.state.title) }
                    Rule()
                    Text(lab.emgStatus).font(.caption).foregroundStyle(Color.muted)
                        .padding(.horizontal, Metric.inset).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    if let problem = lab.problem {
                        Rule()
                        Text(problem).font(.caption).foregroundStyle(Color.destructive)
                            .padding(.horizontal, Metric.inset).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let active = lab.active { live(active) }
                PanelGroup("Export", caption: "\(lab.recordings.count) workout\(lab.recordings.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: lab.totalBytes, countStyle: .file)). Export the zip and hand it to Claude.") {
                    ActionRow(exporting ? "Preparing zip…" : "Export all workout data", icon: .share) {
                        exporting = true
                        Task { exported = await lab.export(); exporting = false }
                    }
                    .disabled(exporting || lab.recordings.isEmpty)
                    if let exported {
                        Rule()
                        ShareLink(item: exported) {
                            HStack { Text("Share \(exported.lastPathComponent)").font(.bodyText).lineLimit(1); Spacer(); LucideIcon(.share, size: 16).foregroundStyle(Color.muted) }.panelRow()
                        }
                        .buttonStyle(.plain)
                    }
                    Rule()
                    ActionRow("Delete all workout data", icon: .trash2) { confirmClear = true }
                        .disabled(lab.recordings.isEmpty)
                }
                if !lab.recordings.isEmpty {
                    PanelGroup("Workouts", caption: "Swipe a workout left, or touch and hold it, to delete its data.") {
                        ForEach(Array(lab.recordings.enumerated()), id: \.element.id) { offset, meta in
                            if offset > 0 { Rule() }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(meta.workoutName) · \(meta.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.bodyText)
                                    Text(summary(meta)).font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Metric.inset).padding(.vertical, 8).frame(minHeight: Metric.rowTall).contentShape(Rectangle())
                            .contextMenu { Button("Delete data", role: .destructive) { lab.delete(meta); exported = nil } }
                            .swipeToDelete { lab.delete(meta); exported = nil }
                        }
                    }
                }
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Workout data").navigationBarTitleDisplayMode(.inline)
        .onAppear { lab.reload() }
        .confirmationDialog("Delete all recorded workout data on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { lab.deleteAll(); exported = nil }
        } message: {
            Text("Your workout history stays. Only the raw band recordings are removed.")
        }
    }

    private func live(_ active: LabMeta) -> some View {
        let live = lab.live
        return PanelGroup("Recording now", caption: active.workoutName) {
            ValueRow("Elapsed") { Text(timerInterval: active.startedAt...Date.distantFuture, countsDown: false).monospacedDigit() }
            Rule()
            ValueRow("Gyroscope") { Text(rate(live.gyroHz, live.counts.gyro)).monospacedDigit() }
            Rule()
            ValueRow("Orientation") { Text(rate(live.orientationHz, live.counts.orientation)).monospacedDigit() }
            Rule()
            ValueRow("EMG") { Text(rate(live.emgHz, live.counts.emgBatches * 16)).monospacedDigit() }
            Rule()
            EMGMeter(levels: live.counts.emgLevel).padding(Metric.inset)
            if !live.counts.gaps.isEmpty {
                Rule()
                ValueRow("Sequence gaps") { Text(live.counts.gaps.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")).monospacedDigit() }
            }
        }
    }

    private func rate(_ hz: Double, _ total: Int) -> String { "\(Int(hz.rounded())) Hz · \(total)" }

    private func summary(_ meta: LabMeta) -> String {
        var parts = ["\(meta.sets.count) set\(meta.sets.count == 1 ? "" : "s")", "\(Int((meta.duration / 60).rounded())) min"]
        parts.append(meta.emgBatches > 0 ? "EMG" : "no EMG")
        parts.append(ByteCountFormatter.string(fromByteCount: meta.bytes, countStyle: .file))
        if !meta.complete { parts.append("incomplete") }
        if meta.capped { parts.append("capped") }
        return parts.joined(separator: " · ")
    }
}

/// Eight bars: peak-to-peak of each EMG channel in the latest batch.
private struct EMGMeter: View {
    let levels: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<8, id: \.self) { ch in
                let level = ch < levels.count ? levels[ch] : 0
                // Log scale: raw ADC peak-to-peak spans several orders of magnitude.
                let fraction = min(1, log10(max(level, 1)) / 4.5)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.ink)
                        .frame(height: max(2, 48 * fraction))
                        .frame(height: 48, alignment: .bottom)
                    Text("\(ch + 1)").font(.caption).foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.standard, value: levels)
        .accessibilityLabel("EMG activity per channel")
    }
}
