import Foundation
import CoreBluetooth
import UIKit

/// Records when this process actually runs and what it is doing, for leases and diagnostics.
/// It notices suspension; it does nothing to prevent it.
final class WakeProbe: @unchecked Sendable {
    static let shared = WakeProbe()
    static let gapThreshold: TimeInterval = 3
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastTick: TimeInterval?
    private var applicationState = "launching"
    private var bandState = "disconnected"
    private var lastBandData: TimeInterval?

    /// Counts device sleep. `systemUptime` stops while the phone sleeps and would hide the gaps.
    private static var now: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    func start(onGap: @escaping @Sendable (String) -> Void) {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.runes.wake-probe"))
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            guard let self, let gap = self.tick() else { return }
            onGap(gap)
        }
        timer = source
        source.resume()
    }

    private func tick() -> String? {
        lock.lock(); defer { lock.unlock() }
        let time = Self.now
        defer { lastTick = time }
        guard let lastTick, time - lastTick >= Self.gapThreshold else { return nil }
        return String(format: "wake_probe gap seconds=%.1f state=%@ band=%@", time - lastTick, applicationState, bandState)
    }

    func setApplicationState(_ state: String) { lock.lock(); applicationState = state; lock.unlock() }
    func setBandState(_ state: String) { lock.lock(); bandState = state; lock.unlock() }
    func noteBandData() { lock.lock(); lastBandData = Self.now; lock.unlock() }

    var phoneState: RelayWire.PhoneState {
        lock.lock(); defer { lock.unlock() }
        let app: RelayWire.PhoneState.App
        switch applicationState {
        case "foreground", "inactive": app = .foreground
        case "background": app = .background
        case "launching": app = .launching
        default: app = .unknown
        }
        let band: RelayWire.PhoneState.Band
        switch bandState {
        case "streaming": band = .streaming
        case "disconnected", "failed", "enrollmentRequired": band = .disconnected
        default: band = .connecting
        }
        return .init(app: app, band: band)
    }
}

/// Holds the links to every paired Mac. The phone is the BLE central: a pending connect to each known Mac
/// never times out, so iOS completes it whenever the Mac is reachable, even with this app suspended.
/// Its queue and peripherals are independent of the band transport.
final class PhoneRelay: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    typealias Demand = RelayWire.Demand

    private enum Phase { case idle, connecting, discovering, bonding, subscribing, hello, live }

    private final class Link {
        var record: RelayKeyStore.Record
        let service: CBUUID
        let controlID: CBUUID, inboundID: CBUUID, bondID: CBUUID
        var peripheral: CBPeripheral?
        var control: CBCharacteristic?
        var inbound: CBCharacteristic?
        var phase = Phase.idle
        var epoch = 0
        var nonce: Data?
        var session: RelayWire.Session?
        var helloAttempts = 0
        var discoveryAttempts = 0
        var demand = Demand.idle
        var ready: Demand?
        var outgoing: [Outgoing] = []
        var state = MacLinks.Mac.State.connecting
        var lastConnected: Date?
        var deferred = false
        var assembler = RelayWire.BindingsAssembler()
        /// Sent after everything else queued, so gestures never wait behind them.
        var bindingsOut: [RelayWire.Message] = []

        init(_ record: RelayKeyStore.Record) {
            self.record = record
            let service = record.pairing.service
            self.service = CBUUID(nsuuid: service)
            controlID = CBUUID(nsuuid: RelayWire.characteristic(.control, of: service))
            inboundID = CBUUID(nsuuid: RelayWire.characteristic(.inbound, of: service))
            bondID = CBUUID(nsuuid: RelayWire.characteristic(.bond, of: service))
        }
    }

    private final class Attempt {
        let pairing: RelayWire.PhonePairing
        let service: CBUUID
        let controlID: CBUUID, inboundID: CBUUID, bondID: CBUUID
        var peripheral: CBPeripheral?
        var inbound: CBCharacteristic?
        var requested = false

        init(_ invitation: RelayWire.Invitation) {
            pairing = RelayWire.PhonePairing(invitation)
            service = CBUUID(nsuuid: invitation.service)
            controlID = CBUUID(nsuuid: RelayWire.characteristic(.control, of: invitation.service))
            inboundID = CBUUID(nsuuid: RelayWire.characteristic(.inbound, of: invitation.service))
            bondID = CBUUID(nsuuid: RelayWire.characteristic(.bond, of: invitation.service))
        }
    }

    private enum Outgoing {
        case raw(Data)
        case message(RelayWire.Message, RelayWire.Event?)

        var event: RelayWire.Event? { if case .message(_, let event) = self { return event } else { return nil } }
    }

    private static let peripheralsKey = "relayMacPeripherals.v1"
    private let queue = DispatchQueue(label: "com.runes.relay")
    private var central: CBCentralManager?
    private var links: [UUID: Link] = [:]
    private var attempt: Attempt?
    private var pairingState = MacLinks.Pairing.idle
    private var restored: [CBPeripheral] = []
    private var scanned: Set<CBUUID> = []
    private var actual: Demand?
    private var lastUnion = Demand.idle
    private var leaseTimer: DispatchSourceTimer?
    private var dropped = 0
    private var lastDropReport: TimeInterval = -.infinity
    private var observers: [NSObjectProtocol] = []
    private var bindings: [RelayWire.Binding] = []
    private var bindingsGeneration: UInt16 = 0

    var onDemand: ((Demand) -> Void)?
    var onStatus: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    override init() {
        super.init()
        MacLinks.shared.attach(self)
    }

    func start() {
        queue.async { [self] in
            do {
                for record in try RelayKeyStore.all() { links[record.id] = Link(record) }
            } catch {
                onDiagnostic?("Mac relay keychain: \(error.localizedDescription)")
            }
            publish()
            startLeaseTimer()
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.sync { self?.sayGoodbye(.terminating) }
            })
            if !links.isEmpty { startCentral() }
        }
    }

    // MARK: Public operations

    func pair(_ invitation: RelayWire.Invitation) {
        queue.async { [self] in
            guard invitation.expires > Date() else { setPairing(.failed(RelayWire.Failure.expiredInvitation.localizedDescription)); return }
            dropAttempt()
            let next = Attempt(invitation)
            attempt = next
            setPairing(.searching(macName: invitation.macName))
            startCentral()
            updateScan()
            // The code is short-lived; give the Mac a little longer than its lifetime to answer.
            queue.asyncAfter(deadline: .now() + max(15, invitation.expires.timeIntervalSinceNow + 30)) { [weak self, weak next] in
                guard let self, let next, self.attempt === next else { return }
                self.dropAttempt()
                self.setPairing(.failed("Couldn't reach your Mac. Keep Runes open on the Mac, then scan its new code."))
            }
        }
    }

    func cancelPairing() {
        queue.async { [self] in
            dropAttempt()
            setPairing(.idle)
        }
    }

    func remove(_ id: UUID) {
        queue.async { [self] in
            guard let link = links.removeValue(forKey: id) else { return }
            MacLinks.shared.publish(bindings: nil, for: id)
            link.epoch += 1
            if link.phase == .live { enqueue(link, .message(.bye(.removed), nil)) }
            let peripheral = link.peripheral
            // Let the goodbye leave before the connection closes.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let peripheral, !self.links.values.contains(where: { $0.peripheral === peripheral }) else { return }
                self.central?.cancelPeripheralConnection(peripheral)
            }
            do { try RelayKeyStore.delete(id) } catch { onDiagnostic?("Mac relay keychain: \(error.localizedDescription)") }
            var saved = UserDefaults.standard.dictionary(forKey: Self.peripheralsKey) as? [String: String] ?? [:]
            saved.removeValue(forKey: id.uuidString)
            UserDefaults.standard.set(saved, forKey: Self.peripheralsKey)
            onDiagnostic?("Mac relay removed \(id.uuidString)")
            updateDemand()
            updateScan()
            publish()
        }
    }

    /// This iPhone's gesture assignments, sent to each Mac now and whenever it connects.
    func setBindings(_ next: [RelayWire.Binding]) {
        queue.async { [self] in
            guard next != bindings else { return }
            bindings = next
            bindingsGeneration &+= 1
            for link in links.values where link.phase == .live { queueBindings(link) }
        }
    }

    private func queueBindings(_ link: Link) {
        link.bindingsOut = RelayWire.bindingChunks(bindings, generation: bindingsGeneration)
        drain(link)
    }

    /// The band streams that are actually open, or nil while they are changing.
    func setReady(_ actual: Demand?) {
        queue.async { [self] in
            self.actual = actual
            for link in links.values where link.phase == .live { sendReady(link) }
        }
    }

    func forward(_ event: RelayWire.Event) {
        queue.async { [self] in
            let age = ProcessInfo.processInfo.systemUptime - event.phoneUptime
            let fresh = event.isRelease || age <= (event.kind == .gesture ? RelayWire.gestureMaxAge : RelayWire.motionMaxAge)
            for link in links.values where link.phase == .live {
                guard let ready = link.ready, ready.active else { continue }
                if event.kind == .gyro && !ready.gyro { continue }
                if event.kind == .orientation && !ready.orientation { continue }
                guard fresh else { noteDropped(); continue }
                enqueue(link, .message(.event(event), event))
            }
        }
    }

    // MARK: Central

    private func startCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.runes.relay.central.v1"
        ])
    }

    private var savedPeripherals: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.peripheralsKey) as? [String: String] ?? [:]
    }

    private func remember(_ link: Link, _ peripheral: CBPeripheral) {
        var saved = savedPeripherals
        let previous = saved[link.record.id.uuidString]
        guard previous != peripheral.identifier.uuidString else { return }
        onDiagnostic?("Mac relay identifier \(link.record.name) previous=\(previous ?? "none") now=\(peripheral.identifier.uuidString)")
        saved[link.record.id.uuidString] = peripheral.identifier.uuidString
        UserDefaults.standard.set(saved, forKey: Self.peripheralsKey)
    }

    private func link(for peripheral: CBPeripheral) -> Link? {
        links.values.first { $0.peripheral === peripheral }
    }

    /// Starts or renews a pending connect. It has no timeout and no retry limit.
    private func connect(_ link: Link) {
        guard let central, central.state == .poweredOn, !link.deferred else { return }
        if link.peripheral == nil, let text = savedPeripherals[link.record.id.uuidString], let id = UUID(uuidString: text),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first,
           !links.values.contains(where: { $0 !== link && $0.peripheral === known }) {
            link.peripheral = known
        }
        guard let peripheral = link.peripheral else { updateScan(); return }
        peripheral.delegate = self
        link.epoch += 1
        switch peripheral.state {
        case .connected:
            beginSetup(link)
        case .connecting:
            link.phase = .connecting
        default:
            link.phase = .connecting
            central.connect(peripheral, options: nil)
        }
        updateScan()
    }

    /// Scans only for Macs that have no pending connect yet, plus a Mac being paired.
    private func updateScan() {
        guard let central, central.state == .poweredOn else { return }
        var services = Set(links.values.filter { !$0.deferred && ($0.peripheral == nil || $0.phase == .idle) }.map(\.service))
        if let attempt, attempt.peripheral == nil { services.insert(attempt.service) }
        guard services != scanned else { return }
        scanned = services
        central.stopScan()
        if !services.isEmpty { central.scanForPeripherals(withServices: Array(services), options: nil) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanned = []
        guard central.state == .poweredOn else {
            guard central.state != .unknown else { return }
            onDiagnostic?("Mac relay Bluetooth state: \(central.state.rawValue)")
            for link in links.values { teardown(link, state: .notNearby) }
            publish()
            return
        }
        let byIdentifier = Dictionary(savedPeripherals.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for peripheral in restored {
            if let id = byIdentifier[peripheral.identifier.uuidString].flatMap(UUID.init(uuidString:)), let link = links[id] {
                link.peripheral = peripheral
            } else {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        restored.removeAll()
        for link in links.values { connect(link) }
        updateScan()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = Set((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                             + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []))
        if let attempt, attempt.peripheral == nil, advertised.isEmpty || advertised.contains(attempt.service),
           link(for: peripheral) == nil {
            attempt.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            updateScan()
            return
        }
        guard link(for: peripheral) == nil else { return }
        // A backgrounded scan may not report service UUIDs; service discovery then confirms the match.
        let waiting = links.values.filter { !$0.deferred && ($0.peripheral == nil || $0.phase == .idle || $0.phase == .connecting) }
        guard let match = waiting.first(where: { advertised.contains($0.service) }) ?? (advertised.isEmpty ? waiting.first : nil) else { return }
        if let stale = match.peripheral, stale !== peripheral {
            onDiagnostic?("Mac relay identifier changed for \(match.record.name)")
            central.cancelPeripheralConnection(stale)
        }
        match.peripheral = peripheral
        connect(match)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let attempt, attempt.peripheral === peripheral {
            setPairing(.confirming(macName: attempt.pairing.invitation.macName))
            peripheral.discoverServices([attempt.service])
            return
        }
        guard let link = link(for: peripheral) else { return }
        beginSetup(link)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let attempt, attempt.peripheral === peripheral { attempt.peripheral = nil; updateScan(); return }
        guard let link = link(for: peripheral) else { return }
        onDiagnostic?("Mac relay connect failed: \(error?.localizedDescription ?? "unknown")")
        link.phase = .idle
        let epoch = link.epoch
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak link] in
            guard let self, let link, link.epoch == epoch else { return }
            self.connect(link)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let attempt, attempt.peripheral === peripheral {
            attempt.peripheral = nil
            attempt.inbound = nil
            attempt.requested = false
            updateScan()
            return
        }
        guard let link = link(for: peripheral) else { return }
        let wasLive = link.phase == .live
        onDiagnostic?("Mac relay disconnected \(link.record.name): \(error?.localizedDescription ?? "closed")")
        let next: MacLinks.Mac.State = link.state == .sleeping || link.state == .forgotten || link.state == .needsUpdate
            ? link.state : wasLive || link.state == .connected ? .notNearby : link.state
        teardown(link, state: next)
        publish()
        connect(link)
    }

    // MARK: Setup on a connected Mac

    private func beginSetup(_ link: Link) {
        guard let peripheral = link.peripheral else { return }
        link.phase = .discovering
        link.session = nil
        link.nonce = nil
        link.outgoing.removeAll(); link.bindingsOut.removeAll()
        link.epoch += 1
        peripheral.delegate = self
        peripheral.discoverServices([link.service])
        remember(link, peripheral)
        // A stuck setup is closed; the disconnect handler then renews the pending connect.
        let epoch = link.epoch
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak link] in
            guard let self, let link, link.epoch == epoch, link.phase != .live, let peripheral = link.peripheral else { return }
            self.onDiagnostic?("Mac relay setup timed out for \(link.record.name)")
            self.central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let attempt, attempt.peripheral === peripheral {
            guard let service = peripheral.services?.first(where: { $0.uuid == attempt.service }) else {
                failPairing("Couldn't reach your Mac. Scan its new code."); return
            }
            peripheral.discoverCharacteristics([attempt.controlID, attempt.inboundID, attempt.bondID], for: service)
            return
        }
        guard let link = link(for: peripheral) else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == link.service }) else {
            // Right after pairing the Mac may still be publishing the service.
            if error == nil, link.discoveryAttempts < 5 {
                link.discoveryAttempts += 1
                queue.asyncAfter(deadline: .now() + 1) { [weak peripheral, weak link] in
                    guard let peripheral, let link, link.peripheral === peripheral, peripheral.state == .connected else { return }
                    peripheral.discoverServices([link.service])
                }
                return
            }
            if error == nil {
                // This Mac no longer hosts our pairing: it removed this iPhone. Check back rarely.
                onDiagnostic?("Mac relay service missing on \(link.record.name)")
                link.state = .forgotten
                postpone(link, seconds: 300)
            }
            central?.cancelPeripheralConnection(peripheral)
            publish()
            return
        }
        link.discoveryAttempts = 0
        peripheral.discoverCharacteristics([link.controlID, link.inboundID, link.bondID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let attempt, attempt.peripheral === peripheral {
            guard let inbound = service.characteristics?.first(where: { $0.uuid == attempt.inboundID }),
                  let control = service.characteristics?.first(where: { $0.uuid == attempt.controlID }) else {
                failPairing("Couldn't reach your Mac. Scan its new code."); return
            }
            attempt.inbound = inbound
            // Reading the encrypted characteristic makes iOS bond with the Mac, once, while the user is here.
            if let bond = service.characteristics?.first(where: { $0.uuid == attempt.bondID }) { peripheral.readValue(for: bond) }
            peripheral.setNotifyValue(true, for: control)
            return
        }
        guard let link = link(for: peripheral), service.uuid == link.service else { return }
        guard error == nil,
              let control = service.characteristics?.first(where: { $0.uuid == link.controlID }),
              let inbound = service.characteristics?.first(where: { $0.uuid == link.inboundID }) else {
            central?.cancelPeripheralConnection(peripheral); return
        }
        link.control = control
        link.inbound = inbound
        if let bond = service.characteristics?.first(where: { $0.uuid == link.bondID }) {
            link.phase = .bonding
            peripheral.readValue(for: bond)
        } else {
            subscribe(link)
        }
    }

    private func subscribe(_ link: Link) {
        guard let peripheral = link.peripheral, let control = link.control else { return }
        link.phase = .subscribing
        // A restored link may still be subscribed; the hello below starts a new session either way.
        if control.isNotifying { sendHello(link) } else { peripheral.setNotifyValue(true, for: control) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let attempt, attempt.peripheral === peripheral, characteristic.uuid == attempt.controlID {
            guard error == nil, characteristic.isNotifying, let inbound = attempt.inbound else {
                failPairing("Bluetooth pairing didn't finish. Scan your Mac's new code to try again."); return
            }
            do {
                peripheral.writeValue(try attempt.pairing.request(phoneName: UIDevice.current.name), for: inbound, type: .withoutResponse)
                attempt.requested = true
            } catch { failPairing(error.localizedDescription) }
            return
        }
        guard let link = link(for: peripheral), characteristic.uuid == link.controlID else { return }
        if error == nil, characteristic.isNotifying {
            if link.phase == .subscribing { sendHello(link) }
        } else {
            onDiagnostic?("Mac relay notifications stopped: \(error?.localizedDescription ?? "unsubscribed")")
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func sendHello(_ link: Link) {
        guard link.peripheral?.state == .connected else { return }
        let nonce = RelayWire.random(16)
        link.phase = .hello
        link.nonce = nonce
        link.session = nil
        link.ready = nil
        link.outgoing.removeAll(); link.bindingsOut.removeAll()
        link.helloAttempts += 1
        link.epoch += 1
        enqueue(link, .raw(RelayWire.phoneHello(link.record.pairing, nonce: nonce)))
        let epoch = link.epoch
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak link] in
            guard let self, let link, link.epoch == epoch, link.phase == .hello else { return }
            if link.helloAttempts >= 3, let peripheral = link.peripheral {
                self.onDiagnostic?("Mac relay handshake unanswered; reconnecting")
                self.central?.cancelPeripheralConnection(peripheral)
            } else {
                self.sendHello(link)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let attempt, attempt.peripheral === peripheral {
            if characteristic.uuid == attempt.bondID {
                onDiagnostic?("Mac relay pairing bond_read ok=\(error == nil)")
            } else if characteristic.uuid == attempt.controlID, attempt.requested, let packet = characteristic.value {
                finishPairing(attempt, packet)
            }
            return
        }
        guard let link = link(for: peripheral) else { return }
        if characteristic.uuid == link.bondID {
            // A refused bond read is logged; the authenticated session does not depend on it.
            onDiagnostic?("Mac relay bond_read ok=\(error == nil) \(error?.localizedDescription ?? "")")
            subscribe(link)
            return
        }
        guard characteristic.uuid == link.controlID, error == nil, let packet = characteristic.value else { return }
        receive(link, packet)
    }

    private func receive(_ link: Link, _ packet: Data) {
        let header: RelayWire.Header
        do { header = try RelayWire.Header(packet) } catch RelayWire.Failure.unsupportedVersion {
            link.state = .needsUpdate
            publish()
            return
        } catch { return }
        do {
            switch header.kind {
            case .macHello:
                guard link.phase == .hello, let nonce = link.nonce,
                      let macNonce = try RelayWire.readMacHello(packet, link.record.pairing, phoneNonce: nonce) else { return }
                link.session = RelayWire.Session(link.record.pairing, phoneNonce: nonce, macNonce: macNonce, isPhone: true)
                link.phase = .live
                link.helloAttempts = 0
                link.state = .connected
                link.lastConnected = Date()
                link.epoch += 1
                onDiagnostic?("Mac relay live: \(link.record.name)")
                enqueue(link, .message(.lease(seconds: RelayWire.leaseDuration, state: WakeProbe.shared.phoneState), nil))
                queueBindings(link)
                publish()
            case .reset:
                // Only a reset naming the current session counts; anything older is stale.
                let tag = try RelayWire.readReset(packet)
                if link.phase == .live, tag == link.session?.tag { sendHello(link) }
            default:
                guard header.kind.sealed, link.phase == .live, var session = link.session else { return }
                // Notifications from an earlier session can arrive after an iOS relaunch. They carry another tag.
                guard header.tag == session.tag else { return }
                let message = try session.open(packet)
                link.session = session
                handle(link, message)
            }
        } catch {
            onDiagnostic?("Mac relay rejected a message (\(error.localizedDescription)); starting a new session")
            if link.phase == .live || link.phase == .hello { sendHello(link) }
        }
    }

    private func handle(_ link: Link, _ message: RelayWire.Message) {
        switch message {
        case .demand(let demand):
            link.demand = demand
            link.ready = nil
            link.outgoing.removeAll { $0.event != nil }
            enqueue(link, .message(.ready(nil), nil))
            updateDemand()
            sendReady(link)
            publish()
        case .ping(let id):
            enqueue(link, .message(.pong(id, WakeProbe.shared.phoneState), nil))
        case .bindings(let chunk):
            if let list = link.assembler.add(chunk) { MacLinks.shared.publish(bindings: list, for: link.record.id) }
        case .bye(let reason):
            onDiagnostic?("Mac relay goodbye from \(link.record.name): \(reason)")
            switch reason {
            case .sleeping: link.state = .sleeping
            case .removed: link.state = .forgotten; postpone(link, seconds: 300)
            default: break
            }
            link.ready = nil
            updateDemand()
            publish()
        default:
            break
        }
    }

    private func sendReady(_ link: Link) {
        let ready: Demand? = link.demand.active && (actual?.covers(link.demand) ?? false) ? link.demand : nil
        guard ready != link.ready else { return }
        link.ready = ready
        if ready == nil { link.outgoing.removeAll { $0.event != nil } }
        enqueue(link, .message(.ready(ready), nil))
    }

    private func updateDemand() {
        let union = Demand.union(links.values.filter { $0.phase == .live && $0.state == .connected }.map(\.demand))
        guard union != lastUnion else { return }
        lastUnion = union
        onDemand?(union)
    }

    // MARK: Sending

    private func enqueue(_ link: Link, _ item: Outgoing) {
        if let event = item.event, event.kind != .gesture,
           let previous = link.outgoing.lastIndex(where: { $0.event?.kind == event.kind }) {
            link.outgoing.remove(at: previous)
            noteDropped()
        }
        if link.outgoing.count >= 32 {
            if let motion = link.outgoing.firstIndex(where: { $0.event.map { $0.kind != .gesture } ?? false }) {
                link.outgoing.remove(at: motion)
                noteDropped()
            } else if let event = item.event, !event.isRelease {
                noteDropped()
                return
            } else if let peripheral = link.peripheral {
                onDiagnostic?("Mac relay queue overflow; reconnecting")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
        }
        link.outgoing.append(item)
        drain(link)
    }

    private func drain(_ link: Link) {
        guard let peripheral = link.peripheral, let inbound = link.inbound, peripheral.state == .connected else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        while peripheral.canSendWriteWithoutResponse, !link.outgoing.isEmpty || !link.bindingsOut.isEmpty {
            let packet: Data
            let next: Outgoing = link.outgoing.isEmpty ? .message(link.bindingsOut.removeFirst(), nil) : link.outgoing.removeFirst()
            switch next {
            case .raw(let data):
                packet = data
            case .message(let message, let event):
                guard var session = link.session else { continue }
                if let event, !event.isRelease,
                   ProcessInfo.processInfo.systemUptime - event.phoneUptime > (event.kind == .gesture ? RelayWire.gestureMaxAge : RelayWire.motionMaxAge) {
                    noteDropped(); continue
                }
                // The counter is assigned only to a packet that is about to leave.
                do { packet = try session.seal(message) } catch { onDiagnostic?("Mac relay could not encode a message"); continue }
                link.session = session
            }
            guard packet.count <= limit else {
                onDiagnostic?("Mac relay link too small (\(limit) bytes) for a \(packet.count)-byte message")
                continue
            }
            peripheral.writeValue(packet, for: inbound, type: .withoutResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let link = link(for: peripheral) { drain(link) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let link = link(for: peripheral), invalidatedServices.contains(where: { $0.uuid == link.service }) else { return }
        beginSetup(link)
    }

    private func noteDropped() {
        dropped += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDropReport >= 5 else { return }
        onDiagnostic?("Mac relay skipped \(dropped) stale or queued samples.")
        dropped = 0
        lastDropReport = now
    }

    // MARK: Lease, lifecycle and pairing

    /// Renews each Mac's lease while this app runs. When the phone is locked, the band's pulse wakes
    /// the app often enough that the lease never lapses while the phone is in range.
    private func startLeaseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + RelayWire.leaseInterval, repeating: RelayWire.leaseInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for link in self.links.values where link.phase == .live {
                self.enqueue(link, .message(.lease(seconds: RelayWire.leaseDuration, state: WakeProbe.shared.phoneState), nil))
            }
        }
        leaseTimer = timer
        timer.resume()
    }

    private func sayGoodbye(_ reason: RelayWire.ByeReason) {
        for link in links.values where link.phase == .live { enqueue(link, .message(.bye(reason), nil)) }
    }

    private func teardown(_ link: Link, state: MacLinks.Mac.State) {
        link.epoch += 1
        link.phase = .idle
        link.session = nil
        link.nonce = nil
        link.control = nil
        link.inbound = nil
        link.ready = nil
        link.helloAttempts = 0
        link.outgoing.removeAll(); link.bindingsOut.removeAll()
        link.state = state
        updateDemand()
    }

    private func postpone(_ link: Link, seconds: TimeInterval) {
        link.deferred = true
        let epoch = link.record.id
        queue.asyncAfter(deadline: .now() + seconds) { [weak self, weak link] in
            guard let self, let link, link.record.id == epoch, self.links[epoch] === link else { return }
            link.deferred = false
            self.connect(link)
        }
    }

    private func finishPairing(_ attempt: Attempt, _ packet: Data) {
        guard let peripheral = attempt.peripheral else { return }
        do {
            let (pairing, macName) = try attempt.pairing.accept(packet)
            let record = RelayKeyStore.Record(id: pairing.id, name: macName, secret: pairing.secret, created: Date())
            try RelayKeyStore.save(record)
            // Pairing this Mac again replaces its old record.
            for (id, old) in links where old.peripheral === peripheral || savedPeripherals[id.uuidString] == peripheral.identifier.uuidString {
                links.removeValue(forKey: id)
                old.epoch += 1
                try? RelayKeyStore.delete(id)
            }
            let link = Link(record)
            link.peripheral = peripheral
            links[record.id] = link
            self.attempt = nil
            setPairing(.paired(macName: macName))
            onDiagnostic?("Mac relay paired with \(macName)")
            // The Mac publishes the link service before it accepts, so setup continues on this connection.
            beginSetup(link)
            updateScan()
            publish()
        } catch {
            failPairing((error as? LocalizedError)?.errorDescription ?? "Pairing failed. Scan your Mac's new code.")
        }
    }

    private func failPairing(_ message: String) {
        dropAttempt()
        setPairing(.failed(message))
    }

    private func dropAttempt() {
        guard let attempt else { return }
        self.attempt = nil
        if let peripheral = attempt.peripheral, link(for: peripheral) == nil { central?.cancelPeripheralConnection(peripheral) }
        updateScan()
    }

    private func setPairing(_ state: MacLinks.Pairing) {
        pairingState = state
        publish()
    }

    private func publish() {
        let macs = links.values.sorted { $0.record.created < $1.record.created }.map {
            MacLinks.Mac(id: $0.record.id, name: $0.record.name, state: $0.phase == .live ? .connected : $0.state, lastConnected: $0.lastConnected)
        }
        MacLinks.shared.publish(macs: macs, pairing: pairingState)
        let summary: String
        if case .searching(let name) = pairingState { summary = "Looking for \(name)…" }
        else if case .confirming(let name) = pairingState { summary = "Pairing with \(name)…" }
        else if case .failed(let message) = pairingState, macs.isEmpty { summary = message }
        else if macs.isEmpty { summary = "Pair a Mac to begin." }
        else if case let names = macs.filter({ $0.state == .connected }).map(\.name), !names.isEmpty { summary = "Connected to \(names.joined(separator: ", "))" }
        else { summary = macs[0].statusText }
        onStatus?(summary)
    }
}
