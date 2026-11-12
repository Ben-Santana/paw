import AudioToolbox
import UIKit

/// The phone's buzz for each change to the score, when it is turned on in Score settings
/// (off unless chosen). A point added is one tap, a point taken away two, a reset a firmer
/// two, and selecting a player a light tick, so the score can be kept by feel.
///
/// On screen these are short taps from the haptic engine. With the screen off (a live game
/// kept from the band, the app held awake by `ScoreAudio`) iOS gives apps no haptics, so
/// the system vibration stands in: once for a point, twice for one taken away.
@MainActor
final class ScoreBuzz {
    static let shared = ScoreBuzz()

    enum Kind: Hashable {
        case add, subtract, reset, select, live

        /// What changed from `old` to `new`, as `ScoreCue` reads it, plus a reset and a game
        /// starting or ending. Nil when nothing worth a buzz changed.
        init?(from old: ScoreGame, to new: ScoreGame) {
            let samePlayers = old.players.map(\.id) == new.players.map(\.id)
            if samePlayers, new.progress != old.progress {
                self = new.progress > old.progress ? .add : new.isEmpty && !old.isEmpty ? .reset : .subtract
            } else if old.live != new.live {
                self = .live
            } else if samePlayers, old.selected != new.selected {
                self = .select
            } else {
                return nil
            }
        }
    }

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private var pending: Task<Void, Never>?

    private init() {}

    func play(_ kind: Kind) {
        guard UIApplication.shared.applicationState == .active else { return vibrate(kind) }
        pending?.cancel()
        switch kind {
        case .add: medium.impactOccurred()
        case .subtract: twice(light, gap: 0.09)
        case .reset: twice(rigid, gap: 0.12)
        case .select: selection.selectionChanged()
        case .live: light.impactOccurred()
        }
    }

    private func twice(_ generator: UIImpactFeedbackGenerator, gap: Double) {
        generator.impactOccurred()
        pending = Task {
            try? await Task.sleep(for: .seconds(gap))
            guard !Task.isCancelled else { return }
            generator.impactOccurred()
        }
    }

    /// The only buzz iOS allows in the background. It is long, so selecting is left silent.
    private func vibrate(_ kind: Kind) {
        let count: Int
        switch kind {
        case .add, .live: count = 1
        case .subtract, .reset: count = 2
        case .select: return
        }
        pending?.cancel()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        guard count > 1 else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
}
