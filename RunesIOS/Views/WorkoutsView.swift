import SwiftUI

// Applications: small band-driven apps. The first is Workouts — saved plans of arm
// exercises, global control gestures, reps counted from the band's motion, and a run
// screen that the Live Activity mirrors so the phone can stay locked.
//
// Workouts is drawn without panels: type, hairline rules and hairline motion. Rules draw
// in from the leading edge, rows arrive in a short stagger, the rep ring fills one tick
// per rep with a ripple, and the waiting ring breathes. Reduce Motion removes movement.

enum AppRoute: Hashable {
    case workouts
    case editWorkout(String)
    case activeWorkout
    case score
    case cook
    case recipe(String)
    case cooking
    case capture
    case note(String)
}

// MARK: Applications

struct ApplicationsScreen: View {
    @ObservedObject var workouts: WorkoutStore
    var done: () -> Void = {}
    @ObservedObject private var pins = PinStore.shared
    @ObservedObject private var scores: ScoreStore
    @ObservedObject private var cook: CookStore
    @ObservedObject private var capture: CaptureStore
    @State private var path: [AppRoute]

    init(workouts: WorkoutStore, scores: ScoreStore? = nil, cook: CookStore? = nil, capture: CaptureStore? = nil,
         initialRoute: AppRoute? = nil, done: @escaping () -> Void = {}) {
        self.workouts = workouts
        self.scores = scores ?? .shared
        self.cook = cook ?? .shared
        self.capture = capture ?? .shared
        self.done = done
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Apps that run from your band, also while your phone is locked.")
                        .font(.caption).foregroundStyle(Color.muted).padding(.bottom, 16)
                    Hairline()
                    ForEach(Array(RunesApp.allCases.enumerated()), id: \.element) { index, app in
                        appRow(app)
                        Hairline(delay: 0.1 * Double(index + 1))
                    }
                    Text("Touch and hold an app to pin it to the home screen.")
                        .font(.caption).foregroundStyle(Color.muted).padding(.top, 16)
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle("Applications").navigationBarTitleDisplayMode(.inline)
            .toolbar { BackToolbarItem(action: done) }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .workouts: WorkoutsScreen(store: workouts, path: $path)
                case .editWorkout(let id): WorkoutEditor(store: workouts, planID: id)
                case .activeWorkout: ActiveWorkoutScreen(store: workouts)
                case .score: ScoreScreen(store: scores)
                case .cook: CookScreen(store: cook, path: $path)
                case .recipe(let id): RecipeScreen(store: cook, recipeID: id, path: $path)
                case .cooking: CookingScreen(store: cook)
                case .capture: CaptureScreen(store: capture, path: $path)
                case .note(let id): NoteScreen(store: capture, noteID: id)
                }
            }
        }
        .tint(Color.ink)
    }

    private func subtitle(_ app: RunesApp) -> String {
        switch app {
        case .workouts: return workouts.run.map { "\($0.name) in progress" } ?? "Your split, a journal, and reps from your band"
        case .score: return scores.game.live ? scores.game.summary : "Keep score from your band, without looking"
        case .cook: return cook.session.map { "\($0.recipe.title) · \($0.position.lowercased())" } ?? "Recipes a step at a time, with hands-free timers"
        case .capture:
            if capture.isRecording { return "Recording" }
            return capture.listening ? "Listening from your pocket" : "Make a gesture, say it, and it’s written down"
        }
    }

    private func running(_ app: RunesApp) -> Bool {
        switch app {
        case .workouts: workouts.run != nil
        case .score: scores.game.live
        case .cook: cook.session != nil
        case .capture: capture.listening || capture.isRecording
        }
    }

    private func appRow(_ app: RunesApp) -> some View {
        NavigationLink(value: app.route) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline)
                    if running(app) { OrbitDot(radius: 22) }
                    LucideIcon(app.icon, size: 18)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.title).font(.heading)
                    Text(subtitle(app)).font(.caption).foregroundStyle(Color.muted)
                }
                Spacer()
                if pins.isPinned(app) {
                    Text("Pinned").font(.caption).foregroundStyle(Color.muted)
                }
                LucideIcon(.chevronRight, size: 16).foregroundStyle(Color.muted)
            }
            .padding(.vertical, 16).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .contextMenu {
            if pins.isPinned(app) {
                Button("Unpin from home", role: .destructive) { pins.unpin(app) }
            } else {
                Button(pins.isFull ? "Pin to home, replacing one" : "Pin to home") {
                    // When all three slots are taken, the home screen asks which to replace.
                    if !pins.pin(app) { done() }
                }
            }
        }
        .accessibilityHint(pins.isPinned(app) ? "Touch and hold to unpin from the home screen." : "Touch and hold to pin to the home screen.")
    }
}

// MARK: Workouts

struct WorkoutsScreen: View {
    @ObservedObject var store: WorkoutStore
    @Binding var path: [AppRoute]
    @AppStorage("workouts.tab") private var tab: WorkoutTab = .today
    @State private var showSettings = false
    @State private var choosingDay = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .today: TodayTab(store: store, start: { choosingDay = true }, openRun: { path.append(.activeWorkout) })
                case .split: SplitTab(store: store, path: $path)
                case .journal: JournalTab(store: store)
                }
            }
            .frame(maxHeight: .infinity)
            WorkoutTabBar(selection: $tab)
        }
        .page()
        .navigationTitle(tab.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                    .accessibilityLabel("Workout settings")
            }
        }
        .sheet(isPresented: $showSettings) { WorkoutSettingsScreen(store: store) }
        .sheet(isPresented: $choosingDay) {
            ChooseDaySheet(store: store) { plan in
                choosingDay = false
                store.start(plan)
                path.append(.activeWorkout)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// A plan as type and ticks: number, name, one tick per set grouped by exercise, and a
/// hairline play button.
struct PlanRow: View {
    let index: Int
    let plan: WorkoutPlan
    let open: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(String(format: "%02d", index + 1))
                        .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.name).font(.heading).lineLimit(1)
                        PlanTicks(plan: plan)
                        Text(plan.items.map(\.exercise.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 18).contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            Button(action: start) {
                ZStack {
                    Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                    LucideIcon(.play, size: 16).offset(x: 1)
                }
                .frame(width: 48, height: 48).contentShape(Circle())
            }
            .buttonStyle(Ripple())
            .accessibilityLabel("Start \(plan.name)")
            .disabled(plan.items.isEmpty)
            .opacity(plan.items.isEmpty ? 0.3 : 1)
        }
    }
}

/// One short vertical hairline per set, a gap between exercises; taller ticks for more reps.
struct PlanTicks: View {
    let plan: WorkoutPlan
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(plan.items) { item in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<item.sets, id: \.self) { _ in
                        Capsule().fill(Color.ink).frame(width: Metric.hairline, height: 6 + min(10, CGFloat(item.reps) / 3))
                    }
                }
            }
            Text(plan.summary).font(.caption).foregroundStyle(Color.muted).padding(.leading, 4)
        }
        .frame(height: 16, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The last seven days as hairline bars, each as tall as that day's reps.
struct WeekStrip: View {
    let history: [WorkoutRecord]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var days: [(date: Date, reps: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let reps = history.filter { calendar.isDate($0.started, inSameDayAs: day) }.reduce(0) { $0 + $1.totalReps }
            return (day, reps)
        }
    }

    var body: some View {
        let days = days
        let peak = max(1, days.map(\.reps).max() ?? 1)
        let total = days.reduce(0) { $0 + $1.reps }
        let sessions = history.filter { $0.started > Date().addingTimeInterval(-7 * 86_400) }.count
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(total)").font(.display).monospacedDigit().contentTransition(.numericText())
                Text(sessions == 1 ? "reps this week · 1 session" : "reps this week · \(sessions) sessions")
                    .font(.caption).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.rule).frame(width: Metric.hairline, height: 36)
                            Capsule().fill(Color.ink)
                                .frame(width: day.reps > 0 ? 2 : Metric.hairline, height: day.reps > 0 ? max(3, 36 * CGFloat(day.reps) / CGFloat(peak)) : 0)
                                .scaleEffect(y: shown ? 1 : 0, anchor: .bottom)
                                .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3).delay(0.04 * Double(index)), value: shown)
                        }
                        Text(day.date, format: .dateTime.weekday(.narrow))
                            .font(.geist(10, relativeTo: .caption2))
                            .foregroundStyle(index == days.count - 1 ? Color.ink : Color.muted)
                    }
                }
            }
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total) reps this week")
    }
}

/// The running workout: a dot pulsing and a hairline scanning beneath.
struct LiveRunBanner: View {
    let run: WorkoutRun
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PulseDot()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(run.name) · in progress").font(.label)
                        Text(run.current.map { "\($0.exercise.name) · \($0.label)" } ?? "Done").font(.caption).foregroundStyle(Color.muted)
                    }
                    Spacer()
                    if run.phase == .counting {
                        Text("\(run.reps)").font(.heading).monospacedDigit().contentTransition(.numericText())
                            .animation(.standard, value: run.reps)
                    }
                    LucideIcon(.chevronRight, size: 16).foregroundStyle(Color.muted)
                }
                RunProgress(run: run, height: 2)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
    }
}

/// Past workouts on a vertical hairline, newest first.
struct HistoryTimeline: View {
    let records: [WorkoutRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Circle().strokeBorder(Color.ink, lineWidth: Metric.hairline)
                            .background(Circle().fill(index == 0 ? Color.ink : Color.paper))
                            .frame(width: 9, height: 9).padding(.top, 5)
                        if index < records.count - 1 { Rectangle().fill(Color.rule).frame(width: Metric.hairline).frame(maxHeight: .infinity) }
                    }
                    .frame(width: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(record.name).font(.bodyText)
                            Spacer()
                            Text(record.started, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(Color.muted)
                        }
                        Text("\(record.sets.count) sets · \(WorkoutStore.reps(record.totalReps)) · \(duration(record))")
                            .font(.caption).foregroundStyle(Color.muted)
                    }
                    .padding(.bottom, 20)
                }
                .arrive(index)
            }
        }
    }

    private func duration(_ record: WorkoutRecord) -> String {
        let minutes = max(1, Int(record.ended.timeIntervalSince(record.started) / 60))
        return "\(minutes) min"
    }
}

// MARK: Editor

struct WorkoutEditor: View {
    @ObservedObject var store: WorkoutStore
    let planID: String
    @State private var draft: WorkoutPlan?
    @State private var picking: Picking?
    @FocusState private var naming: Bool

    private enum Picking: Identifiable {
        case add, replace(String)
        var id: String { if case .replace(let id) = self { return id } else { return "add" } }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let binding = Binding($draft) {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Day name", text: binding.name)
                            .font(.display).submitLabel(.done).focused($naming)
                        FocusRule(active: naming)
                        if !binding.wrappedValue.items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                PlanTicks(plan: binding.wrappedValue)
                                Text(binding.wrappedValue.muscles.sorted { $0.name < $1.name }.map(\.name).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Color.muted)
                            }
                            .animation(.standard, value: binding.wrappedValue)
                        }
                    }
                    .padding(.top, 16).padding(.bottom, 28)
                    .workoutRow()
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(binding.items) { item in
                        let id = item.wrappedValue.id
                        ExerciseRow(number: (binding.wrappedValue.items.firstIndex { $0.id == id } ?? 0) + 1,
                                    item: item, unit: store.unit,
                                    choose: { picking = .replace(id) },
                                    remove: { withAnimation(.entrance) { draft?.items.removeAll { $0.id == id } } })
                            .swipeToDelete { draft?.items.removeAll { $0.id == id } }
                            .workoutRow()
                    }
                    .onMove { source, destination in draft?.items.move(fromOffsets: source, toOffset: destination) }
                    AddRow(title: "Add exercise") { picking = .add }
                        .workoutRow()
                        .listRowSeparator(.hidden)
                        .moveDisabled(true)
                } header: {
                    Heading("Exercises", count: binding.wrappedValue.items.count)
                        .listRowInsets(EdgeInsets(top: 0, leading: Metric.gutter, bottom: 0, trailing: Metric.gutter))
                }
            }
        }
        .workoutList()
        .scrollDismissesKeyboard(.interactively)
        .page()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { endEditing() }.font(.label)
            }
        }
        .navigationTitle(draft?.name ?? "Day").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picking) { target in
            ExercisePicker(selected: selected(target)) { exercise in
                withAnimation(.entrance) {
                    switch target {
                    case .add:
                        draft?.items.append(WorkoutItem(exercise: exercise, sets: 3, reps: WorkoutItem.defaultTarget(exercise)))
                    case .replace(let id):
                        guard let i = draft?.items.firstIndex(where: { $0.id == id }) else { return }
                        let measureChanged = draft?.items[i].exercise.measure != exercise.measure
                        draft?.items[i].exercise = exercise
                        if measureChanged { draft?.items[i].reps = WorkoutItem.defaultTarget(exercise) }
                    }
                }
            }
        }
        .onAppear { if draft == nil { draft = store.plans.first { $0.id == planID } } }
        .onDisappear { if let draft { store.save(draft) } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if let draft { store.save(draft) }; dismiss() }.font(.label)
            }
        }
    }

    private func selected(_ target: Picking) -> Exercise? {
        if case .replace(let id) = target { return draft?.items.first { $0.id == id }?.exercise }
        return nil
    }

}

private struct ExerciseRow: View {
    let number: Int
    @Binding var item: WorkoutItem
    let unit: WeightUnit
    let choose: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(String(format: "%02d", number))
                    .font(.geist(12, .medium, relativeTo: .caption)).monospacedDigit().foregroundStyle(Color.muted)
                    .contentTransition(.numericText())
                Button(action: choose) {
                    HStack(spacing: 10) {
                        MuscleGlyph(group: item.exercise.group, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.exercise.name).font(.heading).multilineTextAlignment(.leading)
                                if item.exercise.detectsReps { LucideIcon(.audioWaveform, size: 14) }
                            }
                            Text(item.exercise.equipment.name).font(.caption).foregroundStyle(Color.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Chooses another exercise")
                Spacer(minLength: 0)
                Menu {
                    menuItem("Change exercise", .pencil, choose)
                    menuItem("Remove", .trash2, role: .destructive, remove)
                } label: {
                    LucideIcon(.ellipsis, size: 18).foregroundStyle(Color.muted).frame(width: 36, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More for \(item.exercise.name)")
            }
            HStack(alignment: .center, spacing: 8) {
                NumberChip(int: $item.sets, range: WorkoutItem.setRange, unit: item.sets == 1 ? "set" : "sets", label: "Sets")
                if item.exercise.measure == .seconds {
                    NumberChip(int: $item.reps, range: WorkoutItem.secondRange, step: 5, unit: "sec", label: "Seconds")
                } else {
                    NumberChip(int: $item.reps, range: WorkoutItem.repRange, unit: item.reps == 1 ? "rep" : "reps", label: "Reps")
                }
                if item.exercise.equipment != .bodyweight || item.weight != nil {
                    NumberChip(weight: $item.weight, unit: unit)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
        }
        .padding(.vertical, 16)
    }
}

// MARK: Running

struct ActiveWorkoutScreen: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    var body: some View {
        Group {
            if let run = store.run { ActiveWorkoutView(run: run, controls: store.controls, weightText: store.weightText, perform: store.perform, end: { confirmEnd = true }) }
            else { Text("No workout running").font(.bodyText).foregroundStyle(Color.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .page()
        .navigationTitle(store.run?.name ?? "Workout").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("End this workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End workout", role: .destructive) { store.end(); dismiss() }
        } message: { Text("Logged sets are saved to your journal.") }
    }
}

/// The run as values and closures, so previews can show any state.
struct ActiveWorkoutView: View {
    let run: WorkoutRun
    let controls: WorkoutControls
    var weightText: (Double?) -> String? = { _ in nil }
    var perform: (WorkoutCommand) -> Void = { _ in }
    var end: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // The set fills the screen; logged sets wait below it.
                VStack(spacing: 0) {
                    RunProgress(run: run, height: 3).padding(.top, 4)
                    Spacer(minLength: 24)
                    current
                    Spacer(minLength: 24)
                    if let next = run.next, run.phase != .finished {
                        HStack(spacing: 10) {
                            Text("Next").font(.caption).foregroundStyle(Color.muted)
                            Rectangle().fill(Color.rule).frame(width: 18, height: Metric.hairline)
                            Text(next.exercise.name).font(.caption)
                        }
                        .id(next)
                        .transition(.push(from: .trailing).combined(with: .opacity))
                        .padding(.bottom, 28)
                    }
                    buttons
                    Button(run.phase == .finished ? "Done" : "End workout", action: end)
                        .buttonStyle(.quiet).padding(.top, 20).padding(.bottom, 8)
                }
                .containerRelativeFrame(.vertical) { height, _ in height }
                if !run.logs.isEmpty { logs.padding(.top, 24).padding(.bottom, 32) }
            }
            .padding(.horizontal, Metric.gutter)
            .animation(.entrance, value: run)
        }
    }

    private var current: some View {
        VStack(spacing: 20) {
            if let slot = run.current {
                VStack(spacing: 4) {
                    Text(slot.exercise.name).font(.display).id(slot.exercise)
                        .transition(.asymmetric(insertion: .push(from: .trailing), removal: .push(from: .trailing)).combined(with: .opacity))
                    Text([slot.label, weightText(slot.weight)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.muted)
                        .contentTransition(.numericText())
                }
                dial(slot).frame(width: 260, height: 260).padding(.vertical, 12)
                HStack(spacing: 8) {
                    if let trigger = statusTrigger { TriggerGlyphs(steps: trigger.steps).foregroundStyle(Color.muted) }
                    Text(status).font(.caption).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                }
                .contentTransition(.opacity)
            } else {
                FinishedMark().frame(width: 120, height: 120)
                Text("Workout done").font(.display)
                Text("\(run.logs.count) sets · \(WorkoutStore.reps(run.logs.filter { $0.exercise.measure == .reps }.reduce(0) { $0 + $1.reps }))")
                    .font(.bodyText).foregroundStyle(Color.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func dial(_ slot: WorkoutSlot) -> some View {
        let counting = run.phase == .counting
        if !slot.assumed {
            RepRing(reps: counting ? run.reps : 0, target: slot.target, counting: counting)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = run.setStarted.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
                let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                if slot.exercise.measure == .seconds {
                    RepRing(reps: counting ? min(elapsed, slot.target) : 0, target: slot.target, counting: counting,
                            center: counting ? "\(elapsed)" : "\(slot.target)", caption: counting ? "of \(slot.target) s" : "seconds", quiet: true)
                } else {
                    RepRing(reps: 0, target: slot.target, counting: counting,
                            center: counting ? clock : "\(slot.target)", caption: counting ? "\(slot.target) reps" : "reps", quiet: true)
                }
            }
        }
    }

    /// The gesture or combo that moves the workout on from here.
    private var statusTrigger: CommandTrigger? {
        switch run.phase {
        case .counting: controls.trigger(for: .stop)
        case .waiting: controls.trigger(for: .start)
        case .finished: nil
        }
    }

    private var status: String {
        switch run.phase {
        // A combo is already drawn step by step beside the words.
        case .counting: statusTrigger.map { $0.isCombo ? "to stop" : "\($0.name) to stop" } ?? ""
        case .waiting: statusTrigger.map { $0.isCombo ? "to start" : "\($0.name) to start" } ?? ""
        case .finished: ""
        }
    }

    private var buttons: some View {
        HStack(spacing: 18) {
            RoundAction(icon: .rotateCcw, label: "Repeat") { perform(.repeatLast) }
                .disabled(run.phase != .counting && run.last == nil)
            switch run.phase {
            case .waiting:
                Button { perform(.start) } label: { Text("Start set") }
                    .buttonStyle(CapsuleAction(filled: true))
            case .counting:
                Button { perform(.stop) } label: { Text("Stop set") }
                    .buttonStyle(CapsuleAction(filled: false))
            case .finished:
                Spacer().frame(maxWidth: .infinity)
            }
            RoundAction(icon: .skipForward, label: "Skip") { perform(.skip) }
                .disabled(run.phase == .finished)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: run.phase)
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 0) {
            Heading("Logged", count: run.logs.count)
            ForEach(Array(run.logs.reversed().enumerated()), id: \.element.id) { index, log in
                if index > 0 { Hairline(inset: 0) }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.slot.exercise.name).font(.bodyText)
                        Text(log.slot.label).font(.caption).foregroundStyle(Color.muted)
                    }
                    Spacer()
                    RepBar(reps: log.reps, target: log.slot.target).frame(width: 64)
                    Text(log.exercise.measure == .seconds ? "\(log.reps) s" : "\(log.reps)/\(log.slot.target)").font(.label).monospacedDigit()
                        .foregroundStyle(log.reps < log.slot.target ? Color.muted : Color.ink)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                .padding(.vertical, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// The rep count inside a ring of hairline ticks, one per target rep. Each rep inks a tick
/// and sends a hairline ripple outward; while waiting, the ring breathes.
private struct RepRing: View {
    let reps: Int
    let target: Int
    let counting: Bool
    var center: String? = nil
    var caption: String? = nil
    /// No ripple or haptic per step, for a ring driven by a clock.
    var quiet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples: [Int] = []

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(ripples, id: \.self) { id in RippleCircle(key: id) }
                if !counting && !reduceMotion { BreathingCircle() }
                Ticks(count: min(target, 60), filled: target > 60 ? Int(Double(reps) / Double(target) * 60) : reps)
                    .animation(.spring(duration: 0.35, bounce: 0.4), value: reps)
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(reps) / CGFloat(max(1, target))))
                    .stroke(Color.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(size * 0.14)
                    .animation(.spring(duration: 0.5, bounce: 0.2), value: reps)
                Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline).padding(size * 0.14)
                VStack(spacing: 0) {
                    Text(center ?? "\(counting ? reps : target)")
                        .font(.geist(center.map { $0.count > 3 ? 64 : 84 } ?? 84, .medium, relativeTo: .largeTitle)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(reps)))
                        .opacity(counting ? 1 : 0.3)
                        .animation(.spring(duration: 0.3, bounce: 0.3), value: reps)
                    Text(caption ?? (counting ? "of \(target)" : "reps")).font(.caption).foregroundStyle(Color.muted)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: reps) { old, new in
            guard new > old, !reduceMotion, !quiet else { return }
            ripples.append(new)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { ripples.removeAll { $0 == new } }
        }
        .sensoryFeedback(.increase, trigger: quiet ? 0 : reps)
        .accessibilityElement()
        .accessibilityLabel(counting ? "\(reps) of \(target) reps" : "\(target) reps to do")
    }

    private struct Ticks: View {
        let count: Int
        let filled: Int
        var body: some View {
            GeometryReader { geo in
                let r = min(geo.size.width, geo.size.height) / 2
                ZStack {
                    ForEach(0..<max(1, count), id: \.self) { i in
                        let on = i < filled
                        Capsule()
                            .fill(on ? Color.ink : Color.faint)
                            .frame(width: on ? 1.5 : Metric.hairline, height: on ? r * 0.12 : r * 0.07)
                            .offset(y: -r * (on ? 0.92 : 0.9))
                            .rotationEffect(.degrees(Double(i) / Double(max(1, count)) * 360))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

private struct RippleCircle: View {
    let key: Int
    @State private var go = false
    var body: some View {
        Circle().stroke(Color.ink, lineWidth: Metric.hairline)
            .padding(30)
            .scaleEffect(go ? 1.18 : 0.86)
            .opacity(go ? 0 : 0.6)
            .onAppear { withAnimation(.easeOut(duration: 1)) { go = true } }
    }
}

private struct BreathingCircle: View {
    @State private var breathe = false
    var body: some View {
        Circle().stroke(Color.rule, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 5]))
            .scaleEffect(breathe ? 1.04 : 0.94)
            .opacity(breathe ? 0.9 : 0.4)
            .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

/// A check drawn in a single hairline stroke inside a drawn circle.
struct FinishedMark: View {
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.ink, style: StrokeStyle(lineWidth: Metric.hairline, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Color.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .padding(36)
        }
        .onAppear { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.9)) { drawn = true } }
        .sensoryFeedback(.success, trigger: drawn)
    }
    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.12))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
            return p
        }
    }
}

/// Every set of the run as a hairline segment: done in ink, the current one filling, the rest faint.
private struct RunProgress: View {
    let run: WorkoutRun
    var height: CGFloat = 2

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(run.slots.enumerated()), id: \.offset) { index, slot in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.rule)
                        Capsule().fill(Color.ink).frame(width: geo.size.width * fill(index, slot))
                    }
                }
                .frame(height: height)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: run)
        .accessibilityHidden(true)
    }

    private func fill(_ index: Int, _ slot: WorkoutSlot) -> CGFloat {
        if index < run.index || run.phase == .finished { return 1 }
        if index == run.index, run.phase == .counting { return min(1, max(0.04, CGFloat(run.reps) / CGFloat(max(1, slot.target)))) }
        return 0
    }
}

struct RepBar: View {
    let reps: Int
    let target: Int
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.rule).frame(height: Metric.hairline)
                Rectangle().fill(Color.ink).frame(width: geo.size.width * min(1, CGFloat(reps) / CGFloat(max(1, target))), height: 1.5)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 8)
    }
}

// MARK: Pieces

/// A full-width rule that draws in from the leading edge.
struct Hairline: View {
    var inset: CGFloat = 0
    var delay: Double = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Rectangle().fill(Color.rule).frame(height: Metric.hairline)
            .scaleEffect(x: drawn || reduceMotion ? 1 : 0, anchor: .leading)
            .padding(.leading, inset)
            .onAppear { withAnimation(.easeOut(duration: 0.6).delay(delay)) { drawn = true } }
            .accessibilityHidden(true)
    }
}

/// An underline that darkens and thickens from the centre while its field is focused.
struct FocusRule: View {
    let active: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(Color.rule).frame(height: Metric.hairline)
            Rectangle().fill(Color.ink).frame(height: 1.5).scaleEffect(x: active ? 1 : 0, anchor: .center)
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: active)
    }
}

struct Heading: View {
    let title: String
    var count: Int?
    init(_ title: String, count: Int? = nil) { self.title = title; self.count = count }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.label)
            if let count { Text("\(count)").font(.caption).foregroundStyle(Color.muted).monospacedDigit().contentTransition(.numericText()) }
            Rectangle().fill(Color.rule).frame(height: Metric.hairline).padding(.leading, 4).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] - 4 }
        }
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
}

struct AddRow: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(Color.muted, style: StrokeStyle(lineWidth: Metric.hairline, dash: [2, 3]))
                    LucideIcon(.plus, size: 14)
                }
                .frame(width: 28, height: 28)
                Text(title).font(.bodyText)
                Spacer()
            }
            .padding(.vertical, 16).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
    }
}

struct GestureChip: View {
    let gesture: GestureKind?
    var body: some View {
        HStack(spacing: 6) {
            if let gesture {
                GestureIcon.image(gesture, size: 16)
                Text(gesture.name).font(.label)
            } else {
                Text("None").font(.label).foregroundStyle(Color.muted)
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 30)
        .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
        .id(gesture)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .animation(.standard, value: gesture)
    }
}

/// Text options over one hairline, with an ink underline that slides to the selection.
struct HairlineSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: KeyPath<Value, String>
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let on = option == selection
                    Button { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { selection = option } } label: {
                        VStack(spacing: 10) {
                            Text(option[keyPath: title]).font(.label).foregroundStyle(on ? Color.ink : Color.muted)
                            ZStack {
                                Color.clear.frame(height: 1.5)
                                if on { Capsule().fill(Color.ink).frame(height: 1.5).matchedGeometryEffect(id: "bar", in: ns) }
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Rectangle().fill(Color.rule).frame(height: Metric.hairline)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

struct PulseDot: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(Color.ink, lineWidth: Metric.hairline)
                .scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 0.8)
            Circle().fill(Color.ink)
        }
        .frame(width: 7, height: 7)
        .onAppear { if !reduceMotion { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } } }
        .accessibilityHidden(true)
    }
}

/// A dot circling a hairline circle, for an app that's running.
struct OrbitDot: View {
    let radius: CGFloat
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(Color.ink).frame(width: 4, height: 4)
            .offset(y: -radius)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { if !reduceMotion { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { turn = true } } }
    }
}

struct RoundAction: View {
    let icon: Lucide
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(Color.rule, lineWidth: Metric.hairline)
                    LucideIcon(icon, size: 18)
                }
                .frame(width: 52, height: 52)
                Text(label).font(.caption).foregroundStyle(Color.muted)
            }
        }
        .buttonStyle(Ripple())
        .opacity(enabled ? 1 : 0.3)
    }
}

/// The main run action: a filled or hairline capsule.
struct CapsuleAction: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label)
            .foregroundStyle(filled ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity, minHeight: Metric.rowTall)
            .background(Capsule().fill(filled ? Color.ink : Color.clear))
            .overlay(Capsule().strokeBorder(Color.ink, lineWidth: Metric.hairline))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .padding(.bottom, 20)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// Rows dim slightly when pressed; no fill.
struct PressRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.standard, value: configuration.isPressed)
    }
}

/// Round hairline buttons shrink and send a ring outward when pressed.
struct Ripple: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .background(
                Circle().stroke(Color.ink, lineWidth: Metric.hairline)
                    .scaleEffect(configuration.isPressed ? 1.25 : 1)
                    .opacity(configuration.isPressed ? 0.35 : 0)
            )
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}

struct Arrive: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.15).delay(0.05 * Double(index))) { shown = true } }
    }
}

extension View {
    /// Fades and rises in, staggered by `index`.
    func arrive(_ index: Int) -> some View { modifier(Arrive(index: index)) }
}

/// Header, rows and footer stacked tight, so the page's spacing doesn't reach the rows.
struct Block<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { header; content; footer }
    }
}

extension Block where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content(); self.header = header(); self.footer = EmptyView()
    }
}
