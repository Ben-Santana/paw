import AVFoundation
import UIKit

/// Sounds for keeping score with the phone locked or in a pocket.
///
/// While a game is live this runs an audio engine that plays a looping silent buffer.
/// That keeps the app's audio session active (the `audio` background mode), so it keeps
/// running with the screen off and each cue plays the moment a band gesture arrives.
/// The session mixes with other audio, so music keeps playing underneath, and it uses
/// the playback category, so cues still sound with the ring/silent switch on silent.
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
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private struct Key: Hashable { let voice: SoundVoice; let pitch: Double }
    private var rendered: [Key: AVAudioPCMBuffer] = [:]
    /// Stops the engine after a settings preview when no game is live.
    private var previewStop: Task<Void, Never>?
    private var previewSequence: Task<Void, Never>?
    /// True while a game is live; the engine is kept running (and restarted) only then.
    private var wanted = false

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

    /// Starts the silent loop when a game goes live, stops it when the game ends.
    func setLive(_ live: Bool) {
        wanted = live
        if live { ensureRunning() } else { stop() }
    }

    /// Plays the sound for a change to a live game.
    func play(_ cue: ScoreCue, with sounds: ScoreSounds) {
        guard wanted, sounds.on else { return }
        switch cue {
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
            silence.scheduleBuffer(silentBuffer(), at: nil, options: .loops)
            silence.play()
            cues.play()
        } catch {
            // Starting from the background can be refused; it is retried when the app is
            // next active, after an interruption, or on the next cue.
        }
    }

    private func stop() {
        silence.stop(); cues.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func attach() {
        engine.attach(silence); engine.attach(cues)
        engine.connect(silence, to: engine.mainMixerNode, format: format)
        engine.connect(cues, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A route change (headphones, Bluetooth) stops the engine; start it again.
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
    }

    /// After the media server resets every audio object is invalid; make new ones.
    private func rebuild() {
        engine = AVAudioEngine(); silence = AVAudioPlayerNode(); cues = AVAudioPlayerNode()
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
        let samples = SoundSynth.render(voice, frequency: pitch, rate: format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
