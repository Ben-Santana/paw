import Foundation

// Reels: Instagram's Reels page in a web view, moved through from the band. Instagram
// has no API for its Reels feed and iOS lets no app touch another app, so the page is
// instagram.com in Runes, signed in once, and each command is a short script run in it
// (`ReelsScript`). The band's gestures are Reels' only while its screen can be seen:
// a web view doesn't play with the phone locked, so then they go back to mappings.

/// What the band can do on the Reels screen.
enum ReelsCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case next, previous, pause, like, mute

    var id: String { rawValue }
    var title: String {
        switch self {
        case .next: "Next reel"
        case .previous: "Previous reel"
        case .pause: "Pause or play"
        case .like: "Like"
        case .mute: "Sound on or off"
        }
    }
    var detail: String {
        switch self {
        case .next: "Scrolls to the next reel."
        case .previous: "Scrolls back to the one before."
        case .pause: "Pauses the reel on screen, and plays it again."
        case .like: "Likes the reel on screen, or unlikes it."
        case .mute: "Turns the reel’s sound on or off."
        }
    }
}

/// Which gesture or combo does what on the Reels screen.
struct ReelsControls: Codable, Hashable, Sendable {
    var triggers: [ReelsCommand: CommandTrigger]

    /// Up and down scroll, as a thumb would on the screen. A watching hand is still, so
    /// the index finger's tap pauses; liking takes a double tap so it never happens by itself.
    static let standard = ReelsControls(triggers: [
        .next: .gesture(.swipeUp), .previous: .gesture(.swipeDown), .pause: .gesture(.tapIndex),
        .like: .gesture(.doubleTapMiddle), .mute: .gesture(.holdMiddle),
    ])
    private static let mappingPrefix = "reels:"

    /// Finger gestures and swipes. Motion and air steps would need the band's motion
    /// streams for as long as the screen is open.
    static let singleChoices = GestureKind.motions
    static func comboChoices(after steps: [ComboStep]) -> [GestureKind] {
        ComboRules.allowedNext(after: steps).filter { !$0.isMotion && !$0.isAir }
    }
    static var rules: TriggerRules { .gestureOrCombo(singleChoices, next: comboChoices, allowsNone: true) }

    func trigger(for command: ReelsCommand) -> CommandTrigger? { triggers[command] }
    func gesture(for command: ReelsCommand) -> GestureKind? { triggers[command]?.gesture }
    /// Assigns a trigger; a command that already had it takes this command's old one.
    mutating func setTrigger(_ trigger: CommandTrigger?, for command: ReelsCommand) { triggers.assign(trigger, to: command) }

    var reserved: Set<GestureKind> { triggers.reserved }
    var mappings: [Mapping] { triggers.mappings(prefix: Self.mappingPrefix) }
    func command(forMapping id: String) -> ReelsCommand? { triggers.command(forMapping: id, prefix: Self.mappingPrefix) }

    init(triggers: [ReelsCommand: CommandTrigger]) { self.triggers = triggers }
    private enum Keys: String, CodingKey { case triggers }
    init(from decoder: Decoder) throws {
        triggers = Dictionary(saved: try decoder.container(keyedBy: Keys.self).decode([String: CommandTrigger].self, forKey: .triggers))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(triggers.saved, forKey: .triggers)
    }
}

/// The gestures and the screen. The web view itself belongs to `ReelsScreen`, which
/// runs the commands this store decides on (`onCommand`).
@MainActor
final class ReelsStore: ObservableObject {
    static let shared = ReelsStore()
    private static let key = "runes.reels.v1"

    @Published private(set) var controls: ReelsControls { didSet { configureDecider() } }
    /// The last command and what came of it, shown briefly over the reel.
    @Published var flash: ReelsFlash?

    /// True while the Reels screen is in front with the app active; only then are the
    /// gestures Reels'.
    var onScreen = false { didSet { if onScreen != oldValue { onReserve?(reservedNow) } } }
    /// Told which gestures Reels holds.
    var onReserve: ((Set<GestureKind>) -> Void)? { didSet { onReserve?(reservedNow) } }
    /// Runs a command in the web view. Set by the screen while it is shown.
    var onCommand: ((ReelsCommand) -> Void)?

    private let decider = TriggerDecider()
    private var reservedNow: Set<GestureKind> { onScreen ? controls.reserved : [] }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ReelsControls.self, from: data) { controls = saved } else { controls = .standard }
        decider.onFire = { [weak self] id in
            guard let self, let command = self.controls.command(forMapping: id) else { return }
            self.perform(command)
        }
        configureDecider()
    }

    private func configureDecider() { decider.configure(controls.mappings) }

    func setTrigger(_ trigger: CommandTrigger?, for command: ReelsCommand) {
        controls.setTrigger(trigger, for: command)
        if let data = try? JSONEncoder().encode(controls) { UserDefaults.standard.set(data, forKey: Self.key) }
        onReserve?(reservedNow)
    }

    func perform(_ command: ReelsCommand) { onCommand?(command) }

    /// Takes a band gesture that is one of Reels' while its screen is in front.
    /// Returns false to let mappings handle it.
    func consume(_ gesture: BandGesture) -> Bool {
        guard onScreen, let kind = GestureKind(gesture), reservedNow.contains(kind) else { return false }
        decider.receive(kind)
        return true
    }

    /// What a script reported, as a word or two over the reel.
    func report(_ command: ReelsCommand, result: String?) {
        let text: String
        switch result {
        case "liked": text = "Liked"
        case "unliked": text = "Like removed"
        case "paused": text = "Paused"
        case "playing": text = "Playing"
        case "muted": text = "Sound off"
        case "unmuted": text = "Sound on"
        case "moved": text = command == .next ? "Next" : "Previous"
        case "end": text = command == .next ? "No more reels yet" : "This is the first reel"
        case "none": text = "Open a reel first"
        default: text = "Couldn’t find the \(command == .like ? "like button" : "reel")"
        }
        flash = ReelsFlash(text: text)
    }
}

struct ReelsFlash: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

/// The scripts each command runs in the page. Instagram's markup has no stable ids, so
/// they work from what every reel has: a `<video>`, the scrolling list it sits in, and a
/// like button labelled "Like" or "Unlike". Each returns one word for `ReelsStore.report`.
enum ReelsScript {
    static let reelsURL = URL(string: "https://www.instagram.com/reels/")!

    /// Instagram serves its full mobile site only to something that looks like Safari.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Helpers shared by every command: the reel nearest the middle of the screen, and
    /// the element that scrolls the list it is in.
    private static let helpers = """
    const videos = [...document.querySelectorAll('video')].filter(v => { const r = v.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
    const middle = innerHeight / 2;
    const distance = v => { const r = v.getBoundingClientRect(); return Math.abs((r.top + r.bottom) / 2 - middle); };
    const current = videos.sort((a, b) => distance(a) - distance(b))[0];
    const scroller = el => {
      for (let e = el && el.parentElement; e; e = e.parentElement) {
        const y = getComputedStyle(e).overflowY;
        if ((y === 'auto' || y === 'scroll') && e.scrollHeight > e.clientHeight + 10) return e;
      }
      return document.scrollingElement;
    };
    """

    static func source(for command: ReelsCommand) -> String {
        let body: String
        switch command {
        case .next, .previous:
            // One screen at a time: the list snaps a reel per screen.
            body = """
            if (!current) return 'none';
            const list = scroller(current);
            const before = list.scrollTop;
            const goal = before + \(command == .next ? 1 : -1) * list.clientHeight;
            if (goal < 0 && before <= 0) return 'end';
            list.scrollTo({ top: Math.max(0, goal), behavior: 'smooth' });
            return 'moved';
            """
        case .pause:
            body = """
            if (!current) return 'none';
            if (current.paused) { current.play(); return 'playing'; }
            current.pause(); return 'paused';
            """
        case .mute:
            body = """
            if (!current) return 'none';
            current.muted = !current.muted;
            if (!current.muted && current.volume === 0) current.volume = 1;
            return current.muted ? 'muted' : 'unmuted';
            """
        case .like:
            // The nearest like button above the reel's own video: walk out from it until
            // an ancestor holds one.
            body = """
            if (!current) return 'none';
            for (let e = current.parentElement; e; e = e.parentElement) {
              const icon = e.querySelector('svg[aria-label="Like"], svg[aria-label="Unlike"]');
              if (!icon) continue;
              const liked = icon.getAttribute('aria-label') === 'Unlike';
              const button = icon.closest('[role="button"], button') || icon.parentElement;
              button.click();
              return liked ? 'unliked' : 'liked';
            }
            return 'missing';
            """
        }
        return "(() => {\n\(helpers)\n\(body)\n})()"
    }

    /// Run when the screen goes away, so no reel keeps playing behind Runes.
    static let pauseAll = "document.querySelectorAll('video').forEach(v => v.pause()); 'paused'"
}
