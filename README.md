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

## Connect

Close the Mac band app and other connected clients. Put the band in pairing mode, choose **Scan for bands**, select it, and choose **Import Mac identity** when the Mac already owns it. Ownership enrollment is only for deliberately setting up or replacing ownership. Accept the iOS pairing prompt. **Enrollment can replace the Mac's saved identity**; the Mac may need enrollment again afterward.

Meta sign-in stays in an isolated, nonpersistent web view. The app validates the intercepted callback before exchanging its token. No Meta-owned URL scheme is registered with iOS. This follows an experimental reverse-engineered service flow; server-side changes or authentication restrictions can block sign-in and are surfaced as failures.

Enrollment persists its host key and stage before progressing. When it finishes, Neural opens a fresh encrypted connection and authenticates the phone before promoting the identity; it also verifies the band when its public key is available. An interrupted finish with a saved band key can be retried with **Connect**; earlier interruptions require explicit sign-in to restart the ceremony using the pending host key. Authentication failures never silently re-enroll the band. Explicit iPhone enrollment permits compatibility mode when Meta omits the band public key, matching the Mac client. A known band key is retained if omitted by the service; supplied invalid or conflicting keys are still rejected. With no known band key, the phone authenticates over an encrypted channel but cannot verify the band identity, and labels the session as unverified. The compatibility flag is persisted before finishing enrollment, and the candidate must succeed on a fresh channel before promotion.

Subsequent **Connect** uses the saved phone identity. Connection desire and the selected iOS peripheral identifier persist across launches. Existing Keychain accounts are retained as credential records; authenticated address bindings allow a new Bluetooth UUID to reuse one. Choose a saved identity by public fingerprint after rediscovery. Connect defaults to saved credentials; pending candidates are explicit when a saved identity exists. Discovery identifiers are local to iOS; they are not desktop identity identifiers. Use **Disconnect** to stop the subscription and cancel future reconnections. Disconnect requests an acknowledged stream stop, then waits for local Core Bluetooth release confirmation or reports a bounded release timeout. Wait for local release before connecting on Mac; destination readiness still needs confirmation.

## Import the Mac identity by QR

To share the Mac's existing band identity instead of enrolling a separate phone identity:

1. On the Mac, disconnect the band in the Mac app. Find the **Mac device ID** used by that app (the Keychain account under `org.meta-neural-py.identity.v1`). This is different from the iPhone's Bluetooth identifier.
2. From this project folder, run `swift Tools/ShowMacIdentity.swift <Mac-device-ID>`. Allow Keychain access if macOS requests it. This standalone Mac utility displays a QR for 60 seconds; no QR image or identity file is saved. It requires the Swift Command Line Tools.
3. On iPhone, scan for and select the same band, then choose **Import Mac identity** and scan the Mac's QR. Allow camera access and accept any iOS Bluetooth pairing prompt.
4. The phone validates the keys, saves a pending candidate in its device-only Keychain, and connects without an ownership enrollment. A candidate replaces the saved phone identity only after connection setup and host authentication succeed. With a saved band key, the phone also verifies the band proof. Compatibility imports cannot verify that proof and are labeled as unverified in the connection status. Authentication failures do not re-enroll.

The QR **contains the private authentication key**. Anyone who copies it can copy the identity. Keep it out of screenshots, recordings, and screen sharing. The window closing does not revoke a photographed code. The utility reads the existing Mac identity without changing it; this is a separate utility, not a button integrated into the Mac app. Version 2 transfers also support Mac records marked `host_verified` with `allow_missing_band_key=true` and no band key. This explicitly carries compatibility permission to the phone; an absent key alone never enables compatibility. The channel remains encrypted and the phone authenticates to the band, but the phone cannot verify the band identity. Existing version 1 transfers with a valid band key remain supported.

Disconnect the active client before connecting the other. Sharing credentials avoids repeated enrollment but does not provide simultaneous connections or automatic handoff. Hardware switching and camera scanning still require verification on real devices.

## Gesture reception

The subscription enables **gestures only**. No EMG, gyroscope, or orientation streams are requested. The interface retains the latest 200 packets and preserves raw and derived codes independently, including unknown values and synthetic flags. A press, derived button-down, derived hold, release, and derived button-up may be different packets; event totals count packets, not user actions.

There are no combo definitions, actions, keyboard control, or model experiments yet. Future consumers can subscribe to the typed `SessionController.gestures` async stream, which has a newest-200 delivery buffer; the journal is independent of UI consumption.

## Background and Live Activity

Core Bluetooth runs independently of the SwiftUI views on a dedicated thread with an active stream run loop. The app enables `bluetooth-central`, initializes a restoration-enabled central manager during launch, and attempts a new L2CAP/authentication/subscription sequence for restored connections. Lost links retry at most five times with exponential delays while execution is available. Bond mismatch (`CBErrorDomain:14`), authentication, storage, and malformed-protocol errors pause for user recovery; none starts enrollment. Turning Bluetooth off pauses recovery. Authentication and enrollment failures require user intervention.

A foreground connection/enrollment starts a Live Activity if allowed. It reports session status and elapsed time without updating on every gesture. The status is marked stale after a minute without a transition so it cannot imply recently confirmed connectivity while the app is suspended. Dismissal, denial, or expiry does not stop Bluetooth processing. A restored/background launch does not try to start a new Live Activity.

A Live Activity does not guarantee screen-off processing. iOS may suspend or terminate the app, and callback data can be delivered later. State restoration is conditional on system policy. Force-quitting, powering off the phone, or operation before first unlock is outside the background guarantee. No audio, location, polling keepalive, or repeated background-task extension is used.

## Diagnostics and manual verification

Open **Diagnostics → Export event journal → Share journal**. The local journal consists of two rotating segments, each up to 2 MiB. It logs gesture packets, connection transitions, lifecycle changes, sequence discontinuities, and sanitized errors. JSON dates are Unix seconds; host uptime is monotonic time for the current boot. `deviceTimestamp` belongs to a separate gesture-device clock and has no inferred wall-clock conversion.

`received.wallTime` and `received.uptime` are captured in the transport callback before decoding, disk I/O, or UI dispatch. `applicationState` records the last iOS lifecycle notification; it **does not detect screen lock or a dark display**. Packets decoded from the same input callback share its receipt context. The journal is bounded, not a complete indefinite recording. A sequence discontinuity is not a validated packet-loss measurement.

Keys and logs use protection that remains accessible after first unlock. Identity keys are device-only Keychain items. Journal files are excluded from backup and do not contain tokens, passwords, receipts, or private keys. Exported gesture data and identifiers remain personal data. **Clear journal and recent events** removes local history and the current export file; future session events continue to be recorded.

See [manual acceptance](Documentation/ManualAcceptance.md) for the device checks. No automated tests, mock band runtime, or scripted test harness is included.

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

## Verification at delivery

The production protocol, cryptography, enrollment, HTTP, Keychain, journal, transport, and session core have been type-checked and compiled together into a library with the available macOS SDK. All Swift sources pass syntax parsing, and the project/property lists pass `plutil` validation. **The iOS app and widget have not been compiled here because full Xcode and an iOS SDK are absent.** Run the build commands above after installing Xcode; no hardware or background reliability is marked verified.

See [connection stabilization and hardware acceptance](Documentation/ConnectionStabilization.md) for the new identity-selection flows, isolated checks, and unexecuted hardware switching experiments.
