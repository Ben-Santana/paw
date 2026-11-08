import Foundation
import CoreBluetooth

/// All mutable transport/protocol state is confined to this running CFRunLoop.
final class BandTransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate, @unchecked Sendable {
    static let service = CBUUID(string: "FEB8")
    /// What the band advertises. FEB8 is only visible after connecting, so a background
    /// scan (which must name a service) has to look for this one.
    static let advertisedService = CBUUID(string: "FD5F")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
    /// Ask iOS to re-establish the link by itself after it drops (iOS 17+).
    private static let connectOptions: [String: Any] = [CBConnectPeripheralOptionEnableAutoReconnect: true]
    static let psm = CBUUID(string: "2D41DA7C-82B6-42AA-B34E-E2E01DF8CC1A")
    /// Once subscribed, the band notifies a single 0x00 on both of these about every 7 seconds.
    /// Each GATT notification wakes the app, which keeps the L2CAP gesture stream flowing while
    /// the phone is locked. L2CAP alone never wakes a suspended app. Measured on 2026-11-08;
    /// this is undocumented band behaviour, so the watchdog reports if it stops.
    static let pulse = CBUUID(string: "2D41DA7A-82B6-42AA-B34E-E2E01DF8CC1A")
    static let pulseSources: Set<CBUUID> = [psm, pulse]
    private static let pulseTimeout: TimeInterval = 30
    var onDevice: ((BandDevice) -> Void)?
    /// The link dropped while wanted; the Bool says whether iOS is reconnecting by itself.
    var onLinkLost: ((Bool) -> Void)?
    var onBattery: ((Int) -> Void)?
    /// false when the band pulse stops arriving, true when it resumes.
    var onPulse: ((Bool) -> Void)?
    var onClosed: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onProgress: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var attempt = 0
    private var attemptStarted: TimeInterval = 0
    private var receivedBytes = 0, sentBytes = 0
    private func diagnostic(_ event: String, error: Error? = nil) {
        let elapsed = attemptStarted == 0 ? 0 : ProcessInfo.processInfo.systemUptime - attemptStarted
        let state = central.map { String($0.state.rawValue) } ?? "nil"
        let peer = peripheral.map { "\($0.identifier.uuidString) state=\($0.state.rawValue)" } ?? "none"
        var detail = "BT attempt=\(attempt) elapsed=\(String(format: "%.2f", elapsed)) event=\(event) central=\(state) authorization=\(CBManager.authorization.rawValue) peripheral=\(peer) desired=\(desired) lifecycle=\(applicationState) txBytes=\(sentBytes) rxBytes=\(receivedBytes) queuedBytes=\(output.count)"
        if let error {
            let e = error as NSError
            detail += " error=\(e.domain):\(e.code) \(e.localizedDescription)"
            if let cause = e.userInfo[NSUnderlyingErrorKey] as? NSError { detail += " underlying=\(cause.domain):\(cause.code) \(cause.localizedDescription)" }
        }
        onDiagnostic?(detail)
    }
    private var connectionStep = "Bluetooth connection"
    var onData: ((Data, ReceiptContext) -> Void)?
    var onFailure: ((BandError) -> Void)?
    var onAvailability: ((Bool, String) -> Void)?
    var onRestore: ((UUID) -> Void)?
    var onTick: (() -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var output = Data()
    private var loop: CFRunLoop!
    private var worker: Thread!
    private let ready = DispatchSemaphore(value: 0)
    private let delegateQueue = DispatchQueue(label: "com.runes.ios.bluetooth-delegates")
    private var timer: Timer?
    private var target: UUID?
    private var scanning = false
    private var scanSeen = Set<UUID>()
    var scanSummary: String { "Detected \(scanSeen.count) nearby Bluetooth devices." }
    private var connectDeadline: TimeInterval?
    private var applicationState = "launching"
    private var desired = false
    // Keep retired objects until Core Bluetooth confirms closure. Never reuse a
    // peripheral for another attempt while its cancellation is outstanding.
    private var retiring: [ObjectIdentifier: CBPeripheral] = [:]
    private var reportingRelease = false
    private var releaseDeadline: TimeInterval?
    private var failed = false
    private var restoredPeripherals: [CBPeripheral] = []
    private var waitingToConnect: UUID?
    // The GATT listing is read-only and runs once per launch, after the data channel opens.
    private var gattListed = false
    private var gattServicesLeft: Int?
    private var gattLogging = false
    private var pulseCharacteristics: [CBCharacteristic] = []
    private var notifyCounts: [CBUUID: Int] = [:]
    private var lastPulse: TimeInterval?
    private var pulseMissingReported = false
    private var batteryCharacteristic: CBCharacteristic?
    var isPoweredOn: Bool { central?.state == .poweredOn }
    var isUnauthorized: Bool { [.denied, .restricted].contains(CBManager.authorization) }

    override init() {
        super.init()
        worker = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, source, .defaultMode)
            ready.signal(); CFRunLoopRun()
        }
        worker.name = "Runes band session"; worker.qualityOfService = .userInitiated; worker.start(); ready.wait()
    }
    func perform(_ work: @escaping () -> Void) { CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work); CFRunLoopWakeUp(loop) }
    /// Runs `work` on the session run loop after `delay` seconds.
    func perform(after delay: TimeInterval, _ work: @escaping () -> Void) {
        perform { Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in work() } }
    }
    func start(selected: UUID?, desired: Bool) {
        perform { [self] in
            target = selected; self.desired = desired
            central = CBCentralManager(delegate: self, queue: delegateQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.runes.ios.band-central.v1", CBCentralManagerOptionShowPowerAlertKey: true])
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let deadline = self.releaseDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
                    self.releaseDeadline = nil; self.reportingRelease = false
                    self.diagnostic("local release confirmation timed out")
                    self.onClosed?(false)
                }
                self.checkPulse()
                if let deadline = self.connectDeadline, ProcessInfo.processInfo.systemUptime >= deadline { self.fail(.transport("Timed out during \(self.connectionStep). Close other band clients and accept any iPhone pairing prompt.")); return }
                self.onTick?()
            }
        }
    }
    func setApplicationState(_ state: String) { perform { self.applicationState = state } }
    func scan() {
        guard isPoweredOn else { onAvailability?(false, "Turn Bluetooth on and allow Runes access."); return }
        scanSeen.removeAll()
        scanning = true
        // This scan is explicitly requested by the visible UI. Do not depend on
        // lifecycle callbacks or advertised service UUIDs to discover the band.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func stopScan() { scanning = false; if isPoweredOn { central.stopScan() } }
    func connect(_ id: UUID) {
        attempt += 1; attemptStarted = ProcessInfo.processInfo.systemUptime
        receivedBytes = 0; sentBytes = 0
        diagnostic("connect requested target=\(id.uuidString)")
        close(); desired = true; target = id; failed = false
        // No deadline while waiting for the link: a pending connect never expires, so the
        // band reconnects whenever it comes back in range, even while the app is suspended.
        if !retiring.isEmpty { waitingToConnect = id; return }
        waitingToConnect = nil
        guard isPoweredOn else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first { attach(known) }
        else { central.scanForPeripherals(withServices: applicationState == "foreground" ? nil : [Self.advertisedService]) }
    }
    func close() {
        diagnostic("closing transport")
        stopScan(); connectDeadline = nil; failed = false
        resetChannelState()
        if let peripheral {
            if peripheral.state != .disconnected, isPoweredOn {
                retiring[ObjectIdentifier(peripheral)] = peripheral
                central.cancelPeripheralConnection(peripheral)
            }
            peripheral.delegate = nil
        }
        peripheral = nil
    }
    /// Drops everything tied to one link; the peripheral itself is left alone.
    private func resetChannelState() {
        if let channel {
            channel.inputStream.delegate = nil; channel.outputStream.delegate = nil
            channel.inputStream.close(); channel.outputStream.close()
            channel.inputStream.remove(from: .current, forMode: .default); channel.outputStream.remove(from: .current, forMode: .default)
        }
        channel = nil; output = Data(); gattServicesLeft = nil; gattLogging = false
        if pulseMissingReported { onPulse?(true) }
        pulseCharacteristics = []; notifyCounts = [:]; lastPulse = nil; pulseMissingReported = false
        batteryCharacteristic = nil
    }
    func disconnect() {
        desired = false; waitingToConnect = nil; restoredPeripherals.removeAll()
        reportingRelease = true
        close()
        if retiring.isEmpty { completeRelease() }
        else { releaseDeadline = ProcessInfo.processInfo.systemUptime + 5 }
    }
    private func completeRelease() {
        guard retiring.isEmpty else { return }
        if reportingRelease {
            reportingRelease = false; releaseDeadline = nil
            diagnostic("local Bluetooth release confirmed")
            onClosed?(true)
        }
        if let next = waitingToConnect, desired { waitingToConnect = nil; connect(next) }
    }
    /// Runs only while the app executes, so a stop is reported on the next wake at the latest.
    private func checkPulse() {
        guard channel != nil, !pulseCharacteristics.isEmpty, !pulseMissingReported, let lastPulse,
              ProcessInfo.processInfo.systemUptime - lastPulse >= Self.pulseTimeout else { return }
        pulseMissingReported = true
        diagnostic("band_pulse missing for \(Int(ProcessInfo.processInfo.systemUptime - lastPulse))s: the locked phone may stop delivering gestures")
        onPulse?(false)
    }
    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [(.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResponse"), (.notify, "notify"), (.indicate, "indicate"), (.notifyEncryptionRequired, "notifyEncrypted"), (.indicateEncryptionRequired, "indicateEncrypted")]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: "+")
    }
    private func bluetoothError(_ error: Error?, fallback: String) -> BandError {
        guard let error else { return .transport(fallback) }
        let value = error as NSError
        return .bluetooth(domain: value.domain, code: value.code, description: value.localizedDescription, fallback: fallback)
    }
    func write(_ data: Data) throws {
        guard channel != nil, !failed else { throw BandError.transport("Band channel is closed.") }
        guard output.count + data.count <= 1 << 20 else { throw BandError.wire("Band write buffer overflow.") }
        output.append(data); try flush()
    }
    private func flush() throws {
        guard let stream = channel?.outputStream else { return }
        while !output.isEmpty, stream.hasSpaceAvailable {
            let count = output.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: min(output.count, 32768)) }
            guard count >= 0 else { throw BandError.transport("L2CAP write failed.") }
            if count == 0 { break }; sentBytes += count; output = Data(output.dropFirst(count))
        }
    }
    private func fail(_ error: BandError) {
        guard !failed else { return }; failed = true; connectDeadline = nil
        diagnostic("failure step=\(connectionStep)", error: error)
        onFailure?(error)
    }
    private func progress(_ message: String) {
        diagnostic(message)
        connectionStep = message
        onProgress?(message)
    }
    private func attach(_ p: CBPeripheral) {
        guard isPoweredOn else {
            restoredPeripherals = [p]
            return
        }
        stopScan(); peripheral = p; p.delegate = self
        if p.state == .connected {
            connectDeadline = ProcessInfo.processInfo.systemUptime + 60
            progress("Bluetooth connected; discovering band service.")
            p.discoverServices([Self.service, Self.batteryService])
        } else {
            progress("Waiting for the band to accept the Bluetooth connection.")
            central.connect(p, options: Self.connectOptions)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        perform { [self] in
            diagnostic("central state changed to \(state.rawValue)")
            let message: String
            switch state {
            case .poweredOn: message = "Bluetooth ready"
            case .poweredOff: message = "Bluetooth is off. Turn it on to reconnect."
            case .unauthorized: message = "Allow Bluetooth access in Settings → Privacy & Security → Bluetooth."
            case .unsupported: message = "Bluetooth is unavailable on this device. Use a physical iPhone."
            case .resetting: message = "Bluetooth is restarting."
            default: message = "Waiting for Bluetooth."
            }
            if state == .poweredOff || state == .unauthorized || state == .unsupported {
                retiring.removeAll(); completeRelease()
            }
            if state == .poweredOn {
                let restored = restoredPeripherals
                restoredPeripherals.removeAll()
                for p in restored {
                    guard desired, p.identifier == target else {
                        central.cancelPeripheralConnection(p)
                        continue
                    }
                    failed = false
                    onRestore?(p.identifier)
                    attach(p)
                }
            }
            onAvailability?(state == .poweredOn, message)
            // A normal connect can also be requested while Bluetooth is starting.
            if state == .poweredOn, desired, peripheral == nil, waitingToConnect == nil, let target {
                connect(target)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        perform { [self] in
            // Restoration arrives before the initial powered-on callback.
            // Queue it without issuing Bluetooth commands in the unknown state.
            diagnostic("restore callback count=\(peripherals.count)")
            restoredPeripherals = peripherals
            if isPoweredOn {
                restoredPeripherals.removeAll()
                for restored in peripherals {
                    guard desired, restored.identifier == target else { central.cancelPeripheralConnection(restored); continue }
                    failed = false
                    onRestore?(restored.identifier); attach(restored)
                }
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Unnamed band"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let normalizedName = name.lowercased()
        let isBand = normalizedName.hasPrefix("meta band") || normalizedName.hasPrefix("meta neural band")
            || services.contains(Self.service) || serviceData[Self.service] != nil
        let rssi = RSSI.intValue
        perform { [self] in
            if scanning {
                scanSeen.insert(p.identifier)
                if isBand { diagnostic("band advertisement id=\(p.identifier.uuidString) rssi=\(rssi) services=\(services.map { $0.uuidString })"); onDevice?(BandDevice(id: p.identifier, name: name, rssi: rssi)) }
            }
            if desired, p.identifier == target, peripheral == nil, !scanning { attach(p) }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        perform { [self] in
            guard peripheral === p else { return }
            // Only the setup steps after the link is up have a deadline.
            connectDeadline = ProcessInfo.processInfo.systemUptime + 60
            progress("Bluetooth connected; discovering band service.")
            p.discoverServices([Self.service, Self.batteryService])
        }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        perform { [self] in
            diagnostic("didFailToConnect id=\(p.identifier.uuidString) callbackState=\(p.state.rawValue)", error: error)
            if retiring.removeValue(forKey: ObjectIdentifier(p)) != nil { completeRelease(); return }
            guard peripheral === p else { return }
            fail(bluetoothError(error, fallback: "Bluetooth connection failed."))
        }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        perform { [self] in
            diagnostic("didDisconnect id=\(p.identifier.uuidString) callbackState=\(p.state.rawValue) systemReconnecting=\(isReconnecting)", error: error)
            if retiring.removeValue(forKey: ObjectIdentifier(p)) != nil { completeRelease(); return }
            guard peripheral === p else { return }
            if let error, case .pairing = bluetoothError(error, fallback: "") { fail(bluetoothError(error, fallback: "Band disconnected.")); return }
            // Keep the peripheral and leave a connect pending right away. Core Bluetooth
            // holds it with no timeout and wakes the app when the band is back.
            resetChannelState(); connectDeadline = nil; failed = false
            if desired, !isReconnecting, isPoweredOn {
                central.connect(p, options: Self.connectOptions)
                diagnostic("pending connect left in place")
            }
            onLinkLost?(isReconnecting)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        perform { [self] in
            guard self.peripheral === peripheral else { return }
            if gattServicesLeft != nil {
                if gattLogging { diagnostic("gatt_listing services=\(services.map { $0.uuid.uuidString })", error: error) }
                gattServicesLeft = services.count
                if services.isEmpty { gattServicesLeft = nil }
                for service in services { peripheral.discoverCharacteristics(nil, for: service) }
                return
            }
            diagnostic("services discovered=\(services.map { $0.uuid.uuidString })", error: error)
            if let battery = services.first(where: { $0.uuid == Self.batteryService }) { peripheral.discoverCharacteristics([Self.batteryLevel], for: battery) }
            guard error == nil, let service = services.first(where: { $0.uuid == Self.service }) else { fail(.wire("Band does not expose the expected FEB8 service.")); return }
            progress("Band service found; discovering its channel characteristic.")
            peripheral.discoverCharacteristics([Self.psm, Self.pulse], for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristic = service.characteristics?.first { $0.uuid == Self.psm }
        let notifiable = (service.characteristics ?? []).filter { Self.pulseSources.contains($0.uuid) && !$0.properties.isDisjoint(with: [.notify, .indicate]) }
        let listing = (service.characteristics ?? []).map { "\($0.uuid.uuidString)[\(Self.describe($0.properties))]" }
        let serviceID = service.uuid.uuidString
        // CBUUID equality matches the 16-bit and 128-bit forms; the band reports the long one.
        let isBandService = service.uuid == Self.service
        let battery = service.uuid == Self.batteryService ? service.characteristics?.first { $0.uuid == Self.batteryLevel } : nil
        perform { [self] in
            guard self.peripheral === peripheral else { return }
            if let left = gattServicesLeft {
                if gattLogging { diagnostic("gatt_listing service=\(serviceID) characteristics=\(listing)", error: error) }
                gattServicesLeft = left > 1 ? left - 1 : nil
                if gattServicesLeft == nil { gattLogging = false }
                return
            }
            if serviceID == Self.batteryService.uuidString || battery != nil {
                // Subscribed once the data channel is open, after any pairing prompt.
                batteryCharacteristic = battery
                if let battery, channel != nil { subscribeBattery(battery, on: peripheral) }
                return
            }
            diagnostic("channel characteristic discovery pulseSources=\(notifiable.count)", error: error)
            if isBandService { pulseCharacteristics = notifiable }
            guard error == nil, let characteristic else { fail(.wire("Band PSM characteristic is missing.")); return }
            progress("Reading the band channel. Accept the iPhone Bluetooth pairing prompt if shown.")
            peripheral.readValue(for: characteristic)
        }
    }
    private func subscribeBattery(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
        if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = characteristic.uuid, on = characteristic.isNotifying
        perform { [self] in
            guard self.peripheral === peripheral else { return }
            diagnostic("band_pulse_subscribe uuid=\(id.uuidString) notifying=\(on)", error: error)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        perform { [self] in
            if self.peripheral === peripheral, characteristic.uuid == Self.batteryLevel {
                if error == nil, let level = value?.first { onBattery?(Int(min(level, 100))) }
                return
            }
            // Once the channel is open, a PSM value is a notification, never a reason to reopen it.
            if self.peripheral === peripheral, Self.pulseSources.contains(characteristic.uuid),
               characteristic.uuid != Self.psm || channel != nil {
                lastPulse = ProcessInfo.processInfo.systemUptime
                if pulseMissingReported { pulseMissingReported = false; diagnostic("band_pulse resumed") }
                let count = notifyCounts[characteristic.uuid, default: 0] + 1
                notifyCounts[characteristic.uuid] = count
                // A pulse arrives every ~7 s; log a sample, not every one, to spare the 4 MiB journal.
                if count <= 3 || count.isMultiple(of: 500) {
                    let bytes = value ?? Data()
                    diagnostic("band_pulse uuid=\(characteristic.uuid.uuidString) n=\(count) len=\(bytes.count) hex=\(bytes.prefix(32).map { String(format: "%02x", $0) }.joined())", error: error)
                }
                return
            }
            guard self.peripheral === peripheral, characteristic.uuid == Self.psm else { return }
            diagnostic("PSM read value=\(value.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "nil")", error: error)
            guard error == nil else { fail(bluetoothError(error, fallback: "System Bluetooth pairing failed. Check OS pairing; saved ownership identities were retained.")); return }
            // A remembered pulse subscription can deliver 0x00 here before the read reply arrives.
            if value == Data([0x00]) { diagnostic("band_pulse before channel open; waiting for the PSM read"); return }
            guard value == Data([0xff, 0x00]) else { fail(.wire("Unsupported band L2CAP PSM.")); return }
            progress("Opening the band data channel.")
            peripheral.openL2CAPChannel(255)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        perform { [self] in
            guard self.peripheral === peripheral else { channel?.inputStream.close(); channel?.outputStream.close(); return }
            diagnostic("L2CAP open callback", error: error)
            guard error == nil, let channel else { fail(bluetoothError(error, fallback: "Could not open the band L2CAP channel.")); return }
            progress("Band data channel opened.")
            self.channel = channel; connectDeadline = nil
            // Subscriptions belong to a connection, so they are renewed every time the channel opens.
            if pulseCharacteristics.isEmpty { diagnostic("band_pulse unavailable: background delivery will stop when iOS suspends the app") }
            for source in pulseCharacteristics { peripheral.setNotifyValue(true, for: source) }
            if let batteryCharacteristic { subscribeBattery(batteryCharacteristic, on: peripheral) }
            lastPulse = ProcessInfo.processInfo.systemUptime
            if !gattListed {
                gattLogging = true; gattListed = true; gattServicesLeft = 0
                peripheral.discoverServices(nil)
            }
            for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
                stream.delegate = self; stream.schedule(in: .current, forMode: .default); stream.open()
            }
            onOpen?()
        }
    }
    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        // Capture receipt metadata on the I/O thread, before UI/main-actor work.
        let receipt = ReceiptContext(wallTime: Date(), uptime: ProcessInfo.processInfo.systemUptime, applicationState: applicationState)
        // Closed streams can already have queued delegate events. Never apply
        // those events to a replacement channel opened during enrollment recovery.
        guard !failed, let activeChannel = channel,
              stream === activeChannel.inputStream || stream === activeChannel.outputStream else { return }
        do {
            if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { throw BandError.transport("L2CAP stream closed or failed (code \(stream.streamError.map { ($0 as NSError).code } ?? 0)).") }
            if eventCode.contains(.hasSpaceAvailable) { try flush() }
            if eventCode.contains(.hasBytesAvailable), let input = stream as? InputStream {
                var buffer = [UInt8](repeating: 0, count: 32768)
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { throw BandError.transport(count == 0 ? "L2CAP input ended." : "L2CAP read failed (code \(input.streamError.map { ($0 as NSError).code } ?? 0)).") }
                receivedBytes += count
                onData?(Data(buffer.prefix(count)), receipt)
            }
        } catch let error as BandError { fail(error) }
        catch { fail(.transport("Band stream failed.")) }
    }
}
