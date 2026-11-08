# Locked-phone wake test

> **Retired harness (2026-11-08).** The Mac relay probe and its timed-run tools were replaced by the real link in the Mac app; see [MacLink.md](MacLink.md). The results below stand. To rerun these steps, check out the `Tools/` folder from the baseline commit.

This test decides who holds the band connection. The band streams only over L2CAP, and Apple says L2CAP won't wake a suspended app the way a GATT notification does. The test checks whether a heartbeat from the Mac keeps gestures flowing while the iPhone is locked.

It takes about half a day, mostly waiting. Passing compiled builds proves nothing here; only these hardware runs count.

## Result (2026-11-08)

Subscribing to band characteristics `2D41DA7A` and `2D41DA7C` (service FEB8) makes the band send a one-byte `00` notification on both, about every 7 seconds. Each one wakes the app, so the locked phone kept delivering gestures with no Mac heartbeat. Prompts at 1, 5 and 15 minutes were hits in about 1.3 to 1.5 seconds, and no suspensions were logged. Without the subscription, or the Mac heartbeat, gestures stopped within about a minute.

The app now subscribes automatically every time the band's data channel opens. If no pulse arrives for 30 seconds, it logs `band_pulse missing` in the journal. Still unchecked: 30- and 60-minute gaps, a full day's battery drain, the band off the wrist, and other band firmware. The runs below remain useful for those.

## Set up once

1. Install a signed **Release** build of RunesIOS on the iPhone. In the scheme, uncheck **Debug executable**, then stop Xcode and unplug the phone. A debugger keeps the app from suspending, so a run with one attached is invalid.
2. Run `sh Tools/build-mac-relay-probe.sh` and open `/private/tmp/RunesRelayProbe.app`. Allow Bluetooth.
3. On iPhone, tap **Pair Mac BLE test receiver** and scan the QR. iOS should now show a Bluetooth pairing request; accept it, and note any prompt on the Mac too.
4. Connect the band on iPhone with its saved identity, with no direct Mac session running.
5. Confirm the Mac shows **Receiving from iPhone** and that a gesture raises the counter.
6. On iPhone, open **Diagnostics** and clear the journal. Record the battery level and turn Low Power Mode off.

## Timed runs

Keep the Mac in **Gestures** mode. Each run takes 60 minutes. Do them in this order:

| Run | Heartbeat | Why |
|---|---|---|
| A | Off | Baseline: shows what the phone does with no help |
| B | 10 s | Lowest battery cost |
| C | 5 s | Middle ground |
| D | 2 s | Best case for latency |

For each run:

1. Choose the heartbeat, then press **Start timed run**.
2. Lock the iPhone and put it face down. Don't wake it until the run ends.
3. Wear the band. Each time the Mac chimes, at 1, 5, 15, 30 and 60 minutes, do one clear index tap.
4. When the run ends, record the phone's battery level.

The Mac stays awake during a run. For a quick rehearsal, launch the probe from Terminal with `RUNES_WAKE_SCHEDULE="0.5,1"`, which sets the prompts in minutes. Skip run A's remaining prompts if it has clearly failed.

## Other checks

Use the best heartbeat from the timed runs:

- **Mac sleep:** close the lid for 5 minutes with the iPhone locked, then open it. Look for `relink_after_mac_wake` in the log, then try a gesture.
- **Walk away:** leave the band and phone apart from the Mac for 5 minutes with the iPhone locked, then return and try a gesture.
- **Mac identifier:** quit and reopen the probe twice, and reboot the Mac once. Look for `stable=true` in the phone journal.
- **Heavy phone use:** open a few large apps, lock the phone, and repeat one 15-minute prompt. This pushes iOS to terminate Runes.

## Bring back

- The CSV files from `~/Library/Logs/RunesWakeTest` (use **Show log**).
- The iPhone journal from **Diagnostics → Export event journal**. It holds gesture data and device identifiers, so share it only as you'd share personal data.
- Battery start and end levels for each run.
- Any pairing prompts you saw, and any time you had to touch the phone.

## What to read in the results

| Evidence | Where | Meaning |
|---|---|---|
| `trial_hit` seconds | Mac CSV | Chime to gesture on Mac, including your reaction time |
| `trial_miss` | Mac CSV | No gesture reached the Mac within 30 seconds |
| `suspension_gaps`, `longest_gap` | Mac CSV | How often and how long the phone app stopped running |
| `phone_state` | Mac CSV | The app's last lifecycle state; it can't detect a dark screen |
| `wake_probe gap` | Phone journal | Each suspension, with its length |
| `gatt_listing` | Phone journal | Every band service and characteristic, listed once per launch |
| `bond_read ok=true` | Phone journal | The phone and Mac bonded |

Check `gatt_listing` for any `notify` or `indicate` characteristic other than battery. One that fires on gestures would let the band wake the phone itself, which would be better than a heartbeat. The test doesn't subscribe to any of them, because writing to unknown band settings needs its own decision.

## Decision

Treat these as starting thresholds. Reaction time usually takes a few hundred milliseconds of each `trial_hit`.

**The phone hub is viable if, at a single heartbeat setting:**

- All five prompts are hits, in two separate runs.
- Every `trial_hit` is under 1 second.
- Nothing needed touching the phone.
- The Mac relinks by itself after sleep and after walking away.
- Battery drain is acceptable for a full day of use.

**Move to the Mac-direct design if** gestures arrive late or in bursts, any prompt is missed, or the only passing setting drains too much battery. The setup screens stay the same; the Mac holds the band connection, and the phone handles setup.

**Not covered here:** two-host band bonding, AccessorySetupKit, and force quit. They need separate tests once this result is in.
