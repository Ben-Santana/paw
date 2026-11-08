# Manual acceptance on your iPhone

Use the same band and record phone model, iOS version, band firmware if available, build version, battery/Low Power Mode, and whether a Live Activity was present. Never count successful compilation as device verification.

## 1. Phone connection

- Close other band clients, start Neural, allow Bluetooth, scan, and explicitly select the band.
- Enroll using phone Meta sign-in and accept system pairing. Confirm subscription reaches **Streaming** rather than merely reporting a peripheral connection.
- Disconnect and reconnect using the saved phone identity, without Meta login.
- Quit normally/relaunch and confirm saved connection intent behavior. Explicit Disconnect must remain disconnected after relaunch.

## 2. Built-in gestures

- Perform the band's available index/middle taps, presses, holds, releases, and directional gestures.
- Inspect packet details: finger, raw/derived action, synthetic flag, sequence, device timestamp, host receipt, and source clock.
- Verify derived-only packets use their derived label and unknown enum codes remain visible. Counts are packets, not a promise of one packet per physical gesture.

## 3. Standalone background session

Install a signed **Release** build, uncheck **Debug executable**, stop the Xcode session, and launch from the phone's Home Screen. Disconnect the cable and debugger. No Mac server is required.

For each case, write down the actual wall-clock interval and perform a recognizable series of gestures near its end:

- Another app is in the foreground.
- Lock Screen is visible.
- Locked display has remained completely dark for **1 minute**.
- Locked display has remained completely dark for **5 minutes**.
- Locked display has remained completely dark for **15 minutes**.

Do not wake the phone to inspect it during a dark-display interval. Reopen afterward and export the journal. Host callback receipt times must occur inside the recorded interval to support background-processing evidence. If device timestamps advance but host receipt times cluster after reopening, report delayed delivery; do not mark the background check passed. The app's `background` label alone cannot prove the screen was dark.

Repeat the intervals with the Live Activity active, then with it dismissed. Status display updates are intentionally bounded and can become stale; they do not prove live event reception.

## 4. Connection recovery and cancellation

- Walk out of range and return; confirm a fresh authenticated gesture subscription and a new session ID.
- Turn Bluetooth off and on; check paused/resumed reconnection without an enrollment loop.
- Cancel the system pairing prompt and Meta sign-in. Cancel while login is preparing and while the login sheet is visible.
- Use Disconnect during connect/reconnect; verify it cancels future connection attempts.
- Interrupt enrollment before completion, then explicitly retry sign-in. Pending host identity should be retained; a finish with a persisted band key can first be retried with Connect.
- Re-enroll from another client to invalidate this phone's identity; verify Neural asks for user recovery instead of silently enrolling again.
- Where iOS provides state restoration after system termination, inspect restoration and new authentication events. User force-quit is a separate unsupported guarantee and must not be used as the sole restoration test.

## 5. Diagnostics and privacy

- Export, share, and clear the journal; ensure live event reception continues.
- Check host times and device times remain distinct. Reconnect boundaries must be visible.
- Confirm exports exclude passwords, login tokens, ownership receipts, private keys, and raw HTTP response bodies.
- If journal writes fail, the UI must display the warning while reception remains active. Do not claim evidence for intervals whose journal is incomplete.

## Acceptance record

Record **pass / fail / not checked** and notes for phone connection, foreground gesture delivery, each background interval, reconnect, enrollment recovery, Live Activity dismissal, and export. Keep raw journal evidence with the result. Hardware and background operation remain unverified until these checks are performed.

## Mac identity QR transfer

- Display a verified Mac identity with `swift Tools/ShowMacIdentity.swift <Mac-device-ID>`; verify the window closes after 60 seconds and no secret is printed or written to disk.
- Disconnect the Mac, select the same band on iPhone, import the QR, and accept camera/Bluetooth permissions. Verify Streaming without Meta sign-in or ownership enrollment.
- Disconnect iPhone and reconnect Mac without enrolling again; repeat in the other direction.
- Deny camera access, cancel scanning, and interrupt scanning by backgrounding; verify recovery without changing the saved identity.
- Scan unrelated JSON, unsupported versions, oversized payloads, malformed base64, invalid private keys, and invalid band points; verify rejection with no key material in logs.
- Import keys for another band or a stale identity; verify authentication fails and the previous verified identity remains intact. Confirm no automatic enrollment occurs.
- Interrupt import before successful authentication, relaunch, and retry Connect; verify the pending candidate is used and only promoted after mutual authentication.
- Confirm export rejects incomplete identities, and supports explicitly permitted compatibility identities without a band public key. Do not photograph or commit real QR codes.

Run the additional [shared identity handoff acceptance](ConnectionStabilization.md) without enrollment, reset, or OS forgetting during the baseline series.
