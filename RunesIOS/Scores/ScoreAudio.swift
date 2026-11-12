import AVFoundation
import UIKit

/// Sounds for keeping score with the phone locked or in a pocket.
///
/// While a game is live this runs an audio engine that plays a looping silent buffer.
/// That keeps the app's audio session active (the `audio` background mode), so it keeps
/// running with the screen off and each cue plays the moment a band gesture arrives.
/// The session mixes with other audio, so music keeps playing underneath, and it uses
/// the playback category, so cues still sound with the ring/silent switch on silent.
/// The session itself is shared (`AudioHub`): Cook's bell and Capture's cues play
/// through `preview` here, and Capture may hold the session open for its microphone.
///
/// Each change plays a sound chosen in Score settings from the Mac's library (`SoundVoice`):
/// one for a point added, one for a point taken, and one per player when they are selected.
/// Players never share a sound, and each also has their own pitch.
@MainActor
final class ScoreAudio {
    static let shared = ScoreAudio()

    private var engine = AVAudioEngine()
    private var silence = AVAudioPlayerNode()
    private var cues = AVAudioPlayerNode()
    /// Stereo cues placed in space: the wrist screen's sweep from one wrist to the other.
    private var spatial = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private struct Key: Hashable { let voice: SoundVoice; let pitch: Double }
    private var rendered: [Key: AVAudioPCMBuffer] = [:]
    /// Stops the engine after a settings preview when no game is live.
    private var previewStop: Task<Void, Never>?
    private var previewSequence: Task<Void, Never>?
    private var pointCue: Task<Void, Never>?
    /// Who needs cues to play the moment they happen (a live game, a workout with sounds
    /// on); the engine is kept running (and restarted) only while someone does.
    private var holders: Set<String> = []
    private var wanted: Bool { !holders.isEmpty }
    /// Plays a band vibration chosen in place of a sound (set by `SessionController`).
    var onBandBuzz: ((BandBuzz) -> Void)?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
        attach()
    }

    // MARK: Control

    /// Starts the silent loop when a game goes live (or a workout with sounds starts),
    /// stops it when the last of them ends.
    func setLive(_ live: Bool, for holder: String = "score") {
        if live { holders.insert(holder) } else { holders.remove(holder) }
        if wanted { ensureRunning() } else { stop() }
    }

    /// Plays a sound right away: through the running engine while someone holds it live,
    /// otherwise as a one-off like a settings preview.
    func cue(_ voice: SoundVoice, pitch: Double = 392, volume: Double) {
        if wanted { play(voice, pitch: pitch, volume: volume) } else { preview(voice, pitch: pitch, volume: volume) }
    }

    /// Plays a stereo pair (44.1 kHz, equal lengths) through the running engine, cutting off
    /// the stereo cue before it. Silent unless someone holds the engine live.
    func cue(left: [Float], right: [Float], volume: Double) {
        guard wanted, !left.isEmpty, left.count == right.count else { return }
        ensureRunning()
        guard engine.isRunning else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(left.count))!
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        spatial.volume = Float(min(1, max(0, volume)))
        spatial.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !spatial.isPlaying { spatial.play() }
    }

    /// Plays the sound for a change to a live game.
    func play(_ cue: ScoreCue, with sounds: ScoreSounds) {
        guard wanted, sounds.on else { return }
        pointCue?.cancel()
        switch cue {
        case .point(let point):
            // After the point's own sound has mostly played, which a new cue would cut off.
            guard let voice = sounds.voice(for: point) else { return }
            pointCue = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.play(voice, pitch: 392, volume: sounds.volume)
            }
        case .add: if let voice = sounds.add { play(voice, pitch: 392, volume: sounds.volume) }
        case .subtract: if let voice = sounds.take { play(voice, pitch: 392, volume: sounds.volume) }
        case .select(let player):
            if let voice = sounds.player(player) { play(voice, pitch: ScoreSounds.pitch(player: player), volume: sounds.volume) }
        }
    }

    /// Plays a sound from settings, whether or not a game is live.
    func preview(_ voice: SoundVoice, pitch: Double = 392, volume: Double) {
        if !wanted {
            previewStop?.cancel()
            previewStop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if self?.wanted == false { self?.stop() }
            }
        }
        play(voice, pitch: pitch, volume: volume, force: true)
    }

    /// Plays a set of player sounds for players 1 to `players`, one after another.
    func preview(set: ScorePlayerSounds, players: Int, volume: Double) {
        previewSequence?.cancel()
        previewSequence = Task { [weak self] in
            for index in 0..<max(1, min(players, set.voices.count)) {
                guard !Task.isCancelled else { return }
                self?.preview(set.voices[index], pitch: ScoreSounds.pitch(player: index), volume: volume)
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private func play(_ voice: SoundVoice, pitch: Double, volume: Double, force: Bool = false) {
        if let buzz = voice.bandBuzz { onBandBuzz?(buzz); return }
        ensureRunning(force: force)
        guard engine.isRunning else { return }
        let key = Key(voice: voice, pitch: pitch)
        let buffer = rendered[key] ?? render(voice, pitch: pitch)
        rendered[key] = buffer
        cues.volume = Float(min(1, max(0, volume)))
        cues.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !cues.isPlaying { cues.play() }
    }

    private func ensureRunning(force: Bool = false) {
        guard wanted || force, !engine.isRunning else { return }
        do {
            try AudioHub.activate("score")
            try engine.start()
            silence.scheduleBuffer(silentBuffer(), at: nil, options: .loops)
            silence.play()
            cues.play()
            spatial.play()
        } catch {
            // Starting from the background can be refused; it is retried when the app is
            // next active, after an interruption, or on the next cue.
        }
    }

    private func stop() {
        silence.stop(); cues.stop(); spatial.stop(); engine.stop()
        AudioHub.release("score")
    }

    private func attach() {
        engine.attach(silence); engine.attach(cues); engine.attach(spatial)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
        engine.connect(cues, to: engine.mainMixerNode, format: format)
        engine.connect(spatial, to: engine.mainMixerNode, format: stereo)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A route change (headphones, Bluetooth) stops the engine; start it again.
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
    }

    /// After the media server resets every audio object is invalid; make new ones.
    private func rebuild() {
        engine = AVAudioEngine(); silence = AVAudioPlayerNode(); cues = AVAudioPlayerNode(); spatial = AVAudioPlayerNode()
        attach()
        ensureRunning()
    }

    // MARK: Synthesis

    private func silentBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))!
        buffer.frameLength = buffer.frameCapacity // zero-filled
        return buffer
    }

    private func render(_ voice: SoundVoice, pitch: Double) -> AVAudioPCMBuffer {
        buffer(SoundSynth.render(voice, frequency: pitch, rate: format.sampleRate))
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
