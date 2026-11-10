import SwiftUI

/// Settings → Motion lab. Pick any exercise, record a set with every raw band stream, label it
/// with the reps actually done, and export everything as one zip.
struct MotionLabScreen: View {
    @ObservedObject private var lab = MotionLab.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var search = ""
    @State private var custom = ""
    @State private var exported: URL?
    @State private var exporting = false
    @State private var confirmClear = false

    private var streaming: Bool { controller.snapshot.state == .streaming }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PanelGroup("Band", caption: "Each set records gyroscope, orientation, gestures and 8-channel EMG (2048 Hz). EMG is switched on only while a set is recording.") {
                    ValueRow("Connection") { Text(controller.snapshot.state.title) }
                    Rule()
                    ValueRow("Hand") { Text(controller.snapshot.hand.map { $0 == .left ? "Left" : "Right" } ?? "—") }
                    Rule()
                    Text(lab.emgStatus).font(.caption).foregroundStyle(Color.muted)
                        .padding(.horizontal, Metric.inset).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
                PanelGroup("Recordings", caption: "\(lab.recordings.count) sets · \(ByteCountFormatter.string(fromByteCount: lab.totalBytes, countStyle: .file)). Export the zip and hand it to Claude for tuning.") {
                    ActionRow(exporting ? "Preparing zip…" : "Export all recordings", icon: .share) {
                        exporting = true
                        Task { exported = await lab.export(); exporting = false }
                    }
                    .disabled(exporting || lab.recordings.isEmpty || lab.active != nil)
                    if let exported {
                        Rule()
                        ShareLink(item: exported) {
                            HStack { Text("Share \(exported.lastPathComponent)").font(.bodyText).lineLimit(1); Spacer(); LucideIcon(.share, size: 16).foregroundStyle(Color.muted) }.panelRow()
                        }
                        .buttonStyle(.plain)
                    }
                    Rule()
                    ActionRow("Delete all recordings", icon: .trash2) { confirmClear = true }
                        .disabled(lab.recordings.isEmpty || lab.active != nil)
                }
                PanelGroup("Other movement", caption: "Anything not in the list, or a baseline: stand still, walk, or type for a minute.") {
                    HStack {
                        TextField("Name, e.g. Baseline still", text: $custom).font(.bodyText).submitLabel(.done)
                        NavigationLink { MotionLabRecordView(target: LabTarget(custom: custom)) } label: { Chevron() }
                    }
                    .panelRow()
                }
                TextField("Search exercises", text: $search)
                    .font(.bodyText).padding(.horizontal, Metric.inset).frame(minHeight: Metric.row)
                    .panel()
                ForEach(ExerciseGroup.allCases) { group in
                    let exercises = Exercise.all.filter { $0.group == group && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                    if !exercises.isEmpty {
                        PanelGroup(group.name) {
                            ForEach(Array(exercises.enumerated()), id: \.element.id) { offset, exercise in
                                if offset > 0 { Rule() }
                                row(exercise)
                            }
                        }
                    }
                }
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Motion lab").navigationBarTitleDisplayMode(.inline)
        .onAppear { lab.reload() }
        .confirmationDialog("Delete every Motion Lab recording on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { lab.deleteAll(); exported = nil }
        }
    }

    private func row(_ exercise: Exercise) -> some View {
        let count = lab.recordings(for: LabTarget(exercise)).count
        return NavigationLink { MotionLabRecordView(target: LabTarget(exercise)) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name).font(.bodyText)
                    Text(exercise.detectsReps ? "Band counts reps" : "Not tracked yet").font(.caption).foregroundStyle(Color.muted)
                }
                Spacer()
                if count > 0 { Text("\(count) set\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(Color.muted).monospacedDigit() }
                Chevron()
            }
            .padding(.horizontal, Metric.inset).padding(.vertical, 8).frame(minHeight: Metric.rowTall).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MotionLabRecordView: View {
    let target: LabTarget
    @ObservedObject private var lab = MotionLab.shared
    @ObservedObject private var controller = SessionController.shared

    private var streaming: Bool { controller.snapshot.state == .streaming }
    private var recordingHere: Bool { lab.active?.exerciseID == target.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(target.name).font(.display)
                    Text(detectorText).font(.caption).foregroundStyle(Color.muted)
                }
                if let draft = lab.draft, draft.exerciseID == target.id {
                    LabelForm(meta: draft)
                } else if recordingHere {
                    recording
                } else {
                    idle
                }
                let sets = lab.recordings(for: target)
                if !sets.isEmpty {
                    PanelGroup("Recorded sets", caption: "Long-press a set to delete it.") {
                        ForEach(Array(sets.enumerated()), id: \.element.id) { offset, meta in
                            if offset > 0 { Rule() }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.bodyText)
                                    Text(summary(meta)).font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Metric.inset).padding(.vertical, 8).frame(minHeight: Metric.rowTall).contentShape(Rectangle())
                            .contextMenu { Button("Delete set", role: .destructive) { lab.delete(meta) } }
                        }
                    }
                }
            }
            .padding(Metric.gutter)
        }
        .page()
        .navigationTitle("Record").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(lab.active != nil || lab.draft != nil)
    }

    private var detectorText: String {
        guard let e = target.exercise else { return "Custom movement · no detector" }
        switch e.signal {
        case .swing(let high, let low)?: return "Band detector: forearm swing \(Int(high))° / reset \(Int(low))°"
        case .burst(let on, let off)?: return "Band detector: gyro burst \(Int(on)) / reset \(Int(off))"
        case nil: return e.measure == .seconds ? "Timed · no band detector yet" : "No band detector yet"
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Press Start, do one normal set, then press Stop and enter how many reps you really did. Record a few sets, ideally with different weights and speeds. Tap Mark at any moment worth noting (e.g. the bottom of each rep).")
                .font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            if let problem = lab.problem { Text(problem).font(.caption).foregroundStyle(Color.destructive) }
            Button("Start set") { lab.start(target, hand: controller.snapshot.hand) }
                .buttonStyle(.primary)
                .disabled(!streaming || lab.active != nil)
            if !streaming { Text("Connect the band first.").font(.caption).foregroundStyle(Color.muted) }
            if lab.active != nil { Text("Another set is recording: \(lab.active!.exerciseName).").font(.caption).foregroundStyle(Color.muted) }
        }
    }

    private var recording: some View {
        let live = lab.live
        return VStack(alignment: .leading, spacing: 20) {
            if let started = lab.active?.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.geist(56, .medium, relativeTo: .largeTitle)).monospacedDigit()
            }
            PanelGroup("Live") {
                if target.exercise?.detectsReps == true {
                    ValueRow("Detector reps") { Text("\(live.counts.detectorReps)").monospacedDigit() }
                    Rule()
                }
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
            if !streaming { Text("Band disconnected — samples will resume when it reconnects.").font(.caption).foregroundStyle(Color.destructive) }
            HStack(spacing: 12) {
                Button("Mark (\(live.counts.marks))") { lab.mark() }.buttonStyle(.secondary)
                Button("Stop") { lab.stop() }.buttonStyle(.primary)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: live.counts.marks)
        }
    }

    private func rate(_ hz: Double, _ total: Int) -> String { "\(Int(hz.rounded())) Hz · \(total)" }

    private func summary(_ meta: LabMeta) -> String {
        var parts: [String] = []
        if let reps = meta.actualReps { parts.append("\(reps) reps") }
        if let held = meta.heldSeconds { parts.append("\(held) s") }
        if let detected = meta.detectorReps { parts.append("detector \(detected)") }
        if !meta.weight.isEmpty { parts.append(meta.weight) }
        parts.append(meta.emgBatches > 0 ? "EMG" : "no EMG")
        if !meta.saved { parts.append("unlabelled") }
        return parts.joined(separator: " · ")
    }
}

/// Ground truth for a finished set.
private struct LabelForm: View {
    @State var meta: LabMeta
    @ObservedObject private var lab = MotionLab.shared
    private var timed: Bool { meta.measure == Measure.seconds.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelGroup("How did the set go?", caption: "\(Int(meta.duration.rounded())) s recorded\(meta.detectorReps.map { " · the band detector counted \($0)" } ?? ""). \(meta.emgBatches > 0 ? "EMG captured." : "No EMG received.")") {
                if timed {
                    Stepper(value: Binding(get: { meta.heldSeconds ?? 0 }, set: { meta.heldSeconds = $0 }), in: 0...3600, step: 5) {
                        HStack { Text("Held").font(.bodyText); Spacer(); Text("\(meta.heldSeconds ?? 0) s").font(.bodyText).monospacedDigit() }
                    }
                    .panelRow()
                } else {
                    Stepper(value: Binding(get: { meta.actualReps ?? 0 }, set: { meta.actualReps = $0 }), in: 0...500) {
                        HStack { Text("Reps actually done").font(.bodyText); Spacer(); Text("\(meta.actualReps ?? 0)").font(.bodyText).monospacedDigit() }
                    }
                    .panelRow()
                }
                Rule()
                TextField("Weight, e.g. 12 kg dumbbells", text: $meta.weight).font(.bodyText).panelRow()
                Rule()
                Picker("Band arm", selection: $meta.bandArm) {
                    Text("Band arm moved").tag("moving")
                    Text("Other arm only").tag("still")
                    Text("Both arms").tag("both")
                }
                .pickerStyle(.segmented).padding(Metric.inset)
                Rule()
                TextField("Notes: tempo, form, grip, anything odd", text: $meta.notes, axis: .vertical)
                    .font(.bodyText).lineLimit(1...4).padding(.horizontal, Metric.inset).padding(.vertical, 12)
            }
            Button("Save set") { lab.save(meta) }.buttonStyle(.primary)
            Button("Discard set", role: .destructive) { lab.discardDraft() }.buttonStyle(.quiet).frame(maxWidth: .infinity)
        }
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
