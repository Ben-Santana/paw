import Foundation

/// The Mac app's sound library (src/soundSettings.ts, src/connectBell.ts): the same 32 voices,
/// with the same names, synthesized the same way so a voice sounds alike on both.
///
/// The Mac plays them live through Web Audio. Here each one is rendered offline to samples,
/// so it can be played instantly (and with the phone locked) from a buffer.
enum SoundVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case whole, pop, soft, lift, bell, hum, click, tick, pip, bells, tone, tap, wood, rim, pluck, marimba
    case kalimba, glass, sparkle, harp, sonar, bubble, droplet, chirp, blip, coin, laser, swoosh, warm, resolve, bounce, shimmer
    // Not sounds: these vibrate the band instead (`BandBuzz`).
    case bandBuzz, bandTap, bandDouble, bandTriple, bandLong, bandHeartbeat, bandRise, bandFade, bandFlutter

    var id: String { rawValue }

    /// The Mac's sounds, without the band vibrations.
    static let sounds = allCases.filter { $0.bandBuzz == nil }
    static let bandBuzzes = allCases.filter { $0.bandBuzz != nil }

    var bandBuzz: BandBuzz? {
        switch self {
        case .bandBuzz: .buzz
        case .bandTap: .tap
        case .bandDouble: .double
        case .bandTriple: .triple
        case .bandLong: .long
        case .bandHeartbeat: .heartbeat
        case .bandRise: .rise
        case .bandFade: .fade
        case .bandFlutter: .flutter
        default: nil
        }
    }

    var label: String {
        if let bandBuzz { return bandBuzz == .buzz ? "Vibrate band" : "Band " + bandBuzz.label.lowercased() }
        return switch self {
        case .whole: "Whole step"
        case .pop: "Pop"
        case .soft: "Soft"
        case .lift: "Lift"
        case .bell: "Bell"
        case .hum: "Hum"
        case .click: "Click"
        case .tick: "Tick"
        case .pip: "Pip"
        case .bells: "Bells"
        case .tone: "Tone"
        case .tap: "Tap"
        case .wood: "Wood block"
        case .rim: "Rimshot"
        case .pluck: "Pluck"
        case .marimba: "Marimba"
        case .kalimba: "Kalimba"
        case .glass: "Glass"
        case .sparkle: "Sparkle"
        case .harp: "Harp"
        case .sonar: "Sonar"
        case .bubble: "Bubble"
        case .droplet: "Droplet"
        case .chirp: "Chirp"
        case .blip: "Arcade blip"
        case .coin: "Coin"
        case .laser: "Laser"
        case .swoosh: "Swoosh"
        case .warm: "Warm chord"
        case .resolve: "Resolve"
        case .bounce: "Bounce"
        case .shimmer: "Shimmer"
        case .bandBuzz, .bandTap, .bandDouble, .bandTriple, .bandLong, .bandHeartbeat, .bandRise, .bandFade, .bandFlutter: ""
        }
    }
}

/// Renders a voice to mono samples. Mirrors connectBell.ts's `sine`, `tone`, `chime` and
/// `click` building blocks, including Web Audio's exponential ramps, then normalizes the
/// result so every voice peaks at the same level (the Mac's are very quiet by design).
struct SoundSynth {
    static let peak: Float = 0.7

    let rate: Double
    private(set) var samples: [Float] = []
    private var noise = SplitMix(seed: 0x52554E4553)

    init(rate: Double) { self.rate = rate }

    /// The voice at `frequency` (the Mac's default is 392 Hz, G4), normalized to `peak`.
    static func render(_ voice: SoundVoice, frequency: Double = 392, rate: Double = 44_100) -> [Float] {
        var synth = SoundSynth(rate: rate)
        synth.play(voice, frequency)
        let loudest = synth.samples.map(abs).max() ?? 0
        guard loudest > 0 else { return synth.samples }
        let gain = peak / loudest
        return synth.samples.map { $0 * gain }
    }

    // The voices, line for line with connectBell.ts `playVoice` (without its 12 ms lead-in).
    private mutating func play(_ voice: SoundVoice, _ f: Double) {
        let now = 0.0
        switch voice {
        case .whole: sine(now, f, 0.08, 0.008, 0.2)
        case .pop: sine(now, f, 0.07, 0.004, 0.09)
        case .soft: sine(now, f, 0.035, 0.05, 0.34)
        case .lift: sine(now, 392, 0.05, 0.08, 0.62, glideTo: 587.33)
        case .bell:
            sine(now, 523.25, 0.04, 0.09, 0.7)
            sine(now + 0.04, 659.25, 0.028, 0.1, 0.75)
        case .hum: sine(now, 311.13, 0.04, 0.12, 0.85)
        case .click:
            click(now, min(4200, f * 3), 0.055)
            chime(now, f, 0.05, 0.08)
        case .tick: click(now, 1600, 0.03)
        case .pip: sine(now, f, 0.04, 0.004, 0.07)
        // The connection voices, as played when the band connects.
        case .bells:
            tone(now, 523.25, 0.16, 0.9)
            tone(now, 784, 0.07, 0.55)
            tone(now, 1046.5, 0.035, 0.32)
        case .tone: tone(now, 392, 0.07, 0.55, glideTo: 523.25)
        case .tap: tone(now, 523.25, 0.06, 0.16)
        case .wood:
            sine(now, f * 0.75, 0.085, 0.002, 0.055)
            sine(now, f * 1.71, 0.025, 0.002, 0.028)
        case .rim:
            click(now, 2600, 0.12)
            sine(now, 880, 0.04, 0.002, 0.035)
        case .pluck:
            sine(now, f, 0.075, 0.003, 0.28)
            sine(now, f * 3, 0.018, 0.002, 0.065)
        case .marimba:
            sine(now, f * 0.5, 0.08, 0.003, 0.32)
            sine(now, f * 2, 0.025, 0.002, 0.07)
        case .kalimba:
            chime(now, f * 1.5, 0.065, 0.3)
            click(now, 3200, 0.018)
        case .glass:
            chime(now, f * 2, 0.045, 0.55)
            sine(now, f * 2.76, 0.015, 0.003, 0.25)
        case .sparkle:
            for (i, ratio) in [2, 2.5, 3].enumerated() { chime(now + Double(i) * 0.055, f * ratio, 0.035, 0.22) }
        case .harp:
            for (i, ratio) in [1, 1.25, 1.5, 2].enumerated() { sine(now + Double(i) * 0.045, f * ratio, 0.045, 0.004, 0.38) }
        case .sonar: sine(now, f * 2, 0.06, 0.015, 0.6)
        case .bubble: sine(now, f * 0.6, 0.08, 0.003, 0.12, glideTo: f * 1.8)
        case .droplet: sine(now, f * 3, 0.065, 0.002, 0.16, glideTo: f)
        case .chirp:
            sine(now, f * 2, 0.045, 0.004, 0.08, glideTo: f * 3)
            sine(now + 0.1, f * 2.5, 0.035, 0.004, 0.07, glideTo: f * 3.5)
        case .blip:
            tone(now, f, 0.06, 0.065)
            tone(now + 0.065, f * 2, 0.045, 0.085)
        case .coin:
            tone(now, 987.77, 0.055, 0.09)
            chime(now + 0.075, 1318.51, 0.05, 0.28)
        case .laser: sine(now, f * 4, 0.055, 0.003, 0.22, glideTo: f * 0.5)
        case .swoosh:
            for i in 0..<5 { click(now + Double(i) * 0.025, 700 + Double(i) * 650, 0.025 + Double(2 - abs(2 - i)) * 0.02) }
        case .warm:
            for ratio in [1, 1.25, 1.5] { sine(now, f * 0.5 * ratio, 0.025, 0.09, 0.55) }
        case .resolve:
            for (i, ratio) in [1, 1.25, 1.5, 2].enumerated() { chime(now + Double(i) * 0.075, f * ratio, 0.04, 0.35) }
        case .bounce:
            for i in 0..<3 {
                sine(now + Double(i) * 0.1, f * (1.5 - Double(i) * 0.25), 0.065 / Double(i + 1), 0.003, 0.08, glideTo: f * 0.75)
            }
        case .shimmer:
            for (i, ratio) in [2, 2.01, 3, 3.02].enumerated() { sine(now + Double(i) * 0.018, f * ratio, 0.018, 0.055, 0.65) }
        // Silent: played on the band, not the speaker.
        case .bandBuzz, .bandTap, .bandDouble, .bandTriple, .bandLong, .bandHeartbeat, .bandRise, .bandFade, .bandFlutter: break
        }
    }

    // MARK: Building blocks

    /// connectBell.ts `sine`: rises to `level` over `attack`, falls over `decay`; an optional
    /// glide takes min(decay, 0.28) s.
    private mutating func sine(_ when: Double, _ f: Double, _ level: Double, _ attack: Double, _ decay: Double, glideTo: Double? = nil) {
        partial(when, from: f, to: glideTo, glide: min(decay, 0.28), level: level, attack: attack, end: when + attack + decay)
    }

    /// connectBell.ts `tone`: an 8 ms attack, falling to silence by `decay`; the glide spans the decay.
    private mutating func tone(_ when: Double, _ f: Double, _ level: Double, _ decay: Double, glideTo: Double? = nil) {
        partial(when, from: f, to: glideTo, glide: decay, level: level, attack: 0.008, end: when + decay)
    }

    /// connectBell.ts `chime`: a fundamental and a quieter, shorter octave, each settling in pitch.
    private mutating func chime(_ when: Double, _ f: Double, _ level: Double, _ decay: Double) {
        for (ratio, share, length) in [(1.0, 1.0, 1.0), (2.0, 0.28, 0.62)] {
            partial(when, from: f * ratio * 0.985, to: f * ratio, glide: 0.028, level: max(0.0002, level * share),
                    attack: 0.005, end: when + decay * length)
        }
    }

    /// connectBell.ts `click`: 18 ms of decaying noise through a band-pass at `frequency` (Q 1.4).
    private mutating func click(_ when: Double, _ frequency: Double, _ level: Double) {
        let length = max(1, Int(rate * 0.018))
        let burst = (0..<length).map { i in noise.next() * pow(1 - Double(i) / Double(length), 2) }
        // RBJ band-pass, constant 0 dB peak gain (Web Audio's "bandpass").
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * 1.4)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        let start = Int(when * rate), count = Int(0.03 * rate)
        reserve(start + count)
        for i in 0..<count {
            let x = i < length ? burst[i] : 0
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            let t = Double(i) / rate
            let gain = t <= 0.022 ? level * pow(0.0001 / level, t / 0.022) : 0.0001
            samples[start + i] += Float(y * gain)
        }
    }

    /// One sine oscillator with Web Audio's exponential envelope: 0.0001 → `level` by
    /// `when + attack`, → 0.0001 by `end`, stopped shortly after.
    private mutating func partial(_ when: Double, from f0: Double, to f1: Double?, glide: Double, level: Double, attack: Double, end: Double) {
        let start = Int(when * rate), stop = Int((end + 0.03) * rate)
        reserve(stop)
        var phase = 0.0
        let floor = 0.0001, peakAt = when + attack
        for n in start..<stop {
            let t = Double(n) / rate, local = t - when
            let freq = f1.map { f0 * pow($0 / f0, min(1, local / max(glide, 1e-6))) } ?? f0
            let gain: Double
            if t < peakAt { gain = floor * pow(level / floor, local / max(attack, 1e-6)) }
            else if t < end { gain = level * pow(floor / level, (t - peakAt) / max(end - peakAt, 1e-6)) }
            else { gain = floor }
            samples[n] += Float(sin(phase) * gain)
            phase += 2 * .pi * freq / rate
        }
    }

    private mutating func reserve(_ count: Int) {
        if samples.count < count { samples += [Float](repeating: 0, count: count - samples.count) }
    }
}

/// A small seeded generator, so a click sounds the same every time it is rendered.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1
    }
}
