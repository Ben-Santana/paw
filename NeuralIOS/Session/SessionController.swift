import Foundation
import SwiftUI

@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()
    @Published private(set) var snapshot = SessionSnapshot()
    @Published private(set) var loginRequest: MetaLoginRequest?
    @Published private(set) var isSigningIn = false
    @Published var uiError: String?
    @Published private(set) var activityMessage: String?
    @Published private(set) var relayStatus = "Pair a Mac test receiver to begin."
    private let relay = PhoneRelay()
    let gestures: AsyncStream<GestureEvent>
    private let eventContinuation: AsyncStream<GestureEvent>.Continuation
    private let core: SessionCore
    private let live = LiveActivityController()
    private var authTask: Task<Void, Never>?
    private var pairTasks: [UUID: Task<Void, Never>] = [:]
    private var loginContinuation: CheckedContinuation<URL, Error>?
    private var foreground = false

    private init() {
        let stream = AsyncStream<GestureEvent>.makeStream(bufferingPolicy: .bufferingNewest(200))
        gestures = stream.stream; eventContinuation = stream.continuation
        core = SessionCore()
        core.onSnapshot = { [weak self] state in Task { @MainActor in
            guard let self else { return }
            self.snapshot = state; self.live.update(state.state, desired: state.wantsConnection)
            if !state.wantsConnection {
                for task in self.pairTasks.values { task.cancel() }; self.pairTasks.removeAll()
            }
        } }
        core.onGesture = { [weak self] event in Task { @MainActor in self?.eventContinuation.yield(event) } }
        core.onOwnership = { [weak self] step, session, attempt in Task { @MainActor in self?.performOwnership(step, session: session, attempt: attempt) } }
        live.onChange = { [weak self] in self?.activityMessage = self?.live.message }
        let session = core
        relay.onDemand = { [weak session] demand in
            session?.transport.perform { [weak session] in session?.setRelayDemand(demand) }
        }
        relay.onDiagnostic = { [weak session] message in
            session?.transport.perform { [weak session] in session?.recordRelayDiagnostic(message) }
        }
        relay.onStatus = { [weak self] status in
            Task { @MainActor in self?.relayStatus = status }
        }
        core.onRelayReady = { [weak relay] in relay?.setReady($0) }
        core.onRelayEvent = { [weak relay] in relay?.forward($0) }
        WakeProbe.shared.start { [weak session] message in
            session?.transport.perform { [weak session] in session?.recordRelayDiagnostic(message) }
        }
        relay.start()
        core.start()
    }
    func lifecycle(_ state: String) {
        foreground = state == "foreground"
        core.transport.perform { [core] in core.lifecycle(state) }
    }
    func canRenewLiveActivity(at date: Date) -> Bool {
        snapshot.wantsConnection && live.canRenew(at: date)
    }
    func renewLiveActivity() {
        guard foreground, snapshot.wantsConnection else { return }
        live.renew(snapshot.state)
    }
    func pairRelay(_ text: String) {
        do { relay.pair(try RelayWire.Invitation.parse(text)) }
        catch { uiError = error.localizedDescription }
    }
    func scan() { core.transport.perform { [core] in core.scan() } }
    func select(_ device: BandDevice) { core.transport.perform { [core] in core.select(device) } }
    func refreshIdentities() { core.transport.perform { [core] in core.refreshIdentityChoices() } }
    func connect(account: UUID? = nil, pending: Bool? = nil) {
        guard foreground else { return }
        uiError = nil; live.start(); activityMessage = live.message
        core.transport.perform { [core] in core.connect(account: account, pending: pending) }
    }
    func importIdentityQR(_ text: String, for id: UUID) {
        guard foreground, !isSigningIn, !snapshot.wantsConnection, snapshot.selected == id else { return }
        do {
            let identity = try IdentityTransfer.parse(text)
            uiError = nil; live.start(); activityMessage = live.message
            core.transport.perform { [core] in core.importIdentity(identity, for: id) }
        } catch { uiError = error.localizedDescription }
    }
    func disconnect() {
        cancelSignIn(); live.end()
        for task in pairTasks.values { task.cancel() }; pairTasks.removeAll()
        core.transport.perform { [core] in core.disconnect() }
    }
    func enroll() {
        guard foreground, snapshot.selected != nil, !isSigningIn else { return }
        isSigningIn = true; uiError = nil
        authTask = Task { [weak self] in
            guard let self else { return }
            let service = MetaService(); defer { service.close(); self.isSigningIn = false; self.authTask = nil }
            do {
                let released: Bool = await withCheckedContinuation { continuation in
                    self.core.transport.perform { [core = self.core] in
                        core.disconnect { confirmed in continuation.resume(returning: confirmed) }
                    }
                }
                try Task.checkCancellation()
                guard released else { throw BandError.transport("Local Bluetooth release was not confirmed. Retry disconnect before starting ownership setup.") }
                let request = try await service.prepareLogin(); try Task.checkCancellation()
                let callback = try await self.presentLogin(request)
                let session = try await service.finishLogin(callback, request: request); try Task.checkCancellation()
                guard self.foreground else { throw BandError.authentication("Return to Neural and sign in again to begin enrollment.") }
                self.live.start(); self.activityMessage = self.live.message
                self.core.transport.perform { [core = self.core] in core.beginEnrollment(session) }
            } catch {
                self.loginRequest = nil
                if !Task.isCancelled, (error as? BandError)?.errorDescription != BandError.cancelled.errorDescription { self.uiError = error.localizedDescription }
            }
        }
    }
    private func presentLogin(_ request: MetaLoginRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in loginContinuation = continuation; loginRequest = request }
    }
    func loginCallback(_ url: URL) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil; loginRequest = nil; continuation.resume(returning: url)
    }
    func loginFailed() {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil; loginRequest = nil
        continuation.resume(throwing: BandError.authentication("Meta sign-in navigation failed. Try signing in again."))
    }
    func cancelSignIn() {
        authTask?.cancel()
        if let continuation = loginContinuation { loginContinuation = nil; continuation.resume(throwing: BandError.cancelled) }
        loginRequest = nil
    }
    func loginSheetDismissed() { if loginContinuation != nil { cancelSignIn() } }
    private func performOwnership(_ step: OwnershipStep, session: MetaSession, attempt: UUID) {
        let taskID = UUID()
        pairTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            let service = MetaService(); defer { service.close(); self.pairTasks[taskID] = nil }
            let result: Result<PairCompletion, Error>
            do { let completion = try await service.complete(step, session: session); try Task.checkCancellation(); result = .success(completion) }
            catch { result = .failure(error) }
            self.core.transport.perform { [core = self.core] in core.ownershipCompleted(result, attempt: attempt) }
        }
    }
    func exportJournal() async -> URL? {
        await withCheckedContinuation { continuation in
            core.transport.perform { [core] in core.exportJournal { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure(let error): self.uiError = error.localizedDescription; continuation.resume(returning: nil)
                    }
                }
            } }
        }
    }
    func clearJournal() { core.transport.perform { [core] in core.clearJournal() } }
}
