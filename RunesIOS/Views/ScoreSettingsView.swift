import SwiftUI

// Score settings: which band gesture or combo does each thing in a live game, and the sounds
// that confirm it with the phone away. Sounds come from the Mac app's library. Player sounds
// come as curated sets, so every player always has their own: selecting a player is heard
// rather than seen.

struct ScoreSettingsScreen: View {
    @ObservedObject var store: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScoreAction?
    @State private var choosingSound: SoundSlot?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    actionsBlock("Band gestures", ScoreAction.all.filter { $0.player == nil },
                                 note: "Swipe up stays with the score screen, where it zooms out to everyone. While a game is live, these gestures don’t run their mappings.")
                    actionsBlock("Each player", ScoreAction.all.filter { $0.player != nil },
                                 note: "Optional: give a player their own gesture or combo, so you can score them without selecting them first.")
                    Button("Reset gestures") { store.resetGestures() }.buttonStyle(.quiet)
                    soundsBlock
                    playersBlock
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Score settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $editing) { action in TriggerSheet(store: store, action: action, playerName: playerName) }
            .sheet(item: $choosingSound) { slot in SoundSheet(store: store, slot: slot) }
        }
        .tint(Color.ink)
    }

    private func playerName(_ index: Int) -> String {
        store.game.players.indices.contains(index) ? store.game.players[index].name : "Player \(index + 1)"
    }

    private func title(_ action: ScoreAction) -> String {
        switch action {
        case .add(let i): "Add a point to \(playerName(i))"
        case .take(let i): "Take a point from \(playerName(i))"
        default: action.title
        }
    }

    // MARK: Gestures

    private func actionsBlock(_ heading: String, _ actions: [ScoreAction], note: String) -> some View {
        Block {
            ForEach(actions) { action in
                Button { editing = action } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(action)).font(.bodyText)
                            Text(action.detail).font(.caption).foregroundStyle(Color.muted)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        TriggerChip(trigger: store.controls.trigger(for: action))
                    }
                    .padding(.vertical, 14).contentShape(Rectangle())
                }
                .buttonStyle(PressRow())
                .accessibilityHint("Chooses the gesture or combo.")
                if action != actions.last { Hairline(inset: 0) }
            }
        } header: {
            Heading(heading)
        } footer: {
            Note(note)
        }
    }

    // MARK: Sounds

    private var soundsBlock: some View {
        let sounds = store.controls.sounds
        return Block {
            Toggle(isOn: Binding(get: { sounds.on }, set: { on in store.setSounds { $0.on = on } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Play sounds").font(.bodyText)
                    Text("While a game is live, also with your phone locked and on silent.").font(.caption).foregroundStyle(Color.muted)
                }
            }
            .padding(.vertical, 12)
            Hairline(inset: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Volume").font(.bodyText)
                Slider(value: Binding(get: { sounds.volume }, set: { v in store.setSounds { $0.volume = v } }), in: 0...1) { editing in
                    let sounds = store.controls.sounds
                    if !editing, let voice = sounds.add ?? sounds.take ?? sounds.player(0) { ScoreAudio.shared.preview(voice, volume: sounds.volume) }
                }
                .accessibilityLabel("Volume")
            }
            .padding(.vertical, 12)
            Hairline(inset: 0)
            soundRow("Point added", sounds.add, slot: .add)
            Hairline(inset: 0)
            soundRow("Point taken away", sounds.take, slot: .take)
        } header: {
            Heading("Sounds")
        } footer: {
            Note("The Mac app’s \(SoundVoice.allCases.count) sounds. Choosing one plays it.")
        }
    }

    private var playersBlock: some View {
        let count = store.game.players.count
        return Block {
            ChoiceList(options: ScorePlayerSounds.allCases.map(Optional.some) + [nil], selected: .some(store.controls.sounds.players),
                       label: { set in
                VStack(alignment: .leading, spacing: 2) {
                    if let set {
                        Text(set.label).font(.bodyText)
                        Text(set.detail).font(.caption).foregroundStyle(Color.muted)
                        Text(set.voices.prefix(count).map(\.label).joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.faint)
                    } else {
                        Text("None").font(.bodyText).foregroundStyle(Color.muted)
                        Text("Selecting a player is silent.").font(.caption).foregroundStyle(Color.muted)
                    }
                }
                .padding(.vertical, 4)
            }, choose: { set in
                store.setSounds { $0.players = set }
                if let set { ScoreAudio.shared.preview(set: set, players: count, volume: max(0.3, store.controls.sounds.volume)) }
            })
        } header: {
            Heading("Player sounds")
        } footer: {
            Note("Played when a player is selected. In every set each player has a different sound and their own pitch. Choosing a set plays it for your players in order.")
        }
    }

    private func soundRow(_ title: String, _ voice: SoundVoice?, slot: SoundSlot) -> some View {
        Button { choosingSound = slot } label: {
            HStack(spacing: 12) {
                Text(title).font(.bodyText)
                Spacer(minLength: 8)
                Text(voice?.label ?? "None").font(.label).foregroundStyle(Color.muted)
                LucideIcon(.chevronRight, size: 14).foregroundStyle(Color.faint)
            }
            .padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(PressRow())
        .accessibilityLabel("\(title), \(voice?.label ?? "None")")
        .accessibilityHint("Chooses the sound.")
    }
}

/// Which sound a sheet is choosing.
enum SoundSlot: Hashable, Identifiable {
    case add, take
    var id: String {
        switch self { case .add: "add"; case .take: "take" }
    }
}

/// A gesture, a combo's steps, or "None", as a hairline capsule.
struct TriggerChip: View {
    /// The trigger's steps; nil or empty reads "None".
    let steps: [ComboStep]?
    init(trigger: ScoreTrigger?) { steps = trigger?.steps }
    init(steps: [ComboStep]?) { self.steps = steps }
    var body: some View {
        Group {
            if let steps, steps.count == 1 {
                GestureChip(gesture: steps[0].gesture)
            } else if let steps, !steps.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { LucideIcon(.chevronRight, size: 9).foregroundStyle(Color.faint) }
                        StepIcon(step: step, size: 15)
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

// MARK: Trigger

/// Chooses one gesture, or builds a combo, for an action.
private struct TriggerSheet: View {
    @ObservedObject var store: ScoreStore
    let action: ScoreAction
    let playerName: (Int) -> String
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable { case gesture = "Gesture", combo = "Combo" }
    @State private var kind = Kind.gesture
    @State private var steps: [ComboStep] = []
    @State private var interval = ComboRules.defaultTime

    private var current: ScoreTrigger? { store.controls.trigger(for: action) }
    private var draft: ScoreTrigger { ScoreTrigger(steps: steps, intervalMs: interval) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HairlineSegments(selection: $kind, options: Kind.allCases, title: \.rawValue)
                    if kind == .gesture { gestureList } else { comboEditor }
                    if kind == .combo, current != nil {
                        Button("Set to None") { store.setTrigger(nil, for: action); dismiss() }.buttonStyle(.quiet)
                    }
                }
                .padding(Metric.gutter)
            }
            .scrollBounceBehavior(.basedOnSize)
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.font(.label) }
                if kind == .combo {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { store.setTrigger(draft, for: action); dismiss() }.font(.label).disabled(!draft.isValid)
                    }
                }
            }
            .onAppear {
                if let current, current.isCombo { kind = .combo; steps = current.steps; interval = current.intervalMs }
            }
        }
        .tint(Color.ink)
        .presentationDetents([.large])
    }

    private var title: String {
        switch action {
        case .add(let i): "Add to \(playerName(i))"
        case .take(let i): "Take from \(playerName(i))"
        default: action.title
        }
    }

    /// Who already uses a trigger; choosing it here swaps with them.
    private func owner(_ trigger: ScoreTrigger) -> ScoreAction? {
        ScoreAction.all.first { $0 != action && store.controls.trigger(for: $0)?.steps == trigger.steps }
    }

    private func ownerText(_ owner: ScoreAction) -> String {
        switch owner {
        case .add(let i): "Adds to \(playerName(i)); they’ll swap"
        case .take(let i): "Takes from \(playerName(i)); they’ll swap"
        default: "\(owner.title); they’ll swap"
        }
    }

    // MARK: One gesture

    private var gestureList: some View {
        // "None" is checked when nothing is set; a combo leaves every row unchecked.
        let selected: GestureKind??
        if let current { selected = current.gesture.map { .some($0) } ?? .none } else { selected = .some(nil) }
        return ChoiceList(options: [nil] + ScoreTrigger.singleChoices.map(Optional.some), selected: selected, label: { gesture in
            if let gesture {
                GestureIcon(gesture: gesture, size: 22).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(gesture.name).font(.bodyText)
                    if let owner = owner(.gesture(gesture)) {
                        Text(ownerText(owner)).font(.caption).foregroundStyle(Color.muted)
                    }
                }
            } else {
                Color.clear.frame(width: 28, height: 1)
                Text("None").font(.bodyText).foregroundStyle(Color.muted)
            }
        }, choose: { gesture in
            store.setTrigger(gesture.map(ScoreTrigger.gesture), for: action); dismiss()
        })
    }

    // MARK: Combo

    private var comboEditor: some View {
        ComboBuilder(steps: $steps, interval: $interval, choices: ScoreTrigger.comboChoices,
                     note: steps.isEmpty ? nil : owner(draft).map(ownerText))
    }
}

/// Builds a combo a step at a time and sets the time allowed between steps. Shared by
/// every app that lets a combo set something off (Score, Capture).
struct ComboBuilder: View {
    @Binding var steps: [ComboStep]
    @Binding var interval: Int
    /// The steps that may follow the ones chosen so far.
    let choices: ([ComboStep]) -> [GestureKind]
    /// A line under the steps once they are valid, such as who else uses them.
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if steps.isEmpty {
                Text("Add two to eight steps, made in this order.").font(.bodyText).foregroundStyle(Color.muted)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { LucideIcon(.chevronRight, size: 10).foregroundStyle(Color.faint) }
                        VStack(spacing: 4) {
                            StepIcon(step: step, size: 20)
                            Text(step.shortName).font(.caption2).foregroundStyle(Color.muted).lineLimit(1)
                        }
                        .frame(minWidth: 34)
                    }
                }
                .accessibilityElement().accessibilityLabel(steps.map(\.name).joined(separator: ", then "))
            }
            HStack(spacing: 12) {
                Menu {
                    let allowed = choices(steps)
                    ForEach(["index", "middle"], id: \.self) { finger in
                        Section(finger == "index" ? "Index finger" : "Middle finger") {
                            ForEach(allowed.filter { $0.finger == finger }, id: \.self) { kind in
                                Button(kind.shortName) { steps.append(ComboStep(kind)) }
                            }
                        }
                    }
                    Section("Swipe") {
                        ForEach(allowed.filter { $0.finger == nil }, id: \.self) { kind in
                            Button(kind.name) { steps.append(ComboStep(kind)) }
                        }
                    }
                } label: {
                    Label { Text("Add step") } icon: { LucideIcon(.plus, size: 16) }
                }
                .buttonStyle(.secondary)
                .disabled(steps.count >= ComboRules.steps.upperBound)
                Button { steps.removeLast() } label: { Label { Text("Undo step") } icon: { LucideIcon(.x, size: 16) } }
                    .buttonStyle(.secondary).disabled(steps.isEmpty)
            }
            if !steps.isEmpty, let problem = ComboRules.problem(steps) {
                Text(problem).font(.caption).foregroundStyle(Color.muted)
            } else if let note {
                Text(note).font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.standard, value: steps)
        VStack(alignment: .leading, spacing: 8) {
            Heading("Time between steps")
            ChipRow(selection: $interval, options: ComboRules.times) { ms in
                ms < 1000 ? "\(ms) ms" : String(format: ms % 1000 == 0 ? "%.0f s" : "%.1f s", Double(ms) / 1000)
            }
            Note("While a finger is held there’s no time limit. A gesture that starts a combo waits until the combo finishes or runs out of time.")
        }
    }
}

// MARK: Sound

/// Lists the whole library; tapping a sound chooses and plays it, so they can be compared.
private struct SoundSheet: View {
    @ObservedObject var store: ScoreStore
    let slot: SoundSlot
    @Environment(\.dismiss) private var dismiss

    private var sounds: ScoreSounds { store.controls.sounds }
    private var selected: SoundVoice? {
        switch slot { case .add: sounds.add; case .take: sounds.take }
    }
    private var title: String {
        switch slot { case .add: "Point added"; case .take: "Point taken away" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ChoiceList(options: [nil] + SoundVoice.allCases.map(Optional.some), selected: .some(selected), label: { voice in
                        VStack(alignment: .leading, spacing: 2) {
                            if let voice {
                                Text(voice.label).font(.bodyText)
                            } else {
                                Text("None").font(.bodyText).foregroundStyle(Color.muted)
                            }
                        }
                    }, choose: choose)
                }
                .padding(Metric.gutter)
            }
            .page()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
        }
        .tint(Color.ink)
        .presentationDetents([.medium, .large])
    }

    private func choose(_ voice: SoundVoice?) {
        store.setSounds { sounds in
            switch slot {
            case .add: sounds.add = voice
            case .take: sounds.take = voice
            }
        }
        if let voice { ScoreAudio.shared.preview(voice, volume: max(0.3, sounds.volume)) }
    }
}
