import Foundation
import UIKit
import CoreBluetooth
import AccessorySetupKit

/// The system band picker (AccessorySetupKit). It is off unless Info.plist declares
/// `NSAccessorySetupKitSupports` = [Bluetooth] plus `NSAccessorySetupBluetoothServices` = [FD5F].
///
/// Why it is opt-in: declaring those keys switches the whole app into AccessorySetupKit
/// mode. Core Bluetooth then only reaches accessories chosen in this picker, and asking for
/// any other peripheral terminates the app. The phone-to-Mac relay connects to the Mac over
/// Core Bluetooth, so it would stop working. On iOS 26, though, only AccessorySetupKit apps
/// are relaunched after a force quit. See README → "Band picker".
/// With the keys absent, onboarding uses the in-app Bluetooth scan instead.
@MainActor
final class AccessoryPicker {
    static let shared = AccessoryPicker()
    static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") as? [String])?.contains("Bluetooth") == true
    }
    enum Failure: Error { case unavailable, cancelled, failed }

    private var session: ASAccessorySession?
    private var pending: CheckedContinuation<UUID, Error>?

    private func activate() {
        guard Self.isEnabled, session == nil else { return }
        let session = ASAccessorySession()
        session.activate(on: .main) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        self.session = session
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded, .accessoryChanged:
            if let id = event.accessory?.bluetoothIdentifier { finish(.success(id)) }
        case .pickerSetupFailed: finish(.failure(Failure.failed))
        case .pickerDidDismiss: finish(.failure(Failure.cancelled))
        default: break
        }
    }

    private func finish(_ result: Result<UUID, Error>) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(with: result)
    }

    /// Shows the system picker and returns the chosen band's Bluetooth identifier.
    func pick(image: UIImage) async throws -> UUID {
        guard Self.isEnabled else { throw Failure.unavailable }
        activate()
        guard let session else { throw Failure.unavailable }
        if let existing = session.accessories.first(where: { $0.state == .authorized })?.bluetoothIdentifier { return existing }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = BandTransport.advertisedService
        let item = ASPickerDisplayItem(name: "Meta Neural Band", productImage: image, descriptor: descriptor)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            session.showPicker(for: [item]) { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    let code = (error as NSError).code
                    self?.finish(.failure(code == ASError.userCancelled.rawValue ? Failure.cancelled : Failure.failed))
                }
            }
        }
    }

    /// Removes the band from the system's accessory list, which also removes its Bluetooth pairing.
    func forgetAll() {
        guard Self.isEnabled else { return }
        activate()
        for accessory in session?.accessories ?? [] { session?.removeAccessory(accessory) { _ in } }
    }
}
