import AVFoundation

/// A finished recording.
struct CaptureClip: Sendable {
    var url: URL
    var duration: Double
    /// The loudest sample of each 50 ms.
    var peaks: [Float]
}

enum CaptureFailure: Error { case noMicrophone }

/// The microphone. While it runs, sound arrives all the time; it is thrown away except
/// for the last second, until `begin` opens a file, and then written (that last second
/// first, so the word spoken while the hold was being recognised is kept) until `end`.
///
/// It runs all the time in pocket mode because iOS only lets an app keep recording in the
/// background, never start: the microphone must already be open when the hold arrives.
///
/// Engine control happens on the main actor; samples arrive on the audio thread and meet
/// it under `lock`.
final class CaptureRecorder: @unchecked Sendable {
    private var engine = AVAudioEngine()
    /// Plays Capture's own cues through the same engine. A second engine starting beside
    /// this one reconfigures the hardware, which would interrupt the recording it announces.
    private var player = AVAudioPlayerNode()
    private let cueFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var wired = false
    private var observer: NSObjectProtocol?
    private let lock = NSLock()

    // Guarded by `lock`.
    private var rate = 48_000.0
    private var ring: [Float] = []
    private var ringHead = 0
    private var ringFilled = 0
    private var file: AVAudioFile?
    private var url: URL?
    private var frames = 0
    private var peaks: [Float] = []
    private var peak: Float = 0
    private var peakFrames = 0
    private var lastLevel = 0.0
    private var metering = true

    /// The microphone level, 0...1, about twenty times a second while `measuresLevel` is on.
    /// Called on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Off while nobody can see the meter (Runes in the background), so the audio thread
    /// doesn't scan each buffer and wake the main thread for it.
    var measuresLevel: Bool {
        get { lock.withLock { metering } }
        set { lock.withLock { metering = newValue } }
    }
    /// The route changed (headphones in or out) and the engine stopped. Called on the main thread.
    var onRouteChange: (@MainActor () -> Void)?

    var isRunning: Bool { engine.isRunning }
    var isWriting: Bool { lock.withLock { file != nil } }

    /// Opens the microphone. The audio session must already be recording (`AudioHub`).
    @MainActor func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.noMicrophone }
        // A recording under way keeps its own rate; `restart` only gets here when they match.
        lock.withLock {
            guard file == nil, format.sampleRate != rate || ring.isEmpty else { return }
            rate = format.sampleRate
            ring = Array(repeating: 0, count: Int(format.sampleRate))
            ringHead = 0; ringFilled = 0
        }
        if !wired {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: cueFormat)
            wired = true
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in self?.ingest(buffer) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onRouteChange?() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        player.play()
    }

    @MainActor func stop() {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The hardware changed under the engine (headphones in or out, another engine
    /// starting). Gets it running again, keeping a recording under way going when the
    /// microphone still delivers the same rate. Returns false when it can't be kept: the
    /// caller then ends the recording and starts afresh.
    @MainActor func restart() throws -> Bool {
        // The engine stops itself only when the format really changed.
        if engine.isRunning { return true }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.noMicrophone }
        if lock.withLock({ file != nil && format.sampleRate != rate }) { return false }
        try start()
        return true
    }

    /// After the media server resets, every audio object is invalid; make a new engine.
    @MainActor func rebuild() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine = AVAudioEngine(); player = AVAudioPlayerNode(); wired = false
    }

    /// Plays a short sound through the open engine. False when the engine isn't running.
    @MainActor func play(_ samples: [Float], volume: Float) -> Bool {
        guard engine.isRunning, wired, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: cueFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        return true
    }

    /// Starts keeping sound, beginning with up to `preroll` seconds from before now.
    func begin(to url: URL, preroll: Double) throws {
        try lock.withLock {
            guard file == nil else { return }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                           AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            let new = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            frames = 0; peaks = []; peak = 0; peakFrames = 0
            let wanted = min(ringFilled, Int(preroll * rate))
            if wanted > 0 {
                var earlier = [Float](repeating: 0, count: wanted)
                for i in 0..<wanted { earlier[i] = ring[(ringHead - wanted + i + ring.count) % ring.count] }
                earlier.withUnsafeBufferPointer { write($0, to: new) }
            }
            ringFilled = 0
            file = new; self.url = url
        }
    }

    /// Stops keeping sound and returns what was recorded, or nil when nothing was being kept.
    func end() -> CaptureClip? {
        let finished: (AVAudioFile, URL, Int, [Float], Double)? = lock.withLock {
            guard let file, let url else { return nil }
            if peakFrames > 0 { peaks.append(peak) }
            let result = (file, url, frames, peaks, rate)
            self.file = nil; self.url = nil
            return result
        }
        guard let (file, url, frames, peaks, rate) = finished else { return nil }
        file.close()
        return CaptureClip(url: url, duration: Double(frames) / rate, peaks: peaks)
    }

    // MARK: Audio thread

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        let report: Bool = lock.withLock {
            if let file {
                write(samples, to: file)
            } else if !ring.isEmpty {
                for sample in samples { ring[ringHead] = sample; ringHead = (ringHead + 1) % ring.count }
                ringFilled = min(ring.count, ringFilled + samples.count)
            }
            guard metering else { return false }
            let now = CACurrentMediaTime()
            guard now - lastLevel >= 0.05 else { return false }
            lastLevel = now
            return true
        }
        guard report, let onLevel else { return }
        var loudest: Float = 0
        for sample in samples { loudest = max(loudest, abs(sample)) }
        onLevel(loudest)
    }

    /// Appends mono samples to the file and to the waveform. Called with `lock` held.
    private func write(_ samples: UnsafeBufferPointer<Float>, to file: AVAudioFile) {
        guard let base = samples.baseAddress, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData else { return }
        target[0].update(from: base, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard (try? file.write(from: buffer)) != nil else { return }
        frames += samples.count
        let slice = max(1, Int(rate / 20))
        for sample in samples {
            peak = max(peak, abs(sample)); peakFrames += 1
            if peakFrames >= slice { peaks.append(peak); peak = 0; peakFrames = 0 }
        }
    }
}
