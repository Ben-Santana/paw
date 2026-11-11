import SwiftUI

struct WristView: View {
    private static let entranceDuration = 1.0
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

    private var waiting: Bool { setting.busy }
    private var requested: Handedness? {
        switch setting.pending { case .write(let hand), .verify(let hand): hand; default: nil }
    }
    private var selected: Handedness? { requested ?? chosenHand }
    private var title: String {
        if waiting { return "Switching wrist" }
        if chosenHand != nil, let hand = setting.confirmed { return "\(hand == .left ? "Left" : "Right") wrist" }
        return setting.error == nil ? "Choose a wrist" : "Wrist not confirmed"
    }
    private var detail: String {
        if !connected { return "Connect your band to change its wrist setting." }
        if waiting { return "Checking your band’s setting…" }
        if let error = setting.error { return error }
        if let hand = setting.confirmed { return "Your band is set for your \(hand.rawValue) wrist." }
        return "Choose the wrist you’re wearing your band on."
    }

    var body: some View {
        let statusTitle = title
        let statusDetail = detail
        return ScrollView {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !visible || scenePhase != .active)) { context in
                let entry = enteredAt.map { min(1, max(0, context.date.timeIntervalSince($0) / Self.entranceDuration)) } ?? 1
                let progress = min(1, max(0, (entry - 0.16) / 0.18))
                let reveal = progress * progress * (3 - 2 * progress)
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Text("Choose your wrist").font(.display).tracking(-0.6)
                            .modifier(WristReveal(progress: reveal))
                        Text("Same gestures. Either hand.").font(.bodyText).foregroundStyle(Color.muted)
                            .modifier(WristReveal(progress: reveal))
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)
                    WristArtwork(state: frame(at: context.date),
                                 confirmed: connected && setting.confirmed != nil && setting.error == nil,
                                 moving: animating && !reduceMotion, entrance: entry,
                                 focus: chosenHand == nil ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: chosenHand == nil)
                        .padding(.top, 12)
                    VStack(spacing: 10) {
                        Text(statusTitle).font(.heading)
                            .modifier(WristReveal(progress: reveal))
                        Text(statusDetail).font(.bodyText).foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(WristReveal(progress: reveal))
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .padding(.top, 4)
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 12) {
                        option(.left, reveal: reveal)
                        option(.right, reveal: reveal)
                    }
                    .padding(.top, 24)
                    Text("Wear the band just above your wrist bone.")
                        .font(.caption).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .modifier(WristReveal(progress: reveal))
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.bottom, 32)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .page()
        .navigationTitle("Wrist").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            visible = true
            enteredAt = reduceMotion ? nil : Date()
            chosenHand = nil
            observedChange = setting.changeID
            showConfirmedHand()
        }
        .task {
            do { try await Task.sleep(for: .seconds(Self.entranceDuration)) } catch { return }
            enteredAt = nil
        }
        .onChange(of: setting) { _, _ in updateSetting() }
        .onChange(of: connected) { _, connected in if !connected { stop() } }
        .onChange(of: band) { _, _ in chosenHand = nil; stop(); showConfirmedHand() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onChange(of: reduceMotion) { _, _ in stop() }
        .onDisappear { visible = false; stop() }
    }

    private func option(_ hand: Handedness, reveal: Double) -> some View {
        let on = selected == hand
        return Button(hand == .left ? "Left" : "Right") { select(hand) }
        .buttonStyle(SecondaryButtonStyle(selected: on))
        .modifier(WristReveal(progress: reveal))
        .disabled(!connected || waiting || motion.active || enteredAt != nil || scenePhase != .active)
        .accessibilityLabel("\(hand == .left ? "Left" : "Right") wrist")
        .accessibilityValue(on ? (waiting ? "Checking" : setting.confirmed == hand ? "Confirmed" : "Not confirmed") : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var animating: Bool {
        visible && scenePhase == .active && motion.active
    }

    private func select(_ hand: Handedness) {
        guard connected, !waiting, !motion.active, enteredAt == nil, scenePhase == .active else { return }
        if setting.confirmed == hand && setting.error == nil {
            focus(on: hand)
            return
        }
        cancelCues()
        choose(hand)
    }

    private func focus(on hand: Handedness) {
        if chosenHand == nil { motion.rest(left: hand == .left, at: Date()) }
        chosenHand = hand
    }

    private func accepted(_ id: UUID?) {
        guard id != observedChange else { return }
        observedChange = id
        if setting.error != nil { stop(); showConfirmedHand(); return }
        guard visible, connected, scenePhase == .active, let id,
              let hand = requested ?? setting.confirmed else { return }
        cancelCues()
        enteredAt = nil
        acceptedChange = id; acceptedHand = hand
        focus(on: hand)
        motion.begin(left: hand == .left, at: Date())
    }

    private func updateSetting() {
        if setting.error != nil || (!setting.busy && setting.confirmed == nil) {
            observedChange = setting.changeID
            stop(); showConfirmedHand()
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
            return
        }
        feedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(orbitRemaining)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            feedback(.wrap, hand, id)
            do { try await Task.sleep(for: .seconds(WristMotion.landingDuration)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            feedback(.settle, hand, id)
            do { try await Task.sleep(for: .seconds(WristMotion.pulseDuration)) } catch { return }
            guard !Task.isCancelled, animatedChange == id else { return }
            motion.rest(left: hand == .left, at: Date())
        }
    }

    private func cancelCues() {
        feedbackTask?.cancel(); feedbackTask = nil
        if let id = acceptedChange { cancelFeedback(id) }
        animatedChange = nil; acceptedChange = nil; acceptedHand = nil
    }

    private func stop() {
        enteredAt = nil
        cancelCues()
        motion.rest(left: setting.confirmed.map { $0 == .left }, at: Date())
    }

    private func showConfirmedHand() {
        if chosenHand != nil, let hand = setting.confirmed { chosenHand = hand }
        motion.rest(left: setting.confirmed.map { $0 == .left }, at: Date())
    }

    private func frame(at date: Date) -> WristFrame {
        if reduceMotion {
            return WristFrame(handBlend: selected == .left ? 1 : 0)
        }
        var result = motion.frame(at: date)
        if !motion.active && setting.confirmed == nil { result.lift = 1 }
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
