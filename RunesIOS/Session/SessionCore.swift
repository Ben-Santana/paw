import Foundation
import OSLog
import CryptoKit

/// Owned by the app; every method and callback below runs on transport.perform.
final class SessionCore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.runes.ios", category: "BandConnection")
    let transport = BandTransport()
    var onSnapshot: ((SessionSnapshot) -> Void)?
    var onRelayEvent: ((RelayWire.Event) -> Void)?
    var onRelayReady: ((RelayWire.Demand?) -> Void)?
    private var relayDemand = RelayWire.Demand.idle
    private var pendingStreams: RelayWire.Demand?
    private var activeStreams: RelayWire.Demand?
    /// Motion streams the phone itself needs (combos with rotation or movement steps).
    private var localMotion = false
    /// EMG is only requested while a Motion Lab recording runs.
    private var localEMG = false
    /// Per connection: the EMG layout was read and validated.
    private var emgReady = false
    private var emgReading = false
    private var activeEMG = false
    private var pendingEMG: Bool?
    /// Why EMG is off until the next recording asks again.
    private var emgBlocked: String?
    /// An unexpected EMG failure dropped the link once; never ask again this app run.
    private var emgHardBlocked = false
    /// Every raw band sample (gyro, orientation, EMG, gesture) while streaming, for the Motion Lab.
    var onRaw: ((RawSample) -> Void)?
    var onEMGStatus: ((String) -> Void)?
    /// Orientation and gyroscope samples, whether they were started for the Mac or for this phone.
    var onMotion: ((RelayWire.Event.Kind, [Double]) -> Void)?
    var onGesture: ((GestureEvent) -> Void)?
    /// One call per physical gesture (plus the end of a hold); drives haptics and animation.
    var onBandGesture: ((BandGesture) -> Void)?
    private var interpreter = GestureInterpreter()
    var onOwnership: ((OwnershipStep, MetaSession, UUID) -> Void)?
    /// Asks the app to hold background execution while a timed retry is waiting.
    var onRetryWait: ((Bool) -> Void)?
    private var snapshot = SessionSnapshot()
    private let identities = IdentityStore()
    private var journal: EventJournal?
    private var proto: BandProtocol?
    private var enrollment: OwnershipCeremony?
    private var meta: MetaSession?
    private var enrollmentAttempt: UUID?
    private var candidate: BandIdentity?
    private var candidateAccount: UUID?
    private var candidatePending = false
    private var identityConfirmation = IdentityConfirmation()
    private var sessionID = UUID()
    private var sequences = SequenceTracker()
    private var appState = "launching"
    private var failures = 0
    private var reconnectAt: TimeInterval? { didSet { if (oldValue == nil) != (reconnectAt == nil) { onRetryWait?(reconnectAt != nil) } } }
    private var waitingSince: TimeInterval?
    private var scanUntil: TimeInterval?
    private var releaseCompletion: ((Bool) -> Void)?
    private var stoppingUntil: TimeInterval?
    private var userRecoveryRequired = false
    private var available = false
    private var started = false
    private var handRequested = false
    private static let notNearbyAfter: TimeInterval = 30

    init() {
        let defaults = UserDefaults.standard
        snapshot.selected = defaults.string(forKey: "selectedBand").flatMap(UUID.init(uuidString:))
        snapshot.wantsConnection = defaults.bool(forKey: "wantsConnection")
        if let hand = defaults.string(forKey: "bandHand") { snapshot.hand = Handedness(rawValue: hand) }
        transport.onDevice = { [weak self] device in
            guard let self else { return }
            if let i = self.snapshot.devices.firstIndex(where: { $0.id == device.id }) { self.snapshot.devices[i] = device } else { self.snapshot.devices.append(device) }
            self.publish()
        }
        transport.onAvailability = { [weak self] ready, message in self?.availability(ready, message: message) }
        transport.onDiagnostic = { [weak self] message in
            guard let self else { return }
            self.logger.info("\(message, privacy: .public)")
            self.record("bluetooth_diagnostic", message)
        }
        transport.onProgress = { [weak self] message in
            guard let self else { return }
            self.logger.info("Bluetooth: \(message, privacy: .public)")
            self.snapshot.message = message
            self.record("transport", message)
            self.publish()
        }
        transport.onOpen = { [weak self] in self?.opened() }
        transport.onData = { [weak self] data, receipt in self?.received(data, receipt: receipt) }
        transport.onFailure = { [weak self] error in self?.fail(error) }
        transport.onLinkLost = { [weak self] systemReconnecting in self?.linkLost(systemReconnecting) }
        transport.onBattery = { [weak self] level in
            guard let self, self.snapshot.battery != level else { return }
            self.snapshot.battery = level; self.record("battery", "level=\(level)"); self.publish()
        }
        transport.onPulse = { [weak self] healthy in
            guard let self else { return }
            if healthy { if self.snapshot.issue == .pulseMissing { self.snapshot.issue = nil } }
            else if self.snapshot.issue == nil { self.snapshot.issue = .pulseMissing }
            self.publish()
        }
        transport.onClosed = { [weak self] confirmed in
            guard let self, self.snapshot.state == .disconnecting else { return }
            let completion = self.releaseCompletion; self.releaseCompletion = nil
            self.snapshot.issue = confirmed ? nil : .stillReleasing
            self.transition(confirmed ? .disconnected : .failed, confirmed
                ? "Bluetooth release confirmed locally."
                : "Bluetooth release was not confirmed. Automatic connection is paused.")
            completion?(confirmed)
        }
        transport.onTick = { [weak self] in self?.tick() }
        transport.onRestore = { [weak self] id in
            guard let self else { return }
            self.proto = nil; self.sequences.reset(); self.interpreter.reset(); self.sessionID = UUID(); self.snapshot.selected = id
            self.pendingStreams = nil; self.activeStreams = nil; self.resetEMG()
            self.snapshot.connectionAttempt.begin()
            self.record("restoration", "Restored peripheral; a new authenticated channel is required.")
            self.transition(.connecting, "Restoring band connection.")
        }
    }
    /// Loads stored state. Bluetooth starts separately, so first-run onboarding can ask for it.
    func start(bluetooth: Bool) {
        transport.perform { [self] in
            do { journal = try EventJournal() } catch { snapshot.journalError = "Journal unavailable. Unlock the phone and retry journal access." }
            do { try refreshIdentities() } catch { snapshot.message = error.localizedDescription }
            publish()
        }
        if bluetooth { startBluetooth() }
    }
    func startBluetooth() {
        guard !started else { return }
        started = true
        transport.start(selected: snapshot.selected, desired: snapshot.wantsConnection)
    }
    private func context() -> ReceiptContext { ReceiptContext(wallTime: Date(), uptime: ProcessInfo.processInfo.systemUptime, applicationState: appState) }
    private func publish() { onSnapshot?(snapshot) }
    private func transition(_ state: SessionState, _ message: String) {
        logger.info("Session \(state.rawValue, privacy: .public): \(message, privacy: .public)")
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .connecting, .reconnecting, .authenticating, .subscribing, .enrolling: if waitingSince == nil { waitingSince = now }
        default: waitingSince = nil
        }
        if state == .streaming, snapshot.issue != .pulseMissing { snapshot.issue = nil }
        if state == .subscribing { snapshot.connectionAttempt.reach(.subscribing) }
        if state == .streaming { snapshot.connectionAttempt.reach(.ready) }
        snapshot.state = state; snapshot.message = message
        WakeProbe.shared.setBandState(state.rawValue)
        if state != .streaming { onRelayReady?(nil) }
        record("connection", "\(state.rawValue): \(message)"); publish()
    }
    private func record(_ kind: String, _ message: String? = nil, event: GestureEvent? = nil, receipt: ReceiptContext? = nil) {
        do {
            if journal == nil { journal = try EventJournal() }
            try journal?.append(kind: kind, receipt: receipt ?? context(), session: sessionID, message: message, gesture: event)
            snapshot.journalError = nil
        } catch { snapshot.journalError = "Event journal could not be written. Background evidence may be incomplete." }
    }
    func lifecycle(_ state: String) {
        appState = state; transport.setApplicationState(state)
        WakeProbe.shared.setApplicationState(state)
        record("lifecycle", state); publish()
    }
    func scan() {
        guard !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        guard available else { snapshot.issue = .bluetoothOff; transition(.failed, "Scan requested while Bluetooth is unavailable."); return }
        snapshot.devices = []; snapshot.issue = nil; transport.scan(); scanUntil = ProcessInfo.processInfo.systemUptime + 30
        transition(.scanning, "Looking for nearby Meta bands.")
    }
    func stopScan() {
        guard snapshot.state == .scanning else { return }
        scanUntil = nil; transport.stopScan(); transition(.disconnected, "Scan stopped.")
    }
    func refreshIdentityChoices() {
        do { try refreshIdentities(); publish() } catch { fail(error) }
    }
    private func refreshIdentities() throws {
        snapshot.identityChoices = try identities.choices()
        if let selected = snapshot.selected { snapshot.identityAccount = identities.account(for: selected) }
    }
    func select(_ device: BandDevice) { select(id: device.id) }
    func select(id: UUID) {
        guard !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        snapshot.selected = id
        snapshot.connectionAttempt = ConnectionAttempt()
        snapshot.issue = nil
        UserDefaults.standard.set(id.uuidString, forKey: "selectedBand")
        do { try refreshIdentities() } catch { fail(error); return }
        snapshot.identityFingerprint = nil
        publish()
    }
    /// The saved identity to try for a band with a new Bluetooth identifier, if one exists.
    /// It is bound to the new identifier only after it authenticates.
    func reusableAccount() -> UUID? {
        guard let id = snapshot.selected else { return nil }
        let own = identities.account(for: id)
        if snapshot.identityChoices.contains(where: { $0.account == own && $0.eligible }) { return own }
        return snapshot.identityChoices.first(where: { $0.eligible && !$0.pending })?.account
    }
    private func setIntent(_ desired: Bool) {
        snapshot.wantsConnection = desired; UserDefaults.standard.set(desired, forKey: "wantsConnection")
    }
    private func chooseCandidate(account: UUID? = nil, pending: Bool? = nil) throws {
        guard let id = snapshot.selected else { throw BandError.storage("Select a band first.") }
        let account = account ?? identities.account(for: id)
        let saved = try identities.load(account)
        let waiting = try identities.load(account, pending: true)
        let choice = try ConnectionIdentitySelection.choose(saved: saved, pending: waiting, preferPending: pending)
        candidate = choice.identity; candidateAccount = account; candidatePending = choice.pending
        snapshot.identityAccount = account; snapshot.identityFingerprint = try choice.identity.publicFingerprint
    }
    func connect(account: UUID? = nil, pending: Bool? = nil) {
        guard snapshot.selected != nil, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        transport.stopScan(); scanUntil = nil; userRecoveryRequired = false; failures = 0; reconnectAt = nil
        snapshot.connectionAttempt.begin()
        do {
            try chooseCandidate(account: account ?? reusableAccount(), pending: pending)
            enrollment = nil; meta = nil; enrollmentAttempt = nil; identityConfirmation.cancel()
            snapshot.issue = nil
            setIntent(true); beginConnection()
        } catch { fail(error) }
    }
    func importIdentity(_ identity: BandIdentity, for id: UUID) {
        guard appState == "foreground", snapshot.selected == id,
              !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        // Keep the saved identity intact until the imported candidate authenticates.
        do {
            let account = identities.account(for: id)
            try identities.save(identity, for: account, pending: true)
            try refreshIdentities()
            connect(account: account, pending: true)
        } catch { fail(error) }
    }
    func beginEnrollment(_ session: MetaSession, for id: UUID) {
        guard snapshot.selected == id, appState == "foreground", stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        snapshot.connectionAttempt.begin()
        do {
            transport.disconnect(); proto = nil; reconnectAt = nil; userRecoveryRequired = false; failures = 0
            let account = identities.account(for: id)
            candidateAccount = account; candidatePending = true
            let previous = try identities.load(account, pending: true)
            enrollment = try OwnershipCeremony(previous: previous, allowMissingBandKey: true) { [identities] record in try identities.save(record, for: account, pending: true) }
            meta = session; enrollmentAttempt = UUID(); candidate = nil; identityConfirmation.cancel()
            snapshot.issue = nil
            setIntent(true); beginConnection()
        } catch { fail(error) }
    }
    private func beginConnection() {
        guard snapshot.wantsConnection, let id = snapshot.selected else { return }
        proto = nil; sequences.reset(); interpreter.reset(); sessionID = UUID(); handRequested = false
        pendingStreams = nil; activeStreams = nil; resetEMG()
        snapshot.connectionAttempt.begin()
        guard available else { transition(.reconnecting, "Waiting for Bluetooth to become available."); return }
        transition(enrollment == nil ? .connecting : .enrolling, enrollment == nil ? "Connecting to your band." : "Enrolling this phone with the band.")
        transport.connect(id)
    }
    private func opened() {
        guard snapshot.wantsConnection else { transport.disconnect(); return }
        if snapshot.connectionAttempt.startedAt == nil { snapshot.connectionAttempt.begin() }
        snapshot.connectionAttempt.reach(.channelOpen)
        do {
            identityConfirmation.beginConnection()
            if enrollment == nil, candidate == nil { try chooseCandidate(account: reusableAccount()) }
            if let candidate {
                let publicPoint = try P256.Signing.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.x963Representation.dropFirst()
                let fingerprint = SHA256.hash(data: Data(publicPoint)).map { String(format: "%02x", $0) }.joined()
                let summary = "Identity fingerprint=\(fingerprint) stage=\(candidate.stage) hasBandKey=\(candidate.bandPoint != nil) compatibility=\(candidate.allowMissingBandKey == true) privateKeyBytes=\(candidate.privateKey.count)"
                logger.info("\(summary, privacy: .public)")
                record("identity_diagnostic", summary)
            }
            proto = try BandProtocol(identity: enrollment == nil ? candidate : nil, ceremony: enrollment)
            snapshot.connectionAttempt.reach(.encryption)
            transition(enrollment == nil ? .authenticating : .enrolling, enrollment == nil ? candidate?.bandPoint == nil ? "Authenticating phone in compatibility mode; band identity is unverified." : "Verifying the band and phone identity." : "Completing ownership enrollment; compatibility mode is allowed if Meta omits the band key.")
            try transport.write(proto!.start(now: ProcessInfo.processInfo.systemUptime))
        } catch { fail(error) }
    }
    private func received(_ data: Data, receipt: ReceiptContext) {
        WakeProbe.shared.noteBandData()
        guard let proto else { return }
        do {
            let oldStage = proto.stage
            let oldEnrollmentStage = enrollment?.record.stage
            let (output, signals) = try proto.feed(data, now: receipt.uptime)
            if oldStage != proto.stage || oldEnrollmentStage != enrollment?.record.stage {
                protocolProgress()
            }
            if !output.isEmpty { try transport.write(output) }
            for signal in signals { try handle(signal, receipt: receipt) }
        } catch { fail(error) }
    }
    private func rpc(_ operation: String, _ channel: UInt16, _ field: Int, _ payload: Data = Data()) throws {
        guard let proto else { throw BandError.transport("Band protocol is not active.") }
        try transport.write(proto.request(operation, channel: channel, field: field, payload: payload, now: ProcessInfo.processInfo.systemUptime))
    }
    func recordRelayDiagnostic(_ message: String) {
        record("relay", message)
    }
    /// Detail that belongs in the journal rather than on screen.
    func note(_ kind: String, _ message: String) { record(kind, message) }

    func setRelayDemand(_ demand: RelayWire.Demand) {
        if relayDemand != demand {
            record("relay", "Mac requested active=\(demand.active) gyro=\(demand.gyro) orientation=\(demand.orientation)")
        }
        relayDemand = demand
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    func setLocalMotion(_ on: Bool) {
        guard localMotion != on else { return }
        localMotion = on
        record("mappings", on ? "Motion streams requested for combos." : "Combos no longer need motion streams.")
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    func setLocalEMG(_ on: Bool) {
        guard localEMG != on else { return }
        localEMG = on
        if on {
            emgBlocked = nil
            if emgHardBlocked { emgStatus("EMG is off for this app run after an earlier failure. Relaunch to retry.") }
        }
        record("motion_lab", on ? "EMG requested for a recording." : "Recording ended; EMG no longer requested.")
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    private func resetEMG() { emgReady = false; emgReading = false; activeEMG = false; pendingEMG = nil }
    private func emgStatus(_ text: String) { record("emg", text); onEMGStatus?(text) }

    private func reconcileStreams() throws {
        guard pendingStreams == nil, !emgReading else { return }
        let wantEMG = localEMG && emgBlocked == nil && !emgHardBlocked
        if wantEMG && !emgReady {
            // Never enable EMG before its layout has been read and validated.
            emgReading = true
            emgStatus("Reading the band’s EMG configuration.")
            try rpc("emg_configuration", 7, 5)
            return
        }
        // The relay only forwards the streams the Mac asked for (see onRelayReady), so streams
        // started for this phone's combos never reach the Mac.
        let requested = RelayWire.Demand(active: true, gyro: (relayDemand.active && relayDemand.gyro) || localMotion,
                                         orientation: (relayDemand.active && relayDemand.orientation) || localMotion)
        if activeStreams == requested, activeEMG == wantEMG {
            onRelayReady?(relayDemand)
            return
        }
        onRelayReady?(nil)
        try rpc("start_streams", 5, 4, BandProtocol.streamFlags(gyro: requested.gyro, orientation: requested.orientation, emg: wantEMG))
        pendingStreams = requested; pendingEMG = wantEMG
    }

    /// Reads the wrist setting once per connection, as the Mac app does. A band that
    /// rejected the read twice is not asked again, so it can never cause a reconnect loop.
    private func requestHand() {
        let defaults = UserDefaults.standard, attempts = defaults.integer(forKey: "handReadAttempts")
        guard !handRequested, attempts < 2 else { return }
        handRequested = true
        defaults.set(attempts + 1, forKey: "handReadAttempts")
        do { try rpc("read_hand", 6, 5) } catch { record("hand", "Hand read not sent.") }
    }

    private func handle(_ signal: BandProtocol.Signal, receipt: ReceiptContext) throws {
        switch signal {
        case .enrolled(let identity): candidate = identity; identityConfirmation.enrolled()
        case .ready:
            let result = try identityConfirmation.authenticated {
                guard let id = snapshot.selected, let account = candidateAccount, var candidate, candidate.canAuthenticate else { throw BandError.authentication("No usable host identity is selected. Choose a saved identity or import the Mac QR.") }
                candidate.stage = candidate.bandPoint == nil ? "host_verified" : "verified"
                try identities.save(candidate, for: account)
                if candidatePending { try identities.clearPending(account) }
                identities.bind(id, to: account)
                candidatePending = false
                self.candidate = candidate
                try refreshIdentities()
            }
            if result == .reconnect {
                enrollment = nil; meta = nil; enrollmentAttempt = nil
                beginConnection(); return
            }
            guard result == .committed else { return }
            transition(.subscribing, "Enabling the band's gesture stream.")
            try rpc("request_active", 6, 5, PB.field(6, 2))
        case .reply(let operation, let payload):
            switch operation {
            case "request_active": try rpc("input_subscription", 5, 4)
            case "input_subscription": try reconcileStreams()
            case "emg_configuration":
                emgReading = false
                switch EMG.configuration(payload) {
                case .success(let summary): emgReady = true; emgStatus("EMG configuration OK: \(summary).")
                case .failure(let error): emgBlocked = error.localizedDescription; emgStatus(error.localizedDescription)
                }
                if snapshot.state == .streaming || pendingStreams == nil { try reconcileStreams() }
            case "start_streams":
                activeStreams = pendingStreams
                pendingStreams = nil
                let emgOn = pendingEMG ?? false
                if emgOn != activeEMG { emgStatus(emgOn ? "EMG streaming." : "EMG stopped.") }
                activeEMG = emgOn; pendingEMG = nil
                if stoppingUntil != nil {
                    try rpc("stop_streams", 5, 4, BandProtocol.stopFlags)
                } else {
                    if snapshot.state != .streaming {
                        failures = 0
                        snapshot.startedAt = Date()
                        transition(.streaming, candidate?.bandPoint == nil ? "Receiving band gestures. Compatibility mode: band identity is unverified." : "Receiving band gestures.")
                        requestHand()
                    }
                    try reconcileStreams()
                }
            case "stop_streams": finishDisconnect()
            case "read_hand":
                if let config = try? Fields(Fields(payload).bytes(6)), let value = try? config.integer(10), value <= 1 {
                    let hand: Handedness = value == 1 ? .left : .right
                    snapshot.hand = hand
                    UserDefaults.standard.set(hand.rawValue, forKey: "bandHand")
                    UserDefaults.standard.set(0, forKey: "handReadAttempts")
                    record("hand", hand.rawValue); publish()
                } else { record("hand", "Hand reply could not be read.") }
            default: break
            }
        case .ownership(let step):
            guard let meta, let attempt = enrollmentAttempt else { throw BandError.authentication("Enrollment login expired. Sign in again.") }
            onOwnership?(step, meta, attempt)
        case .emgUnavailable(let reason):
            emgReading = false; emgBlocked = reason
            emgStatus(reason)
            if pendingStreams != nil { pendingStreams = nil; pendingEMG = nil }
            try reconcileStreams()
        case .emg(let values, let sequence, let timestamp):
            guard snapshot.state == .streaming else { return }
            onRaw?(RawSample(kind: .emg, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp, emg: values))
        case .motion(let kind, let values, let sequence, let timestamp):
            guard snapshot.state == .streaming else { return }
            onRaw?(RawSample(kind: kind == .gyro ? .gyro : .orientation, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp, values: values))
            if localMotion { onMotion?(kind, values) }
            onRelayEvent?(RelayWire.Event(kind: kind, sequence: sequence, timestamp: timestamp,
                                          phoneUptime: receipt.uptime, phoneTime: receipt.wallTime, values: values))
        case .gesture(let finger, let action, let derived, let synthetic, let sequence, let timestamp):
            let event = GestureEvent(id: UUID(), sessionID: sessionID, fingerCode: finger, actionCode: action, derivedActionCode: derived, synthetic: synthetic, sequence: sequence, deviceTimestamp: timestamp, received: receipt)
            if let previous = sequences.gap(sequence, stream: event.stream) {
                record("discontinuity", "\(event.stream.rawValue) gesture sequence changed from \(previous) to \(sequence); packet loss is not inferred.", receipt: receipt)
            }
            if snapshot.state == .streaming {
                onRaw?(RawSample(kind: .gesture, uptime: receipt.uptime, sequence: sequence, timestamp: timestamp,
                                 gesture: [finger, action, derived, synthetic ? 1 : 0]))
                onRelayEvent?(RelayWire.Event(kind: .gesture, sequence: sequence, timestamp: timestamp,
                                              phoneUptime: receipt.uptime, phoneTime: receipt.wallTime,
                                              gesture: [finger, action, derived, synthetic ? 1 : 0]))
            }
            record("gesture", event: event, receipt: receipt)
            snapshot.eventCount += 1; snapshot.events.insert(event, at: 0)
            if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
            onGesture?(event)
            react(interpreter.feed(event))
            if interpreter.hasPending {
                transport.perform(after: GestureInterpreter.settle + 0.005) { [weak self] in
                    guard let self else { return }
                    self.react(self.interpreter.flush(now: ProcessInfo.processInfo.systemUptime))
                }
            }
            publish()
        }
    }
    private func react(_ gestures: [BandGesture]) {
        guard !gestures.isEmpty else { return }
        for gesture in gestures {
            if gesture.isNewGesture { snapshot.gestureTotal += 1 }
            snapshot.lastGesture = gesture
            record("band_gesture", gesture.title)
            onBandGesture?(gesture)
        }
        publish()
    }
    func ownershipCompleted(_ result: Result<PairCompletion, Error>, attempt: UUID) {
        guard attempt == enrollmentAttempt else { return }
        do {
            let completion = try result.get()
            guard let proto else { throw BandError.transport("Enrollment channel closed.") }
            try transport.write(proto.resume(completion))
            protocolProgress()
        } catch { fail(error) }
    }
    private func protocolProgress() {
        updateConnectionProgress()
        let message = "Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none")."
        logger.info("\(message, privacy: .public)")
        record("protocol", message)
        publish()
    }
    private func updateConnectionProgress() {
        snapshot.connectionAttempt.observeProtocolStage(proto?.stage)
    }
    func disconnect(_ completion: ((Bool) -> Void)? = nil) {
        if let completion { releaseCompletion = completion }
        snapshot.connectionAttempt.stop()
        setIntent(false); reconnectAt = nil; scanUntil = nil; transport.stopScan(); enrollmentAttempt = nil; meta = nil
        if snapshot.issue != .stillReleasing { snapshot.issue = nil }
        guard snapshot.state != .disconnecting else { return }
        if snapshot.state == .streaming {
            transition(.disconnecting, "Stopping gesture subscription before releasing Bluetooth.")
            do {
                if pendingStreams == nil { try rpc("stop_streams", 5, 4, BandProtocol.stopFlags) }
                stoppingUntil = ProcessInfo.processInfo.systemUptime + 3
                return
            }
            catch { record("shutdown", "Could not request an acknowledged stream stop.") }
        }
        finishDisconnect()
    }
    /// Forgets the band on this phone. Saved credentials stay in the Keychain, so setting
    /// the same band up again does not need another Meta sign-in.
    func forget(_ completion: @escaping () -> Void) {
        disconnect { [weak self] _ in
            guard let self else { return }
            self.snapshot.selected = nil; self.snapshot.devices = []; self.snapshot.battery = nil; self.snapshot.hand = nil
            self.snapshot.issue = nil; self.snapshot.events = []; self.snapshot.eventCount = 0
            self.snapshot.connectionAttempt = ConnectionAttempt()
            self.snapshot.lastGesture = nil; self.snapshot.gestureTotal = 0
            for key in ["selectedBand", "bandHand", "handReadAttempts"] { UserDefaults.standard.removeObject(forKey: key) }
            self.record("connection", "Band forgotten on this phone; credentials retained.")
            self.transition(.disconnected, "Band forgotten.")
            completion()
        }
    }
    private func finishDisconnect() {
        identityConfirmation.cancel()
        stoppingUntil = nil; proto = nil; enrollment = nil; candidate = nil; candidateAccount = nil; snapshot.startedAt = nil
        transition(.disconnecting, "Closing Bluetooth; waiting for local release confirmation.")
        transport.disconnect()
    }
    private func availability(_ ready: Bool, message: String) {
        available = ready; snapshot.bluetoothReady = ready
        if !ready {
            reconnectAt = nil; proto = nil; transport.close()
            snapshot.issue = transport.isUnauthorized ? .bluetoothDenied : .bluetoothOff
            if snapshot.wantsConnection {
                snapshot.connectionAttempt.begin()
                transition(.reconnecting, message)
            } else { snapshot.message = message; publish() }
        } else {
            if snapshot.issue == .bluetoothOff || snapshot.issue == .bluetoothDenied { snapshot.issue = nil }
            if snapshot.wantsConnection {
                // Bluetooth availability must not replace active connection progress.
                if !userRecoveryRequired, snapshot.state != .connecting { beginConnection() }
            } else { snapshot.message = message; publish() }
        }
    }
    /// The link dropped while the band was wanted. The transport has already left a
    /// pending connect in place (or iOS is reconnecting by itself), so nothing here
    /// depends on a timer that a suspended app could not run.
    private func linkLost(_ systemReconnecting: Bool) {
        proto = nil; sequences.reset(); interpreter.reset(); sessionID = UUID(); handRequested = false
        pendingStreams = nil; activeStreams = nil; resetEMG(); snapshot.startedAt = nil
        if stoppingUntil != nil || snapshot.state == .disconnecting { finishDisconnect(); return }
        guard snapshot.wantsConnection, enrollment == nil else {
            if enrollment != nil { fail(BandError.transport("Band disconnected during setup.")) }
            return
        }
        snapshot.connectionAttempt.begin()
        transition(.reconnecting, systemReconnecting ? "Link lost; iOS is reconnecting automatically." : "Link lost; a pending connect is waiting for the band.")
    }
    private func fail(_ error: Error) {
        identityConfirmation.cancel()
        let error = error as? BandError ?? .wire("Band operation failed. Reconnect in the foreground.")
        if snapshot.state != .disconnecting, snapshot.wantsConnection || snapshot.connectionAttempt.outcome == .connecting {
            updateConnectionProgress()
            snapshot.connectionAttempt.fail(error)
        }
        let detail = "\(error.localizedDescription) Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none")."
        logger.error("\(detail, privacy: .public)")
        record("error", detail); proto = nil; snapshot.startedAt = nil
        if emgReading || pendingEMG == true {
            // Don't let EMG turn into a reconnect loop: one unexpected failure disables it for this run.
            emgHardBlocked = true; emgStatus("EMG disabled after a connection error while enabling it.")
        }
        resetEMG()
        if stoppingUntil != nil || snapshot.state == .disconnecting { transport.disconnect(); record("shutdown", "Stream stop was not acknowledged."); finishDisconnect(); return }
        if enrollment != nil || ConnectionRetryPolicy.stopsAutoConnect(error) {
            // Identity and ownership failures need the person; retrying cannot fix them.
            transport.disconnect()
            userRecoveryRequired = true; reconnectAt = nil; enrollment = nil; meta = nil; enrollmentAttempt = nil
            setIntent(false)
            try? refreshIdentities()
            snapshot.issue = SessionIssue.from(error)
            transition(.failed, detail + " Automatic connection is paused. Saved and pending identities were retained.")
        } else if snapshot.wantsConnection {
            failures += 1
            let delay = ConnectionRetryPolicy.backoff(failures: failures)
            transport.close()
            reconnectAt = ProcessInfo.processInfo.systemUptime + delay
            if case .storage = error { snapshot.issue = .phoneLocked }
            transition(.reconnecting, detail + " Retry \(failures) in \(Int(delay)) s; automatic connection stays on.")
        } else {
            transport.disconnect()
            snapshot.issue = SessionIssue.from(error)
            transition(.failed, detail)
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let until = stoppingUntil, now >= until { record("shutdown", "Stream stop acknowledgement timed out."); finishDisconnect(); return }
        if let until = scanUntil, now >= until {
            scanUntil = nil; transport.stopScan(); transition(.disconnected, snapshot.devices.isEmpty ? "No bands found. \(transport.scanSummary)" : "Scan finished.")
        }
        if let until = reconnectAt, now >= until, available, snapshot.wantsConnection, !userRecoveryRequired { reconnectAt = nil; beginConnection() }
        if let since = waitingSince, now - since >= Self.notNearbyAfter, snapshot.wantsConnection, snapshot.issue == nil, available, enrollment == nil {
            snapshot.issue = .bandNotNearby; publish()
        }
        do { try proto?.tick(now: now) } catch { fail(error) }
    }
    func exportJournal(_ completion: @escaping (Result<URL, Error>) -> Void) {
        do { if journal == nil { journal = try EventJournal() }; completion(.success(try journal!.export())) }
        catch { snapshot.journalError = "Could not export the journal."; publish(); completion(.failure(BandError.storage("Could not export the journal."))) }
    }
    func clearJournal() {
        do { if journal == nil { journal = try EventJournal() }; try journal?.clear(); snapshot.events = []; snapshot.eventCount = 0; snapshot.journalError = nil; publish() }
        catch { snapshot.journalError = "Could not clear the journal."; publish() }
    }
}
