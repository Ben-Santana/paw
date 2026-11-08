# Shared identity stabilization and hardware acceptance

Implemented software behavior is separate from verified hardware behavior. This change does not enroll, reset, forget pairings, or establish a band bond-count limit. Live hardware tests below remain unexecuted.

## User flow

1. Setup: disconnect the active client. Import the existing Mac identity on iPhone, or select an existing saved identity. Only deliberately new ownership uses explicit enrollment confirmation. Missing-band-key compatibility is supported; it encrypts the channel and authenticates the host without verifying band identity.
2. Normal use: Connect uses the saved identity. Eligible pending records are selectable separately. The same selection policy applies to foreground connect, cold launch and restored channels. QR import explicitly selects its pending candidate.
3. Rediscovery: select the new Bluetooth UUID and choose the existing credential record by public host fingerprint. Its original Keychain account is retained. Commit the address alias only after successful authentication. In compatibility mode the user must identify the physical band; names, RSSI, and successful host authentication are not band-identity proof.
4. Handoff: Disconnect on the source; wait for local cleanup. Mac reports helper/session closure, without claiming remote readiness. iPhone waits for Core Bluetooth closure or explicitly reports that release was not confirmed. Source reconnection is paused. Connect the destination with the same identity and confirm Streaming.
5. Recovery: pairing error CBErrorDomain:14 pauses immediately and preserves its domain/code. Repair an obsolete OS pairing only when appropriate, rediscover, and select the existing identity. Authentication, storage, and malformed-protocol errors require user recovery. Other iPhone transport failures retry at most five times (1, 2, 4, 8, 16 seconds while execution is available); Mac retries at most three times (1, 2, 4 seconds). No failure automatically enrolls.

Saved records are preserved while pending candidates are tested. An explicitly selected pending candidate replaces the saved record only after authentication. Selecting the previous saved record does not discard pending state. iPhone clears the promoted pending record after successful authentication; Mac retains it for inspection. No private key appears in the identity list or diagnostics.

## Controlled hardware record

Before each series record phone/Mac OS, app builds, band firmware when available, battery, Meta/other-client state, and whether a Live Activity is active. Record public host fingerprints, identity account, selected peripheral UUID, connection stage, errors, and source/destination wall times. Do not include private keys or QR captures.

- Baseline: connect each app separately using the same fingerprint. No enrollment during the series.
- Retained bonds: Mac → phone → Mac, at least ten round trips, without pairing mode, OS forgetting, or enrollment. Record new system pairing prompts and the furthest completed stage. A timeout before protocol bytes is not host-identity rejection.
- Pairing-mode effects: compare ordinary reconnect with entering pairing mode as the sole changed variable. Check whether the previously working host still connects. Do not infer bond capacity from one failure.
- Concurrent links: hold one client streaming, inspect advertisements, then attempt the other client without enrollment. Distinguish second Bluetooth link, L2CAP channel, authenticated setup and subscription. Reverse roles. A second subscription failing does not establish a one-bond limit.
- Identifier changes: record UUIDs before/after reconnect, pairing mode and reboot. Verify explicit association uses the same credential fingerprint and that failed authentication does not bind the new address.
- Cancellation: cancel during scan, Bluetooth connect, authentication, retry delay, Meta login and stream shutdown. No later callbacks may restart a canceled connection. Mac must remain paused after relaunch; iPhone's saved connection intent must remain false.
- Failure classification: use a stale pending candidate, then choose the saved record; confirm no enrollment. Exercise out-of-range/Bluetooth-off recovery and OS bond mismatch separately.
- iOS background: standalone signed build, debugger detached. Record gestures after 1/5/15/60 dark-screen minutes and after a long idle interval, with Live Activity active/dismissed/denied. Compare transport callback times, not just device timestamps or the background label. Restoration and user force-quit are separate cases.

Acceptance: mark each case pass/fail/not checked and attach sanitized journals. Repeatable switching requires both directions to reach authenticated Streaming with unchanged public host fingerprint. Builds, mocks and unit tests do not satisfy hardware acceptance.

## Isolated checks

Mac: `npm run test:python`; `npm run build`; run `node scripts/connection-stability-smoke.mjs` and `node scripts/startup-smoke.mjs` against a Vite preview. Optional `PREVIEW_URL` selects an isolated port; screenshots default to `/private/tmp/neural-connection-ui`. These UI tests use mocked bridge messages.

iPhone policy checks, from this project folder:

```sh
swiftc -module-cache-path /private/tmp/neural-swift-module-cache NeuralIOS/Session/Models.swift NeuralIOS/Protocol/Wire.swift NeuralIOS/Persistence/IdentityStore.swift Tools/ConnectionPolicyTests.swift -o /private/tmp/neural-connection-policy-tests
/private/tmp/neural-connection-policy-tests
```

These compile production selection/error/retry/binding logic with generated ephemeral keys and a temporary preferences suite. They do not query Keychain, initialize Bluetooth or contact Meta. Build the iOS app separately to verify integration.
