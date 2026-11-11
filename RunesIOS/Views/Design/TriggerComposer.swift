import SwiftUI

// One way to say what the band has to do: a track of steps and a pad of gestures.
// Touch a step and the pad changes it; touch the dashed slot and the pad adds to it; or
// let the band listen and make the gesture itself. `TriggerRules` decides whether that is
// one gesture, a combo, or either, so Mappings, Score, Capture, Workouts and Cook all set
// their gestures here.

// MARK: Composer

/// The track, the pad and, for combos, the time between steps. It edits the steps it is
/// given in place; `TriggerSheet` wraps it for a draft that is saved or cancelled.
struct TriggerComposer: View {
    @Binding var steps: [ComboStep]
    @Binding var interval: Int
    let rules: TriggerRules
    /// A sentence about the steps as they stand: who else uses them, what they will do.
    var note: String? = nil
    /// Gestures something else already uses on their own, marked with a dot on the pad.
    var taken: Set<GestureKind> = []
    /// The band. With it, steps can be made instead of chosen, a key lights when its gesture
    /// arrives, and air shapes can be drawn.
    var feed: MappingStore? = nil
    /// On a page with other things on it, the pad stays away until a step is touched.
    var collapses = false

    private enum Slot: Equatable { case step(Int), end }
    private struct AirTarget: Identifiable { let id: Int }
    private static let tile = CGSize(width: 50, height: 56)
    private static let link: CGFloat = 10

    @State private var slot = Slot.end
    @State private var open = true
    @State private var settled = false
    @State private var listening = false
    /// Listening for one gesture rather than a run of steps.
    @State private var listeningForOne = false
    @State private var heardThrough = 0
    @State private var lastTaken: (kind: GestureKind, at: Date)?
    @State private var stopTask: Task<Void, Never>?
    @State private var echo: GestureKind?
    @State private var echoes = 0
    @State private var airTarget: AirTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The step the pad would change, when one is selected.
    private var selected: Int? {
        if open, case .step(let index) = slot, steps.indices.contains(index) { return index }
        return nil
    }
    private var showsEnd: Bool { rules.buildsCombos ? steps.count < rules.maxSteps : steps.isEmpty }
    private var showsTiming: Bool { rules.buildsCombos && (rules.comboOnly || steps.count > 1) }
    /// Whether the band would be heard as one gesture: nothing chosen yet, or the one chosen is selected.
    private var wantsOne: Bool {
        !rules.buildsCombos || (!rules.comboOnly && (steps.isEmpty || (steps.count == 1 && selected != nil)))
    }
    private var appear: AnyTransition { reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                track
                if let index = selected { inspector(index).transition(.opacity) }
                if let sentence {
                    Text(sentence).font(.caption).foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .id(sentence).transition(.opacity)
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 16) {
                    pad
                    if feed != nil { listenButton }
                }
                .transition(.opacity)
            }
            if showsTiming { timing.transition(.opacity) }
        }
        .animation(.standard, value: steps)
        .animation(.standard, value: slot)
        .animation(.standard, value: open)
        .animation(.standard, value: listening)
        .sensoryFeedback(.selection, trigger: steps)
        .onAppear(perform: settle)
        .onChange(of: steps) { _, _ in normalize() }
        .onDisappear(perform: stopListening)
        .bandFeed(feed, heard: heard)
        .sheet(item: $airTarget) { target in
            if let feed {
                AirGestureEditor(store: feed, initial: steps.indices.contains(target.id) ? steps[target.id].air : nil) { shape in
                    if steps.indices.contains(target.id) { steps[target.id] = .airShape(shape) }
                    else if steps.count < rules.maxSteps { steps.append(.airShape(shape)) }
                }
            }
        }
    }

    // MARK: Track

    private var track: some View {
        let held = TriggerRules.held(steps)
        return FlowLayout(spacing: 0, lineSpacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let linked = index < steps.count - 1 || showsEnd
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Button { select(.step(index)) } label: { stepTile(step, on: selected == index) }
                            .buttonStyle(PressRow())
                            .accessibilityLabel(steps.count > 1 ? "Step \(index + 1), \(step.name)" : step.name)
                            .accessibilityHint("Selects it, to change it on the pad.")
                            .accessibilityAddTraits(selected == index ? .isSelected : [])
                        if linked { LucideIcon(.chevronRight, size: 9).foregroundStyle(Color.faint).frame(width: Self.link) }
                    }
                    // A line under every step made with a finger down.
                    HStack(spacing: 0) {
                        Rectangle().fill(held.steps[index] ? Color.ink : Color.clear).frame(width: Self.tile.width, height: 1.5)
                        if linked { Rectangle().fill(held.bridges[index] ? Color.ink : Color.clear).frame(width: Self.link, height: 1.5) }
                    }
                    .accessibilityHidden(true)
                }
                .transition(appear)
            }
            if showsEnd {
                let on = open && selected == nil
                VStack(spacing: 4) {
                    Button { select(.end) } label: {
                        VStack(spacing: 4) {
                            LucideIcon(.plus, size: 18).frame(height: 22)
                            Text(steps.isEmpty ? (rules.buildsCombos ? "Start" : "None") : "Then")
                                .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(on ? Color.ink : Color.muted)
                        .frame(width: Self.tile.width, height: Self.tile.height)
                        .overlay(RoundedRectangle(cornerRadius: Metric.control)
                            .strokeBorder(on ? Color.ink : Color.faint, style: StrokeStyle(lineWidth: Metric.hairline, dash: [3, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressRow())
                    .accessibilityLabel(steps.isEmpty ? "Choose a gesture" : "Add a step")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    Color.clear.frame(width: Self.tile.width, height: 1.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepTile(_ step: ComboStep, on: Bool) -> some View {
        VStack(spacing: 4) {
            StepIcon(step: step, size: 20).frame(height: 22)
            Text(step.shortName).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? Color.paper : Color.ink)
        .frame(width: Self.tile.width, height: Self.tile.height)
        .background(on ? Color.ink : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
        .overlay(RoundedRectangle(cornerRadius: Metric.control).strokeBorder(Color.rule, lineWidth: on ? 0 : Metric.hairline))
        .contentShape(Rectangle())
    }

    // MARK: Selected step

    /// The selected step in words, with what can be done to it: its place, its axis, removal.
    @ViewBuilder private func inspector(_ index: Int) -> some View {
        let step = steps[index]
        let removable = steps.count > 1 || rules.comboOnly || (rules.buildsCombos && rules.allowsNone)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    if steps.count > 1 {
                        Text("Step \(index + 1) of \(steps.count)").font(.caption).foregroundStyle(Color.muted)
                            .monospacedDigit().contentTransition(.numericText())
                    }
                    Text(step.name).font(.label).contentTransition(.opacity)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if steps.count > 1 {
                    tool(.arrowLeft, "Move earlier", enabled: index > 0) { move(index, by: -1) }
                    tool(.arrowRight, "Move later", enabled: index < steps.count - 1) { move(index, by: 1) }
                }
                if removable { tool(.trash2, "Remove step", enabled: true) { remove(index) } }
            }
            .frame(minHeight: steps.count > 1 || removable ? Metric.tap : nil)
            if step.gesture.isMotion {
                HairlineSegments(selection: Binding(get: { step.axis ?? .x }, set: { axis in change(index) { $0.axis = axis } }),
                                 options: Axis.allCases, title: \.label)
                    .accessibilityLabel("Axis")
            }
            if step.gesture == .rotation {
                HairlineSegments(selection: Binding(get: { step.direction ?? .any }, set: { direction in change(index) { $0.direction = direction } }),
                                 options: RotationDirection.allCases, title: \.label)
                    .accessibilityLabel("Direction")
            }
            if step.gesture.isAir, feed != nil {
                Button { airTarget = AirTarget(id: index) } label: { Label { Text("Edit shape") } icon: { LucideIcon(.pencil, size: 16) } }
                    .buttonStyle(.secondary)
            }
        }
    }

    private func tool(_ icon: Lucide, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        IconButton(icon, size: 18, action: action)
            .buttonStyle(PressRow())
            .opacity(enabled ? 1 : 0.3).disabled(!enabled)
            .accessibilityLabel(label)
    }

    private var sentence: String? {
        if listening {
            return listeningForOne ? "Listening. Make the gesture on your band." : "Listening. Make the steps on your band, in order."
        }
        if let problem = rules.problem(steps) { return problem }
        if steps.isEmpty {
            if rules.comboOnly { return "Add two to eight steps, in the order you’ll make them." }
            let start = rules.allowsNone ? "Not set. Choose a gesture" : "Choose a gesture"
            return rules.buildsCombos ? start + ", then add more after it for a combo." : start + "."
        }
        return note
    }

    // MARK: Pad

    private struct PadRow: Identifiable { let id: String; let keys: [GestureKind] }
    private static let rows = [
        PadRow(id: "Index finger", keys: [.tapIndex, .doubleTapIndex, .holdIndex, .releaseIndex]),
        PadRow(id: "Middle finger", keys: [.tapMiddle, .doubleTapMiddle, .holdMiddle, .releaseMiddle]),
        PadRow(id: "Swipe", keys: [.swipeUp, .swipeDown, .swipeLeft, .swipeRight]),
        PadRow(id: "Wrist", keys: [.rotation, .movement, .air]),
    ]

    private var pad: some View {
        // Air shapes are drawn or recorded with the band's help.
        let offered = rules.offered.subtracting(feed == nil ? [.air] : [])
        let current = selected.map { steps[$0].gesture }
        // What else uses a gesture only matters while one gesture is being chosen.
        let taken = wantsOne ? taken.intersection(offered) : []
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.rows) { row in
                if row.keys.contains(where: offered.contains) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.id).font(.caption).foregroundStyle(Color.muted).accessibilityAddTraits(.isHeader)
                        // Four columns, so a key keeps its place whether or not its neighbours are offered.
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { column in
                                if row.keys.indices.contains(column), offered.contains(row.keys[column]) {
                                    key(row.keys[column], current: current, taken: taken.contains(row.keys[column]))
                                } else {
                                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                                }
                            }
                        }
                    }
                }
            }
            if !taken.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.muted).frame(width: 4, height: 4)
                    Text("Already used. Choosing one swaps the two.").font(.caption).foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func key(_ kind: GestureKind, current: GestureKind?, taken: Bool) -> some View {
        let on = kind == current
        let can = on || canPlace(kind)
        let heard = echo == kind && !on
        return Button { place(kind) } label: {
            VStack(spacing: 5) {
                GestureIcon(gesture: kind, size: 22).frame(height: 24)
                Text(kind.shortName).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(on ? Color.paper : Color.muted)
            }
            .foregroundStyle(on ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(on ? Color.ink : heard ? Color.soft : Color.paper, in: RoundedRectangle(cornerRadius: Metric.control))
            .overlay(RoundedRectangle(cornerRadius: Metric.control)
                .strokeBorder(heard ? Color.ink : Color.rule, lineWidth: on ? 0 : Metric.hairline))
            .overlay(alignment: .topTrailing) {
                if taken, !on { Circle().fill(Color.muted).frame(width: 4, height: 4).padding(7) }
            }
            .opacity(can ? 1 : 0.3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .disabled(!can)
        .accessibilityLabel(kind.name)
        .accessibilityValue(taken && !on ? "Already used" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var listenButton: some View {
        Button { listening ? stopListening() : startListening() } label: {
            HStack(spacing: 10) {
                if listening { PulseDot() } else { LucideIcon(.circleDot, size: 16) }
                Text(listening ? "Stop listening" : wantsOne ? "Make it on your band" : "Make the steps on your band")
            }
        }
        .buttonStyle(.secondary)
        .accessibilityHint("While it listens, the band’s gestures don’t do anything else.")
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time between steps").font(.label)
            ChipRow(selection: $interval, options: ComboRules.times, title: ComboRules.timeLabel)
                .padding(.horizontal, -Metric.inset)
                .accessibilityLabel("Time between steps")
            Text("While a finger is held, which the line under the steps shows, there’s no time limit. A gesture that starts a combo waits until the combo finishes or runs out of time.")
                .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Editing

    private func settle() {
        guard !settled else { return }
        settled = true
        if collapses { open = steps.isEmpty || !rules.isValid(steps) }
        if steps.count == 1, !rules.comboOnly { slot = .step(0) }
        else if !steps.isEmpty, steps.count >= rules.maxSteps { slot = .step(steps.count - 1) }
        else { slot = .end }
    }

    /// Keeps the selection on something that exists after the steps change under it.
    private func normalize() {
        switch slot {
        case .step(let index) where index >= steps.count:
            slot = showsEnd || steps.isEmpty ? .end : .step(steps.count - 1)
        case .end where !showsEnd && !steps.isEmpty:
            slot = .step(steps.count - 1)
        default: break
        }
    }

    private func select(_ new: Slot) {
        // On a shared page, touching the selection again puts the pad away.
        if collapses, open, slot == new { stopListening(); open = false; return }
        slot = new; open = true
    }

    private func canPlace(_ kind: GestureKind) -> Bool {
        if kind.isAir, feed == nil { return false }
        if let index = selected { return rules.canReplace(index, with: kind, in: steps) }
        return rules.canAppend(kind, to: steps)
    }

    private func place(_ kind: GestureKind) {
        if kind.isAir { airTarget = AirTarget(id: selected ?? steps.count); return }
        if let index = selected {
            guard steps[index].gesture != kind else { return }
            // Swapping rotation for movement keeps the axis.
            steps[index] = ComboStep(kind, axis: steps[index].axis, direction: steps[index].direction)
        } else {
            let count = steps.count + 1
            steps.append(ComboStep(kind))
            // The first gesture stays selected, so choosing again changes it; a combo keeps adding.
            slot = (rules.comboOnly || count > 1) && count < rules.maxSteps ? .end : .step(count - 1)
        }
    }

    private func change(_ index: Int, _ edit: (inout ComboStep) -> Void) {
        guard steps.indices.contains(index) else { return }
        var step = steps[index]
        edit(&step)
        steps[index] = step
    }

    private func move(_ index: Int, by offset: Int) {
        guard steps.indices.contains(index), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        slot = .step(index + offset)
    }

    private func remove(_ index: Int) {
        guard steps.indices.contains(index) else { return }
        let left = steps.count - 1
        steps.remove(at: index)
        slot = left == 0 ? .end : .step(min(index, left - 1))
    }

    // MARK: Band

    private func startListening() {
        guard let feed else { return }
        heardThrough = feed.recent.last?.id ?? 0
        lastTaken = nil
        listeningForOne = wantsOne
        if !listeningForOne, showsEnd { slot = .end }
        // Paused, the band's gestures reach the editor and nothing else.
        feed.paused = true
        listening = true
    }

    private func stopListening() {
        stopTask?.cancel(); stopTask = nil
        guard listening else { return }
        listening = false
        feed?.paused = false
    }

    private func heard(_ recent: [MappingStore.RecentGesture]) {
        let new = recent.filter { $0.id > heardThrough }
        guard let last = new.last else { return }
        heardThrough = last.id
        flash(last.gesture)
        guard listening else { return }
        // Motion is set by hand (axis, direction); only taps, holds and swipes are heard.
        var working = steps
        for item in new where !item.gesture.isMotion && !item.gesture.isAir { take(item.gesture, into: &working) }
        if working != steps { steps = working }
    }

    private func take(_ kind: GestureKind, into working: inout [ComboStep]) {
        let now = Date()
        if listeningForOne {
            guard rules.singles.contains(kind) else { return }
            working = [ComboStep(kind)]
            slot = .step(0)
            // A double tap arrives after the tap that began it, so wait a moment before closing.
            stopTask?.cancel()
            stopTask = Task {
                try? await Task.sleep(for: .milliseconds(900))
                if !Task.isCancelled { stopListening() }
            }
        } else {
            if let before = lastTaken, before.kind.doubleTap == kind, working.last?.gesture == before.kind, now.timeIntervalSince(before.at) < 1 {
                // The tap just heard was the first half of this double tap.
                working[working.count - 1] = ComboStep(kind)
            } else {
                guard rules.canAppend(kind, to: working) else { return }
                working.append(ComboStep(kind))
            }
            if working.count >= rules.maxSteps { slot = .step(working.count - 1); stopListening() } else { slot = .end }
        }
        lastTaken = (kind, now)
    }

    /// Lights the key for a gesture the band just made.
    private func flash(_ kind: GestureKind) {
        echoes += 1
        let mine = echoes
        withAnimation(.standard) { echo = kind }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if echoes == mine { withAnimation(.standard) { echo = nil } }
        }
    }
}

private struct BandFeed: ViewModifier {
    @ObservedObject var feed: MappingStore
    let heard: ([MappingStore.RecentGesture]) -> Void
    func body(content: Content) -> some View {
        content.onChange(of: feed.recent) { _, recent in heard(recent) }
    }
}

private extension View {
    @ViewBuilder func bandFeed(_ feed: MappingStore?, heard: @escaping ([MappingStore.RecentGesture]) -> Void) -> some View {
        if let feed { modifier(BandFeed(feed: feed, heard: heard)) } else { self }
    }
}

extension Axis { var label: String { rawValue.uppercased() } }
extension RotationDirection {
    var label: String { switch self { case .left: "← Left"; case .right: "Right →"; case .any: "Either way" } }
}

// MARK: Sheet

/// Sets one trigger: the composer over a draft, with Cancel and Save.
struct TriggerSheet: View {
    let title: String
    /// What the trigger will do, in a sentence.
    var caption: String? = nil
    let rules: TriggerRules
    var taken: Set<GestureKind> = []
    var feed: MappingStore? = nil
    /// A sentence about a draft: who else uses it, what it will do.
    var note: ([ComboStep]) -> String? = { _ in nil }
    /// Why a draft can't be saved though its steps are allowed: something else is set off by them.
    var blocked: ([ComboStep]) -> String? = { _ in nil }
    /// Whether the draft may not be the switch-controls combo. Only that combo's own sheet turns this off.
    var checksSwitch = true
    /// The steps and the time between them. No steps means none.
    let save: ([ComboStep], Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [ComboStep]
    @State private var interval: Int
    private let initial: [ComboStep]

    init(title: String, caption: String? = nil, rules: TriggerRules, steps: [ComboStep], intervalMs: Int = ComboRules.defaultTime,
         taken: Set<GestureKind> = [], feed: MappingStore? = nil, note: @escaping ([ComboStep]) -> String? = { _ in nil },
         blocked: @escaping ([ComboStep]) -> String? = { _ in nil }, checksSwitch: Bool = true,
         save: @escaping ([ComboStep], Int) -> Void) {
        self.title = title; self.caption = caption; self.rules = rules; self.taken = taken; self.feed = feed; self.note = note; self.save = save
        self.blocked = blocked; self.checksSwitch = checksSwitch
        initial = steps
        _steps = State(initialValue: steps)
        _interval = State(initialValue: ComboRules.times.contains(intervalMs) ? intervalMs : ComboRules.defaultTime)
    }

    /// What stops these steps being saved: the caller's reason, or the switch-controls combo using them.
    private var clash: String? {
        blocked(steps) ?? (checksSwitch ? ControlSwitch.shared.clash(steps) : nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let caption {
                        Text(caption).font(.bodyText).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    TriggerComposer(steps: $steps, interval: $interval, rules: rules, note: clash ?? note(steps), taken: taken, feed: feed)
                    if rules.allowsNone, !initial.isEmpty {
                        Button("Set to none") { save([], interval); dismiss() }.buttonStyle(.quiet)
                    }
                }
                .padding(Metric.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(steps, interval); dismiss() }.font(.label).disabled(!rules.isValid(steps) || clash != nil)
                }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.large])
    }
}

// MARK: Row and chip

/// A ledger row for something the band does: what it is, and the trigger that does it.
struct TriggerRow: View {
    let title: String
    var detail: String? = nil
    /// Nil or empty reads "None".
    let steps: [ComboStep]?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.bodyText)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Color.muted)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                TriggerChip(steps: steps).fixedSize()
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityHint("Chooses the gesture or combo.")
    }
}

/// A trigger drawn small: its gesture's icon, or a combo's icons in order.
struct TriggerGlyphs: View {
    let steps: [ComboStep]
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { LucideIcon(.chevronRight, size: size * 0.6).foregroundStyle(Color.faint) }
                StepIcon(step: step, size: size)
            }
        }
        .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
    }
}

/// A gesture, a combo's steps, or "None", as a hairline capsule.
struct TriggerChip: View {
    /// The trigger's steps; nil or empty reads "None".
    let steps: [ComboStep]?
    /// A long combo shows this many steps and counts the rest.
    private static let shown = 5
    init(trigger: ScoreTrigger?) { steps = trigger?.steps }
    init(steps: [ComboStep]?) { self.steps = steps }
    var body: some View {
        Group {
            if let steps, steps.count == 1 {
                GestureChip(gesture: steps[0].gesture)
            } else if let steps, !steps.isEmpty {
                let visible = steps.count > Self.shown ? Array(steps.prefix(Self.shown - 1)) : steps
                HStack(spacing: 3) {
                    TriggerGlyphs(steps: visible)
                    if steps.count > visible.count {
                        Text("+\(steps.count - visible.count)").font(.caption).foregroundStyle(Color.muted).monospacedDigit().padding(.leading, 3)
                    }
                }
                .padding(.horizontal, 10).frame(minHeight: 30)
                .overlay(Capsule().strokeBorder(Color.rule, lineWidth: Metric.hairline))
                .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
            } else {
                GestureChip(gesture: nil)
            }
        }
        .animation(.standard, value: steps)
    }
}

// MARK: Layout

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Space between lines; the same as between chips unless set.
    var lineSpacing: CGFloat? = nil
    private var gap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + gap
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.items.isEmpty { rows.append(current); current = ([index], size.width, size.height) }
            else { current = (current.items + [index], next, max(current.height, size.height)) }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
