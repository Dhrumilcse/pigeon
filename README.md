# Pigeon

A minimal iOS app that reads live data from a WHOOP 5.0 strap over BLE — including the custom WHOOP service, not just the public GATT characteristics. Persists every sample to SwiftData and renders Apple-Health-style charts. Keeps collecting overnight in the background.

## What it does

- Scans for WHOOP devices (Gen5 service `fd4b0001-…`, Gen4 `61080001-…`).
- Surfaces devices already connected to the system, so you don't have to toggle Bluetooth.
- Auto-reconnects to the last-known WHOOP on launch.
- Authenticates with the WHOOP using the `CLIENT_HELLO` (command `0x91`) handshake.
- Tells the strap to stop the historical-sync firehose (`EXIT_HIGH_FREQ_SYNC`, command `0x61`) so realtime HR/RR gets the airtime.
- Starts the realtime stream with `TOGGLE_REALTIME_HR_ON` (command `0x03`).
- Drains the strap's buffered HR history on demand via a **Sync History** button in Settings → WHOOP — see *Historical sync* below.
- Reassembles fragmented V5 frames on `fd4b0005` (long packets arrive as multiple 244 B BLE notifications).
- Decodes K2 frames for heart rate + R-R intervals.
- Computes HRV (RMSSD) over a 60 s rolling window with ectopic-beat filtering.
- Persists every HR / RR / HRV sample to SwiftData with retention = forever.
- Stays connected while the app is backgrounded (`UIBackgroundModes: bluetooth-central`) and survives force-quit via CoreBluetooth state restoration.
- Reads standard `0x180A` Device Information + `0x180F` Battery for the General / Battery pages.
- Renders bar charts (HR + HRV) under Settings → Samples with a segmented `30m / 1h / 4h / 8h / 1d / 4d` range picker.
- Categorized debug log (TX / RX / OK / INFO / WARN / ERR) with filter chips and share-as-text.

## WHOOP BLE protocol notes (what we found)

The custom WHOOP service `fd4b0001-cce1-4033-93ce-002d5875f58a` exposes:

| Characteristic         | Role                                              |
|------------------------|---------------------------------------------------|
| `fd4b0002` (write)     | Command channel — write V5 command frames here    |
| `fd4b0003` (notify)    | Command responses + auth replies                  |
| `fd4b0004` (notify)    | (subscribed, unused so far)                       |
| `fd4b0005` (notify)    | Realtime data stream                              |
| `fd4b0007` (notify)    | (subscribed, unused so far)                       |

### V5 frame format

Every WHOOP custom packet (TX or RX) uses this envelope:

```
[ 8-byte header ][ payload (LEN bytes, includes 4-byte CRC32 trailer) ]

Header:
  aa            SOF
  01            version
  LO HI         payload length (u16 LE)
  flag1 flag2   00 01 for app→strap, 01 00 for strap→app
  CRC16 LO HI   CRC-16/Modbus over the first 6 bytes (poly 0xA001)

Payload:
  byte 0        packet type (0x23=COMMAND, 0x24=COMMAND_RESPONSE, 0x28=REALTIME_DATA, 0x2B=REALTIME_RAW_DATA, 0x2F=HISTORICAL_DATA, 0x30=EVENT, 0x31=METADATA, 0x32=CONSOLE_LOGS, …)
  byte 1        K-value (for data packets) or sequence (for commands)
  byte 2..n-5   command/data bytes
  byte n-4..n-1 CRC32 (IEEE 802.3) over the padded payload bytes
```

Large frames (typical: 1244 B K21 raw motion, 2140 B K20) arrive as multiple ~244 B BLE notifications. Pigeon reassembles them into a single logical frame before dispatch. Realtime K2 (HR + RR) and command responses are always handled; `0x2F` HISTORICAL_DATA + `0x31` METADATA are handled only while a Sync History drain is in flight (see below). Other K-types (K=20, K=21 raw motion) are dropped.

### Realtime HR stream (K2 frame)

`fd4b0005` emits 32-byte V5 frames at ~1 Hz once `TOGGLE_REALTIME_HR_ON` is sent. Empirically (Goose's Rust parser doesn't decode K2 specifically), the 20-byte payload looks like:

```
[0]  0x28  packet type (REALTIME_DATA)
[1]  0x02  K-value (K2)
[2]        sequence counter, +1 per frame
[3..6]     u32 LE counter (constant within a short window)
[7]        constant marker (e.g. 0x4e per session)
[8]        HR in BPM (matches public 0x2A37 byte-for-byte)
[9]        RR interval count (0–2 observed)
[10..n]    RR intervals, u16 LE in 1/1024-second units → ms
[..]       padding / status bytes (last observed 0x01 at offset 18)
```

The strap's beat-detection runs through a **confidence gate in firmware** — when the optical signal is noisy (motion, slack contact), RR slots come through as zero. HR keeps streaming. WHOOP's own app reflects this by showing HRV only as a daily metric computed during sleep. Pigeon computes RMSSD opportunistically from whatever RR we get.

### Historical sync (K=18)

Tapping **Sync History** in Settings → WHOOP sends `SEND_HISTORICAL_DATA` (cmd 22). The strap then dumps its buffered page queue as a series of `HistoryStart → K-packets → HistoryEnd` batches. Each batch must be ACKed individually with `HISTORICAL_DATA_RESULT` (cmd 23) before the strap will move on to the next.

K=18 payload (124 B frame, 112 B payload after envelope):

```
[0]     0x2F  packet type (HISTORICAL_DATA)
[1]     0x12  K-value (K=18)
[2]           status / stream byte
[3..6]        u32 LE counter_or_page  (monotonic, used as dedup key)
[7..10]       u32 LE timestamp_seconds (unix epoch)
[11..12]      u16 LE timestamp_subseconds (out of 32768)
[13]          (unused / flags)
[14]          HR in bpm  ← Goose calls this a "marker"; empirically it is the value
[15..]        other aggregates (respiratory rate, body temp, etc — undecoded)
```

ACK payload mirrors Goose's `historicalDataResultPayload(fromHistoryEndMetadataPayload:)`:
`[0x01] + HistoryEnd[13..21]` — the success byte plus 8 echo bytes from the HistoryEnd metadata body. The strap will keep retransmitting `HistoryEnd` every ~2 s until it sees this ACK.

End-of-stream is signaled either by `HistoryComplete` (metadata `kind=3`) or by a 3 s idle timeout after the last packet — whichever comes first. On either signal Pigeon does one batched `save()` and rebuilds the affected `HourlySummary` / `DailySummary` / `MonthlySummary` rows by re-folding all matching `HRSample` rows for the touched buckets.

Dedup uses `HRSample.sourceKey = "k18:<page>"`. On every K=18 ingest Pigeon checks `fetchCount(predicate: $0.sourceKey == key)` — if non-zero, skip. Realtime inserts leave `sourceKey` nil so the predicate never matches them.

A few empirical notes from running this:

- **K=18 carries only HR** — no RR, no HRV. Beat-by-beat data is firmware-discarded; the only way to recover HRV during activity is the realtime R17 PPG path (cmd 107), not historical sync. (See *Open questions* in `SKILL.md`.)
- **Realtime never pauses during the drain.** K2 frames keep flowing at ~1 Hz on the same characteristic alongside the K=18/20/21 burst — no need to disable realtime first.
- **The strap's local buffer is small** (~1 hour observed on Gen5 firmware `50.38.1.0`). It's shared with the WHOOP official app: pages the WHOOP app ACKs are gone for Pigeon too. So Sync History catches what's accumulated since the last drain by either client — it does *not* backfill multi-day gaps.
- **`HistoryComplete` (metadata `kind=3`) only arrives once every batch has been ACKed.** Before Pigeon was wired to ACK, kind=3 never appeared — the strap was stuck retransmitting kind=2.
- **K=20 (2140 B) and K=21 (1244 B) are streamed during the same drain** but currently dropped. K=21 is raw IMU motion per Goose; K=20 is undecoded.

### Command IDs (Goose-derived)

| ID   | Name                          | Wired in Pigeon? |
|------|-------------------------------|------------------|
| 3    | TOGGLE_REALTIME_HR            | yes (after auth) |
| 22   | SEND_HISTORICAL_DATA          | yes (Sync History button) |
| 23   | HISTORICAL_DATA_RESULT (ACK)  | yes (one per HistoryEnd batch) |
| 34   | GET_DATA_RANGE                | no |
| 63   | SEND_R10_R11_REALTIME         | tried — UNSUPPORTED on Gen5 firmware `50.38.1.0` |
| 91   | GET_HELLO (auth handshake)    | yes |
| 96   | ENTER_HIGH_FREQ_SYNC          | no |
| 97   | EXIT_HIGH_FREQ_SYNC           | yes (after auth, before realtime HR) |
| 106  | TOGGLE_IMU_MODE               | no |
| 107  | ENABLE_OPTICAL_DATA           | no (candidate for R17 PPG / beat-by-beat HRV) |
| 108  | TOGGLE_OPTICAL_MODE           | no |
| 153  | TOGGLE_PERSISTENT_R20         | no |
| 154  | TOGGLE_PERSISTENT_R21         | no |

Command-response result codes (per Goose): `0=FAILURE`, `1=SUCCESS`, `2=PENDING`, `3=UNSUPPORTED`. Pigeon decodes these and logs `ack cmd=0xNN → SUCCESS`.

## Persistence

SwiftData store, three `@Model` classes (`Pigeon/Models.swift`):

- `HRSample(timestamp, bpm, sourceKey?)` — written for every valid K2 HR (~1 Hz, `sourceKey` nil) and for every K=18 historical page (`sourceKey = "k18:<page>"`, used for dedup on re-sync).
- `RRSample(timestamp, intervalMS)` — written for each filtered R-R interval (sparse).
- `HRVSample(timestamp, rmssdMS)` — written each time RMSSD is computed.

Retention is forever (no rolloff). Default location: `Application Support/default.store`. The charts use SwiftUI `@Query` with a `#Predicate<Sample> { $0.timestamp >= rangeStart }` so range changes re-fetch reactively.

## Background + state restoration

- `Info.plist`: `UIBackgroundModes` = `[bluetooth-central]`. App keeps the BLE link alive while backgrounded.
- `CBCentralManager` initialized with `CBCentralManagerOptionRestoreIdentifierKey: "pigeon.central"`. iOS will relaunch the app in the background to deliver BLE events even after force-quit (until the device reboots and stays locked).
- `centralManager(_:willRestoreState:)` re-attaches the delegate, repopulates connection state, and triggers `discoverServices(nil)` so the auth + realtime command flow re-runs on the surviving connection.

## File map

```
Pigeon/
├── PigeonApp.swift           SwiftUI app entry; owns the ModelContainer
├── ContentView.swift         TabView shell (Home + Settings); injects container into BluetoothManager
├── HomeView.swift            Live HR readout + HRV / Battery metric cards
├── SettingsView.swift        WHOOP card → detail / General / Battery / Samples (HR + HRV charts) / Debug
├── BluetoothManager.swift    BLE state machine, V5 framing/parsing/reassembly, CRC, HRV math, SwiftData inserts, state-restoration delegate, typed debug log
├── Models.swift              SwiftData @Model classes: HRSample, RRSample, HRVSample
└── WhoopIdentification.swift Helpers for recognising a WHOOP device
```

## Build

```bash
xcodebuild \
  -project Pigeon.xcodeproj \
  -scheme Pigeon \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

For an actual device:
```bash
xcodebuild \
  -project Pigeon.xcodeproj \
  -scheme Pigeon \
  -configuration Debug \
  -destination 'platform=iOS,id=<device-id>' \
  -allowProvisioningUpdates \
  build
```

Or use `./build.sh` for a device build that auto-picks a paired iPhone.

## References

- `~/goose/` — full reference WHOOP client (Swift + Rust). The protocol code in Pigeon mirrors `GooseSwift/GooseBLEClient+Parsing.swift` (frame builder, CRCs) and `Rust/core/src/protocol.rs` (packet types + the K-table). Commands are sourced from `GooseSwift/GooseBLEClient.swift`'s `SensorStreamCommandKind` catalog.
