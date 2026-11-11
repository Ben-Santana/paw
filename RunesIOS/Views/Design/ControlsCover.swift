import SwiftUI

/// What a running app's screen looks like while the regular mappings have the band: the
/// whole screen blurs, then the Runes mark fades in over it, so it is plain that the app's
/// gestures aren't its own just now. With the app's controls selected nothing is added and
/// the screen is as it always was. Touching the cover hands the band back to the app, as
/// the switch-controls combo does.
///
/// Everything here is always in the tree and only its blur and opacity change. Putting the
/// cover in and taking it out again made it arrive as a hard-edged box.
private struct RegularControlsCover: ViewModifier {
    /// Whether the screen in front belongs to the running app.
    let active: Bool
    @ObservedObject private var controls = ControlSwitch.shared

    /// The blur goes first and the mark follows; leaving, the mark goes first.
    private static let blurIn = Animation.easeOut(duration: 0.22)
    private static let markIn = Animation.easeOut(duration: 0.18).delay(0.16)
    private static let markOut = Animation.easeIn(duration: 0.1)
    private static let blurOut = Animation.easeOut(duration: 0.2).delay(0.06)

    func body(content: Content) -> some View {
        let covered = active && controls.regular
        ZStack {
            // Opaque, so the blur doesn't fade to nothing at the edges of the screen.
            content
                .blur(radius: covered ? 16 : 0, opaque: true)
                .ignoresSafeArea()
                .allowsHitTesting(!covered)
                .accessibilityHidden(covered)
                .animation(covered ? Self.blurIn : Self.blurOut, value: covered)
            Color.paper.opacity(covered ? 0.35 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(covered ? Self.blurIn : Self.blurOut, value: covered)
            LucideIcon(profile: ProfileIcon.logo, size: 88, lineWidth: 1.25)
                .foregroundStyle(Color.ink)
                .opacity(covered ? 1 : 0)
                .allowsHitTesting(false)
                .animation(covered ? Self.markIn : Self.markOut, value: covered)
            if covered {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture { controls.select(regular: false) }
                    .accessibilityElement()
                    .accessibilityLabel("Regular controls")
                    .accessibilityHint("Gives the band back to this app.")
                    .accessibilityAddTraits(.isButton)
                    .transition(.identity)
            }
        }
        .sensoryFeedback(.selection, trigger: covered)
    }
}

extension View {
    /// Blurs the screen behind the Runes mark while the regular controls are selected and
    /// `active` says a running app's screen is in front.
    func regularControlsCover(active: Bool) -> some View { modifier(RegularControlsCover(active: active)) }
}

// MARK: Setting

/// The switch-controls combo as a row. It is one setting, shown in Mappings and in each
/// app's settings, and it opens the same sheet from all of them.
struct SwitchControlsRow: View {
    @ObservedObject private var mappings = MappingStore.shared
    @State private var choosing = false

    var body: some View {
        TriggerRow(title: "Switch controls", detail: "Hands the band to your regular mappings while an app runs, and back.",
                   steps: mappings.library.switchControls?.steps) { choosing = true }
            .sheet(isPresented: $choosing) { SwitchControlsSheet() }
    }
}

/// The row with a heading, for an app's settings.
struct SwitchControlsBlock: View {
    var body: some View {
        Block {
            SwitchControlsRow()
        } header: {
            Heading("Regular controls")
        } footer: {
            Note("One combo for Workouts, Score and Cook, whichever profile is active. Make it while one of them runs and your mappings work again; make it again to go back. The app keeps running either way.")
        }
    }
}

/// Builds the switch-controls combo: two to eight finger and swipe steps that nothing else uses.
struct SwitchControlsSheet: View {
    @ObservedObject private var mappings = MappingStore.shared

    var body: some View {
        let current = mappings.library.switchControls
        TriggerSheet(title: "Switch controls",
                     caption: "While Workouts, Score or Cook is running, this combo hands the band to your regular mappings, and back to the app. It is the same in every profile.",
                     rules: SwitchControls.rules, steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                     feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                     blocked: { ControlSwitch.shared.taken($0) }, checksSwitch: false,
                     save: { steps, interval in
            mappings.setSwitchControls(steps.isEmpty ? nil : SwitchCombo(steps: steps, intervalMs: interval))
        })
    }
}
