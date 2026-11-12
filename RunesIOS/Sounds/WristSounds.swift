import Foundation

/// The wrist screen's two sounds, rendered offline in stereo at 44.1 kHz.
///
/// - `rise`: a riser that travels from one wrist to the other as the beads fly. A soft,
///   detuned pad (near a triangle, so it never buzzes) glides up an octave on D (the
///   dominant) while its filter opens and it swells in; a band of air rises with it, and
///   the Swoosh voice lands it on arrival. Everything is kept under ~2 kHz, so it stays a
///   warm rush rather than an engine.
/// - `resolve`: the answer once the band confirms. A warm G major chord (the tonic, so the
///   riser's D resolves home), strummed from the bottom with a 4–3 suspension on top: the
///   C leans into the B. It sits toward the chosen wrist in a small, soft room.
///
/// Pure Foundation, so `Tools` can render it to WAV files for listening.
enum WristSounds {
    typealias Stereo = (left: [Float], right: [Float])

    static let rate = 44_100.0
    static let peak: Float = 0.7
    /// How far toward each edge the sounds sit (−1 is hard left).
    static let width = 0.85

    // MARK: Riser

    /// `length` seconds of rise ending on arrival at the `toLeft` (or right) wrist, then a
    /// short tail of room. `swoosh` is the Swoosh voice, played as it lands.
    static func rise(length: Double, toLeft: Bool, swoosh: [Float]) -> Stereo {
        let count = Int(length * rate)
        var mono = [Float](repeating: 0, count: count)
        var noise = Noise(seed: 0x57524953)

        // Pad: three soft voices a few cents apart, gliding D3 → D4, accelerating.
        let detunes = [-0.08, 0.0, 0.07] // semitones
        let harmonics: [(Double, Double)] = [(1, 1), (2, 0.22), (3, 0.08)]
        var phases = [Double](repeating: 0, count: detunes.count * harmonics.count)
        var filtered = 0.0, filtered2 = 0.0
        // Air: noise through a resonant band-pass whose centre climbs with the pad.
        var low = 0.0, band = 0.0
        for n in 0..<count {
            let t = Double(n) / Double(count)
            let base = 146.83 * pow(2, pow(t, 1.35))
            var saw = 0.0
            for (v, detune) in detunes.enumerated() {
                let f = base * pow(2, detune / 12)
                for (h, (k, share)) in harmonics.enumerated() {
                    let i = v * harmonics.count + h
                    saw += sin(phases[i]) * share
                    phases[i] += 2 * .pi * f * k / rate
                }
            }
            saw /= Double(detunes.count)
            // The filter opens as it rises, but only from dark to warm.
            let cutoff = 260 * pow(5, pow(t, 1.2))
            let k = 1 - exp(-2 * .pi * cutoff / rate)
            filtered += k * (saw - filtered)
            filtered2 += k * (filtered - filtered2)

            let centre = 450 * pow(3.5, t)
            let g = 2 * sin(.pi * min(centre, rate / 6) / rate)
            let x = noise.next()
            low += g * band
            let high = x - low - 0.55 * band
            band += g * high

            mono[n] = Float((filtered2 * 0.85 + band * 0.12 * t) * swell(t))
        }

        // The Swoosh lands it: its run of clicks ends as the beads arrive.
        let landing = count - Int(Double(swoosh.count) * 0.85)
        for i in swoosh.indices where landing + i >= 0 && landing + i < count {
            mono[landing + i] += swoosh[i] * 0.35
        }
        // Takes the edge off everything, the Swoosh's clicks included.
        mono = lowpass(lowpass(mono, cutoff: 1800), cutoff: 2400)

        let from = toLeft ? width : -width
        var out = place(mono) { n in
            let t = Double(n) / Double(count)
            return from - 2 * from * t * t * (3 - 2 * t)
        }
        out = room(out, wet: 0.2, tail: 1.1)
        return normalized(out)
    }

    /// Fades in slowly then builds hard, peaking just before arrival; a quick release
    /// leaves only the room.
    private static func swell(_ t: Double) -> Double {
        let top = 0.84
        if t < top { return pow(t / top, 2.3) }
        let r = (t - top) / (1 - top)
        return pow(1 - r, 1.6)
    }

    // MARK: Resolution

    /// The chord, voiced around the `toLeft` (or right) wrist.
    static func resolve(toLeft: Bool) -> Stereo {
        let length = 2.4
        let count = Int(length * rate)
        var left = [Float](repeating: 0, count: count), right = left
        let side = toLeft ? -0.45 : 0.45

        // (frequency, start, level, pan offset, held for)
        let notes: [(Double, Double, Double, Double, Double)] = [
            (98.00, 0.000, 0.30, 0.00, 2.0),    // G2, felt more than heard on a phone
            (196.00, 0.000, 0.55, -0.25, 2.0),  // G3
            (293.66, 0.024, 0.42, 0.10, 2.0),   // D4
            (392.00, 0.048, 0.34, -0.10, 2.0),  // G4
            (523.25, 0.072, 0.26, 0.25, 0.20),  // C5, the suspension
            (493.88, 0.230, 0.30, 0.25, 1.8),   // B4, where it resolves
        ]
        for (frequency, start, level, offset, held) in notes {
            // Two voices a few cents apart, one each way, for a gentle chorus.
            for (cents, spread) in [(-3.5, -0.2), (3.5, 0.2)] {
                let note = warm(frequency * pow(2, cents / 1200), level: level * 0.5, held: held)
                let pan = min(1, max(-1, side + offset + spread))
                let angle = (pan + 1) * .pi / 4
                let l = Float(cos(angle)), r = Float(sin(angle))
                let first = Int(start * rate)
                for i in note.indices where first + i < count {
                    left[first + i] += note[i] * l
                    right[first + i] += note[i] * r
                }
            }
        }
        let out = room((left, right), wet: 0.24, tail: 1.2)
        return normalized(out)
    }

    /// An electric-piano-like note: a soft attack, then each harmonic dying away faster
    /// than the one below, so it mellows as it rings. Released over 0.35 s after `held`.
    private static func warm(_ f: Double, level: Double, held: Double) -> [Float] {
        let release = 0.35
        let count = Int((held + release) * rate)
        let harmonics: [(Double, Double)] = [(1, 1), (2, 0.32), (3, 0.11), (4, 0.04)]
        var out = [Float](repeating: 0, count: count)
        let attack = 0.03
        for n in 0..<count {
            let t = Double(n) / rate
            let rise = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
            let fade = t < held ? 1 : max(0, 1 - (t - held) / release)
            var sample = 0.0
            for (k, share) in harmonics {
                sample += sin(2 * .pi * f * k * t) * share * exp(-t / (1.1 / pow(k, 0.8)))
            }
            out[n] = Float(sample * level * rise * fade * fade)
        }
        return out
    }

    // MARK: Space

    /// Places mono samples in stereo: `pan(n)` from −1 (left) to 1 (right), equal power,
    /// with the far ear up to 0.6 ms late.
    static func place(_ mono: [Float], pan: (Int) -> Double) -> Stereo {
        let lag = 0.0006 * rate
        var left = [Float](repeating: 0, count: mono.count), right = left
        for n in mono.indices {
            let p = min(1, max(-1, pan(n)))
            let angle = (p + 1) * .pi / 4
            let leftDelay = Int(max(0, p) * lag), rightDelay = Int(max(0, -p) * lag)
            if n >= leftDelay { left[n] = mono[n - leftDelay] * Float(cos(angle)) }
            if n >= rightDelay { right[n] = mono[n - rightDelay] * Float(sin(angle)) }
        }
        return (left, right)
    }

    /// A small, dark room (Schroeder: four damped combs into two all-passes per side, the
    /// sides tuned apart so the tail spreads wide), `tail` seconds added to the end.
    private static func room(_ dry: Stereo, wet: Float, tail: Double) -> Stereo {
        let count = dry.left.count + Int(tail * rate)
        func pad(_ x: [Float]) -> [Float] { x + [Float](repeating: 0, count: count - x.count) }
        let input = zip(dry.left, dry.right).map { ($0 + $1) * 0.5 }
        let source = pad(input)
        func side(_ spread: Int) -> [Float] {
            var sum = [Float](repeating: 0, count: count)
            for delay in [1116, 1188, 1277, 1356] {
                let d = delay + spread
                var line = [Float](repeating: 0, count: d), index = 0, damp: Float = 0
                for n in 0..<count {
                    let out = line[index]
                    damp += 0.45 * (out - damp)
                    line[index] = source[n] + damp * 0.8
                    index = (index + 1) % d
                    sum[n] += out
                }
            }
            for delay in [556, 441] {
                let d = delay + spread / 2
                var line = [Float](repeating: 0, count: d), index = 0
                for n in 0..<count {
                    let buffered = line[index]
                    let out = -sum[n] + buffered
                    line[index] = sum[n] + buffered * 0.5
                    index = (index + 1) % d
                    sum[n] = out
                }
            }
            return sum
        }
        let wl = side(0), wr = side(23)
        var left = pad(dry.left), right = pad(dry.right)
        for n in 0..<count {
            left[n] += wl[n] * wet * 0.25
            right[n] += wr[n] * wet * 0.25
        }
        return (left, right)
    }

    /// A one-pole low-pass at `cutoff` Hz (6 dB per octave).
    private static func lowpass(_ x: [Float], cutoff: Double) -> [Float] {
        let k = Float(1 - exp(-2 * .pi * cutoff / rate))
        var out = x, last: Float = 0
        for i in out.indices { last += k * (out[i] - last); out[i] = last }
        return out
    }

    private static func normalized(_ x: Stereo) -> Stereo {
        let loudest = max(x.left.map(abs).max() ?? 0, x.right.map(abs).max() ?? 0)
        guard loudest > 0 else { return x }
        let gain = peak / loudest
        return (x.left.map { $0 * gain }, x.right.map { $0 * gain })
    }
}

/// A small seeded generator, so the air sounds the same every time.
private struct Noise {
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
