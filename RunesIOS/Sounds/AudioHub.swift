import AVFoundation

/// The app's one audio session, shared by everything that makes or records sound: Score's
/// cues, Cook's bell and Capture's microphone. Each asks for the session by name and gives
/// it back when done; it is switched off only when nobody holds it. While Capture needs
/// the microphone the session records as well as plays, whoever else is using it.
@MainActor
enum AudioHub {
    enum Microphone: Sendable { case phone, headset }

    private static var holders: Set<String> = []
    /// Non-nil while something records.
    private(set) static var microphone: Microphone?

    static func setMicrophone(_ value: Microphone?) {
        guard value != microphone else { return }
        microphone = value
        // Others already playing carry on in the new category.
        if !holders.isEmpty { try? configure() }
    }

    /// Makes the session active for `holder`. Can be refused in the background; callers retry.
    static func activate(_ holder: String) throws {
        try configure()
        try AVAudioSession.sharedInstance().setActive(true)
        holders.insert(holder)
    }

    /// The buffer length asked for before `setLongBuffers(true)`, to go back to; nil while
    /// buffers are normal.
    private static var normalBuffer: TimeInterval?

    /// Asks the hardware for sound in 100 ms chunks instead of the usual few milliseconds,
    /// so the processor can sleep between them. For an open microphone nobody is watching
    /// (pocket mode with Runes in the background); it delays sounds played meanwhile by
    /// about as much.
    static func setLongBuffers(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        if on {
            guard normalBuffer == nil else { return }
            let preferred = session.preferredIOBufferDuration
            normalBuffer = preferred > 0 ? preferred : session.ioBufferDuration
            try? session.setPreferredIOBufferDuration(0.1)
        } else if let normal = normalBuffer {
            normalBuffer = nil
            try? session.setPreferredIOBufferDuration(normal)
        }
    }

    static func release(_ holder: String) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Playback that mixes with music, audible with the silent switch on. With a
    /// microphone it also records: from the phone, so headphones keep playing music at
    /// full quality, or from the headset when asked.
    private static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        let category: AVAudioSession.Category
        if let microphone {
            category = .playAndRecord
            options.formUnion([.defaultToSpeaker, .allowBluetoothA2DP])
            if microphone == .headset { options.insert(.allowBluetoothHFP) }
        } else {
            category = .playback
        }
        guard session.category != category || session.categoryOptions != options else { return }
        try session.setCategory(category, mode: .default, options: options)
    }
}
