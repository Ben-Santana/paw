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
                    SwitchControlsBlock()
                    soundsBlock
                    playersBlock
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Score settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $editing) { action in ScoreTriggerSheet(store: store, action: action, playerName: playerName) }
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
                TriggerRow(title: title(action), detail: action.detail, steps: store.controls.trigger(for: action)?.steps) { editing = action }
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

// MARK: Trigger

/// Chooses one gesture, or builds a combo, for an action.
private struct ScoreTriggerSheet: View {
    @ObservedObject var store: ScoreStore
    let action: ScoreAction
    let playerName: (Int) -> String

    private var current: ScoreTrigger? { store.controls.trigger(for: action) }

    var body: some View {
        TriggerSheet(title: title, caption: action.detail,
                     rules: .gestureOrCombo(ScoreTrigger.singleChoices, next: ScoreTrigger.comboChoices, allowsNone: true),
                     steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                     taken: Set(ScoreAction.all.filter { $0 != action }.compactMap { store.controls.trigger(for: $0)?.gesture }),
                     feed: band, note: { steps in owner(steps).map(ownerText) },
                     save: { steps, interval in
            store.setTrigger(steps.isEmpty ? nil : ScoreTrigger(steps: steps, intervalMs: interval), for: action)
        })
    }

    /// The band, except in previews and screenshots.
    private var band: MappingStore? { RunesIOSApp.snapshotName == nil ? .shared : nil }

    private var title: String {
        switch action {
        case .add(let i): "Add to \(playerName(i))"
        case .take(let i): "Take from \(playerName(i))"
        default: action.title
        }
    }

    /// Who already uses these steps; choosing them here swaps with them.
    private func owner(_ steps: [ComboStep]) -> ScoreAction? {
        ScoreAction.all.first { $0 != action && store.controls.trigger(for: $0)?.steps == steps }
    }

    private func ownerText(_ owner: ScoreAction) -> String {
        switch owner {
        case .add(let i): "Adds to \(playerName(i)); they’ll swap."
        case .take(let i): "Takes from \(playerName(i)); they’ll swap."
        default: "\(owner.title) uses this; they’ll swap."
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
