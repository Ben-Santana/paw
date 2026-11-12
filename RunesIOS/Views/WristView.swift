import SwiftUI

struct WristView: View {
    private static let entranceDuration = 1.4
    private static let nudgeDuration = 0.5
    let setting: HandSetting
    let connected: Bool
    let band: UUID?
    let choose: (Handedness) -> Void
    let feedback: (WristFeedbackPhase, Handedness, UUID) -> Void
    let cancelFeedback: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var acceptedHand: Handedness?
    @State private var observedChange: UUID?
    @State private var visible = false
    @State private var enteredAt: Date?
    @State private var chosenHand: Handedness?
    @State private var acceptedChange: UUID?
    @State private var motion = WristMotion()
    @State private var feedbackTask: Task<Void, Never>?
    @State private var animatedChange: UUID?
    @State private var nudged: Date?

    init(setting: HandSetting, connected: Bool, band: UUID?, choose: @escaping (Handedness) -> Void,
         feedback: @escaping (WristFeedbackPhase, Handedness, UUID) -> Void, cancelFeedback: @escaping (UUID) -> Void) {
        self.setting = setting; self.connected = connected; self.band = band
        self.choose = choose; self.feedback = feedback; self.cancelFeedback = cancelFeedback
        // Opens on the wrist the band is set for, rather than moving there once on screen.
        _chosenHand = State(initialValue: setting.confirmed)
    }

    private var waiting: Bool { setting.busy }
    private var requested: Handedness? {
        switch setting.pending { case .write(let hand), .verify(let hand): hand; default: nil }
    }
    private var selected: Handedness? { requested ?? chosenHand }
    private var canSelect: Bool {
        connected && !waiting && !motion.active && enteredAt == nil && scenePhase == .active
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !visible || scenePhase != .active)) { context in
                let entry = enteredAt.map { min(1, max(0, context.date.timeIntervalSince($0) / Self.entranceDuration)) } ?? 1
                let progress = min(1, max(0, (entry - 0.16) / 0.18))
                let reveal = progress * progress * (3 - 2 * progress)
                let state = frame(at: context.date)
                VStack(spacing: 0) {
                    WristArtwork(state: state,
                                 confirmed: connected && setting.confirmed != nil && setting.error == nil,
                                 moving: animating && !reduceMotion, entrance: entry,
                                 focus: chosenHand == nil ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: chosenHand == nil)
                        .overlay {
                            HStack(spacing: 0) {
                                option(.left)
                                option(.right)
                            }
                        }
                        .overlay(alignment: .top) {
                            handLabels(blend: state.handBlend)
                                .modifier(WristReveal(progress: reveal))
                        }
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
        }
        }
        .scrollBounceBehavior(.basedOnSize)
        .page()
        .navigationTitle("Choose wrist").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            visible = true
            enteredAt = reduceMotion ? nil : Date()
            chosenHand = setting.confirmed
            observedChange = setting.changeID
            showConfirmedHand()
            WristCues.shared.setActive(scenePhase == .active)
        }
        .task {
            do { try await Task.sleep(for: .seconds(Self.entranceDuration)) } catch { return }
            enteredAt = nil
        }
        .onChange(of: setting) { _, _ in updateSetting() }
        .onChange(of: connected) { _, connected in if !connected { stop() } }
        .onChange(of: band) { _, _ in stop(); showConfirmedHand() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop() }
            WristCues.shared.setActive(visible && phase == .active)
        }
        .onChange(of: reduceMotion) { _, _ in stop() }
        .onDisappear { visible = false; stop(); WristCues.shared.setActive(false) }
    }

    /// The letters follow their hands: the chosen one darkens and leans in with it.
    private func handLabels(blend: Double) -> some View {
        GeometryReader { geometry in
            let spacing = min(82, geometry.size.width * 0.22)
            let lean = WristArtwork.focusLean * spacing / WristFlow.handOffset
            ForEach([("L", -1.0, blend), ("R", 1.0, 1 - blend)], id: \.0) { letter, side, share in
                let emphasis = chosenHand == nil ? 0 : share
                Text(letter)
                    .font(.geist(28, .semibold, relativeTo: .title))
                    .foregroundStyle(Color.faint.mix(with: .ink, by: emphasis))
                    .position(x: geometry.size.width / 2 + side * (spacing - lean * emphasis), y: geometry.size.height / 2)
            }
        }
        .frame(height: 40)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: chosenHand == nil)
        .accessibilityHidden(true)
    }

    private func option(_ hand: Handedness) -> some View {
        let on = selected == hand
        return Button { select(hand) } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .accessibilityLabel("\(hand == .left ? "Left" : "Right") wrist")
        .accessibilityValue(on ? (waiting ? "Checking" : setting.confirmed == hand ? "Confirmed" : "Not confirmed") : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var animating: Bool {
        visible && scenePhase == .active && motion.active
    }

    private func select(_ hand: Handedness) {
        guard canSelect else { return }
        if setting.confirmed == hand && setting.error == nil {
            focus(on: hand)
            nudged = Date()
            WristCues.shared.nudge()
            return
        }
        cancelCues()
        WristCues.shared.tap()
        choose(hand)
    }

    private func focus(on hand: Handedness) {
        if chosenHand == nil { motion.rest(left: hand == .left, at: Date()) }
        chosenHand = hand
    }

    private func accepted(_ id: UUID?) {
        guard id != observedChange else { return }
        observedChange = id
        if setting.error != nil { fail(); return }
        guard visible, connected, scenePhase == .active, let id,
              let hand = requested ?? setting.confirmed else { return }
        cancelCues()
        enteredAt = nil
        acceptedChange = id; acceptedHand = hand
        focus(on: hand)
        motion.begin(left: hand == .left, at: Date())
        if !reduceMotion { WristCues.shared.flight(arrivals: motion.arrivals(), left: hand == .left) }
    }

    private func updateSetting() {
        if setting.error != nil || (!setting.busy && setting.confirmed == nil) {
            observedChange = setting.changeID
            fail()
            return
        }
        accepted(setting.changeID)
        confirm(setting.confirmedChangeID)
        if !setting.busy && acceptedChange == nil { showConfirmedHand() }
    }

    private func confirm(_ id: UUID?) {
        guard let id, id == acceptedChange, let hand = setting.confirmed, hand == acceptedHand,
              animatedChange != id, visible, connected,
              scenePhase == .active, setting.error == nil else { return }
        animatedChange = id
        let now = Date()
        let orbitRemaining = motion.confirm(at: now)
        if reduceMotion {
            motion.rest(left: hand == .left, at: now)
            feedback(.settle, hand, id)
            WristCues.shared.settle(left: hand == .left)
            return
        }
        feedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(orbitRemaining)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            feedback(.wrap, hand, id)
            WristCues.shared.wrap()
            do { try await Task.sleep(for: .seconds(WristMotion.landingDuration)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            feedback(.settle, hand, id)
            WristCues.shared.settle(left: hand == .left)
            do { try await Task.sleep(for: .seconds(WristMotion.pulseDuration)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            motion.rest(left: hand == .left, at: Date())
        }
    }

    /// A change that was under way did not take; with nothing under way this only tidies up.
    private func fail() {
        if motion.active { WristCues.shared.refuse() }
        stop(); showConfirmedHand()
    }

    private func cancelCues() {
        feedbackTask?.cancel(); feedbackTask = nil
        WristCues.shared.cancel()
        if let id = acceptedChange { cancelFeedback(id) }
        animatedChange = nil; acceptedChange = nil; acceptedHand = nil
    }

    private func stop() {
        enteredAt = nil
        cancelCues()
        motion.rest(left: setting.confirmed.map { $0 == .left }, at: Date())
    }

    private func showConfirmedHand() {
        // Neither hand is chosen while the band's setting is unknown.
        if !setting.busy { chosenHand = setting.confirmed }
        motion.rest(left: setting.confirmed.map { $0 == .left }, at: Date())
    }

    private func frame(at date: Date) -> WristFrame {
        if reduceMotion {
            return WristFrame(handBlend: selected == .left ? 1 : 0)
        }
        var result = motion.frame(at: date)
        if !motion.active && setting.confirmed == nil { result.lift = 1 }
        if let nudged {
            let age = date.timeIntervalSince(nudged) / Self.nudgeDuration
            if age >= 0, age < 1 { result.pulse = max(result.pulse, WristMotion.swell(age) * 0.6) }
        }
        return result
    }
}

private struct WristReveal: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .accessibilityHidden(progress < 1)
    }
}
