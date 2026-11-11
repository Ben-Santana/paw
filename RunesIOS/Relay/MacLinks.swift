import Foundation

/// The iPhone app's view of its Macs. Views observe `MacLinks.shared`; nothing here talks about protocol details.
///
///     @ObservedObject var links = MacLinks.shared
///     links.macs          // each paired Mac and whether it is connected
///     links.pairing       // progress after scanning a Mac's code
///     try links.pair(qrText)
///     links.remove(mac.id)
@MainActor
final class MacLinks: ObservableObject {
    nonisolated static let shared = MacLinks()
    nonisolated private init() {}

    struct Mac: Identifiable, Equatable, Sendable {
        enum State: String, Sendable {
            case connected, connecting, sleeping, notNearby
            /// The Mac removed this iPhone. Remove the Mac here and pair again.
            case forgotten
            /// The Mac runs a newer relay version.
            case needsUpdate
        }
        let id: UUID
        var name: String
        var state: State
        var lastConnected: Date?
        /// The link is running over the cable instead of Bluetooth.
        var cable = false

        var statusText: String {
            switch state {
            case .connected: return cable ? "Connected by cable" : "Connected"
            case .connecting: return "Looking for \(name)…"
            case .sleeping: return "\(name) is asleep"
            case .notNearby: return "\(name) isn't nearby"
            case .forgotten: return "\(name) removed this iPhone. Remove it here, then pair again."
            case .needsUpdate: return "Update Runes on this iPhone to use \(name)."
            }
        }
    }

    enum Pairing: Equatable, Sendable {
        case idle
        /// Looking for the Mac that showed the code.
        case searching(macName: String)
        /// Connected; iOS may show a Bluetooth pairing request now.
        case confirming(macName: String)
        case paired(macName: String)
        case failed(String)
    }

    @Published private(set) var macs: [Mac] = []
    @Published private(set) var pairing: Pairing = .idle
    /// Each Mac's gesture assignments, as it last sent them. Kept between launches.
    @Published private(set) var macBindings: [UUID: [RelayWire.Binding]] = MacLinks.loadBindings()
    private static let bindingsKey = "relayMacBindings.v1"

    private nonisolated static func loadBindings() -> [UUID: [RelayWire.Binding]] {
        guard let data = UserDefaults.standard.data(forKey: bindingsKey),
              let saved = try? JSONDecoder().decode([UUID: [RelayWire.Binding]].self, from: data) else { return [:] }
        return saved
    }

    /// What paired Macs do with a gesture or combo, one line each: “Swipe left” in Work: ⌘ + ].
    func macUses(_ trigger: String) -> [(mac: String, binding: RelayWire.Binding)] {
        macs.flatMap { mac in (macBindings[mac.id] ?? []).filter { $0.trigger == trigger }.map { (mac.name, $0) } }
    }
    private weak var relay: PhoneRelay?

    var isConnected: Bool { macs.contains { $0.state == .connected } }

    /// One line for compact status, matching `SessionController.relayStatus`.
    var summary: String {
        if case .searching(let name) = pairing { return "Looking for \(name)…" }
        if case .failed(let message) = pairing, macs.isEmpty { return message }
        if case .confirming(let name) = pairing { return "Pairing with \(name)…" }
        if macs.isEmpty { return "Pair a Mac to begin." }
        let connected = macs.filter { $0.state == .connected }.map(\.name)
        if !connected.isEmpty { return "Connected to \(connected.joined(separator: ", "))" }
        return macs[0].statusText
    }

    /// Accepts the text of a Mac's QR code.
    func pair(_ text: String) throws {
        let invitation = try RelayWire.Invitation.parse(text)
        relay?.pair(invitation)
    }

    func cancelPairing() { relay?.cancelPairing() }

    /// Forgets the Mac on this iPhone, and tells the Mac when it is connected.
    func remove(_ id: UUID) { relay?.remove(id) }

    nonisolated func attach(_ relay: PhoneRelay) {
        Task { @MainActor in self.relay = relay }
    }

    nonisolated func publish(bindings: [RelayWire.Binding]?, for mac: UUID) {
        Task { @MainActor in
            if let bindings { self.macBindings[mac] = bindings } else { self.macBindings.removeValue(forKey: mac) }
            if let data = try? JSONEncoder().encode(self.macBindings) { UserDefaults.standard.set(data, forKey: Self.bindingsKey) }
        }
    }

    nonisolated func publish(macs: [Mac], pairing: Pairing) {
        Task { @MainActor in
            if self.macs != macs { self.macs = macs }
            if self.pairing != pairing { self.pairing = pairing }
        }
    }
}
