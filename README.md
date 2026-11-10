# RunesIOS

Native iPhone client for Meta Neural Band connection, verified enrollment, built-in gesture reception, and background sessions. Requires **iOS 26 or later** and full **Xcode 26 or later with an iOS SDK supporting the connected phone**. The checked-in Xcode project opens directly; Python and project-generation tools are not required to build or run it.

This is the first implementation of the product's native connection and gesture pipeline. Hardware behavior, Meta sign-in, and screen-off delivery have **not yet been verified on an iPhone**. Background support is implemented using Core Bluetooth and a user-started Live Activity; it is not a promise of indefinite execution.

## Open and install

1. Install full Xcode and its iOS platform support. Command Line Tools alone cannot build this app. Launch Xcode once to finish installation. If needed select it with `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
2. Open `RunesIOS.xcodeproj` and choose the **RunesIOS** scheme.
3. In Xcode Settings → Accounts, sign in to your Apple Account. Select your team in **Signing & Capabilities for both RunesIOS and RunesActivity**. If these bundle identifiers are unavailable, change the app identifier and give the extension the same prefix plus `.activity`.
4. Connect your iPhone, trust the Mac, and enable **Settings → Privacy & Security → Developer Mode** if prompted. Select the phone as the run destination and press Run. No App Store submission is required for local development.
5. A free Personal Team can be used for local development where supported; its short provisioning lifetime requires periodically rebuilding. Xcode will report any account/capability limitations.

The Simulator can run the interface but is not evidence of Bluetooth, pairing, or screen-off operation. This project deliberately has no simulated band or test-only runtime paths.

## Using the app

On first launch Runes walks through setup: welcome → allow Bluetooth → pairing mode → choose your band → Meta sign-in (with a plain warning that the band may disconnect from other devices such as the Mac) → a "tap your index finger" check → done. A band that already has a saved setup on this phone skips sign-in. **Use my Mac’s setup instead** imports the Mac identity by QR (see below) rather than signing in.

After setup the main screen is a single ring that shows **Not set up, Connecting, Connected or Needs attention**, and it ripples when a gesture arrives. Battery, wrist and last gesture sit under it, and the Mac link (`SessionController.relayStatus`) appears as one line at the bottom. Problems appear as one sentence and one button. Protocol detail never appears on screen; it goes to the journal. Settings has forget band, haptics, battery alerts, privacy and licenses. **Settings → Motion lab** (`Workouts/MotionLab.swift`, `Workouts/MotionRecorder.swift`, `Views/MotionLabView.swift`) records labelled sets of any exercise with every raw band stream — gyroscope, orientation, gestures and 8-channel 2048 Hz EMG (`Protocol/EMG.swift`; requested only while a set records, and a refusal turns EMG off instead of dropping the link) — runs the shipping rep detector alongside, and exports all sets as one zip with a README of the formats. Checks: `Tests/MotionLabTests.swift`. **Settings → Advanced** holds journal export, Mac test receiver pairing, Mac identity import and raw packets.

The look follows the Mac app (`docs/design.md`) and is written up in `Documentation/StyleGuide.md`: monochrome, Geist (bundled under the OFL in `Resources/Fonts`), 6 px controls, 8 px panels, 200 ms motion, plus a matching dark mode. Tokens and shared parts live in `Views/Design/Theme.swift`; `RUNES_SNAPSHOT=style-guide` shows the guide as a screen. Reduce Motion and Dynamic Type are respected. SwiftUI previews in `Views/Previews.swift` use fixed view states. In DEBUG builds, `RUNES_SNAPSHOT=<name>` shows one of those states for screenshots without starting the session. There is still no simulated band.

## Mappings

The hand button on the home screen opens **Mappings**, the iPhone version of the Mac app's Motions page: profiles, one row per gesture, combos (2–8 steps, hold/release pairing, the Mac's timing choices; steps can be recorded from the band), and one action or several linked actions run in order. `Mappings/MappingEngine.swift` is a port of the Mac's `ShortcutEngine` combo logic. Actions are iPhone-native (Apple Shortcut, open link, web API, notification, copy, haptic, wait, profile switching). API calls, notifications and profile switches also run while the phone is locked; opening apps, copying and haptics need Runes on screen. Combos can also use **rotation** (axis, and left/right/either way) and **movement** (axis) steps, detected with the Mac's thresholds (25° rotation, gyroscope above 80 re-arming below 30). The phone asks the band for orientation and gyroscope only while a live combo uses them; the Mac relay still receives only the streams the Mac requested. Combos can also use **air gesture** steps (`Mappings/AirGesture.swift`, `Views/AirGestureEditor.swift`): a shape drawn with a finger or recorded with the band, matched with the Mac's DTW matcher after the preceding gesture, within the step's own 0.5–10 s window; competing shapes go to the highest similarity above its minimum. They're saved in the Mac's format. Icons are the Mac's: Lucide 0.468.0 path data in `Views/Design/LucideData.swift` (generated by `Tools/lucide-icons.js`) and the Mac's hand-drawn finger icons in `Views/Design/Icons.swift`.

## Applications: Workouts

The grid button on the home screen opens **Applications**. The first app is **Workouts** (`Workouts/`, `Views/WorkoutsView.swift`, `Views/WorkoutTabs.swift`, `Views/BodyMap.swift`). It has three tabs. **Today** shows a hairline body, front and back: each muscle fills with ink when a set trains it and fades by a seventh each day after, back to an outline after a week (muscles a set only works second-hand count half). Below it are Start workout, which asks which day of your split to do and suggests the one after your last, and this week's reps. **Split** holds your training days (a push/pull/legs starter on first launch); each day lists exercises with sets, target reps (seconds for timed ones) and an optional weight. **Journal** shows workouts this month, sets this week, a weekly streak, sets per week, sets per muscle over the last 7 days, each exercise's best and a per-session sparkline, and every session. The exercise picker (`Workouts/ExerciseCatalog.swift`, 112 exercises, most popular first) filters by group, searches by name, equipment or muscle, and marks the 28 exercises whose reps the band can count with a waveform. Reps come from the band's orientation (forearm swing away from where the set started) or gyroscope bursts. Exercises the band can't follow log their target reps when the set stops; timed ones log the time between start and stop. The gear on Workouts opens its settings: the four global gestures (start set, default double tap index; stop set, double tap middle; repeat last set, swipe left; skip set, swipe right), which don't run their mappings while a workout runs, Low/Normal/High rep sensitivity (thresholds are untuned guesses), kg or lb, and clearing the journal. The Live Activity shows the current exercise, the live count (throttled to 1 update/s), the last logged set and the next one, and it alerts with a sound when a set is logged. Checks: `Tests/WorkoutTests.swift` (see its header for the `swiftc` line).

The second app is **Score** (`Scores/`, `Views/ScoreView.swift`): two to six players (named Player 1, Player 2 and so on until renamed), each a block of colour with one number (the one screen in Runes that uses colour; `ScoreTint` in `Shared/`). It is full screen, one player at a time: tap to add a point, the bar in the corner to take one away, the name to rename or remove that player. Swipe up to zoom out to everyone at once, where the game is started, reset and given more players (it opens there until a game is live); swipe down zooms back into the selected player. One at a time the players sit side by side in order like pages: swipe left for the next player and right for the one before, and they slide past. In the grid, swiping right moves the outline to the next player and left to the one before. The screen follows whoever was changed last, the phone stays awake while it is open, and it is the only screen that turns to landscape (`OrientationLock` in `RunesIOSApp.swift`). **Start game** gives the band its gestures until **End game**. Which gesture does what is chosen in **Score settings** (the gear in the everyone view; `Views/ScoreSettingsView.swift`, `ScoreControls`): add a point to or take one from the selected player (default double tap and tap-and-hold index), next and previous player (swipe right and left), and optionally a point to or from a particular player. Each action takes one gesture or a combo of two to eight finger and swipe steps with the Mappings timing choices; motion and air steps are left out so the motion sensors stay off during a game. No two actions share a trigger (choosing one another action has swaps them), and swipe up stays with the screen's zoom. A dedicated `MappingEngine` decides which trigger fired, so combos and double-tap waits behave exactly as in Mappings. While a game is live every mapping that uses one of the game's gestures is off (`ScoreControls.reserved`: each trigger's gestures, plus a finger's tap with its double tap and its release with its hold), including combos with such a step; Mappings shows them as "Off during the game" and they come back when it ends. Every change made from the band is confirmed by the Live Activity, which alerts with a sound and the new score; the Lock Screen and Dynamic Island show the numbers. Nothing is spoken. While a game is live the phone also plays sounds so it can be kept by ear with the phone locked (`Scores/ScoreAudio.swift`): one for a point added, one for a point taken away, and one per player when they are selected. The point sounds (Resolve and Bounce by default) are chosen in Score settings from the Mac app's whole library of 32 voices (`Sounds/SoundLibrary.swift`, a sample-for-sample port of `src/connectBell.ts` rendered offline), with a volume and an off switch. Player sounds are picked as one of five curated sets (`ScorePlayerSounds`: Mallets, Chimes, Arcade, Percussion, Soft), so every player always has a different voice, plus their own pitch. Any of them can be None. It runs a silent audio loop under the `audio` background mode for as long as the game is live, mixed with any music and audible with the silent switch on. A paired Mac still receives the raw gestures. Checks: `Tests/ScoreTests.swift`.

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
xcodebuild -project RunesIOS.xcodeproj -scheme RunesIOS -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For an unsigned device compilation:

```sh
xcodebuild -project RunesIOS.xcodeproj -scheme RunesIOS -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To install a standalone signed build, select your phone, edit the scheme's **Run → Info → Build Configuration** to **Release**, uncheck **Debug executable**, then Run. Stop the Xcode session and launch Runes from the phone's Home Screen. It does not use a Mac development server. Keep the same bundle ID and signing team between rebuilds to preserve the phone's Keychain identity.

## Structure and provenance

- `RunesIOS/Protocol`: bounded protobuf/DataX decoding, AirShield records, mutual trust, RPC and gesture subscription.
- `RunesIOS/Transport`: Core Bluetooth and L2CAP stream I/O on the session run loop.
- `RunesIOS/Authentication`: Meta service exchange, isolated login, persisted ownership ceremony.
- `RunesIOS/Session`: connection lifecycle, observable UI adapter, typed gestures, and Live Activity management.
- `RunesIOS/Persistence`: protected Keychain identity storage and rotating local journal.
- `RunesIOS/Views`: connection, gestures, packet details, and diagnostics.
- `Shared` / `RunesActivity`: ActivityKit attributes and Lock Screen/Dynamic Island presentation.

Protocol reference: the installed **meta-neural-py 0.1.0a1** source, captured as SHA-256 entries in `Documentation/ProtocolReference.sha256`. The Swift implementation is a port of the required paths, not an official Meta mobile SDK. Third-party attribution is in `THIRD_PARTY_NOTICES.md`. No neighboring repository is needed at runtime or build time.

`generate_project.py` can regenerate the checked-in project using Python's standard library if source membership changes; it is optional and never runs during a build. Signing-team selection is kept in Xcode. No development team or account credentials are committed.

## Checks

```sh
swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift Tools/ConnectionPolicyTests.swift -o /private/tmp/runes-connection-policy-tests && /private/tmp/runes-connection-policy-tests
swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Session/BandStatus.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift Tests/SessionPolicyTests.swift -o /private/tmp/runes-session-policy-tests && /private/tmp/runes-session-policy-tests
swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Session/Models.swift RunesIOS/Protocol/Wire.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Mappings/MappingModel.swift RunesIOS/Mappings/AirGesture.swift RunesIOS/Mappings/MappingEngine.swift Tests/MappingEngineTests.swift -o /private/tmp/runes-mapping-tests && /private/tmp/runes-mapping-tests
```

Builds and policy checks pass (Xcode 27.2, iOS 26 target). Hardware behaviour, onboarding with a real band, and locked-phone reconnection are **not yet verified on a device**. `generate_project.py` predates resources and Xcode's reformatting; edit the checked-in project instead.
