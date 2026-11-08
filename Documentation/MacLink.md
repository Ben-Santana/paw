# iPhone → Mac link

The Mac app never connects to the band. Runes on iPhone holds the band and relays gestures to each paired Mac over Bluetooth LE. The iPhone is the BLE central and the Mac is the peripheral: a locked iPhone app can keep a central link and pending connects alive, but it can barely advertise. To the user it reads as "the Mac connects to my iPhone".

## Code

| Piece | Where |
|---|---|
| Protocol, pairing, crypto (shared) | `RunesIOS/Relay/RelayWire.swift`, `RelayKeyStore.swift`. The Mac app vendors identical copies; `scripts/sync-relay-wire.sh` copies them and `--check` reports drift. |
| iPhone central | `RunesIOS/Relay/PhoneRelay.swift` |
| iPhone status API for views | `RunesIOS/Relay/MacLinks.swift`: `MacLinks.shared.macs`, `.pairing`, `.pair(text)`, `.remove(id)`, `.summary`. `SessionController.relayStatus` still carries the one-line summary. |
| Mac logic, no Bluetooth | `mac_os_meta_band_app/native/phone-link/PhoneLinkCore.swift` |
| Mac peripheral helper | `mac_os_meta_band_app/native/phone-link/PhoneLinkHelper.swift`, built to `dist-electron/runes-phone-link` |
| Mac event source | `mac_os_meta_band_app/python/event_sources.py` (`PhoneEventSource`), sink in `bridge.py` |

## Pairing (once)

1. The Mac shows a QR: `RUNESMAC1:` plus base64url of version, an ephemeral X25519 public key, a 16-byte one-time token, an expiry (2 minutes, refreshed automatically) and the Mac's name. Nothing long-lived is in it.
2. The Mac advertises a pairing service whose UUID is derived from the token, so the phone finds the Mac that showed the code.
3. The phone connects, reads the encrypted bond characteristic (iOS bonds with the Mac and may show its pairing prompt here), and sends its ephemeral key with a confirmation MAC keyed by the X25519 secret salted with the token. Only someone who scanned the QR can produce it.
4. The Mac checks it, consumes the token, and answers with its own confirmation, which proves it holds the QR's private key. Both derive a 32-byte link secret and a pairing ID and store them in the Keychain (one item per pairing, `com.runes.relay.v1`).
5. The Mac publishes a link service whose UUID and characteristic UUIDs derive from the link secret, then sends the accept. The phone continues on the same connection. Each Mac has its own service, so a phone only ever finds its own Macs. A phone can pair with several Macs; a Mac can pair with several phones.

Removing a Mac on the phone deletes its Keychain item and, if connected, tells the Mac (`bye removed`), which deletes its side. The Mac can also remove a phone in Device settings.

## Every connection

- The phone keeps a pending connect to each known Mac. It has no timeout and no retry limit, so iOS completes it when the Mac is in range again, after Mac sleep, or after the Mac app restarts, even while Runes is suspended. A scan runs only for Macs it has no identifier for.
- Setup: discover the Mac's service, read the bond characteristic, subscribe, then the phone sends `phoneHello` (fresh nonce + MAC). The Mac answers `macHello` echoing that nonce. Session keys are derived per direction from both nonces.
- **Background relaunch fix:** after iOS relaunches the app, it may deliver Mac notifications from the previous session. Before, the first control message then failed to decrypt and tore the link down. Now the phone starts every session, ignores a `macHello` that doesn't echo its current nonce, and ignores sealed packets whose session tag isn't the current one. A Mac that sees a stale tag replies `reset`, and the phone says hello again.

## Packet format (version 1)

Each GATT value is one packet. Byte 0 is the version and byte 1 the kind. Sealed packets continue with a 4-byte session tag, a 4-byte counter and ChaCha20-Poly1305 output with the header as associated data. The counter must strictly increase, which rejects replay and reordering. A future version byte is reported as "update needed", never as corruption.

| Kind | Direction | Body |
|---|---|---|
| `demand` 0x10 | Mac → phone | flags: active, gyro, orientation |
| `ready` 0x11 | phone → Mac | streams actually open, or none |
| `gesture` 0x12 | phone → Mac | seq u32, timestamp u64, age ms u16, finger, action, derived, synthetic (44-byte packet) |
| `gyro` 0x13 / `orientation` 0x14 | phone → Mac | seq, timestamp, age, 3×i16 / 4×f32 |
| `lease` 0x15 | phone → Mac | lease ms, app and band state, every 4 s while running |
| `ping` 0x16 / `pong` 0x17 | Mac ↔ phone | id (+ state) |
| `bye` 0x18 | both | normal, removed, terminating, sleeping |

## Safety

- The Mac drops a session after 25 s without an authenticated packet. A locked phone still runs about every 7 s because of the band pulse ([WakeTest.md](WakeTest.md)).
- While a key, mouse button, adjustment or pointer mode is held, the Mac pings every second. It releases everything after 2.5 s without a reply, and immediately on unsubscribe, lease expiry, a failed packet, Mac sleep, a helper restart, or phone goodbye.
- Gestures older than 1 s and motion older than 0.2 s (age measured on the phone) are rejected, as are events before the phone confirms the requested streams. Releases always pass, so nothing can stay held.
- Motion is requested only when an assignment or an open test view uses it.

## Tests

From this folder:

```sh
swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Relay/RelayWire.swift RunesIOS/Protocol/*.swift \
  RunesIOS/Authentication/OwnershipCeremony.swift RunesIOS/Persistence/IdentityStore.swift RunesIOS/Session/Models.swift \
  Tools/RelayProtocolTests.swift -o /private/tmp/runes-relay-tests && /private/tmp/runes-relay-tests
```

In the Mac app: `npm run test:phone-link` (Mac logic against a simulated phone, plus the drift check), `npm run test:python`, and with a preview running, `npm run test:connection`.

## Hardware checklist

Use a signed Release build on the iPhone with no debugger attached, and the packaged Mac app. Mark each step pass or fail.

1. **Pair:** On first launch the Mac shows "Open Runes on your iPhone and scan this code." Scan it in Runes on iPhone and accept any iOS Bluetooth request. The Mac menu bar then shows **Connected to iPhone** and the code doesn't come back. Quit and reopen the Mac app: still no code.
2. **Gesture to shortcut:** Assign tap-index to a shortcut and tap. It fires once. Hold-index with a hold-to-adjust assignment, turn your wrist, then release. Repeats stop on release.
3. **Mac sleep and wake:** Hold a mouse button through a hold assignment, close the lid, and wait 5 minutes. The button must not be stuck. Open the lid: the menu bar returns to **Connected to iPhone** without touching the phone, and a tap works.
4. **Walk away and back:** Start a hold, then walk out of range with the phone. Everything releases within about 3 seconds. Stay away 5 minutes: **iPhone not nearby**. Come back: connected again without touching anything.
5. **Phone locked:** Lock the iPhone and put it face down for 15 and then 60 minutes. A tap after each wait fires on the Mac within about a second.
6. **Remove a Mac:** Pair a second Mac, then remove one in Runes on iPhone. That Mac shows its pairing code again. The other Mac keeps working. Re-pair the removed Mac.
7. **App restarts:** Quit and reopen the Mac app: it reconnects within about 15 s. Restart the iPhone: the Mac shows **Open Runes on iPhone once**; open Runes once and it connects.
