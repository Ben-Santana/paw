import AppKit
import CoreBluetooth
import CryptoKit
import CoreImage

/// A hardware test receiver. It reports deliveries without invoking desktop actions.
final class MacRelayProbe: NSObject, NSApplicationDelegate, CBPeripheralManagerDelegate {
    private let serviceID = CBUUID(string: RelayWire.service)
    private let control = CBMutableCharacteristic(type: CBUUID(string: RelayWire.control), properties: [.notify], value: nil, permissions: [])
    private let eventsID = CBUUID(string: RelayWire.events)
    private let bondID = CBUUID(string: RelayWire.bond)
    private var manager: CBPeripheralManager?
    private var peer: CBCentral?
    private var framer = RelayWire.Framer()
    private var macChallenge: Data?
    private var cipher: RelayWire.Cipher?
    private var authorized = false
    private var applied = false
    private var outgoing = Data()
    private var demand = RelayWire.Demand.gestures
    private var sleeping = false
    private var key: Data?
    private var counts: [RelayWire.Event.Kind: Int] = [:]
    private var window: NSWindow?
    private let qr = NSImageView()
    private let status = NSTextField(labelWithString: "Starting Bluetooth…")
    private let totals = NSTextField(labelWithString: "")
    private let select = NSSegmentedControl(labels: ["Gestures", "Gestures + motion", "Paused"], trackingMode: .selectOne, target: nil, action: nil)
    private var hideQR: Timer?
    private let heartbeatSelect = NSSegmentedControl(labels: ["Off", "10 s", "5 s", "2 s"], trackingMode: .selectOne, target: nil, action: nil)
    private let wakeStatus = NSTextField(labelWithString: "Heartbeat off")
    private let trialStatus = NSTextField(labelWithString: "No timed run")
    private let runButton = NSButton(title: "Start timed run", target: nil, action: nil)
    private let heartbeatIntervals: [TimeInterval?] = [nil, 10, 5, 2]
    private var heartbeatTimer: Timer?
    private var clock: Timer?
    private var heartbeatSequence: UInt64 = 0
    private var heartbeatsInFlight: [UInt64: Date] = [:]
    private var heartbeatsSent = 0
    private var acksReceived = 0
    private var lastAck: Date?
    private var longestAckSilence: TimeInterval = 0
    private var clockOffset: TimeInterval?
    private var wokeAt: Date?
    private var trials = WakeTrials(schedule: MacRelayProbe.trialSchedule(), window: 30)
    private var wakeLog: WakeLog?
    private var appActivity: NSObjectProtocol?
    private var runActivity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        self.window = window
        window.title = "Neural BLE test receiver"
        window.setContentSize(NSSize(width: 460, height: 590))
        heartbeatSelect.selectedSegment = 0
        heartbeatSelect.target = self
        heartbeatSelect.action = #selector(changeHeartbeat)
        runButton.target = self
        runButton.action = #selector(toggleRun)
        let reveal = NSButton(title: "Show log", target: self, action: #selector(revealLog))
        let runRow = NSStackView(views: [runButton, reveal])
        // A hidden probe must keep its timing; App Nap would look like a phone failure.
        appActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Timing the wake test")
        wakeLog = try? WakeLog()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        select.selectedSegment = 0
        select.target = self
        select.action = #selector(changeDemand)
        let button = NSButton(title: "Show pairing QR", target: self, action: #selector(showQR))
        qr.imageScaling = .scaleProportionallyUpOrDown
        let stack = NSStackView(views: [status, totals, select, heartbeatSelect, wakeStatus, trialStatus, runRow, button, qr])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                qr.widthAnchor.constraint(equalToConstant: 250),
                qr.heightAnchor.constraint(equalToConstant: 250)
            ])
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            if let saved = try RelayKeyStore.load() {
                key = saved
            } else {
                let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try RelayKeyStore.save(fresh)
                key = fresh
                showQR()
            }
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } catch {
            status.stringValue = error.localizedDescription
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.record("mac_sleep")
            self?.sendDemand()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.wokeAt = Date()
            self?.record("mac_wake")
            self?.sendDemand()
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func showQR() {
        guard let key else { return }
        let invitation = RelayWire.Invitation(key: key, expires: Date().addingTimeInterval(120))
        guard let data = try? JSONEncoder().encode(invitation),
              let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": data]),
              let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return }
        qr.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        hideQR?.invalidate()
        hideQR = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.qr.image = nil }
    }

    @objc private func changeDemand() {
        demand = select.selectedSegment == 0 ? .gestures : select.selectedSegment == 1 ? .motion : .idle
        sendDemand()
    }

    private var currentDemand: RelayWire.Demand { sleeping ? .idle : demand }

    @objc private func changeHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heartbeatsInFlight.removeAll()
        let interval = heartbeatIntervals[heartbeatSelect.selectedSegment]
        record("heartbeat_interval", detail: interval.map { String($0) } ?? "off")
        guard let interval else { wakeStatus.stringValue = "Heartbeat off"; return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sendHeartbeat() }
        sendHeartbeat()
    }

    private func sendHeartbeat() {
        // Never queue behind an undelivered frame: a backlog would hide how the link behaves.
        guard authorized, !sleeping, outgoing.isEmpty, let cipher else { return }
        var sealing = cipher
        heartbeatSequence += 1
        let now = Date()
        do {
            outgoing.append(try sealing.seal(.heartbeat(.init(sequence: heartbeatSequence, macTime: now))))
            self.cipher = sealing
            heartbeatsInFlight[heartbeatSequence] = now
            heartbeatsSent += 1
            flush()
        } catch { restartHandshake() }
    }

    private func acknowledged(_ ack: RelayWire.HeartbeatAck) {
        let now = Date()
        var roundTrip: TimeInterval?
        if let sent = heartbeatsInFlight.removeValue(forKey: ack.sequence) {
            roundTrip = now.timeIntervalSince(sent)
            clockOffset = WakeTrials.clockOffset(sent: sent, phone: ack.phoneTime, received: now)
        }
        if let lastAck { longestAckSilence = max(longestAckSilence, now.timeIntervalSince(lastAck)) }
        lastAck = now
        acksReceived += 1
        if let wokeAt {
            record("relink_after_mac_wake", seconds: now.timeIntervalSince(wokeAt))
            self.wokeAt = nil
        }
        record("heartbeat_ack", sequence: ack.sequence, seconds: roundTrip, ack: ack)
    }

    @objc private func toggleRun() {
        if trials.isRunning {
            trials.cancel()
            finishRun("cancelled")
        } else {
            trials.start(at: Date())
            runActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Timed wake test")
            runButton.title = "Stop timed run"
            record("run_started", detail: trials.schedule.map { String(Int($0)) }.joined(separator: " "))
        }
        updateTrialStatus()
    }

    private func finishRun(_ outcome: String) {
        if let runActivity { ProcessInfo.processInfo.endActivity(runActivity) }
        runActivity = nil
        runButton.title = "Start timed run"
        let hits = trials.results.filter { $0.latency != nil }.count
        record("run_\(outcome)", detail: "hits=\(hits)/\(trials.results.count) acks=\(acksReceived)/\(heartbeatsSent) longest_ack_silence=\(String(format: "%.1f", longestAckSilence))")
    }

    private func tick() {
        for action in trials.tick(now: Date()) {
            switch action {
            case .prompt(let index):
                NSSound(named: "Glass")?.play()
                record("trial_prompt", sequence: UInt64(index))
            case .missed(let index):
                record("trial_miss", sequence: UInt64(index))
            case .finished:
                finishRun("finished")
            }
            updateTrialStatus()
        }
        guard heartbeatTimer != nil else { return }
        let age = lastAck.map { String(format: "%.1f s ago", Date().timeIntervalSince($0)) } ?? "none yet"
        wakeStatus.stringValue = "Acks \(acksReceived)/\(heartbeatsSent) · last \(age) · longest silence \(String(format: "%.1f", longestAckSilence)) s"
    }

    private func updateTrialStatus() {
        let lines = trials.results.map { result in
            let minutes = String(format: "%g", result.dueAfter / 60)
            return result.latency.map { "\(minutes) min: \(String(format: "%.2f", $0)) s" } ?? "\(minutes) min: missed"
        }
        trialStatus.stringValue = lines.isEmpty ? (trials.isRunning ? "Run started. Gesture at each chime." : "No timed run") : lines.joined(separator: " · ")
    }

    @objc private func revealLog() {
        guard let url = wakeLog?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func record(_ event: String, sequence: UInt64? = nil, seconds: TimeInterval? = nil, ack: RelayWire.HeartbeatAck? = nil, detail: String = "") {
        wakeLog?.write(event: event, sequence: sequence, seconds: seconds, offset: clockOffset, ack: ack, detail: detail)
    }

    private static func trialSchedule() -> [TimeInterval] {
        // Minutes after the run starts. NEURAL_WAKE_SCHEDULE="0.5,1" shortens a rehearsal.
        let text = ProcessInfo.processInfo.environment["NEURAL_WAKE_SCHEDULE"] ?? "1,5,15,30,60"
        return text.split(separator: ",").compactMap { Double($0) }.map { $0 * 60 }
    }

    private func sendDemand() {
        guard authorized else { return }
        applied = false
        log("demand active=\(currentDemand.active) gyro=\(currentDemand.gyro) orientation=\(currentDemand.orientation)")
        do {
            outgoing.append(try cipher!.seal(.demand(currentDemand)))
            guard outgoing.count <= RelayWire.maxFrame * 2 else { throw RelayWire.Failure.invalidFrame }
            flush()
        } catch { restartHandshake() }
    }

    private func resetLink() {
        peer = nil
        macChallenge = nil
        cipher = nil
        authorized = false
        applied = false
        framer = RelayWire.Framer()
        outgoing.removeAll()
    }

    private func restartHandshake() {
        guard let peer, key != nil else { return }
        resetLink()
        self.peer = peer
        log("handshake_started")
        let challenge = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        do {
            macChallenge = challenge
            outgoing = try RelayWire.frame(challenge)
            status.stringValue = "Authenticating iPhone…"
            flush()
        } catch { resetLink() }
    }

    private func flush() {
        guard let manager, let peer, peer.maximumUpdateValueLength > 0 else { return }
        while !outgoing.isEmpty {
            let count = min(outgoing.count, peer.maximumUpdateValueLength)
            guard manager.updateValue(Data(outgoing.prefix(count)), for: control, onSubscribedCentrals: [peer]) else { return }
            outgoing.removeFirst(count)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            resetLink()
            status.stringValue = peripheral.state == .unauthorized ? "Allow Bluetooth access in System Settings." : "Waiting for Bluetooth"
            return
        }
        peripheral.stopAdvertising()
        peripheral.removeAllServices()
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [control, CBMutableCharacteristic(type: eventsID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable]),
                                   CBMutableCharacteristic(type: bondID, properties: [.read], value: nil, permissions: [.readEncryptionRequired])]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { status.stringValue = "Could not publish the test service."; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        status.stringValue = error == nil ? "Waiting for iPhone" : "Bluetooth advertising failed"
        log(error == nil ? "advertising" : "advertising_failed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == control.uuid else { return }
        // Authentication decides who is accepted. A rotated Bluetooth ID must not lock the phone out.
        peer = central
        peripheral.setDesiredConnectionLatency(.low, for: central)
        record("subscribed", detail: central.identifier.uuidString)
        restartHandshake()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == control.uuid, central.identifier == peer?.identifier else { return }
        resetLink()
        status.stringValue = "Waiting for iPhone"
        log("link_closed")
        record("link_closed")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == bondID else { peripheral.respond(to: request, withResult: .attributeNotFound); return }
        request.value = Data([1])
        peripheral.respond(to: request, withResult: .success)
        record("bonded_read", detail: request.central.identifier.uuidString)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        do {
            for request in requests {
                guard request.central.identifier == peer?.identifier, request.characteristic.uuid == eventsID,
                      let bytes = request.value else { continue }
                for frame in try framer.append(bytes) {
                    if cipher == nil {
                        guard let key, let macChallenge, frame.count == 32 else { throw RelayWire.Failure.invalidFrame }
                        cipher = try RelayWire.Cipher(key: key, challenge: macChallenge + frame, isPhone: false)
                        continue
                    }
                    let message = try cipher!.open(frame)
                    switch message {
                    case .hello where !authorized:
                        authorized = true
                        qr.image = nil
                        sendDemand()
                    case .ready(let state) where authorized:
                        applied = state == currentDemand && currentDemand.active
                        status.stringValue = applied ? "Receiving from iPhone" : currentDemand.active ? "Waiting for band" : "Relay paused"
                        log("ready \(applied) at=\(Date().timeIntervalSince1970)")
                    case .heartbeatAck(let ack) where authorized:
                        acknowledged(ack)
                    case .event(let event) where authorized:
                        guard applied else { continue }
                        if event.kind == .gyro && !currentDemand.gyro { continue }
                        if event.kind == .orientation && !currentDemand.orientation { continue }
                        report(event)
                    default:
                        throw RelayWire.Failure.invalidFrame
                    }
                }
            }
        } catch {
            log("relay_frame_rejected \(String(describing: type(of: error)))")
            restartHandshake()
        }
    }

    private func log(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }

    private func report(_ event: RelayWire.Event) {
        if event.kind == .gesture {
            let now = Date()
            // Phone app receipt to Mac receipt. Time iOS held the data while the app was
            // suspended happens before phoneTime, so only trial latency can reveal it.
            let transit = clockOffset.map { now.timeIntervalSince(event.phoneTime) + $0 }
            record("gesture", sequence: event.sequence, seconds: transit)
            if let result = trials.gesture(at: now) {
                record("trial_hit", sequence: UInt64(result.index), seconds: result.latency)
                updateTrialStatus()
            }
        }
        let count = counts[event.kind, default: 0] + 1
        counts[event.kind] = count
        if event.kind == .gesture || count == 1 || count.isMultiple(of: 100) {
            totals.stringValue = "Gestures \(counts[.gesture, default: 0]) · Gyro \(counts[.gyro, default: 0]) · Orientation \(counts[.orientation, default: 0])"
            log("event \(event.kind.rawValue) seq=\(event.sequence) phone=\(event.phoneTime.timeIntervalSince1970) mac=\(Date().timeIntervalSince1970)")
        }
    }
}

/// One CSV per launch. Holds timing and state only, never keys or gesture content.
final class WakeLog {
    let url: URL
    private let handle: FileHandle

    init() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NeuralWakeTest", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        url = folder.appendingPathComponent("run-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("wall_time,event,sequence,seconds,clock_offset,phone_state,band_state,band_data_age,suspension_gaps,longest_gap,battery,low_power,detail\n".utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func write(event: String, sequence: UInt64?, seconds: TimeInterval?, offset: TimeInterval?, ack: RelayWire.HeartbeatAck?, detail: String) {
        func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        let fields = [String(format: "%.3f", Date().timeIntervalSince1970), event, sequence.map(String.init) ?? "", number(seconds), number(offset),
                      ack?.applicationState ?? "", ack?.bandState ?? "", number(ack?.bandDataAge),
                      ack.map { String($0.suspensionGaps) } ?? "", number(ack?.longestGap),
                      number(ack?.batteryLevel.map(Double.init)), ack.map { String($0.lowPowerMode) } ?? "", detail]
        try? handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
    }
}

@main
struct MacRelayProbeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacRelayProbe()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
