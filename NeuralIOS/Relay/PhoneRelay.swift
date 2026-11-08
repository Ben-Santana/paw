import Foundation
import CoreBluetooth
import CryptoKit
import UIKit

/// Measures when this process actually runs, for the locked-phone wake test.
/// It records suspension; it does nothing to prevent it.
final class WakeProbe: @unchecked Sendable {
    static let shared = WakeProbe()
    static let gapThreshold: TimeInterval = 3
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastTick: TimeInterval?
    private var applicationState = "launching"
    private var bandState = "disconnected"
    private var lastBandData: TimeInterval?
    private var gaps = 0
    private var longestGap: TimeInterval = 0
    private var battery: Float?
    private var lowPower = false

    /// Counts device sleep. `systemUptime` stops while the phone sleeps and would hide the gaps.
    private static var now: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    func start(onGap: @escaping @Sendable (String) -> Void) {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.neural.wake-probe"))
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
        let gap = time - lastTick
        gaps += 1
        longestGap = max(longestGap, gap)
        return String(format: "wake_probe gap seconds=%.1f state=%@ band=%@", gap, applicationState, bandState)
    }

    func setApplicationState(_ state: String) { lock.lock(); applicationState = state; lock.unlock() }
    func setBandState(_ state: String) { lock.lock(); bandState = state; lock.unlock() }
    func noteBandData() { lock.lock(); lastBandData = Self.now; lock.unlock() }

    func acknowledge(_ beat: RelayWire.Heartbeat) -> RelayWire.HeartbeatAck {
        DispatchQueue.main.async { [self] in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            lock.lock()
            battery = level < 0 ? nil : level
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        return .init(sequence: beat.sequence, phoneTime: Date(), applicationState: applicationState, bandState: bandState,
                     bandDataAge: lastBandData.map { Self.now - $0 }, suspensionGaps: gaps, longestGap: longestGap,
                     batteryLevel: battery, lowPowerMode: lowPower)
    }
}

/// Experimental Mac link. Its queue and peripheral are independent of the band transport.
final class PhoneRelay: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.neural.ble-prototype")
    private let service = CBUUID(string: RelayWire.service)
    private let controlID = CBUUID(string: RelayWire.control)
    private let eventsID = CBUUID(string: RelayWire.events)
    private let bondID = CBUUID(string: RelayWire.bond)
    private static let macIdentifierKey = "relayMacPeripheral"
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var restored: [CBPeripheral] = []
    private var events: CBCharacteristic?
    private var control: CBCharacteristic?
    private var waitingForKnown = false
    private var resubscribing = false
    private var identifierNoted = false
    private var key: Data?
    private var paired = false
    private var cipher: RelayWire.Cipher?
    private var framer = RelayWire.Framer()
    private struct Queued {
        let message: RelayWire.Message
        let prefix: Data
        let event: RelayWire.Event?

        var isMotion: Bool { event.map { $0.kind != .gesture } ?? false }
    }

    private var pending: [Queued] = []
    private var inFlight = Data()
    private var dropped = 0
    private var lastDropReport: TimeInterval = -.infinity
    var onDiagnostic: ((String) -> Void)?
    private var demand: RelayWire.Demand?
    private var ready: RelayWire.Demand?
    private var epoch = UUID()
    private var retry = 0
    private var scanning = false
    private var retryScheduled = false
    var onDemand: ((RelayWire.Demand) -> Void)?
    var onStatus: ((String) -> Void)?

    func start() {
        queue.async { [self] in
            do {
                key = try RelayKeyStore.load()
                paired = key != nil
                if paired {
                    onStatus?("Waiting for Mac test relay")
                    startCentral()
                }
            } catch { onStatus?(error.localizedDescription) }
        }
    }

    func pair(_ invitation: RelayWire.Invitation) {
        queue.async { [self] in
            guard invitation.expires > Date() else { onStatus?("The Mac test QR code expired."); return }
            // Commit the candidate only after the Mac answers with an authenticated request.
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            resetLink()
            key = invitation.key
            paired = false
            queue.asyncAfter(deadline: .now() + max(0, invitation.expires.timeIntervalSinceNow)) { [weak self] in
                guard let self, !self.paired, self.key == invitation.key else { return }
                if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
                self.central?.stopScan()
                self.resetLink()
                self.key = try? RelayKeyStore.load()
                self.paired = self.key != nil
                self.onStatus?("Pairing expired. Scan a fresh Mac test QR code.")
                if self.paired { self.scan() }
            }
            onStatus?("Finding the Mac test relay…")
            startCentral()
            scan()
        }
    }

    private func startCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.neural.ble-prototype.mac.v1"
            ])
        }
    }

    private func scan() {
        guard key != nil, !scanning, !retryScheduled, peripheral == nil,
              let central, central.state == .poweredOn else { return }
        scanning = true
        central.scanForPeripherals(withServices: [service], options: nil)
    }

    private func resetLink() {
        epoch = UUID()
        scanning = false
        retryScheduled = false
        waitingForKnown = false
        resubscribing = false
        identifierNoted = false
        peripheral?.delegate = nil
        peripheral = nil
        events = nil
        control = nil
        cipher = nil
        framer = RelayWire.Framer()
        pending.removeAll()
        inFlight.removeAll()
        demand = nil
        ready = nil
        onDemand?(.idle)
    }

    /// A pending connect needs no timer, so it survives suspension and relaunches the app.
    /// The scan runs alongside it in case the Mac's Bluetooth identifier changed.
    private func awaitKnownMac() -> Bool {
        guard paired, peripheral == nil, let central, central.state == .poweredOn,
              let text = UserDefaults.standard.string(forKey: Self.macIdentifierKey),
              let id = UUID(uuidString: text),
              let known = central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        peripheral = known
        known.delegate = self
        waitingForKnown = true
        central.connect(known, options: nil)
        central.scanForPeripherals(withServices: [service], options: nil)
        scanning = true
        onDiagnostic?("wake_probe pending_connect id=\(id.uuidString)")
        return true
    }

    private func retryLink(_ reason: String, awaitKnown: Bool = false) {
        onDiagnostic?("Mac relay reconnect: \(reason)")
        if !awaitKnown, let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetLink()
        onStatus?("Waiting for Mac test relay")
        if awaitKnown, awaitKnownMac() { return }
        let expected = epoch
        let seconds = min(16, 1 << min(retry, 4))
        retry += 1
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            guard let self, self.epoch == expected else { return }
            self.retryScheduled = false
            self.scan()
        }
    }

    func setReady(_ actual: RelayWire.Demand?) {
        queue.async { [self] in
            guard let demand else { return }
            let current = actual == demand ? actual : nil
            guard ready != current else { return }
            ready = current
            if current == nil { pending.removeAll { $0.event != nil } }
            send(.ready(current))
        }
    }

    func forward(_ event: RelayWire.Event) {
        queue.async { [self] in
            guard let ready, ready.active else { return }
            if event.kind == .gyro && !ready.gyro { return }
            if event.kind == .orientation && !ready.orientation { return }
            guard ProcessInfo.processInfo.systemUptime - event.phoneUptime <= 0.2 else {
                noteDroppedSample()
                return
            }
            send(.event(event), event: event)
        }
    }

    private func noteDroppedSample() {
        dropped += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDropReport >= 5 else { return }
        onDiagnostic?("Mac relay skipped \(dropped) stale or queued samples.")
        dropped = 0
        lastDropReport = now
    }

    private func send(_ message: RelayWire.Message, prefix: Data = Data(), event: RelayWire.Event? = nil) {
        guard cipher != nil else { return }
        if let event, event.kind != .gesture,
           let previous = pending.lastIndex(where: { $0.event?.kind == event.kind }) {
            pending.remove(at: previous)
            noteDroppedSample()
        }
        if pending.count >= 24 {
            if let motion = pending.firstIndex(where: \.isMotion) {
                pending.remove(at: motion)
                noteDroppedSample()
            } else if event != nil {
                noteDroppedSample()
                return
            } else if let sample = pending.firstIndex(where: { $0.event != nil }) {
                pending.remove(at: sample)
                noteDroppedSample()
            } else {
                retryLink("control queue overflow")
                return
            }
        }
        pending.append(Queued(message: message, prefix: prefix, event: event))
        drain()
    }

    private func drain() {
        guard let peripheral, let events else { return }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard limit > 0 else { retryLink("invalid GATT write size"); return }
        while peripheral.canSendWriteWithoutResponse {
            if inFlight.isEmpty {
                guard !pending.isEmpty else { return }
                let next = pending.removeFirst()
                if let event = next.event, ProcessInfo.processInfo.systemUptime - event.phoneUptime > 0.2 {
                    noteDroppedSample()
                    continue
                }
                // Assign a cipher sequence only to a frame we are about to send.
                // Once started, finish all its fragments so the receiver can decode the next frame.
                do {
                    guard let frame = try cipher?.seal(next.message) else { return }
                    inFlight = next.prefix + frame
                } catch {
                    retryLink("could not encode relay frame")
                    return
                }
            }
            let count = min(limit, inFlight.count)
            let fragment = Data(inFlight.prefix(count))
            inFlight.removeFirst(count)
            peripheral.writeValue(fragment, for: events, type: .withoutResponse)
        }
    }

    private func attach(_ peer: CBPeripheral) {
        guard peripheral == nil else { return }
        central?.stopScan()
        scanning = false
        peripheral = peer
        peer.delegate = self
        if peer.state == .connected { peer.discoverServices([service]) }
        else if peer.state == .disconnected { central?.connect(peer, options: nil) }
        let expected = epoch
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.epoch == expected, self.peripheral?.state != .connected else { return }
            self.retryLink("connection timed out")
        }
    }

    private func subscribeControl(_ peer: CBPeripheral) {
        guard let control else { return }
        // A restored link is still subscribed, so the Mac would never restart its handshake.
        if control.isNotifying {
            resubscribing = true
            peer.setNotifyValue(false, for: control)
        } else {
            peer.setNotifyValue(true, for: control)
        }
        let expected = epoch
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.epoch == expected, self.demand == nil else { return }
            self.retryLink("handshake timed out")
        }
    }

    private func noteMacIdentifier(_ peer: CBPeripheral) {
        guard !identifierNoted else { return }
        identifierNoted = true
        let id = peer.identifier.uuidString
        let previous = UserDefaults.standard.string(forKey: Self.macIdentifierKey)
        onDiagnostic?("wake_probe mac_identifier id=\(id) previous=\(previous ?? "none") stable=\(previous == id)")
        UserDefaults.standard.set(id, forKey: Self.macIdentifierKey)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown {
                onDiagnostic?("Mac relay Bluetooth state: \(central.state.rawValue)")
                resetLink()
            }
            return
        }
        let candidates = restored
        restored.removeAll()
        if key != nil, let first = candidates.first { attach(first) }
        else if !awaitKnownMac() { scan() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, self.peripheral?.identifier != peripheral.identifier else { return }
        if waitingForKnown, let stale = self.peripheral {
            onDiagnostic?("wake_probe mac_identifier_changed from=\(stale.identifier.uuidString) to=\(peripheral.identifier.uuidString)")
            central.cancelPeripheralConnection(stale)
            stale.delegate = nil
            self.peripheral = nil
            waitingForKnown = false
        }
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        if waitingForKnown {
            central.stopScan()
            scanning = false
            waitingForKnown = false
        }
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if self.peripheral === peripheral { retryLink(error?.localizedDescription ?? "Bluetooth disconnected") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if self.peripheral === peripheral { retryLink(error?.localizedDescription ?? "Bluetooth disconnected", awaitKnown: true) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let match = peripheral.services?.first(where: { $0.uuid == service }) else { retryLink(error?.localizedDescription ?? "relay service or characteristic unavailable"); return }
        peripheral.discoverCharacteristics([controlID, eventsID, bondID], for: match)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil,
              let control = service.characteristics?.first(where: { $0.uuid == controlID }),
              let input = service.characteristics?.first(where: { $0.uuid == eventsID }) else { retryLink(error?.localizedDescription ?? "relay service or characteristic unavailable"); return }
        events = input
        self.control = control
        // Bond before the handshake starts, so a pairing prompt can't run out its timeout.
        if let bond = service.characteristics?.first(where: { $0.uuid == bondID }) {
            peripheral.readValue(for: bond)
        } else {
            subscribeControl(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, characteristic.uuid == controlID else { return }
        if resubscribing, error == nil, !characteristic.isNotifying {
            resubscribing = false
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        if error != nil || !characteristic.isNotifying { retryLink(error?.localizedDescription ?? "control notifications stopped") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if self.peripheral === peripheral, characteristic.uuid == bondID {
            // A refused bond is a test result, not a link failure.
            onDiagnostic?("wake_probe bond_read ok=\(error == nil) id=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "none")")
            subscribeControl(peripheral)
            return
        }
        guard self.peripheral === peripheral, characteristic.uuid == controlID else { return }
        guard error == nil, let bytes = characteristic.value else { retryLink(error?.localizedDescription ?? "relay service or characteristic unavailable"); return }
        do {
            for payload in try framer.append(bytes) {
                if cipher == nil {
                    guard let key, payload.count == 32 else { throw RelayWire.Failure.invalidInvitation }
                    let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    cipher = try RelayWire.Cipher(key: key, challenge: payload + challenge, isPhone: true)
                    send(.hello, prefix: try RelayWire.frame(challenge))
                    continue
                }
                let message = try cipher!.open(payload)
                if case .heartbeat(let beat) = message {
                    let ack = WakeProbe.shared.acknowledge(beat)
                    onDiagnostic?("wake_probe heartbeat seq=\(beat.sequence) state=\(ack.applicationState) band=\(ack.bandState)")
                    send(.heartbeatAck(ack))
                    continue
                }
                guard case .demand(let requested) = message else { throw RelayWire.Failure.invalidFrame }
                if !paired {
                    guard let key else { throw RelayWire.Failure.invalidInvitation }
                    try RelayKeyStore.save(key)
                    paired = true
                }
                noteMacIdentifier(peripheral)
                retry = 0
                demand = requested
                ready = nil
                pending.removeAll { $0.event != nil }
                let expected = epoch
                send(.ready(nil))
                guard epoch == expected else { return }
                onStatus?(requested.active ? "Mac test relay connected" : "Mac test relay paused")
                onDemand?(requested)
            }
        } catch { retryLink("control frame failed authentication or decoding") }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if self.peripheral === peripheral && invalidatedServices.contains(where: { $0.uuid == service }) { retryLink("Mac service changed") }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if self.peripheral === peripheral { drain() }
    }
}
