import SwiftUI

/// Up to three applications pinned to the bottom of the home screen, in order, plus the
/// app waiting to take a slot when all three are full.
@MainActor
final class PinStore: ObservableObject {
    static let shared = PinStore()
    static let capacity = 3
    private static let key = "home.pinnedApps"

    @Published private(set) var pinned: [RunesApp] {
        didSet { UserDefaults.standard.set(pinned.map(\.rawValue).joined(separator: ","), forKey: Self.key) }
    }
    /// Set when the user pinned a fourth app; the home screen asks which pin it replaces.
    @Published var pending: RunesApp?

    init(pinned: [RunesApp]? = nil) {
        if let pinned {
            self.pinned = pinned
        } else {
            let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
            var seen: [RunesApp] = []
            for id in raw.split(separator: ",") {
                if let app = RunesApp(rawValue: String(id)), !seen.contains(app) { seen.append(app) }
            }
            self.pinned = Array(seen.prefix(Self.capacity))
        }
        #if DEBUG
        // Screenshots: RUNES_PENDING_PIN=<app id> opens the replace prompt straight away.
        if let id = ProcessInfo.processInfo.environment["RUNES_PENDING_PIN"], let app = RunesApp(rawValue: id) { pending = app }
        #endif
    }

    var isFull: Bool { pinned.count >= Self.capacity }
    func isPinned(_ app: RunesApp) -> Bool { pinned.contains(app) }

    /// Pins the app if there is room; otherwise remembers it so the home screen can ask.
    /// Returns true when it was pinned straight away.
    @discardableResult
    func pin(_ app: RunesApp) -> Bool {
        guard !isPinned(app) else { return true }
        if isFull { pending = app; return false }
        pinned.append(app)
        return true
    }

    func unpin(_ app: RunesApp) {
        pinned.removeAll { $0 == app }
    }

    /// Puts the pending app where `old` was.
    func replace(_ old: RunesApp) {
        guard let new = pending, let index = pinned.firstIndex(of: old) else { pending = nil; return }
        pinned[index] = new
        pending = nil
    }

    func cancelPending() { pending = nil }
}

/// Keeps a view swaying like an iOS home-screen icon in edit mode. Neighbours sway in
/// opposite directions so the row does not move as one block.
struct Jiggle: ViewModifier {
    let active: Bool
    var index: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swing = false

    private var direction: Double { index.isMultiple(of: 2) ? 1 : -1 }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active && !reduceMotion ? (swing ? 1.6 : -1.6) * direction : 0))
            .offset(y: active && !reduceMotion ? (swing ? -0.8 : 0.8) : 0)
            .task(id: active) {
                guard active, !reduceMotion else { withAnimation(.standard) { swing = false }; return }
                // Let the view settle before a repeating animation starts; starting one while
                // the view is still being inserted leaves a stale copy on screen.
                try? await Task.sleep(for: .milliseconds(120 + 40 * index))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { swing = true }
            }
    }
}

extension View {
    func jiggle(_ active: Bool, index: Int = 0) -> some View { modifier(Jiggle(active: active, index: index)) }
}
