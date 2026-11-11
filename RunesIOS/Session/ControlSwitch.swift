import Foundation

/// Who has the band while an app runs: the app's own controls, or the regular mappings.
/// The switch-controls combo (`SwitchControls`) flips it; touching the cover on the
/// app's screen (`regularControlsCover`) hands the band back. An app always starts with its own controls, and the choice ends with it.
///
/// With the regular controls selected the app keeps running (reps count, timers run, the
/// score stays) but takes no gestures, so every mapping is live again. Capture is left
/// out: its one gesture is meant to work everywhere.
@MainActor
final class ControlSwitch: ObservableObject {
    static let shared = ControlSwitch()

    /// The running app the band switches to and from. Nil when no app runs or no combo is set.
    @Published private(set) var app: RunesApp?
    /// True while the regular mappings have the band though `app` is running.
    @Published private(set) var regular = false
    /// The combo, when one is set and valid.
    @Published private(set) var combo: SwitchCombo?

    /// Told when `app` or `regular` changes. `announce` is true when a person switched,
    /// from the band or the screen, and should hear it.
    var onChange: ((_ announce: Bool) -> Void)?

    private var applying = false

    private init() {}

    /// The combo's steps in words: "Tap and hold middle, then swipe up".
    var comboName: String? {
        combo.map { CommandTrigger(steps: $0.steps, intervalMs: $0.intervalMs).name }
    }

    /// For a trigger being chosen anywhere else: why these steps can't be used, when they are the combo's.
    func clash(_ steps: [ComboStep]) -> String? {
        guard let combo, combo.steps == steps else { return nil }
        return "Switch controls uses this combo. Choose another."
    }

    /// For the combo itself: what is already set off by these steps, in any profile or app.
    func taken(_ steps: [ComboStep]) -> String? {
        guard steps.count > 1 else { return nil }
        if let profile = MappingStore.shared.library.profiles.first(where: { $0.combos.contains { $0.steps == steps } }) {
            return "A combo in the \(profile.name) profile uses these steps. Choose another."
        }
        let user: String? = WorkoutCommand.allCases.first { WorkoutStore.shared.controls.trigger(for: $0)?.steps == steps }.map { "Workouts uses this for “\($0.title)”." }
            ?? CookCommand.allCases.first { CookStore.shared.controls.trigger(for: $0)?.steps == steps }.map { "Cook uses this for “\($0.title)”." }
            ?? ScoreAction.all.first { ScoreStore.shared.controls.trigger(for: $0)?.steps == steps }.map { "Score uses this for “\($0.title)”." }
            ?? (CaptureStore.shared.controls.trigger.steps == steps ? "Capture uses this to record a note." : nil)
        return user.map { "\($0) Choose another." }
    }

    /// The saved combo changed.
    func setCombo(_ saved: SwitchCombo?) {
        combo = SwitchControls.isValid(saved) ? saved : nil
        refresh()
    }

    /// Flips between the app's controls and the regular ones. Nothing happens with no app running.
    func toggle() { select(regular: !regular) }

    func select(regular wanted: Bool) {
        guard app != nil, wanted != regular else { return }
        regular = wanted
        refresh(announce: true)
    }

    /// Works out which app the band belongs to and tells every engine. Called whenever an
    /// app starts or ends, and when the combo or the selection changes.
    func refresh(announce: Bool = false) {
        // Telling the apps makes them report their gestures again, which leads back here.
        guard !applying else { return }
        applying = true
        defer { applying = false }

        let workouts = WorkoutStore.shared, score = ScoreStore.shared, cook = CookStore.shared
        // The order gestures are offered in: the first running app holds the combo.
        let running: [RunesApp] = [workouts.run != nil ? .workouts : nil, score.game.live ? .score : nil,
                                   cook.session != nil ? .cook : nil].compactMap { $0 }
        let mapping = SwitchControls.mapping(combo)
        let owner = mapping == nil ? nil : running.first
        let before = (app, regular)
        if owner == nil { regular = false }
        if owner != app { app = owner }

        workouts.yielded = regular; score.yielded = regular; cook.yielded = regular
        workouts.switchMapping = owner == .workouts && !regular ? mapping : nil
        score.switchMapping = owner == .score && !regular ? mapping : nil
        cook.switchMapping = owner == .cook && !regular ? mapping : nil
        MappingStore.shared.switchMapping = owner != nil && regular ? mapping : nil

        if before != (app, regular) || announce { onChange?(announce) }
    }
}
