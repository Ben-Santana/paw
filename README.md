# NeuralIOS

Native iPhone client for Meta Neural Band connection, verified enrollment, built-in gesture reception, and background sessions. Requires **iOS 26 or later** and full **Xcode 26 or later with an iOS SDK supporting the connected phone**. The checked-in Xcode project opens directly; Python and project-generation tools are not required to build or run it.

This is the first implementation of the product's native connection and gesture pipeline. Hardware behavior, Meta sign-in, and screen-off delivery have **not yet been verified on an iPhone**. Background support is implemented using Core Bluetooth and a user-started Live Activity; it is not a promise of indefinite execution.

## Open and install

1. Install full Xcode and its iOS platform support. Command Line Tools alone cannot build this app. Launch Xcode once to finish installation. If needed select it with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
2. Open `NeuralIOS.xcodeproj` and choose the **NeuralIOS** scheme.
3. In Xcode Settings → Accounts, sign in to your Apple Account. Select your team in **Signing & Capabilities for both NeuralIOS and NeuralActivity**. If these bundle identifiers are unavailable, change the app identifier and give the extension the same prefix plus `.activity`.
4. Connect your iPhone, trust the Mac, and enable **Settings → Privacy & Security → Developer Mode** if prompted. Select the phone as the run destination and press Run. No App Store submission is required for local development.
5. A free Personal Team can be used for local development where supported; its short provisioning lifetime requires periodically rebuilding. Xcode will report any account/capability limitations.

The Simulator can run the interface but is not evidence of Bluetooth, pairing, or screen-off operation. This project deliberately has no simulated band or test-only runtime paths.

## Using the app

On first launch Neural walks through setup: welcome → allow Bluetooth → pairing mode → choose your band → Meta sign-in (with a plain warning that the band may disconnect from other devices such as the Mac) → a "tap your index finger" check → done. A band that already has a saved setup on this phone skips sign-in. **Use my Mac’s setup instead** imports the Mac identity by QR (see below) rather than signing in.

After setup the main screen is a single ring that shows **Not set up, Connecting, Connected or Needs attention**, and it ripples when a gesture arrives. Battery, wrist and last gesture sit under it, and the Mac link (`SessionController.relayStatus`) appears as one line at the bottom. Problems appear as one sentence and one button. Protocol detail never appears on screen; it goes to the journal. Settings has forget band, haptics, battery alerts, privacy and licenses. **Settings → Advanced** holds journal export, Mac test receiver pairing, Mac identity import and raw packets.

The look follows the Mac app (`docs/design.md`): monochrome, Geist (bundled under the OFL in `Resources/Fonts`), 6 px controls, 8 px panels, 200 ms motion, plus a matching dark mode. Reduce Motion and Dynamic Type are respected. SwiftUI previews in `Views/Previews.swift` use fixed view states. In DEBUG builds, `NEURAL_SNAPSHOT=<name>` shows one of those states for screenshots without starting the session. There is still no simulated band.

## Staying connected

- **Never gives up on ordinary errors.** Only an identity or ownership rejection (or OS pairing mismatch) turns auto-connect off, and so does the person pressing Disconnect. Transport, protocol and locked-Keychain errors back off 1, 2, 4, 8, 16, then 20 s indefinitely; each wait holds a background task so the timer can fire.
- **Pending connects, not timers.** When the link drops, the transport immediately leaves `CBCentralManager.connect()` pending, with `CBConnectPeripheralOptionEnableAutoReconnect`. A pending connect has no deadline, so the band reconnects whenever it returns, even while the app is suspended. Only setup steps after the link is up have a 60 s deadline. Background scans look for the advertised `FD5F` service, not `FEB8`.
- **Band pulse.** The subscription to `2D41DA7A`/`2D41DA7C` (see `Documentation/WakeTest.md`) is kept. If it stops for 30 s, the app shows a gentle "Gestures may pause while your phone is locked" with **Reconnect**.
- **Battery** comes from the standard battery service (`180F/2A19`, read + notify). **Hand** comes from the same `read_hand` RPC the Mac app uses; if the band rejects it twice, it is never asked again.
- **Gesture sequences.** The band numbers raw gestures and derived interactions with two separate counters. The journal now tracks each one separately. In the 2026-11-08 export, 2,368 "discontinuity" rows came from comparing the two counters; split per stream, 0 of 3,076 gestures were discontinuous.
- **Live Activity** is minimal (state only) and has no expiry reminder. It does not affect background execution and could be dropped.

### Band picker (AccessorySetupKit)

`Transport/AccessoryPicker.swift` implements the system picker but is **off by default**. Turn it on by adding `NSAccessorySetupKitSupports = [Bluetooth]` and `NSAccessorySetupBluetoothServices = [FD5F]` to Info.plist. Trade-off: on iOS 26 only AccessorySetupKit apps are relaunched after a force quit, but in that mode Core Bluetooth can only reach accessories chosen in the picker. That would likely break the Core Bluetooth link to the Mac (`Relay/`). Without the keys, onboarding uses the in-app scan.

## Import the Mac identity by QR

On the Mac, disconnect the band, then run `swift Tools/ShowMacIdentity.swift <Mac-device-ID>`. On iPhone, choose your band and pick **Use my Mac’s setup instead** (onboarding) or **Settings → Advanced → Use my Mac’s band setup**. The QR **contains the private authentication key**, so keep it out of screenshots. The imported identity replaces the saved one only after it authenticates.

## Journal

**Settings → Advanced → Export journal.** The journal is two rotating 2 MiB segments, excluded from backup and free of tokens and private keys. It records gestures, connection transitions, lifecycle, sanitized errors, battery, hand, pulse and per-stream sequence discontinuities.

## Command-line builds

With full Xcode installed, simulator compilation requires no team:

```sh
xcodebuild -project NeuralIOS.xcodeproj -scheme NeuralIOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For an unsigned device compilation:

```sh
xcodebuild -project NeuralIOS.xcodeproj -scheme NeuralIOS -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To install a standalone signed build, select your phone, edit the scheme's **Run → Info → Build Configuration** to **Release**, uncheck **Debug executable**, then Run. Stop the Xcode session and launch Neural from the phone's Home Screen. It does not use a Mac development server. Keep the same bundle ID and signing team between rebuilds to preserve the phone's Keychain identity.

## Structure and provenance

- `NeuralIOS/Protocol`: bounded protobuf/DataX decoding, AirShield records, mutual trust, RPC and gesture subscription.
- `NeuralIOS/Transport`: Core Bluetooth and L2CAP stream I/O on the session run loop.
- `NeuralIOS/Authentication`: Meta service exchange, isolated login, persisted ownership ceremony.
- `NeuralIOS/Session`: connection lifecycle, observable UI adapter, typed gestures, and Live Activity management.
- `NeuralIOS/Persistence`: protected Keychain identity storage and rotating local journal.
- `NeuralIOS/Views`: connection, gestures, packet details, and diagnostics.
- `Shared` / `NeuralActivity`: ActivityKit attributes and Lock Screen/Dynamic Island presentation.

Protocol reference: the installed **meta-neural-py 0.1.0a1** source, captured as SHA-256 entries in `Documentation/ProtocolReference.sha256`. The Swift implementation is a port of the required paths, not an official Meta mobile SDK. Third-party attribution is in `THIRD_PARTY_NOTICES.md`. No neighboring repository is needed at runtime or build time.

`generate_project.py` can regenerate the checked-in project using Python's standard library if source membership changes; it is optional and never runs during a build. Signing-team selection is kept in Xcode. No development team or account credentials are committed.

## Checks

```sh
swiftc -module-cache-path /private/tmp/neural-swift-module-cache NeuralIOS/Session/Models.swift NeuralIOS/Protocol/Wire.swift NeuralIOS/Persistence/IdentityStore.swift Tools/ConnectionPolicyTests.swift -o /private/tmp/neural-connection-policy-tests && /private/tmp/neural-connection-policy-tests
swiftc -module-cache-path /private/tmp/neural-swift-module-cache NeuralIOS/Session/Models.swift NeuralIOS/Session/BandStatus.swift NeuralIOS/Protocol/Wire.swift NeuralIOS/Persistence/IdentityStore.swift Tests/SessionPolicyTests.swift -o /private/tmp/neural-session-policy-tests && /private/tmp/neural-session-policy-tests
```

Builds and policy checks pass (Xcode 27.2, iOS 26 target). Hardware behaviour, onboarding with a real band, and locked-phone reconnection are **not yet verified on a device**. `generate_project.py` predates resources and Xcode's reformatting; edit the checked-in project instead.
