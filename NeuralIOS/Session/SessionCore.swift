import Foundation
import OSLog
import CryptoKit

struct SessionSnapshot: Sendable {
    var state: SessionState = .disconnected
    var message = "Select your band to connect."
    var devices: [BandDevice] = []
    var selected: UUID?
    var events: [GestureEvent] = []
    var eventCount = 0
    var startedAt: Date?
    var journalError: String?
    var wantsConnection = false
    var identityChoices: [IdentityChoice] = []
    var identityAccount: UUID?
    var identityFingerprint: String?
}

/// Owned by the app; every method and callback below runs on transport.perform.
final class SessionCore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.neural.ios", category: "BandConnection")
    let transport = BandTransport()
    var onSnapshot: ((SessionSnapshot) -> Void)?
    var onRelayEvent: ((RelayWire.Event) -> Void)?
    var onRelayReady: ((RelayWire.Demand?) -> Void)?
    private var relayDemand = RelayWire.Demand.idle
    private var pendingStreams: RelayWire.Demand?
    private var activeStreams: RelayWire.Demand?
    var onGesture: ((GestureEvent) -> Void)?
    var onOwnership: ((OwnershipStep, MetaSession, UUID) -> Void)?
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
    private var verificationReconnect = false
    private var sessionID = UUID()
    private var lastSequence: UInt64?
    private var appState = "launching"
    private var retries = 0
    private var reconnectAt: TimeInterval?
    private var scanUntil: TimeInterval?
    private var releaseCompletion: ((Bool) -> Void)?
    private var stoppingUntil: TimeInterval?
    private var userRecoveryRequired = false
    private var available = false

    init() {
        snapshot.selected = UserDefaults.standard.string(forKey: "selectedBand").flatMap(UUID.init(uuidString:))
        snapshot.wantsConnection = UserDefaults.standard.bool(forKey: "wantsConnection")
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
        transport.onClosed = { [weak self] confirmed in
            guard let self, self.snapshot.state == .disconnecting else { return }
            let completion = self.releaseCompletion; self.releaseCompletion = nil
            self.transition(confirmed ? .disconnected : .failed, confirmed
                ? "Bluetooth release confirmed locally. Connect on Mac using the same identity; destination availability still needs confirmation."
                : "Bluetooth release was not confirmed. Automatic connection is paused. Wait before connecting on Mac; do not re-enroll.")
            completion?(confirmed)
        }
        transport.onTick = { [weak self] in self?.tick() }
        transport.onRestore = { [weak self] id in
            guard let self else { return }
            self.proto = nil; self.lastSequence = nil; self.sessionID = UUID(); self.snapshot.selected = id
            self.pendingStreams = nil; self.activeStreams = nil
            self.record("restoration", "Restored peripheral; a new authenticated channel is required.")
            self.transition(.connecting, "Restoring band connection.")
        }
    }
    func start() {
        transport.perform { [self] in
            do { journal = try EventJournal() } catch { snapshot.journalError = "Journal unavailable. Unlock the phone and retry journal access." }
            do { try refreshIdentities() } catch { snapshot.message = error.localizedDescription }
            publish()
        }
        transport.start(selected: snapshot.selected, desired: snapshot.wantsConnection)
    }
    private func context() -> ReceiptContext { ReceiptContext(wallTime: Date(), uptime: ProcessInfo.processInfo.systemUptime, applicationState: appState) }
    private func publish() { onSnapshot?(snapshot) }
    private func transition(_ state: SessionState, _ message: String) {
        logger.info("Session \(state.rawValue, privacy: .public): \(message, privacy: .public)")
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
        guard available else { transition(.failed, "Turn Bluetooth on and allow Neural access."); return }
        snapshot.devices = []; transport.scan(); scanUntil = ProcessInfo.processInfo.systemUptime + 15
        transition(.scanning, "Looking for nearby Meta bands.")
    }
    func refreshIdentityChoices() {
        do { try refreshIdentities(); publish() } catch { fail(error) }
    }
    private func refreshIdentities() throws {
        snapshot.identityChoices = try identities.choices()
        if let selected = snapshot.selected { snapshot.identityAccount = identities.account(for: selected) }
    }
    func select(_ device: BandDevice) {
        guard !snapshot.wantsConnection, stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        snapshot.selected = device.id
        UserDefaults.standard.set(device.id.uuidString, forKey: "selectedBand")
        do { try refreshIdentities() } catch { fail(error); return }
        snapshot.identityFingerprint = nil
        publish()
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
        transport.stopScan(); scanUntil = nil; userRecoveryRequired = false; retries = 0; reconnectAt = nil
        do {
            try chooseCandidate(account: account, pending: pending)
            enrollment = nil; meta = nil; enrollmentAttempt = nil; verificationReconnect = false
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
    func beginEnrollment(_ session: MetaSession) {
        guard let id = snapshot.selected, appState == "foreground", stoppingUntil == nil, snapshot.state != .disconnecting else { return }
        do {
            transport.disconnect(); proto = nil; reconnectAt = nil; userRecoveryRequired = false
            let account = identities.account(for: id)
            candidateAccount = account; candidatePending = true
            let previous = try identities.load(account, pending: true)
            enrollment = try OwnershipCeremony(previous: previous, allowMissingBandKey: true) { [identities] record in try identities.save(record, for: account, pending: true) }
            meta = session; enrollmentAttempt = UUID(); candidate = nil; verificationReconnect = false
            setIntent(true); beginConnection()
        } catch { fail(error) }
    }
    private func beginConnection() {
        guard snapshot.wantsConnection, let id = snapshot.selected else { return }
        proto = nil; lastSequence = nil; sessionID = UUID()
        pendingStreams = nil; activeStreams = nil
        guard available else { transition(.reconnecting, "Waiting for Bluetooth to become available."); return }
        transition(enrollment == nil ? .connecting : .enrolling, enrollment == nil ? "Connecting to your band." : "Enrolling this phone with the band.")
        transport.connect(id)
    }
    private func opened() {
        guard snapshot.wantsConnection else { transport.disconnect(); return }
        do {
            if enrollment == nil, candidate == nil { try chooseCandidate() }
            if let candidate {
                let publicPoint = try P256.Signing.PrivateKey(rawRepresentation: candidate.privateKey).publicKey.x963Representation.dropFirst()
                let fingerprint = SHA256.hash(data: Data(publicPoint)).map { String(format: "%02x", $0) }.joined()
                let summary = "Identity fingerprint=\(fingerprint) stage=\(candidate.stage) hasBandKey=\(candidate.bandPoint != nil) compatibility=\(candidate.allowMissingBandKey == true) privateKeyBytes=\(candidate.privateKey.count)"
                logger.info("\(summary, privacy: .public)")
                record("identity_diagnostic", summary)
            }
            proto = try BandProtocol(identity: enrollment == nil ? candidate : nil, ceremony: enrollment)
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

    func setRelayDemand(_ demand: RelayWire.Demand) {
        if relayDemand != demand {
            record("relay", "Mac requested active=\(demand.active) gyro=\(demand.gyro) orientation=\(demand.orientation)")
        }
        relayDemand = demand
        guard snapshot.state == .streaming else { return }
        do { try reconcileStreams() } catch { fail(error) }
    }

    private func reconcileStreams() throws {
        guard pendingStreams == nil else { return }
        let requested = RelayWire.Demand(active: true, gyro: relayDemand.active && relayDemand.gyro,
                                         orientation: relayDemand.active && relayDemand.orientation)
        if activeStreams == requested {
            onRelayReady?(relayDemand)
            return
        }
        onRelayReady?(nil)
        try rpc("start_streams", 5, 4, BandProtocol.streamFlags(gyro: requested.gyro, orientation: requested.orientation))
        pendingStreams = requested
    }

    private func handle(_ signal: BandProtocol.Signal, receipt: ReceiptContext) throws {
        switch signal {
        case .enrolled(let identity): candidate = identity; verificationReconnect = true
        case .ready:
            if verificationReconnect {
                // Enrollment is not accepted until the persisted identity works on
                // a completely new encrypted channel, matching the desktop path.
                verificationReconnect = false; enrollment = nil; meta = nil; enrollmentAttempt = nil
                beginConnection(); return
            }
            guard let id = snapshot.selected, let account = candidateAccount, var candidate, candidate.canAuthenticate else { throw BandError.authentication("No usable host identity is selected. Choose a saved identity or import the Mac QR.") }
            candidate.stage = candidate.bandPoint == nil ? "host_verified" : "verified"
            try identities.save(candidate, for: account)
            if candidatePending { try identities.clearPending(account) }
            identities.bind(id, to: account)
            candidatePending = false
            self.candidate = candidate
            try refreshIdentities()
            transition(.subscribing, "Enabling the band's gesture stream.")
            try rpc("request_active", 6, 5, PB.field(6, 2))
        case .reply(let operation, _):
            switch operation {
            case "request_active": try rpc("input_subscription", 5, 4)
            case "input_subscription": try reconcileStreams()
            case "start_streams":
                activeStreams = pendingStreams
                pendingStreams = nil
                if stoppingUntil != nil {
                    try rpc("stop_streams", 5, 4, BandProtocol.stopFlags)
                } else {
                    if snapshot.state != .streaming {
                        retries = 0
                        snapshot.startedAt = Date()
                        transition(.streaming, candidate?.bandPoint == nil ? "Receiving band gestures. Compatibility mode: band identity is unverified." : "Receiving band gestures.")
                    }
                    try reconcileStreams()
                }
            case "stop_streams": finishDisconnect()
            default: break
            }
        case .ownership(let step):
            guard let meta, let attempt = enrollmentAttempt else { throw BandError.authentication("Enrollment login expired. Sign in again.") }
            onOwnership?(step, meta, attempt)
        case .motion(let kind, let values, let sequence, let timestamp):
            guard snapshot.state == .streaming else { return }
            onRelayEvent?(RelayWire.Event(kind: kind, sequence: sequence, timestamp: timestamp,
                                          phoneUptime: receipt.uptime, phoneTime: receipt.wallTime, values: values))
        case .gesture(let finger, let action, let derived, let synthetic, let sequence, let timestamp):
            let event = GestureEvent(id: UUID(), sessionID: sessionID, fingerCode: finger, actionCode: action, derivedActionCode: derived, synthetic: synthetic, sequence: sequence, deviceTimestamp: timestamp, received: receipt)
            if let lastSequence, sequence != (lastSequence &+ 1) & 0xffffffff { record("discontinuity", "Gesture sequence changed from \(lastSequence) to \(sequence); packet loss is not inferred.", receipt: receipt) }
            lastSequence = sequence
            if snapshot.state == .streaming {
                onRelayEvent?(RelayWire.Event(kind: .gesture, sequence: sequence, timestamp: timestamp,
                                              phoneUptime: receipt.uptime, phoneTime: receipt.wallTime,
                                              gesture: [finger, action, derived, synthetic ? 1 : 0]))
            }
            record("gesture", event: event, receipt: receipt)
            snapshot.eventCount += 1; snapshot.events.insert(event, at: 0)
            if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
            onGesture?(event); publish()
        }
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
        let message = "Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none")."
        logger.info("\(message, privacy: .public)")
        record("protocol", message)
    }
    func disconnect(_ completion: ((Bool) -> Void)? = nil) {
        if let completion { releaseCompletion = completion }
        setIntent(false); reconnectAt = nil; scanUntil = nil; transport.stopScan(); enrollmentAttempt = nil; meta = nil
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
    private func finishDisconnect() {
        stoppingUntil = nil; proto = nil; enrollment = nil; candidate = nil; candidateAccount = nil; snapshot.startedAt = nil
        transition(.disconnecting, "Closing Bluetooth; waiting for local release confirmation.")
        transport.disconnect()
    }
    private func availability(_ ready: Bool, message: String) {
        available = ready
        if !ready {
            reconnectAt = nil; proto = nil; transport.close()
            if snapshot.wantsConnection { transition(.reconnecting, message) } else { snapshot.message = message; publish() }
        } else if snapshot.wantsConnection {
            if !userRecoveryRequired, snapshot.state != .connecting { beginConnection() }
            // Bluetooth availability must not replace active connection progress.
        } else { snapshot.message = message; publish() }
    }
    private func fail(_ error: Error) {
        let error = error as? BandError ?? .wire("Band operation failed. Reconnect in the foreground.")
        let detail = "\(error.localizedDescription) Protocol: \(proto?.stage ?? "closed"); enrollment: \(enrollment?.record.stage ?? "none")."
        logger.error("\(detail, privacy: .public)")
        record("error", detail); proto = nil; transport.disconnect(); snapshot.startedAt = nil
        if stoppingUntil != nil || snapshot.state == .disconnecting { record("shutdown", "Stream stop was not acknowledged."); finishDisconnect(); return }
        let retryDelay = ConnectionRetryPolicy.delay(for: error, retries: retries)
        if enrollment != nil || retryDelay == nil {
            userRecoveryRequired = true; reconnectAt = nil; enrollment = nil; meta = nil; enrollmentAttempt = nil
            setIntent(false)
            try? refreshIdentities()
            transition(.failed, detail + " Automatic connection is paused. Saved and pending identities were retained. Choose an identity, rediscover the band, or repair OS pairing as appropriate; do not re-enroll as a connection repair.")
        } else if snapshot.wantsConnection {
            let delay = retryDelay!; retries += 1
            reconnectAt = ProcessInfo.processInfo.systemUptime + delay
            transition(.reconnecting, error.localizedDescription + " Retry \(retries)/5 when execution is available.")
        } else { transition(.failed, error.localizedDescription) }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let until = stoppingUntil, now >= until { record("shutdown", "Stream stop acknowledgement timed out."); finishDisconnect(); return }
        if let until = scanUntil, now >= until {
            scanUntil = nil; transport.stopScan(); transition(.disconnected, snapshot.devices.isEmpty ? "No bands found. \(transport.scanSummary) Release the other client and scan again. Use pairing mode only when OS pairing is needed." : "Select your band.")
        }
        if let until = reconnectAt, now >= until, available, snapshot.wantsConnection, !userRecoveryRequired { reconnectAt = nil; beginConnection() }
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
