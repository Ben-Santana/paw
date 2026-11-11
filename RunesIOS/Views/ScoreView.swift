import SwiftUI

// Score: full screen, one player at a time, in their colour. Tap to add a point, the bar
// in the corner to take one away, the name to rename or remove. Swipe sideways for the
// other players (left for the next, like turning a page) and up to zoom out to everyone at once (the player's box shrinks into its
// tile), where the game is started, reset, given more players and a game type (tennis,
// table tennis, the user's own: `ScoreTypesView.swift`). A swipe up on the band
// does the same zoom, in or out, while this screen is in view. A game is kept from the band with the phone away (see `ScoreControls`; Score settings chooses the gestures and sounds),
// and the screen follows whoever was changed last. The phone stays awake on this screen,
// and it is the only one that turns to landscape.
// Colour is used here and nowhere else in Runes, so players can be told apart at a glance.

struct ScoreScreen: View {
    @ObservedObject var store: ScoreStore
    @State private var showAll: Bool
    /// Where the selected player's tile sits among the others, for the zoom.
    @State private var tile: CGRect?
    /// While true, the selected player is one box moving between full screen and their tile.
    @State private var morphing = false
    @State private var boxExpanded = false
    @State private var confirmReset = false
    @State private var editing: EditedPlayer?
    @State private var appeared = false
    @State private var showSettings = false
    @State private var showTypes = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Opens on everyone's scores until a game is live, since that is where one starts.
    init(store: ScoreStore, showAll: Bool? = nil) {
        self.store = store
        _showAll = State(initialValue: showAll ?? !store.game.live)
    }

    private var actions: ScoreActions {
        ScoreActions(
            change: store.change, select: store.select,
            add: { withAnimation(.entrance) { store.addPlayer() } },
            reset: { confirmReset = true },
            toggleLive: {
                if store.game.live { store.end() } else { store.start(); show(all: false) }
            },
            edit: { editing = EditedPlayer(id: $0) },
            showAll: { show(all: $0) },
            back: { dismiss() },
            settings: { showSettings = true },
            types: { showTypes = true },
            hints: { index in
                // A player's own triggers, or the selected-player ones while they're selected.
                let c = store.controls, selected = store.game.selected == index
                let add = c.trigger(for: .add(index)) ?? (selected ? c.trigger(for: .addSelected) : nil)
                let take = c.trigger(for: .take(index)) ?? (selected ? c.trigger(for: .takeSelected) : nil)
                return [add.map { ScoreHint(trigger: $0, effect: "+1") }, take.map { ScoreHint(trigger: $0, effect: "−1") }].compactMap { $0 }
            })
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            // The whole display, in this view's safe-area coordinates.
            let full = CGRect(x: -insets.leading, y: -insets.top,
                              width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            ZStack {
                // Everyone is always laid out underneath, so the selected tile's place is known.
                ScoreBoard(game: store.game, active: showAll && !morphing, hidden: morphing ? store.game.selected : nil, actions: actions)
                    .allowsHitTesting(showAll && !morphing).accessibilityHidden(!showAll)
                if !showAll && !morphing {
                    ScoreStage(game: store.game, screen: full.size, actions: actions)
                }
                // Zooming is the selected player's own box growing from their tile to the
                // whole screen, or shrinking back into place: same colour, same number.
                if morphing, store.game.players.indices.contains(store.game.selected) {
                    let frame = boxExpanded ? full : (tile ?? full)
                    PlayerFace(game: store.game, index: store.game.selected, expanded: boxExpanded,
                               screen: full.size, insets: insets, active: false)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: screenSpace)
            .onPreferenceChange(SelectedTileKey.self) { tile = $0 }
        }
        .sensoryFeedback(.selection, trigger: store.game.selected)
        .page()
        // The real navigation bar, so the back button stays put when this is pushed, as on
        // every other screen. Full screen keeps only the back button.
        .toolbar {
            if showAll {
                ToolbarItem(placement: .principal) {
                    Button { show(all: false) } label: { LucideIcon(.chevronDown, size: 20).foregroundStyle(Color.muted) }
                        .accessibilityLabel("One player at a time")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { LucideIcon(.settings, size: 19) }
                        .accessibilityLabel("Score settings")
                    Button { showTypes = true } label: { LucideIcon(.trophy, size: 19) }
                        .accessibilityLabel("Game type").accessibilityValue(store.game.rules.name)
                    Button { withAnimation(.entrance) { store.addPlayer() } } label: { LucideIcon(.plus, size: 20) }
                        .disabled(!store.game.canAdd)
                        .accessibilityLabel("Add player")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .statusBarHidden(!showAll)
        .sheet(isPresented: $showSettings) { ScoreSettingsScreen(store: store) }
        .sheet(isPresented: $showTypes) { GameTypeScreen(store: store) }
        .confirmationDialog("Reset the score?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset score", role: .destructive) { store.reset() }
        } message: { Text("Everyone goes back to zero.") }
        .sheet(item: $editing) { player in
            if store.game.players.indices.contains(player.id) {
                PlayerSheet(name: store.game.names[player.id], canRemove: store.game.canRemove,
                            save: { store.rename(player.id, to: $0) },
                            remove: { withAnimation(.entrance) { store.removePlayer(player.id) } })
                    .presentationDetents([.height(store.game.canRemove ? 280 : 220)])
            }
        }
        // A scoreboard is glanced at, not touched; it must not dim or lock mid-game.
        // It is also the one screen that turns, so a phone propped on its side reads well.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true; OrientationLock.set(.allButUpsideDown)
            appeared = true; store.onScreen = scenePhase == .active
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false; OrientationLock.set(.portrait)
            appeared = false; store.onScreen = false
        }
        // Band swipe up only belongs to this screen while it can be seen.
        .onChange(of: scenePhase) { _, phase in store.onScreen = appeared && phase == .active }
        .onChange(of: store.showAllToggles) { show(all: !showAll) }
    }

    /// Zooms out to everyone or into the selected player. The full-screen view and the
    /// tile are drawn alike, so swapping either for the moving box shows no seam.
    private func show(all: Bool) {
        guard all != showAll, !morphing else { return }
        guard !reduceMotion, tile != nil else { showAll = all; return }
        boxExpanded = all   // out starts full screen; in starts as the tile
        morphing = true
        showAll = all
        Task { @MainActor in
            // Let the box appear where it starts before it moves.
            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.spring(duration: 0.5, bounce: 0.12)) { boxExpanded = !all } completion: { morphing = false }
        }
    }
}

private struct EditedPlayer: Identifiable { let id: Int }

struct ScoreActions {
    var change: (Int, Int) -> Void = { _, _ in }
    var select: (Int) -> Void = { _ in }
    var add: () -> Void = {}
    var reset: () -> Void = {}
    var toggleLive: () -> Void = {}
    var edit: (Int) -> Void = { _ in }
    var showAll: (Bool) -> Void = { _ in }
    var back: () -> Void = {}
    var settings: () -> Void = {}
    var types: () -> Void = {}
    /// The band triggers that reach a player right now, shown in their corner.
    var hints: (Int) -> [ScoreHint] = { _ in [] }
}

struct ScoreHint: Hashable {
    let trigger: ScoreTrigger
    let effect: String
}

/// A deliberate swipe along one axis: how far it went, or nil when it was a tap or diagonal.
private func flick(_ value: DragGesture.Value, sideways: Bool = false) -> CGFloat? {
    let t = value.translation
    let (along, across) = sideways ? (t.width, t.height) : (t.height, t.width)
    return abs(along) > 70 && abs(along) > abs(across) * 1.5 ? along : nil
}

/// The selected tile's frame in the screen's coordinates.
private struct SelectedTileKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
private let screenSpace = "scorescreen"

// MARK: One player

/// The selected player across the whole screen. The others wait to either side in order,
/// the next one on the right: swipe left for the next player, right for the one before,
/// and they slide past like pages.
struct ScoreStage: View {
    let game: ScoreGame
    /// The whole display, which each page fills.
    let screen: CGSize
    var actions = ScoreActions()
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slide = Animation.spring(duration: 0.45, bounce: 0.14)

    var body: some View {
        // The colour runs under the island and home indicator; the insets are read here
        // so each page can keep its controls clear of them, upright or on its side.
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            ZStack {
                ScoreTint.fill(game.players[game.selected].tint)
                ForEach(Array(game.players.enumerated()), id: \.element.id) { index, _ in
                    // The next player waits on the right, so a swipe to the left brings them in.
                    PlayerFace(game: game, index: index, expanded: true, screen: screen, insets: insets, actions: actions)
                        .offset(x: CGFloat(index - game.selected) * screen.width + drag)
                        .accessibilityHidden(index != game.selected)
                }
            }
            .ignoresSafeArea()
        }
        .animation(reduceMotion ? nil : Self.slide, value: game.selected)
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                let t = value.translation
                guard abs(t.width) > abs(t.height), !reduceMotion else { return }
                // Nobody waits past the first or last player; the page resists instead.
                let blocked = t.width < 0 ? game.selected == game.players.count - 1 : game.selected == 0
                drag = blocked ? t.width / 4 : t.width
            }
            .onEnded { value in
                if let dy = flick(value), dy < 0 { drag = 0; actions.showAll(true); return }
                let dx = value.translation.width, sideways = abs(dx) > abs(value.translation.height)
                let target = sideways && dx < -60 ? game.selected + 1 : sideways && dx > 60 ? game.selected - 1 : game.selected
                settle(game.players.indices.contains(target) ? target : game.selected)
            })
    }

    /// Lets go of the page: it springs to `index`, or back where it was.
    private func settle(_ index: Int) {
        withAnimation(reduceMotion ? nil : Self.slide) {
            drag = 0
            if index != game.selected { actions.select(index) }
        }
    }
}

/// One player's box: colour, name, number, the minus and the band gestures that reach
/// them. Drawn the same way full screen and as a tile, with everything placed by the box's
/// size, so going between the two is this box growing or shrinking.
private struct PlayerFace: View {
    let game: ScoreGame
    let index: Int
    /// Full screen, or a tile among the others.
    let expanded: Bool
    /// The whole display. The number is drawn for it and scaled down in a tile, so it can
    /// grow smoothly; nil draws it at tile size.
    var screen: CGSize? = nil
    var insets = EdgeInsets()
    /// False when another copy of this view is the one on screen, so haptics fire once.
    var active = true
    var actions = ScoreActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bump = false
    /// How many characters the number had before its latest change. A digit coming or going
    /// (10 → 9) mustn't bounce: the spring would overshoot the leaving digit's fade, and it
    /// would flicker back before it's gone.
    @State private var drawnCount: Int?

    private var player: ScorePlayer { game.players[index] }
    private var numberAnimation: Animation {
        label.count == (drawnCount ?? label.count)
            ? .spring(duration: 0.3, bounce: 0.3)
            : .spring(duration: 0.25, bounce: 0)
    }
    private var ink: Color { ScoreTint.ink(player.tint) }
    /// The player side swipes have reached; with more than two, the one the index finger changes.
    private var selected: Bool { game.selected == index }
    /// The points as the game type reads them: a number, or tennis's 15, 30, 40 and Ad.
    private var label: String { game.points(index) }
    /// Everything the player has won, so haptics and the bump follow a won game too.
    private var tally: Int { player.sets * 1_000_000 + player.games * 1_000 + player.score }
    private var tileSize: CGFloat {
        let base: CGFloat = game.players.count > 4 ? 64 : game.players.count > 2 ? 88 : 120
        return label.count > 3 ? base * 0.5 : label.count > 2 ? base * 0.64 : base
    }
    private var drawnSize: CGFloat {
        guard let screen else { return tileSize }
        let base: CGFloat = label.count > 3 ? 120 : label.count > 2 ? 170 : 240
        return max(tileSize, min(base, screen.height * 0.5))
    }

    var body: some View {
        ZStack {
            // The whole box adds a point; the name and the minus sit on top of it.
            // A tap, not a button: a button would also fire at the end of a swipe.
            RoundedRectangle(cornerRadius: expanded ? 0 : 22, style: .continuous).fill(ScoreTint.fill(player.tint))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3).opacity(!expanded && selected ? 1 : 0)
                }
                .overlay {
                    Text(label)
                        .font(.geist(drawnSize, .semibold, relativeTo: .largeTitle)).monospacedDigit()
                        .fixedSize()
                        .contentTransition(.numericText(value: Double(player.score)))
                        .animation(numberAnimation, value: label)
                        .onChange(of: label, initial: true) { _, new in drawnCount = new.count }
                        .scaleEffect((expanded ? 1 : tileSize / drawnSize) * (bump && !reduceMotion ? 1.07 : 1))
                }
                // Under the number, near the end of a game: the points still to win it.
                .overlay {
                    let size = expanded ? drawnSize : tileSize
                    ZStack {
                        if let left = game.toGo(index) {
                            ToGo(left: left, large: expanded).transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .offset(y: size * 0.5 + (expanded ? 22 : 10))
                    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.35), value: game.toGo(index))
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.change(index, 1) }
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel([player.name, label, game.standing(index), game.pointName(index) ?? game.toGo(index).map { "\($0) to win the game" }]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Adds a point.")
                .accessibilityAddTraits(!expanded && selected ? .isSelected : [])

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // The navigation bar's back button sits here, full screen.
                    Color.clear.frame(width: expanded ? Metric.tap : 0, height: Metric.tap)
                    Button { actions.edit(index) } label: {
                        // Laid out at full size and scaled, so a tile doesn't cut a name short
                        // for space it won't use (names are at most 16 characters).
                        Text(player.name).font(.heading).lineLimit(1).fixedSize().opacity(0.8)
                            .scaleEffect(expanded ? 1 : 0.7)
                            .frame(maxWidth: .infinity, minHeight: Metric.tap).contentShape(Rectangle())
                    }
                    .buttonStyle(PressRow())
                    .accessibilityHint("Renames or removes this player.")
                    Color.clear.frame(width: expanded ? Metric.tap : 0, height: Metric.tap)
                }
                // Games and sets won, for game types that count them, and who won the match.
                if let standing = game.standing(index) {
                    Text(standing).font(.label).monospacedDigit().lineLimit(1).fixedSize().opacity(0.8)
                        .scaleEffect(expanded ? 1 : 0.8).padding(.top, expanded ? -6 : -12)
                        .contentTransition(.numericText()).animation(.standard, value: standing)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                Spacer().allowsHitTesting(false)
                HStack(spacing: 0) {
                    MinusBar(name: player.name, enabled: game.canTake(index)) { actions.change(index, -1) }
                    Spacer(minLength: 0).allowsHitTesting(false)
                    hints.padding(.trailing, 10).allowsHitTesting(false)
                }
                // Full screen only: which player this is, and the way out to everyone.
                Button { actions.showAll(true) } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(game.players.indices, id: \.self) { i in
                                Circle().frame(width: 6, height: 6).opacity(i == index ? 0.9 : 0.3)
                            }
                        }
                        LucideIcon(.chevronUp, size: 18).opacity(0.6)
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(PressRow())
                .frame(height: expanded ? Metric.tap : 0)
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
                .accessibilityLabel("All scores")
            }
            .padding(.top, expanded ? max(UIApplication.shared.windowSafeTop, 8) : 6)
            .padding(.bottom, expanded ? max(insets.bottom, 8) : 8)
            .padding(.leading, expanded ? max(insets.leading, 12) : 8)
            .padding(.trailing, expanded ? max(insets.trailing, 12) : 8)
        }
        .foregroundStyle(ink)
        // Only the player who was changed: a won game also puts the others back to zero.
        .sensoryFeedback(trigger: tally) { old, new in active && selected ? (new > old ? .increase : .decrease) : nil }
        .onChange(of: tally) { _, _ in
            guard !reduceMotion else { return }
            bump = true
            withAnimation(.spring(duration: 0.35, bounce: 0.5)) { bump = false }
        }
    }

    /// The band gestures that reach this player right now (Score settings chooses them).
    @ViewBuilder private var hints: some View {
        let hints = actions.hints(index)
        if !hints.isEmpty {
            HStack(spacing: 10) {
                ForEach(hints, id: \.self) { GestureHint(trigger: $0.trigger, effect: $0.effect) }
            }
            .opacity(game.live ? 0.8 : 0.4).transition(.opacity)
        }
    }
}

/// The points a player still needs to win the game, lead included, as open rings that close
/// up one by one; whatever lead the game type asks for, it is the same count. The last one
/// is filled and beats, with no words: game, set or match point is read out by VoiceOver
/// and said by the band's confirmation. More than eight is said in a line instead.
private struct ToGo: View {
    let left: Int
    let large: Bool
    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pip: CGFloat = large ? 11 : 7
        HStack(spacing: large ? 8 : 5) {
            if left > 8 {
                Text("\(left) to go").font(large ? .label : .caption).monospacedDigit().contentTransition(.numericText(value: Double(left)))
            } else {
                ForEach(0..<left, id: \.self) { _ in
                    Circle().strokeBorder(lineWidth: large ? 2 : 1.5).background(Circle().opacity(left == 1 ? 1 : 0))
                        .frame(width: pip, height: pip)
                        .scaleEffect(left == 1 && beat ? 1.45 : 1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .opacity(0.85)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { beat = true }
        }
        .accessibilityHidden(true)
    }
}

/// A bare, heavy bar in the corner that takes a point away, as in the web scorekeeper.
private struct MinusBar: View {
    let name: String
    /// False when the player has nothing to take back.
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Capsule().frame(width: 18, height: 3)
                .frame(width: Metric.row, height: Metric.row).contentShape(Rectangle())
        }
        .buttonStyle(CornerPress())
        .disabled(!enabled).opacity(enabled ? 0.6 : 0.25)
        .accessibilityLabel("Take a point from \(name)")
    }
}

private struct GestureHint: View {
    let trigger: ScoreTrigger
    let effect: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(trigger.steps.enumerated()), id: \.offset) { _, step in
                GestureIcon.image(step.gesture, size: 15).renderingMode(.template)
            }
            Text(effect).font(.caption).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trigger.name): \(effect)")
    }
}

// MARK: Everyone

/// Every player at once, with the game's controls. Values and closures, so previews can
/// show any state.
struct ScoreBoard: View {
    let game: ScoreGame
    /// False while zoomed in; both views stay laid out, and only the shown one gives haptics.
    var active = true
    /// The tile the moving box stands in for during a zoom.
    var hidden: Int? = nil
    var actions = ScoreActions()

    /// Upright: two to a row, an odd last one across. On its side: one row up to four,
    /// then three to a row.
    private func rows(wide: Bool) -> [[Int]] {
        let all = Array(game.players.indices)
        // Two players upright stack one above the other, each getting the full width.
        let columns = wide ? (all.count <= 4 ? all.count : 3) : (all.count <= 2 ? 1 : 2)
        return stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                if wide {
                    // On its side the controls stand beside the scores, which need the height.
                    HStack(spacing: 12) {
                        grid(wide: true)
                        VStack(spacing: 4) { typeLine; startButton; resetButton }.frame(width: 170)
                    }
                    .padding(.leading, 4).padding(.trailing, 12).padding(.top, 4)
                } else {
                    grid(wide: false).padding(.horizontal, 4).padding(.top, 4).padding(.bottom, game.rules.points == nil ? 20 : 6)
                    typeLine.padding(.horizontal, Metric.gutter).padding(.bottom, 6)
                    HStack(spacing: 18) { resetButton; startButton }
                        .padding(.horizontal, Metric.gutter).padding(.bottom, 8)
                }
            }
        }
        .sensoryFeedback(trigger: game.live) { _, _ in active ? .impact(weight: .light) : nil }
        .animation(.standard, value: game.live)
        .animation(.standard, value: game.selected)
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            if let dy = flick(value), dy > 0 { actions.showAll(false) }
            // Right moves the outline to the next player and left to the one before.
            else if let dx = flick(value, sideways: true) {
                let count = game.players.count
                actions.select((game.selected + (dx > 0 ? 1 : -1) + count) % count)
            }
        })
    }

    private func grid(wide: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(rows(wide: wide), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { index in
                        ScorePanel(game: game, index: index, active: active, actions: actions)
                            .opacity(hidden == index ? 0 : 1)
                            .id(game.players[index].id)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The game type and its rules, when there are any; tapping it chooses another.
    @ViewBuilder private var typeLine: some View {
        if game.rules.points != nil {
            Button(action: actions.types) {
                Text("\(game.rules.name) · \(game.rules.detail)").font(.caption).foregroundStyle(Color.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(PressRow())
            .accessibilityHint("Chooses the game type.")
        }
    }

    private var resetButton: some View {
        RoundAction(icon: .rotateCcw, label: "Reset", action: actions.reset).disabled(game.isEmpty)
    }
    private var startButton: some View {
        Button(action: actions.toggleLive) { Text(game.live ? "End game" : "Start game") }
            .buttonStyle(CapsuleAction(filled: !game.live))
    }
}

/// A player's tile among the others. The selected tile reports where it is, so the zoom
/// can grow from it and shrink back into it.
private struct ScorePanel: View {
    let game: ScoreGame
    let index: Int
    let active: Bool
    let actions: ScoreActions

    var body: some View {
        PlayerFace(game: game, index: index, expanded: false, active: active, actions: actions)
            .background {
                if game.selected == index {
                    GeometryReader { geo in
                        Color.clear.preference(key: SelectedTileKey.self, value: geo.frame(in: .named(screenSpace)))
                    }
                }
            }
    }
}

/// The corner minus shrinks while pressed; it has no outline to react with.
private struct CornerPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.8 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.lively, value: configuration.isPressed)
    }
}

/// A player's name, and the way out of the game when more than two are playing.
private struct PlayerSheet: View {
    @State var name: String
    let canRemove: Bool
    let save: (String) -> Void
    let remove: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FormSheet("Player", save: { save(name) }) {
            VStack(alignment: .leading, spacing: 20) {
                TitleField(prompt: "Name", text: $name, focus: $focused)
                    .onChange(of: name) { _, new in
                        if new.count > ScoreGame.nameLimit { name = String(new.prefix(ScoreGame.nameLimit)) }
                    }
                if canRemove {
                    Button("Remove player") { dismiss(); remove() }.buttonStyle(.secondary)
                }
            }
        }
        .onAppear { focused = true }
    }
}

#if DEBUG
extension PreviewFixtures {
    static func score(_ scores: Int..., live: Bool = true) -> ScoreGame {
        var game = ScoreGame()
        while game.players.count < scores.count, game.addPlayer() {}
        for (index, score) in scores.enumerated() { game.change(index, by: score) }
        game.change(0, by: 0)
        game.live = live
        return game
    }
    /// A tennis match part-way through: a set each way and deuce in the third.
    static func tennis() -> ScoreGame {
        var game = ScoreGame()
        game.rename(0, to: "Sam"); game.rename(1, to: "Alex")
        game.play(ScoreRules.presets.first { $0.id == "tennis" } ?? .open)
        for (player, games) in [(0, 6), (1, 6), (0, 2), (1, 3)] { for _ in 0..<games * 4 { game.change(player, by: 1) } }
        for player in [0, 1, 0, 1, 0, 1, 0] { game.change(player, by: 1) }
        game.live = true
        return game
    }
    /// Table tennis at ten all, then one more point if `ahead`: two to go each, or game point.
    static func deuce(ahead: Bool = false) -> ScoreGame {
        var game = ScoreGame()
        game.rename(0, to: "Sam"); game.rename(1, to: "Alex")
        game.play(ScoreRules.presets.first { $0.id == "table-tennis" } ?? .open)
        for player in [0, 1] { for _ in 0..<10 { game.change(player, by: 1) } }
        if ahead { game.change(0, by: 1) }
        game.live = true
        return game
    }
}

#Preview("Score · live") { NavigationStack { ScoreScreen(store: ScoreStore(preview: PreviewFixtures.score(7, 4))) } }
#Preview("Score · all four") { NavigationStack { ScoreScreen(store: ScoreStore(preview: PreviewFixtures.score(7, 4, 11, 2)), showAll: true) } }
#Preview("Score · tennis") { NavigationStack { ScoreScreen(store: ScoreStore(preview: PreviewFixtures.tennis()), showAll: true) } }
#Preview("Score · idle") { NavigationStack { ScoreScreen(store: ScoreStore(preview: PreviewFixtures.score(0, 0, live: false))) } }
#endif
