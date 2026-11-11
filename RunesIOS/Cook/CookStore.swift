import Foundation
import UIKit
import UserNotifications

/// The sound for something that happened while cooking; the session turns it into a voice.
enum CookCue: Sendable { case step, start, pause, extend, stop, reset, select, ring, finish, nothing }

/// Saved recipes and the one being cooked. While a recipe is being cooked its gestures
/// are taken here and mappings that use them are off. Timers are absolute end times, so
/// they survive the phone locking and the app being closed: each one also schedules a
/// notification, which rings whether or not Runes is running.
@MainActor
final class CookStore: ObservableObject {
    static let shared = CookStore()
    private static let key = "runes.cook.v1"
    private nonisolated static let notificationPrefix = "cook.timer."

    private struct Saved: Codable {
        var recipes: [Recipe]
        var controls: CookControls?
        var sounds: Bool?
        var session: CookSession?
    }

    @Published private(set) var recipes: [Recipe]
    @Published private(set) var controls: CookControls { didSet { configureDecider(); motionChanged() } }
    /// Sounds for steps and timers while Runes is open. A finished timer always notifies.
    @Published private(set) var sounds: Bool
    @Published private(set) var session: CookSession? { didSet { if (oldValue == nil) != (session == nil) { motionChanged() } } }

    /// Told whether cooking needs the band's motion streams: only while a recipe is being
    /// cooked and one of its combos has a rotation, movement or air step.
    var onMotionDemand: ((Bool) -> Void)? { didSet { motionOn = motionWanted; onMotionDemand?(motionOn) } }
    private var motionOn = false
    private var motionWanted: Bool { session != nil && controls.usesMotion }
    private func motionChanged() {
        guard !previewOnly, motionWanted != motionOn else { return }
        motionOn = motionWanted
        onMotionDemand?(motionOn)
    }

    /// Told which gestures cooking holds (none when nothing is being cooked).
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    /// Shows the recipe on the Live Activity (nil restores band status), with an optional alert.
    var onActivity: ((CookActivityState?, LiveAlert?) -> Void)? { didSet { if session != nil { show() } } }
    var onCue: ((CookCue) -> Void)?
    /// True while the cooking screen is in front; it shows a ringing timer itself.
    var onScreen = false

    private var previewOnly = false
    /// Decides which command a band gesture completes, combos included.
    private let decider = TriggerDecider()
    private var wake: Timer?
    private var ringTask: Task<Void, Never>?
    private var scheduled: Set<String> = []
    private var askedToNotify = false

    private var reservedNow: Set<GestureKind> {
        session == nil || yielded ? [] : controls.reserved.union(SwitchControls.reserved(switchMapping))
    }
    /// The switch-controls combo, while this is the app the band switches to and from and
    /// its controls are selected. Set by `ControlSwitch`.
    var switchMapping: Mapping? {
        didSet { if switchMapping != oldValue { configureDecider(); if !previewOnly { onReserve?(reservedNow) } } }
    }
    /// True while the regular mappings have the band though a recipe is being cooked. Timers keep running.
    var yielded = false { didSet { if yielded != oldValue, !previewOnly { onReserve?(reservedNow) } } }
    private func configureDecider() {
        if !previewOnly { decider.configure(SwitchControls.adding(switchMapping, to: controls.mappings)) }
    }

    private init() {
        var saved = Saved(recipes: [.starter])
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded }
        recipes = saved.recipes
        controls = saved.controls ?? .standard
        sounds = saved.sounds ?? true
        session = saved.session
        scheduled = Set((saved.session?.timers ?? []).map { Self.notificationPrefix + $0.id })
        decider.onFire = { [weak self] id in
            guard let self else { return }
            if id == SwitchControls.mappingID { if self.session != nil { ControlSwitch.shared.toggle() }; return }
            guard let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        decider.configure(controls.mappings)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
        arm()
    }

    #if DEBUG
    /// Fixed state for screenshots and previews; never saved.
    init(preview recipes: [Recipe], session: CookSession? = nil) {
        self.recipes = recipes; controls = .standard; sounds = true; self.session = session; previewOnly = true
    }
    #endif

    // MARK: Recipes

    func recipe(_ id: String) -> Recipe? { recipes.first { $0.id == id } }

    /// Adds a recipe, or replaces the one with the same id. New recipes go first.
    func save(_ recipe: Recipe) {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) { recipes[index] = recipe } else { recipes.insert(recipe, at: 0) }
        persist()
    }

    func delete(_ id: String) {
        if session?.recipe.id == id { end() }
        recipes.removeAll { $0.id == id }
        persist()
    }

    func setTrigger(_ trigger: CommandTrigger?, for command: CookCommand) {
        controls.setTrigger(trigger, for: command)
        persist()
        if !previewOnly { onReserve?(reservedNow) }
    }
    func setSounds(_ on: Bool) { sounds = on; persist() }

    /// Fetches a page and reads the recipe it publishes.
    func fetch(_ url: URL) async throws -> Recipe {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Recipe sites turn away clients that don't look like a browser.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let data: Data
        do { (data, _) = try await URLSession(configuration: configuration).data(for: request) }
        catch { throw CookError.unreachable }
        guard data.count < 8_000_000, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let recipe = RecipeParser.recipe(fromHTML: html, source: url.absoluteString) else { throw CookError.noRecipe }
        return recipe
    }

    // MARK: Cooking

    func start(_ recipe: Recipe) {
        guard recipe.isUsable else { return }
        if session != nil { end() }
        session = CookSession(recipe: recipe)
        changed()
    }

    /// Stops cooking: timers are cancelled and the gestures go back to mappings.
    func end() {
        guard let finished = session else { return }
        session = nil
        if finished.finished, let index = recipes.firstIndex(where: { $0.id == finished.recipe.id }) {
            recipes[index].cooked += 1; recipes[index].lastCooked = Date()
        }
        ringTask?.cancel(); ringTask = nil
        persist(); arm(); syncNotifications()
        guard !previewOnly else { return }
        onReserve?(reservedNow)
        onActivity?(nil, nil)
    }

    func perform(_ command: CookCommand) {
        guard var current = session else { return }
        let event = current.apply(command)
        session = current
        react(to: event)
    }

    /// Takes a band gesture that is one of cooking's while a recipe is being cooked.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard session != nil, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }

    /// Takes a rotation or movement from the band's motion while a recipe is being cooked
    /// and one of its combos uses it. Returns false to let mappings have it.
    func consume(_ step: ComboStep) -> Bool {
        guard session != nil, reservedNow.contains(step.gesture) else { return false }
        decider.receive(step)
        return true
    }

    /// The band's orientation, for air steps in cooking's combos.
    func orientation(_ q: [Double]) {
        if motionOn { decider.orientation(q) }
    }

    /// The main button of one of the current step's timers: start, pause, start again, stop ringing.
    func toggleTimer(slot: Int) {
        guard var current = session else { return }
        current.select(slot: slot)
        let event = current.toggle(step: current.step, slot: slot)
        session = current
        react(to: event)
    }
    func resetTimer(slot: Int) {
        guard var current = session, current.timer(step: current.step, slot: slot) != nil else { return }
        current.select(slot: slot)
        current.reset(step: current.step, slot: slot)
        session = current
        react(to: .reset)
    }
    func select(slot: Int) {
        guard var current = session, current.slot != slot else { return }
        current.select(slot: slot); session = current
        react(to: .selected(current.slot))
    }
    func addMinute(to id: String) {
        guard var current = session, let timer = current.addMinute(to: id) else { return }
        session = current
        react(to: .extended(timer))
    }
    func stopRinging() {
        guard var current = session, !current.ringing(at: Date()).isEmpty else { return }
        current.stopRinging(); session = current
        react(to: .stopped)
    }
    /// Shows a step, optionally with one of its timers selected.
    func go(to step: Int, slot: Int? = nil) {
        guard var current = session else { return }
        current.go(to: step, slot: slot); session = current
        changed()
    }
    func toggle(ingredient index: Int) {
        guard var current = session else { return }
        current.toggle(ingredient: index); session = current
        persist()
    }

    private func react(to event: CookEvent?) {
        guard let session else { return }
        var alert: LiveAlert?
        let cue: CookCue
        switch event {
        case .step:
            cue = .step; alert = LiveAlert(title: session.position, body: session.text)
        case .finished:
            cue = .finish; alert = LiveAlert(title: "Recipe finished", body: session.recipe.title)
        case .started(let timer):
            cue = .start; alert = LiveAlert(title: "Timer started", body: "\(timer.label) · \(DurationFinder.short(timer.total))")
            askToNotify()
        case .paused(let timer):
            cue = .pause; alert = LiveAlert(title: "Timer paused", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case .resumed(let timer):
            cue = .start; alert = LiveAlert(title: "Timer started again", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case .reset:
            cue = .reset; alert = LiveAlert(title: "Timer reset", body: session.durations.indices.contains(session.slot) ? session.durations[session.slot].short : session.position)
        case .selected(let slot):
            cue = .select
            let duration = session.durations.indices.contains(slot) ? session.durations[slot] : nil
            alert = LiveAlert(title: "Timer \(slot + 1) of \(session.durations.count)",
                              body: [duration?.label, duration?.short].compactMap { $0 }.joined(separator: " · "))
        case .stopped:
            cue = .stop
        case .extended(let timer):
            cue = .extend; alert = LiveAlert(title: "One more minute", body: "\(timer.label) · \(DurationFinder.clock(timer.remaining(at: Date()))) left")
        case nil:
            cue = .nothing
        }
        if sounds, !previewOnly { onCue?(cue) }
        // With Runes open the screen shows the change; an alert is for a locked phone.
        changed(alert: UIApplication.shared.applicationState == .active ? nil : alert)
    }

    private func changed(alert: LiveAlert? = nil) {
        persist()
        guard !previewOnly else { return }
        arm(); syncNotifications()
        onReserve?(reservedNow)
        show(alert: alert)
    }

    // MARK: Timers

    /// Wakes at the next timer's end, so the screen and the Lock Screen turn to ringing.
    private func arm() {
        wake?.invalidate(); wake = nil
        guard !previewOnly, let end = session?.nextEnd(after: Date()) else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rang() }
        }
        RunLoop.main.add(timer, forMode: .common)
        wake = timer
    }

    private func rang() {
        objectWillChange.send()
        arm(); show()
        ring()
    }

    /// Coming back to the app: timers may have ended while it was suspended.
    private func woke() {
        guard session != nil else { return }
        objectWillChange.send()
        arm(); show()
        ring()
    }

    /// Repeats the bell while a timer rings and Runes is open. In the background the
    /// timer's notification is the bell.
    private func ring() {
        guard ringTask == nil, sounds, UIApplication.shared.applicationState == .active else { return }
        ringTask = Task { [weak self] in
            for _ in 0..<8 {
                guard let self, !Task.isCancelled, let session = self.session, !session.ringing(at: Date()).isEmpty,
                      UIApplication.shared.applicationState == .active else { break }
                self.onCue?(.ring)
                try? await Task.sleep(for: .milliseconds(1800))
            }
            self?.ringTask = nil
        }
    }

    /// One pending notification per running timer; anything else of ours is withdrawn.
    private func syncNotifications() {
        guard !previewOnly else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Array(scheduled))
        scheduled = []
        guard let session else { return }
        let now = Date()
        for timer in session.running(at: now) {
            let content = UNMutableNotificationContent()
            content.title = "Time’s up"
            content.body = "\(timer.label) · step \(timer.step + 1) of \(session.recipe.title)"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timer.end.timeIntervalSince(now)), repeats: false)
            let id = Self.notificationPrefix + timer.id
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            scheduled.insert(id)
        }
    }

    /// True for one of Cook's timer notifications.
    nonisolated static func isTimer(_ identifier: String) -> Bool { identifier.hasPrefix(notificationPrefix) }

    private func askToNotify() {
        guard !askedToNotify, !previewOnly else { return }
        askedToNotify = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    // MARK: Lock Screen

    private func show(alert: LiveAlert? = nil) {
        guard !previewOnly, let session else { return }
        onActivity?(activityState(session), alert)
    }

    func activityState(_ session: CookSession, now: Date = Date()) -> CookActivityState {
        let timers = session.live(at: now).prefix(5).map {
            CookActivityTimer(id: $0.id, end: $0.end, total: $0.total, ringing: $0.isRinging(at: now), remaining: $0.paused)
        }
        return CookActivityState(position: session.position, step: session.step, count: session.count,
                                 timers: Array(timers), finished: session.finished)
    }

    private func persist() {
        guard !previewOnly else { return }
        let saved = Saved(recipes: recipes, controls: controls, sounds: sounds, session: session)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum CookError: LocalizedError {
    case unreachable, noRecipe
    var errorDescription: String? {
        switch self {
        case .unreachable: "That page couldn’t be reached. Check the link and your connection."
        case .noRecipe: "No recipe was found on that page. Paste its text instead."
        }
    }
}
