#!/usr/bin/env swift
// Run with the Mac Bluetooth device identifier used by meta_neural_py.
import AppKit
import CoreImage
import CryptoKit
import Security

struct SavedIdentity: Decodable {
    let version: Int
    let private_key: Data
    let band_key: Data?
    let stage: String
    let allow_missing_band_key: Bool?
}
struct Transfer: Encodable {
    let type = "runes-band-identity"
    let version = 2
    let privateKey: Data
    let bandPoint: Data?
    let allowMissingBandKey: Bool
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("Usage: swift Tools/ShowMacIdentity.swift <Mac band device ID>") }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "org.meta-neural-py.identity.v1",
    kSecAttrAccount as String: CommandLine.arguments[1],
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess, let data = result as? Data else {
    fail("Could not read the saved Mac identity (Keychain status \(status)). Check the device ID and Keychain permission.")
}
guard data.count <= 8192,
      let identity = try? JSONDecoder().decode(SavedIdentity.self, from: data),
      identity.version == 1, identity.private_key.count == 32,
      (try? P256.Signing.PrivateKey(rawRepresentation: identity.private_key)) != nil else {
    fail("A verified Mac identity with a band public key is required. Saved identity is invalid.")
}
let compatibility = identity.stage == "host_verified" && identity.band_key == nil && identity.allow_missing_band_key == true
guard compatibility || (identity.stage == "verified" && identity.band_key != nil) else {
    fail("A verified Mac identity with a band public key is required. Incomplete identities cannot be exported.")
}
if let point = identity.band_key {
    guard point.count == 64,
          (try? P256.Signing.PublicKey(x963Representation: Data([4]) + point)) != nil else {
        fail("A verified Mac identity with a band public key is required. Band key is invalid.")
    }
}
let payload = try JSONEncoder().encode(Transfer(privateKey: identity.private_key, bandPoint: identity.band_key, allowMissingBandKey: compatibility))
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(payload, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
let cg = CIContext().createCGImage(qr, from: qr.extent)!
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Transfer band identity to iPhone"
window.isReleasedWhenClosed = false
window.contentView!.wantsLayer = true
window.contentView!.layer?.backgroundColor = NSColor.white.cgColor
let image = NSImageView(frame: NSRect(x: 30, y: 110, width: 500, height: 500))
image.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
image.imageScaling = .scaleProportionallyUpOrDown
window.contentView!.addSubview(image)
let label = NSTextField(wrappingLabelWithString: "On iPhone, select your band → Import Mac identity.\nThis QR contains your private key. Keep it out of photos and screen sharing.\nCloses after 60 seconds. Disconnect the Mac before connecting the phone.")
label.frame = NSRect(x: 25, y: 15, width: 510, height: 90)
label.textColor = .black; label.alignment = .center
window.contentView!.addSubview(label)
let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in app.terminate(nil) }
let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in app.terminate(nil) }
window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
app.run()
