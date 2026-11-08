# BLE phone hub hardware trial

> **Retired harness (2026-11-08).** The Mac relay probe and its timed-run tools were replaced by the real link in the Mac app; see [MacLink.md](MacLink.md). The results below stand. To rerun these steps, check out the `Tools/` folder from the baseline commit.

This is the first release gate for the phone hub. Run the [locked-phone wake test](WakeTest.md) first: it uses the same setup and decides whether the rest of this trial matters. The iPhone holds the band connection and opens a separate BLE connection to a Mac receiver. The receiver displays event counters and timing samples. It is a test harness for transport and acquisition.

## Run the trial

1. Build and install a signed Release build of RunesIOS using its existing bundle identifier. Disconnect the debugger before testing. Retain the phone's existing band identity.
2. Run `sh Tools/build-mac-relay-probe.sh` and open the resulting app. The script defaults to `/private/tmp/RunesRelayProbe.app`. Allow Bluetooth if prompted. For a timing log, run the executable in the app's `Contents/MacOS` directory from Terminal.
3. In Runes on iPhone, tap **Pair Mac BLE test receiver** near Diagnostics and scan the receiver's QR. Use **Show pairing QR** if the display expired. Keep the QR private. It carries the prototype's relay credential, separate from band ownership.
4. Connect the band to iPhone using its saved identity. Release any Mac direct band session first. Wait for **Receiving from iPhone** on Mac and verify a deliberate gesture increments the counter. Select **Gestures + motion** on the Mac and move the band to verify that both motion counters advance. Switch back to **Gestures** and confirm that only the gesture counter advances.
5. Turn Wi-Fi off in Settings on both devices, leaving Bluetooth enabled. Repeat the gesture and motion checks. Use a wired or external record of test gestures for timing. The printed timestamps come from two different wall clocks, so calibrate their offset before comparing them.

## Locked phone acceptance

- Leave the phone dark and locked with the Mac in **Gestures** mode. Perform a deliberate gesture after 1, 15, and 60 minutes of inactivity. Verify receipt of the first event on Mac while iPhone remains locked.
- Let the Mac sleep and wake while iPhone remains locked. Verify the phone rediscovers the receiver or resumes the existing link, negotiates demand, and delivers fresh gestures without a phone interaction.
- While iPhone remains locked, choose **Gestures + motion** on Mac. Measure gyro and orientation delivery, latency, missed samples, and recovery after brief interruption. Switch back to gestures and check that motion stops.
- Repeat across the Live Activity's eight-hour active limit without renewing it. Evaluate dismissal, denied Live Activities, Low Power Mode, and system termination separately. Do not use force-quit as a substitute for system termination.
- Log app and OS versions, both link states, requested and acknowledged streams, first delivered gesture, and any intervention. Compare with the foreground baseline. A locked phone needs actual Mac receipt for each pass. For production, also verify action dispatch, stale event rejection, and stuck input recovery.

The prototype uses a persisted test credential and a bounded GATT event queue. Production pairing needs one-time enrollment credentials, and product integration remains gated on the locked-phone results. If motion hits the GATT limit, repeat using a measured L2CAP event path before changing the user experience.
