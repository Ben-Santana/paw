import UIKit

/// What the wrist screen sounds and feels like on the phone. Two sounds, both placed in
/// stereo space (`WristSounds`): a riser that swells and climbs as it travels from one
/// wrist to the other with the beads, and a warm chord that resolves on the chosen wrist
/// once the band confirms. Haptics mark the steps in between. The band's own buzzes are
/// `WristFeedbackPhase`.
@MainActor
final class WristCues {
    static let shared = WristCues()

    private static let volume = 0.6
    private static let rate = 44_100.0

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notice = UINotificationFeedbackGenerator()
    private var swoosh: [Float] = []
    private var chords: [Bool: WristSounds.Stereo] = [:]
    private var ticks: Task<Void, Never>?
    private var active = false

    private init() {}

    /// Keeps the sound engine running while the wrist screen is in front, so no cue has
    /// to wait for it to start.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        ScoreAudio.shared.setLive(on, for: "wrist")
        if on {
            render()
            [light, soft, rigid].forEach { $0.prepare() }
        } else {
            ticks?.cancel()
        }
    }

    /// A wrist was tapped and the change is on its way to the band.
    func tap() { light.impactOccurred() }

    /// The wrist tapped is the one already set.
    func nudge() {
        selection.selectionChanged()
        if active { ScoreAudio.shared.cue(.pip, pitch: 587.33, volume: 0.35) }
    }

    /// The beads set off toward the `left` (or right) wrist; `arrivals` are the seconds
    /// until each lands there.
    func flight(arrivals: [TimeInterval], left: Bool) {
        ticks?.cancel()
        guard active else { return }
        // Long enough to peak as the last bead lands, then let go.
        let length = min(2.6, max(0.9, (arrivals.last ?? 1.2) + 0.45))
        let (l, r) = WristSounds.rise(length: length, toLeft: left, swoosh: swoosh)
        ScoreAudio.shared.cue(left: l, right: r, volume: Self.volume)
        let began = ContinuousClock.now
        ticks = Task { [soft] in
            for (index, time) in arrivals.enumerated() {
                do { try await Task.sleep(until: began + .seconds(time), clock: .continuous) } catch { return }
                soft.impactOccurred(intensity: 0.45 + 0.05 * Double(index))
            }
        }
    }

    /// The ring closed around the wrist.
    func wrap() { rigid.impactOccurred(intensity: 0.7) }

    /// The band confirmed the `left` (or right) wrist.
    func settle(left: Bool) {
        notice.notificationOccurred(.success)
        guard active else { return }
        guard let (l, r) = chords[left] else { return }
        ScoreAudio.shared.cue(left: l, right: r, volume: Self.volume)
    }

    /// The change did not take.
    func refuse() {
        ticks?.cancel()
        notice.notificationOccurred(.error)
        if active { ScoreAudio.shared.cue(.soft, pitch: 196, volume: Self.volume) }
    }

    /// Stops the taps still to come; a sound already playing ends on its own.
    func cancel() { ticks?.cancel() }

    private func render() {
        guard swoosh.isEmpty else { return }
        swoosh = SoundSynth.render(.swoosh, rate: Self.rate)
        chords = [true: WristSounds.resolve(toLeft: true), false: WristSounds.resolve(toLeft: false)]
    }
}
