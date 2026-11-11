import Foundation

/// What sets off one of an app's commands (a Workouts or Cook control): one gesture, or a
/// combo of two to eight steps, rotation, movement and air shapes included. A combo with a
/// motion or air step keeps the band's motion sensors on while its app runs.
struct CommandTrigger: Codable, Hashable, Sendable {
    var steps: [ComboStep]
    var intervalMs = ComboRules.defaultTime

    init(steps: [ComboStep], intervalMs: Int = ComboRules.defaultTime) { self.steps = steps; self.intervalMs = intervalMs }
    static func gesture(_ kind: GestureKind) -> CommandTrigger { CommandTrigger(steps: [ComboStep(kind)]) }

    var isCombo: Bool { steps.count > 1 }
    /// The gesture when this is a single one.
    var gesture: GestureKind? { isCombo ? nil : steps.first?.gesture }
    /// "Double tap index", "Swipe up, then tap index".
    var name: String {
        steps.enumerated().map { $0.offset == 0 ? $0.element.name : $0.element.name.lowercased() }.joined(separator: ", then ")
    }

    /// Gestures a trigger may use on its own. Releases only make sense inside a combo.
    static let singleChoices = GestureKind.motions
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] { ComboRules.allowedNext(after: steps) }
    /// What the composer offers for a command: a gesture, a combo, or nothing.
    static var rules: TriggerRules { .gestureOrCombo(singleChoices, next: comboChoices, allowsNone: true) }

    /// Whether it needs the band's motion streams: a rotation, movement or air step.
    var usesMotion: Bool { steps.contains { $0.gesture.isMotion || $0.gesture.isAir } }

    var isValid: Bool {
        !steps.isEmpty && Self.rules.isValid(steps) && (!isCombo || ComboRules.times.contains(intervalMs))
    }
}

extension Dictionary where Value == CommandTrigger {
    /// Sets a command's trigger (nil clears it). A command that already had the same steps
    /// takes this command's old trigger, so no two share one.
    mutating func assign(_ trigger: CommandTrigger?, to command: Key) {
        let old = self[command]
        if let trigger, let other = first(where: { $0.key != command && $0.value.steps == trigger.steps })?.key { self[other] = old }
        self[command] = trigger
    }

    /// Whether any live trigger needs the band's motion streams.
    var usesMotion: Bool { values.contains { $0.isValid && $0.usesMotion } }

    /// The gestures these triggers take while their app runs; mappings that use one are off
    /// meanwhile. A double tap arrives after the tap that began it and a hold ends with a
    /// release, so those are taken with them.
    var reserved: Set<GestureKind> {
        Set(values.filter(\.isValid).flatMap { $0.steps.map(\.gesture) }).withPartners
    }
}

extension Dictionary where Value == CommandTrigger, Key: RawRepresentable, Key.RawValue == String {
    /// The triggers as mappings, for a `MappingEngine` that only decides which one was made.
    /// A single gesture's mapping must be named after it; the placeholder action never runs.
    func mappings(prefix: String) -> [Mapping] {
        compactMap { command, trigger in
            guard trigger.isValid else { return nil }
            if let gesture = trigger.gesture { return Mapping(id: gesture.rawValue, enabled: true, actions: [.haptic(.light)]) }
            return Mapping(id: prefix + command.rawValue, enabled: true, actions: [.haptic(.light)], steps: trigger.steps, intervalMs: trigger.intervalMs)
        }
    }
    /// The command a fired mapping stands for.
    func command(forMapping id: String, prefix: String) -> Key? {
        if id.hasPrefix(prefix) { return Key(rawValue: String(id.dropFirst(prefix.count))) }
        return first { $0.value.isValid && $0.value.gesture?.rawValue == id }?.key
    }

    /// Saved by command name, as Score's are.
    var saved: [String: CommandTrigger] { Dictionary<String, CommandTrigger>(uniqueKeysWithValues: map { ($0.key.rawValue, $0.value) }) }
    init(saved: [String: CommandTrigger]) {
        self.init(uniqueKeysWithValues: saved.compactMap { name, trigger in Key(rawValue: name).map { ($0, trigger) } })
    }
}
