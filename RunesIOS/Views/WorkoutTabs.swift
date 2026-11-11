import SwiftUI

// Workouts' three tabs — Today (the body map and this week's activity), Split (training days)
// and Journal (progress) — plus the exercise picker and the settings behind the gear.

enum WorkoutTab: String, CaseIterable, Identifiable {
    case today, split, journal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Workouts"
        case .split: "Split"
        case .journal: "Journal"
        }
    }
    var label: String { self == .today ? "Today" : title }
    var icon: Lucide {
        switch self {
        case .today: .dumbbell
        case .split: .calendarDays
        case .journal: .bookOpen
        }
    }
}

struct WorkoutTabBar: View {
    @Binding var selection: WorkoutTab
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.rule).frame(height: Metric.hairline)
            HStack(spacing: 0) {
                ForEach(WorkoutTab.allCases) { tab in
                    let on = tab == selection
                    Button { withAnimation(.standard) { selection = tab } } label: {
                        VStack(spacing: 4) {
                            LucideIcon(tab.icon, size: 20, lineWidth: on ? 1.8 : 1.5)
                            Text(tab.label).font(.geist(11, on ? .medium : .regular, relativeTo: .caption2))
                        }
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .frame(maxWidth: .infinity, minHeight: Metric.rowTall).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.top, 4)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: Today

struct TodayTab: View {
    @ObservedObject var store: WorkoutStore
    let start: () -> Void
    let openRun: () -> Void
    @State private var inspecting: ExerciseGroup?

    var body: some View {
        VStack(spacing: 14) {
            if let run = store.run {
                LiveRunBanner(run: run, open: openRun)
            }
            MuscleBlob(freshness: store.freshness(), daysSince: { store.daysSince(of: $0.muscles) }) { inspecting = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.run == nil {
                Button(action: start) {
                    VStack(spacing: 2) {
                        Text("Start workout")
                        if let next = store.upNext { Text("Up next: \(next.name)").font(.caption).opacity(0.7) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.plans.isEmpty)
            }
            Hairline()
            WeekStrip(history: store.history)
        }
        .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 14)
        .sheet(item: $inspecting) { group in
            MuscleHistorySheet(title: group.name, weeks: store.weeklySets(of: group.muscles), daysSince: store.daysSince(of: group.muscles))
        }
    }
}

// MARK: Split

struct SplitTab: View {
    @ObservedObject var store: WorkoutStore
    @Binding var path: [AppRoute]

    var body: some View {
        List {
            Section {
                ForEach(Array(store.plans.enumerated()), id: \.element.id) { index, plan in
                    VStack(alignment: .leading, spacing: 0) {
                        PlanRow(index: index, plan: plan,
                                open: { path.append(.editWorkout(plan.id)) },
                                start: { store.start(plan); path.append(.activeWorkout) })
                        if store.upNext?.id == plan.id, store.plans.count > 1 {
                            Text("Up next").font(.caption).foregroundStyle(Color.muted).padding(.leading, 28).padding(.top, -10).padding(.bottom, 12)
                        }
                    }
                    .contextMenu {
                        menuItem("Duplicate", .copy) { store.duplicate(planID: plan.id) }
                        menuItem("Delete", .trash2, role: .destructive) { store.delete(planID: plan.id) }
                    }
                    .swipeToDelete { store.delete(planID: plan.id) }
                    .workoutRow()
                }
                .onMove { source, destination in store.move(planFrom: source, to: destination) }
                AddRow(title: "Add day") {
                    let plan = WorkoutPlan.new(store.plans.count + 1)
                    store.save(plan); path.append(.editWorkout(plan.id))
                }
                .workoutRow()
                .listRowSeparator(.hidden)
                .moveDisabled(true)
            } header: {
                Heading("Your split", count: store.plans.count)
                    .listRowInsets(EdgeInsets(top: 8, leading: Metric.gutter, bottom: 0, trailing: Metric.gutter))
            }
        }
        .workoutList()
    }
}

/// Starting a workout: pick a day from the split.
struct ChooseDaySheet: View {
    @ObservedObject var store: WorkoutStore
    let choose: (WorkoutPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.plans.isEmpty {
                        Note("Add a day in Split first.")
                    }
                    ForEach(Array(store.plans.enumerated()), id: \.element.id) { index, plan in
                        Button { choose(plan) } label: {
                            HStack(alignment: .center, spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(plan.name).font(.heading)
                                        if store.upNext?.id == plan.id {
                                            Text("Up next").font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                                                .overlay(Capsule().strokeBorder(Color.ink, lineWidth: Metric.hairline))
                                        }
                                    }
                                    Text(plan.items.map(\.exercise.name).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(Color.muted).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(plan.summary).font(.caption).foregroundStyle(Color.muted)
                                }
                                Spacer(minLength: 8)
                                HStack(spacing: -6) {
                                    ForEach(groups(plan), id: \.self) { MuscleGlyph(group: $0, size: 26) }
                                }
                                LucideIcon(.play, size: 16)
                            }
                            .padding(.vertical, 16).contentShape(Rectangle())
                        }
                        .buttonStyle(PressRow())
                        .disabled(plan.items.isEmpty)
                        .arrive(index)
                        Hairline(inset: 0)
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8)
            }
            .page()
            .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }

    private func groups(_ plan: WorkoutPlan) -> [ExerciseGroup] {
        var seen: [ExerciseGroup] = []
        for item in plan.items where !seen.contains(item.exercise.group) { seen.append(item.exercise.group) }
        return Array(seen.prefix(3))
    }
}

// MARK: Journal

struct JournalTab: View {
    @ObservedObject var store: WorkoutStore
    @State private var deleting: WorkoutRecord?

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                if store.history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        LucideIcon(.bookOpen, size: 28).foregroundStyle(Color.muted)
                        Text("Nothing logged yet").font(.heading)
                        Text("Finish a set and it shows up here: your sessions, how each muscle is getting worked, and how every exercise is progressing.")
                            .font(.bodyText).foregroundStyle(Color.muted)
                    }
                    .padding(.top, 24)
                } else {
                    stats.arrive(0)
                    weeks.arrive(1)
                    muscles.arrive(2)
                    exercises.arrive(3)
                    sessions.arrive(4)
                }
            }
            .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
        }
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { record in
            Button("Delete workout", role: .destructive) { store.deleteRecord(record.id) }
        }
    }

    // MARK: Numbers

    /// Weeks in a row, ending this week or last, with at least one workout.
    private var streak: Int {
        let weeks = Set(store.history.map { calendar.dateInterval(of: .weekOfYear, for: $0.started)?.start ?? $0.started })
        var week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        if !weeks.contains(week) { week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week }
        var count = 0
        while weeks.contains(week) {
            count += 1
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        return count
    }

    private var stats: some View {
        let month = store.history.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .month) }
        let weekSets = store.history.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .weekOfYear) }.reduce(0) { $0 + $1.sets.count }
        return HStack(alignment: .top, spacing: 0) {
            stat("\(month.count)", "workouts this month")
            stat("\(weekSets)", "sets this week")
            stat("\(streak)", streak == 1 ? "week streak" : "weeks streak")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.display).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Sets per week for the last eight weeks.
    private var weeks: some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let bars: [(Date, Int)] = (0..<8).reversed().map { offset in
            let week = calendar.date(byAdding: .weekOfYear, value: -offset, to: start)!
            let sets = store.history.filter { calendar.isDate($0.started, equalTo: week, toGranularity: .weekOfYear) }.reduce(0) { $0 + $1.sets.count }
            return (week, sets)
        }
        let peak = max(1, bars.map(\.1).max() ?? 1)
        return Block {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    VStack(spacing: 6) {
                        Text(bar.1 > 0 ? "\(bar.1)" : "").font(.geist(10, relativeTo: .caption2)).foregroundStyle(Color.muted).monospacedDigit()
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(Color.rule).frame(width: Metric.hairline, height: 64)
                            Capsule().fill(Color.ink).frame(width: 3, height: bar.1 > 0 ? max(3, 64 * CGFloat(bar.1) / CGFloat(peak)) : 0)
                        }
                        Text(bar.0, format: .dateTime.day().month(.defaultDigits))
                            .font(.geist(10, relativeTo: .caption2))
                            .foregroundStyle(index == bars.count - 1 ? Color.ink : Color.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sets per week, last eight weeks: \(bars.map { "\($0.1)" }.joined(separator: ", "))")
        } header: {
            Heading("Sets per week")
        }
    }

    /// Sets that trained each muscle first-hand in the last seven days.
    private var muscles: some View {
        let since = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = store.allSets.filter { $0.at >= since }
        let counts = Dictionary(uniqueKeysWithValues: Muscle.allCases.map { m in (m, recent.filter { $0.exercise.primary.contains(m) }.count) })
        let peak = max(1, counts.values.max() ?? 1)
        return Block {
            VStack(spacing: 10) {
                ForEach(Muscle.allCases.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }) { muscle in
                    let n = counts[muscle] ?? 0
                    HStack(spacing: 12) {
                        Text(muscle.name).font(.bodyText).foregroundStyle(n > 0 ? Color.ink : Color.muted)
                            .frame(width: 104, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.rule).frame(height: Metric.hairline)
                                Capsule().fill(Color.ink).frame(width: n > 0 ? max(3, geo.size.width * CGFloat(n) / CGFloat(peak)) : 0, height: 3)
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(height: 10)
                        Text("\(n)").font(.label).monospacedDigit().foregroundStyle(n > 0 ? Color.ink : Color.muted)
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 8)
        } header: {
            Heading("Sets per muscle, last 7 days")
        } footer: {
            Note("Most people grow well on about 10–20 hard sets per muscle each week.")
        }
    }

    private struct ExerciseProgress: Identifiable {
        let exercise: Exercise
        /// Per session, oldest first: the top weight, or the most reps (seconds) without weight.
        let points: [Double]
        let best: String
        let last: Date
        let sets: Int
        var id: String { exercise.id }
    }

    private var progress: [ExerciseProgress] {
        let byExercise = Dictionary(grouping: store.history.reversed().flatMap { record in record.sets.map { (record.id, $0) } }) { $0.1.exercise.id }
        return byExercise.compactMap { _, entries -> ExerciseProgress? in
            guard let exercise = entries.first?.1.exercise else { return nil }
            let logs = entries.map(\.1)
            let weighted = logs.contains { ($0.weight ?? 0) > 0 }
            var sessions: [String: Double] = [:], order: [String] = []
            for (record, log) in entries {
                let value = weighted ? (log.weight ?? 0) : Double(log.reps)
                if sessions[record] == nil { order.append(record) }
                sessions[record] = max(sessions[record] ?? 0, value)
            }
            let best: String
            if weighted, let top = logs.max(by: { ($0.weight ?? 0, $0.reps) < ($1.weight ?? 0, $1.reps) }) {
                best = "\(store.weightText(top.weight) ?? "") × \(top.reps)\(exercise.measure == .seconds ? " s" : "")"
            } else {
                let top = logs.map(\.reps).max() ?? 0
                best = exercise.measure == .seconds ? "\(top) s" : WorkoutStore.reps(top)
            }
            return ExerciseProgress(exercise: exercise, points: order.compactMap { sessions[$0] }.suffix(12),
                                    best: best, last: logs.map(\.at).max() ?? .distantPast, sets: logs.count)
        }
        .sorted { $0.last > $1.last }
    }

    private var exercises: some View {
        let list = progress
        return Block {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline(inset: 0) }
                HStack(spacing: 12) {
                    MuscleGlyph(group: item.exercise.group, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.exercise.name).font(.bodyText).lineLimit(1)
                        Text("Best \(item.best) · \(item.sets) sets").font(.caption).foregroundStyle(Color.muted)
                    }
                    Spacer(minLength: 8)
                    Sparkline(points: item.points).frame(width: 72, height: 26)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Heading("Exercises", count: list.count)
        } footer: {
            Note("Each line is one session: the heaviest weight you used, or your most reps when there's no weight.")
        }
    }

    private var sessions: some View {
        Block {
            ForEach(Array(store.history.prefix(60).enumerated()), id: \.element.id) { index, record in
                if index > 0 { Hairline(inset: 0) }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.name).font(.bodyText)
                            Spacer()
                            Text(record.started, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                                .font(.caption).foregroundStyle(Color.muted)
                        }
                        Text(summary(record)).font(.caption).foregroundStyle(Color.muted)
                        Text(record.muscles.sorted { $0.name < $1.name }.map(\.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.muted).lineLimit(2)
                    }
                }
                .padding(.vertical, 12).contentShape(Rectangle())
                .contextMenu { menuItem("Delete", .trash2, role: .destructive) { deleting = record } }
                .swipeToDelete(confirms: true) { deleting = record }
            }
        } header: {
            Heading("Sessions", count: store.history.count)
        } footer: {
            Note("Swipe a session left, or touch and hold it, to delete it.")
        }
    }

    private func summary(_ record: WorkoutRecord) -> String {
        let minutes = max(1, Int(record.ended.timeIntervalSince(record.started) / 60))
        var parts = ["\(record.sets.count) sets", WorkoutStore.reps(record.totalReps), "\(minutes) min"]
        if record.volume > 0 { parts.append("\(Int(record.volume)) \(store.unit.title) moved") }
        return parts.joined(separator: " · ")
    }
}

/// A hairline line through the points, the last one marked.
struct Sparkline: View {
    let points: [Double]
    var body: some View {
        GeometryReader { geo in
            let low = points.min() ?? 0, high = points.max() ?? 1
            let span = max(high - low, 1e-9)
            let xy: [CGPoint] = points.enumerated().map { i, v in
                CGPoint(x: points.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(points.count - 1) : geo.size.width,
                        y: high == low ? geo.size.height / 2 : geo.size.height * (1 - CGFloat((v - low) / span)))
            }
            ZStack {
                Path { p in
                    guard let first = xy.first else { return }
                    p.move(to: first); for pt in xy.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.ink, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                if let last = xy.last { Circle().fill(Color.ink).frame(width: 5, height: 5).position(last) }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Exercise picker

struct ExercisePicker: View {
    var selected: Exercise?
    let pick: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var query = ""

    enum Filter: Hashable {
        case all, band, group(ExerciseGroup)
        var title: String {
            switch self {
            case .all: "All"
            case .band: "Band counts"
            case .group(let g): g.name
            }
        }
        static let tabs: [Filter] = [.all] + ExerciseGroup.allCases.map { .group($0) } + [.band]
    }

    private var results: [Exercise] {
        let words = query.lowercased().split(separator: " ")
        return Exercise.all.filter { e in
            switch filter {
            case .all: break
            case .band: guard e.detectsReps else { return false }
            case .group(let g): guard e.group == g else { return false }
            }
            let haystack = "\(e.name) \(e.equipment.name) \(e.group.name) \(e.primary.map(\.name).joined(separator: " "))".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabs
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            LucideIcon(.audioWaveform, size: 15)
                            Text("The band counts these reps. Others log your target when you stop the set, or the time for timed ones.")
                                .font(.caption).foregroundStyle(Color.muted)
                        }
                        .padding(.vertical, 12)
                        Hairline(inset: 0)
                        ForEach(results) { exercise in
                            row(exercise)
                            Hairline(inset: 0)
                        }
                        if results.isEmpty {
                            Text("No exercises match.").font(.bodyText).foregroundStyle(Color.muted).padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, Metric.gutter)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .page()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises or muscles")
            .navigationTitle("Exercises").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
    }

    private var tabs: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(Filter.tabs, id: \.self) { tab in
                        let on = tab == filter
                        Button { withAnimation(.standard) { filter = tab; reader.scrollTo(tab, anchor: .center) } } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    if case .group(let g) = tab { MuscleGlyph(group: g, size: 18) }
                                    if tab == .band { LucideIcon(.audioWaveform, size: 14) }
                                    Text(tab.title).font(.label)
                                }
                                .foregroundStyle(on ? Color.ink : Color.muted)
                                Rectangle().fill(on ? Color.ink : Color.clear).frame(height: 1.5)
                            }
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .id(tab)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 6)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.rule).frame(height: Metric.hairline) }
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func row(_ exercise: Exercise) -> some View {
        Button { pick(exercise); dismiss() } label: {
            HStack(spacing: 14) {
                MuscleGlyph(group: exercise.group, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.name).font(.bodyText).foregroundStyle(Color.ink)
                    Text("\(exercise.primary.map(\.name).joined(separator: ", ")) · \(exercise.detail)")
                        .font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if exercise.detectsReps { LucideIcon(.audioWaveform, size: 16).accessibilityLabel("Band counts reps") }
                else if exercise.measure == .seconds { LucideIcon(.timer, size: 16).foregroundStyle(Color.muted) }
                if exercise == selected { LucideIcon(.check, size: 16) }
            }
            .padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(exercise == selected ? .isSelected : [])
    }
}

// MARK: Settings

extension WorkoutCommand: Identifiable { public var id: String { rawValue } }

struct WorkoutSettingsScreen: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    @State private var choosing: WorkoutCommand?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    gestures
                    Block {
                        HairlineSegments(selection: Binding(get: { store.sensitivity }, set: store.setSensitivity),
                                         options: RepSensitivity.allCases, title: \.title)
                    } header: {
                        Heading("Rep detection")
                    } footer: {
                        Note("Lower needs a bigger movement for each rep. Only exercises marked with a waveform are counted; the rest log your target. Detection hasn’t been tuned on a real band yet.")
                    }
                    Block {
                        HairlineSegments(selection: Binding(get: { store.unit }, set: store.setUnit),
                                         options: WeightUnit.allCases, title: \.title)
                    } header: {
                        Heading("Weights")
                    }
                    if !store.history.isEmpty {
                        Button("Clear journal") { clearing = true }.buttonStyle(.quiet)
                    }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Workout settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .confirmationDialog("Clear your journal?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear journal", role: .destructive, action: store.clearHistory)
            } message: { Text("Every logged workout is deleted. Your split stays.") }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = WorkoutCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: CommandTrigger.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                        ?? (steps.first.map { $0.gesture.isMotion } == true ? "Exercises turn and move your wrist, so a combo that starts with rotation or movement will start often. Begin with a finger or swipe step." : nil)
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }

    private var gestures: some View {
        Block {
            ForEach(WorkoutCommand.allCases, id: \.self) { command in
                TriggerRow(title: command.title, detail: command.detail,
                           steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                if command != WorkoutCommand.allCases.last { Hairline(inset: 0) }
            }
        } header: {
            Heading("Gestures")
        } footer: {
            Note("A gesture or a combo each, the same for every workout. While a workout runs, mappings that use these gestures are off.")
        }
    }
}

// MARK: Number chips

/// A small hairline chip showing a number and its unit. Tapping it shows + above and − below and
/// opens the keyboard to type the number; tapping elsewhere or Done puts it away.
struct NumberChip: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals = false
    let unit: String
    /// Shown instead of the number when it is zero, such as "No weight".
    var zeroText: String? = nil
    let label: String

    @FocusState private var focused: Bool
    @State private var text = ""
    static let width: CGFloat = 92

    var body: some View {
        VStack(spacing: 6) {
            if focused { stepButton(plus: true).transition(.move(edge: .bottom).combined(with: .opacity)) }
            ZStack {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("", text: $text)
                        .keyboardType(decimals ? .decimalPad : .numberPad)
                        .focused($focused)
                        .font(.geist(17, .medium, relativeTo: .body)).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text(unit).font(.caption).foregroundStyle(Color.muted)
                }
                .opacity(focused ? 1 : 0)
                if !focused {
                    display.allowsHitTesting(false)
                }
            }
            .frame(width: Self.width, height: 38)
            .background(RoundedRectangle(cornerRadius: Metric.control).fill(focused ? Color.soft : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(focused ? Color.ink : Color.rule, lineWidth: Metric.hairline))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if focused { stepButton(plus: false).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: focused)
        .onAppear { text = format(value) }
        .onChange(of: focused) { _, now in
            if now { text = value == 0 && zeroText != nil ? "" : format(value) } else { commit() }
        }
        .onChange(of: text) { _, typed in
            guard focused, let number = parse(typed) else { return }
            value = clamp(number)
        }
        .onChange(of: value) { _, new in if !focused { text = format(new) } }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == 0 ? (zeroText ?? "0") : "\(format(value)) \(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = clamp(value + step)
            case .decrement: value = clamp(value - step)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var display: some View {
        if value == 0, let zeroText {
            Text(zeroText).font(.caption).foregroundStyle(Color.muted)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(format(value)).font(.geist(17, .medium, relativeTo: .body)).monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Text(unit).font(.caption).foregroundStyle(Color.muted)
            }
            .animation(.standard, value: value)
        }
    }

    private func stepButton(plus: Bool) -> some View {
        let enabled = plus ? value < range.upperBound : value > range.lowerBound
        return Button {
            value = clamp(value + (plus ? step : -step))
            text = format(value)
        } label: {
            ZStack {
                Rectangle().frame(width: 12, height: 1.4)
                if plus { Rectangle().frame(width: 1.4, height: 12) }
            }
            .frame(width: Self.width, height: 34)
            .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: Metric.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(Ripple())
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(plus ? "More" : "Less")
    }

    private func clamp(_ v: Double) -> Double {
        let snapped = decimals ? (v * 10).rounded() / 10 : v.rounded()
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
    private func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
    private func commit() {
        if let number = parse(text) { value = clamp(number) }
        text = format(value)
    }
    private func format(_ v: Double) -> String {
        decimals && v.rounded() != v ? String(format: "%.1f", v) : String(Int(v))
    }
}

extension NumberChip {
    /// For a whole-number setting such as sets or reps.
    init(int: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String, label: String) {
        self.init(value: Binding(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0) }),
                  range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), unit: unit, label: label)
    }
    /// For an optional weight, where zero means none.
    init(weight: Binding<Double?>, unit: WeightUnit) {
        self.init(value: Binding(get: { weight.wrappedValue ?? 0 }, set: { weight.wrappedValue = $0 > 0 ? $0 : nil }),
                  range: WorkoutItem.weightRange, step: unit.step, decimals: true, unit: unit.title, zeroText: "No weight", label: "Weight")
    }
}

/// Hides the keyboard: the Done button above it.
@MainActor func endEditing() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: List rows

extension View {
    /// A List row drawn like the rest of Workouts: page background, hairline separator, page gutter.
    func workoutRow() -> some View {
        listRowBackground(Color.paper)
            .listRowSeparatorTint(Color.rule)
            .listRowInsets(EdgeInsets(top: 0, leading: Metric.gutter, bottom: 0, trailing: Metric.gutter))
    }
    func workoutList() -> some View {
        listStyle(.plain).scrollContentBackground(.hidden).environment(\.defaultMinListRowHeight, 1)
    }
}
