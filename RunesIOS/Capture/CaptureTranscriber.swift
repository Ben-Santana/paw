import AVFoundation
import Speech

/// Turns a recording into words on the phone. Nothing is sent anywhere: this uses the
/// system's on-device speech models, which iOS downloads once per language.
enum CaptureTranscriber {
    enum Failure: Error {
        /// No on-device model for the phone's language.
        case unsupported
        /// The recording couldn't be turned into the sound format the model reads.
        case unreadable
    }

    static func transcribe(_ url: URL, locale: Locale = .current) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        // The newer model reads long, natural speech best; the dictation model covers more languages.
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            do { return try await run(transcriber, on: file) { String($0.text.characters) } }
            catch Failure.unsupported { file.framePosition = 0 }
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
            return try await run(transcriber, on: file) { String($0.text.characters) }
        }
        #if DEBUG
        NSLog("Capture transcription: no speech model for %@ (transcriber available: %d, its locales: %d, dictation locales: %d)", locale.identifier,
              SpeechTranscriber.isAvailable ? 1 : 0, await SpeechTranscriber.supportedLocales.count, await DictationTranscriber.supportedLocales.count)
        #endif
        throw Failure.unsupported
    }

    private static func run<Module: SpeechModule>(_ module: Module, on file: AVAudioFile,
                                                  text: @escaping @Sendable (Module.Result) -> String) async throws -> String {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        // The model reads its own format (16 kHz, 16-bit), not the recording's.
        var best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        if best == nil { best = await module.availableCompatibleAudioFormats.first }
        guard let format = best else {
            #if DEBUG
            NSLog("Capture transcription: the model offers no audio format (assets: %@)", String(describing: await AssetInventory.status(forModules: [module])))
            #endif
            throw Failure.unsupported
        }
        let inputs = try convert(file, to: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        let words = Task {
            var pieces: [String] = []
            for try await result in module.results { pieces.append(text(result)) }
            return pieces.joined()
        }
        do {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            for input in inputs { continuation.yield(input) }
            continuation.finish()
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            words.cancel()
            throw error
        }
        return try await words.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole recording in the model's format, a third of a second at a time. A note is
    /// five minutes at most, so this stays under ten megabytes.
    private static func convert(_ file: AVAudioFile, to format: AVAudioFormat) throws -> [AnalyzerInput] {
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: format) else { throw Failure.unreadable }
        let chunk: AVAudioFrameCount = 16_384
        let capacity = AVAudioFrameCount(Double(chunk) * format.sampleRate / source.sampleRate) + 256
        var inputs: [AnalyzerInput] = []
        var ended = false
        while !ended {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.unreadable }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                guard !ended, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else {
                    ended = true
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return buffer
            }
            if let failure { throw failure }
            if output.frameLength > 0 { inputs.append(AnalyzerInput(buffer: output)) }
            if status == .error || (status == .endOfStream && output.frameLength == 0) { break }
        }
        return inputs
    }
}
