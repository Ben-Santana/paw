import Foundation

/// The one combo that hands the band between a running app's controls (Workouts, Score,
/// Cook) and the regular mappings. It is saved beside the profiles (`MappingLibrary.switchControls`),
/// so it is the same whichever profile is active, and it only does anything while an app runs.
///
/// Whoever has the band also has this combo in its `MappingEngine`: the running app while
/// its controls are selected, mappings while the regular ones are. That engine then treats
/// it like any other combo, so a gesture that begins it waits for it and its steps don't
/// also run something else.
enum SwitchControls {
    /// The combo's id in whichever engine holds it.
    static let mappingID = "switch-controls"

    /// Always a combo, so it never takes a gesture's own row away from every profile. Finger
    /// and swipe steps only: it must not keep the band's motion sensors on.
    static let rules = TriggerRules(next: { steps in
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }, allowsNone: true)

    static func isValid(_ trigger: SwitchCombo?) -> Bool {
        guard let trigger, !trigger.steps.isEmpty else { return false }
        return rules.isValid(trigger.steps) && ComboRules.times.contains(trigger.intervalMs)
    }

    /// The combo as a mapping for an engine, or nil when none is set. The placeholder action never runs.
    static func mapping(_ trigger: SwitchCombo?) -> Mapping? {
        guard let trigger, isValid(trigger) else { return nil }
        return Mapping(id: mappingID, enabled: true, actions: [.haptic(.light)], steps: trigger.steps, intervalMs: trigger.intervalMs)
    }

    /// `mappings` with the switch among them. Anything made of the same steps gives way, so
    /// the switch can always be made.
    static func adding(_ switcher: Mapping?, to mappings: [Mapping]) -> [Mapping] {
        guard let switcher else { return mappings }
        return mappings.filter { !sameSteps($0, switcher.steps ?? []) } + [switcher]
    }

    /// The gestures the combo is made of, with the taps and releases that arrive with them.
    /// The app that has the band takes these too, so the whole combo reaches one engine.
    static func reserved(_ switcher: Mapping?) -> Set<GestureKind> {
        Set((switcher?.steps ?? []).map(\.gesture)).withPartners
    }

    /// Whether a mapping is set off by exactly these steps.
    static func sameSteps(_ mapping: Mapping, _ steps: [ComboStep]) -> Bool {
        if let own = mapping.steps { return own == steps }
        return steps.count == 1 && mapping.motion == steps[0].gesture
    }
}
