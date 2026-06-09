# Pigeon — agent orientation

You're working on an iOS app that talks to a WHOOP 5.0 strap over BLE, persists samples to SwiftData, and renders Apple-Health-style charts. The user iterates fast and prefers minimal, focused changes — don't refactor what they didn't ask about.

## What's already working

- **Scan / connect / reconnect** — scan filters on WHOOP service UUIDs, `retrieveConnectedPeripherals` surfaces system-connected straps, `retrievePeripherals(withIdentifiers:)` auto-reconnects to the last device (UUID stored in `UserDefaults` key `pigeon.rememberedDeviceID`).
- **`CLIENT_HELLO`** (cmd `0x91`) — hardcoded 16-byte auth frame, verified against Goose.
- **After-auth command sequence**: `EXIT_HIGH_FREQ_SYNC` (cmd `0x61`) to stop the historical firehose, then `TOGGLE_REALTIME_HR_ON` (cmd `0x03` payload `[1]`) to start the K2 stream, then `START_RAW_DATA` (cmd `0x51` payload `[1]`) to start Raw43/K21 accelerometer frames. Commands are built dynamically via `buildV5CommandFrame`.
- **V5 reassembly** — long frames (K20 = 2140 B, K21 = 1244 B) arrive as multiple ~244 B BLE notifications; `processV5Chunk` stitches them back into a single logical frame keyed by characteristic UUID.
- **V5 dispatcher (focused)** — `handleCompleteV5Frame` always handles `0x24` COMMAND_RESPONSE, `0x28` REALTIME_DATA (K2), and `0x2B` REALTIME_RAW_DATA (Raw43/K21 accel). `0x2F` HISTORICAL_DATA and `0x31` METADATA are decoded only while `historicalSyncInProgress == true` (i.e. between the Sync History tap and the idle-timer finalize). Console logs and other K-types are silently dropped.
- **HR + RR + HRV computation** — K2 byte `[8]` = HR, byte `[9]` = RR count, bytes `[10+]` = RR intervals (u16 LE in 1/1024 s → ms). `ingestRRIntervals` keeps a 60 s rolling window with min/max RR filter (300-2000 ms) and ectopic-diff filter (max 200 ms successive delta), publishes RMSSD.
- **Persistence (SwiftData)** — `HRSample`, `RRSample`, `HRVSample`, `MotionSample` plus `HourlySummary` / `DailySummary` / `MonthlySummary` are `@Model` classes in `Models.swift`. Every valid HR, every filtered R-R, every RMSSD, and one compact aggregate per valid Raw43/K21 accel frame is inserted via a `ModelContext` the `BluetoothManager` owns. Realtime HR/HRV updates touch the summary rows incrementally; historical drains rebuild them in batch (see below). Retention = forever.
- **Historical sync** — Sync History button in Settings → WHOOP sends `SEND_HISTORICAL_DATA` (cmd 22). The dispatcher routes `0x2F`/`0x31` to a state machine that decodes K=18 → `HRSample` (timestamp at payload [7..10], HR at [14]), ACKs each `HistoryEnd` (metadata kind=2) with `HISTORICAL_DATA_RESULT` (cmd 23, payload `[0x01] + HistoryEnd[13..21]`), dedupes via `HRSample.sourceKey = "k18:<page>"`, flushes every 500 packets, and finalizes on either `HistoryComplete` (kind=3) or a 3 s idle timeout — whichever comes first. Finalize rebuilds the touched hourly/daily/monthly summary rows from scratch by re-folding raw `HRSample` rows for those buckets, then persists `lastHistoricalSyncAt` to `UserDefaults` (key `pigeon.lastHistoricalSyncAt`).
- **Background BLE** — `Info.plist` declares `UIBackgroundModes: bluetooth-central`. Connection survives backgrounding.
- **State restoration** — `CBCentralManager` initialized with `CBCentralManagerOptionRestoreIdentifierKey: "pigeon.central"`. `centralManager(_:willRestoreState:)` re-attaches the delegate to restored peripherals and re-runs service discovery so the auth + realtime sequence flows again.
- **Standard public services** — `0x180A` device info (manufacturer, model, serial, FW, HW) + `0x180F` battery surfaced on the General / Battery pages.
- **Typed debug log** (`DebugLogEntry`) with `info/ok/tx/rx/warn/err` levels, tags, optional hex, filter chips (`All / Transmit / Receive / Errors`), RR status banner, share-as-text. Entries are emitted via `logInfo / logOK / logTX / logRX / logWarn / logError`.
- **Charts (Apple-Health-style)** — Settings → Samples → Heart Rate / Heart Rate Variability. Segmented picker for `30m / 1h / 4h / 8h / 1d / 4d`. Y-axis on trailing edge, X-axis hidden, fixed-width red/purple bars. Home also has a Motion card + detail page powered by `MotionSample`. `@Query` with a `#Predicate<Sample>` on timestamp powers each chart.

## File map

| File                       | What it owns                                                                                                  |
|----------------------------|---------------------------------------------------------------------------------------------------------------|
| `PigeonApp.swift`          | App entry; creates the `ModelContainer` for sample/summary models and attaches it via `.modelContainer(...)` |
| `ContentView.swift`        | TabView shell; receives the `ModelContainer` and injects it into `BluetoothManager`'s init                    |
| `HomeView.swift`           | Live HR readout + HR / HRV / Motion cards and detail views                                                    |
| `SettingsView.swift`       | WHOOP card → detail, General, Battery, Samples (HR + HRV charts), Debug                                       |
| `BluetoothManager.swift`   | BLE state machine, V5 framing + parsing + reassembly, CRC, HRV math, SwiftData inserts, state-restoration delegate, typed debug log |
| `Models.swift`             | SwiftData `@Model` classes: `HRSample`, `RRSample`, `HRVSample`, `MotionSample`, summaries                    |
| `WhoopIdentification.swift`| WHOOP service UUIDs + name/advertisement helpers                                                              |

## The single most important external reference

`/Users/dhrumil/goose/` is a working WHOOP client in Swift + Rust. **Use it as the source of truth for protocol questions before guessing.**

| Question                                 | Where in Goose                                                                 |
|------------------------------------------|--------------------------------------------------------------------------------|
| How is a V5 frame built?                 | `GooseSwift/GooseBLEClient+Parsing.swift` → `buildV5CommandFrame`, CRCs        |
| What packet types exist?                 | `Rust/core/src/protocol.rs` → `PACKET_TYPE_*` constants                        |
| Which command IDs are real?              | `GooseSwift/GooseBLEClient.swift` → `SensorStreamCommandKind` catalog          |
| How is a K-something packet decoded?     | `Rust/core/src/protocol.rs` → `parse_data_packet_body_summary`, `parse_k10/k17/k21` |
| What's the auth handshake?               | `GooseSwift/GooseBLEClient+UserActions.swift` → `sendClientHello`              |
| What's `result_code = N` mean?           | `GooseSwift/GooseBLEClient+Parsing.swift` → `commandResultName` (0=FAILURE, 1=SUCCESS, 2=PENDING, 3=UNSUPPORTED) |
| Where does HRV come from in WHOOP?       | R17 (`packet_k = 17`) optical / labrador PPG packets — see `parse_r17_body_summary` in `protocol.rs`           |

## The flow

```
scan/retrieve → connect → discoverServices(nil) → discoverCharacteristics(nil, for: each)
            ↓
on fd4b0002 found:  setNotifyValue(true) → send CLIENT_HELLO (cmd 0x91)
            ↓
on COMMAND_RESPONSE acking 0x91:
    isAuthenticated = true
    +0.3 s:  send EXIT_HIGH_FREQ_SYNC (cmd 0x61)
    +0.6 s:  send REALTIME_HR_ON     (cmd 0x03 payload [1])
    +0.9 s:  send START_RAW_DATA     (cmd 0x51 payload [1])
            ↓
on fd4b0005 K2 frame:  parseV5RealtimeData → currentHeartRate / RR / HRV
                       + SwiftData inserts (HRSample, RRSample, HRVSample)
on fd4b0005 Raw43/K21: parseGen5RawAccelPayload → MotionSample compact aggregate
```

Sync History drain (separate, manually triggered):

```
tap "Sync History" → historicalSyncInProgress = true
                  → send SEND_HISTORICAL_DATA (cmd 22)
            ↓
strap streams batches on fd4b0005:
    META kind=1 (HistoryStart)
    HIST K=18  (decode → HRSample with sourceKey="k18:<page>", dedup, batched save every 500)
    HIST K=20, K=21  (logged, not decoded; realtime Raw43/K21 is decoded separately)
    META kind=2 (HistoryEnd) → send HISTORICAL_DATA_RESULT (cmd 23) once per batch
    (strap moves to next batch — repeat HistoryStart…)
            ↓
either META kind=3 (HistoryComplete) OR 3 s of silence
    → finalizeHistoricalSync:
        try? modelContext.save()
        for each touched hour:  rebuildHourlySummaryFromSamples
        for each touched day:   rebuildDailySummaryFromSamples + rebuildMonthlySummary
        historicalSyncInProgress = false
        lastHistoricalSyncAt = now  (UserDefaults)
```

`didUpdateValueFor` has three branches (in order):

1. `handleStandardCharacteristic` — public GATT (`0x180A` info, `0x180F` battery). Returns true → handled.
2. `isCustomWhoopCharacteristic` (`fd4b…`) → `processV5Chunk` accumulates; once a frame completes, `handleCompleteV5Frame` dispatches by packet type.
3. Anything else — silently ignored (we don't subscribe to `0x2A37` anymore).

`handleCompleteV5Frame` dispatches:

- `0x24` COMMAND_RESPONSE → `handleCommandResponse` (auth-ack triggers the EXIT + REALTIME_HR sequence; everything else just logs `ack cmd=… → RESULT_NAME`).
- `0x28` REALTIME_DATA → `handleRealtimeHR` (parses K2, updates published state, persists samples).
- `0x2B` REALTIME_RAW_DATA → `handleRealtimeRawMotion` (parses Gen5 Raw43/K21 accelerometer frames and persists `MotionSample` aggregates).
- `0x2F` HISTORICAL_DATA → logs K-value/length; if K=18 and `historicalSyncInProgress`, calls `ingestHistoricalK18`.
- `0x31` METADATA → logs kind/length; if `historicalSyncInProgress`, drives the sync state machine (kind=1 resets the per-batch ACK gate, kind=2 sends the ACK and resets the idle timer, kind=3 finalizes).
- default → drop silently.

## Empirical findings worth knowing

- **K2 frames on `fd4b0005`**: `payload[8]` = HR in BPM (validated byte-for-byte against `0x2A37` in an early session). `payload[9]` = RR count. `payload[10+]` = RR intervals u16 LE in 1/1024-s units. Goose's Rust parser doesn't have a K2 decoder — this layout was reverse-engineered.
- **RR is firmware-gated**: the strap's beat detector applies a confidence gate at the source. When optical signal is noisy (motion, slack contact), it emits HR but withholds the R-peak marks. Missed RR is **not** recoverable — the strap doesn't buffer beat-by-beat data for later sync. Goose's investigation confirms historical packets (K18/K24) carry only aggregated respiratory rate, not beat-by-beat RR.
- **Beat-by-beat data lives in R17 (K17) optical/PPG packets** — not enabled in Pigeon. Goose enables it with `cmd 107` (`ENABLE_OPTICAL_DATA_ON`) using `[1, 1]` payload (the Gen5 "revision boolean" format). This is the path to making HRV robust across activity levels, deferred for now.
- **Raw43/K21 Gen5 accelerometer layout** — `START_RAW_DATA` (cmd `0x51`, payload `[1]`) enables `REALTIME_RAW_DATA` frames (`payload[0] = 0x2B`, `payload[1] = 0x15`). Verified layout: timestamp seconds at `[7..10]`, subseconds `[11..12]`, sample counts `[14..19] = 100,100,3`, x samples `[20..219]`, y `[220..419]`, z `[420..619]`, all signed i16 LE scaled by `1/4096 g`. Store one `MotionSample` per valid frame, not all 300 raw values.
- **Raw43 validity check** — `parseGen5RawAccelPayload` only accepts frames whose mean vector magnitude is `0.8...1.2 g`. The first still captures showed clean `|g|≈0.997-0.999`.
- **Raw motion commands** — `START_RAW_DATA` succeeds and is enough. `TOGGLE_IMU_MODE` (cmd `0x6A`) returned `FAILURE` on this Gen5 firmware and should not be part of the normal sequence. `STOP_RAW_DATA` (cmd `0x52`, payload `[1]`) is exposed through Debug's Motion Probe stop card and verifies whether Raw43 frames stop during a short post-stop window.
- **Cmd 63 (`SEND_R10_R11_REALTIME_ON`) is `UNSUPPORTED` on Gen5 firmware `50.38.1.0`**. Returns `result_code = 3` in the ack. Removed from Pigeon's command sequence.
- **Historical drain runs in batches, not one continuous dump.** One `SEND_HISTORICAL_DATA` produces a series of `HistoryStart → K-packets → HistoryEnd` batches. Each `HistoryEnd` must be ACKed individually before the strap will send the next batch. Without the ACK the strap retransmits `HistoryEnd` every ~2 s and never sends `HistoryComplete`. ACK payload = `[0x01] + HistoryEnd[13..21]`.
- **K=18 carries only HR (offset 14), no RR / HRV.** Goose's `history_hr_marker_offset(18) = 14` and `parse_data_packet_body_summary` treats it as a present/absent marker; empirically the byte IS the bpm value on this firmware (validated against the realtime range). Beat-by-beat data is firmware-discarded — the only path to richer historical HRV is the realtime R17 PPG stream (cmd 107), which is a separate feature.
- **The strap's local page buffer is small (~1 hour observed on Gen5 firmware `50.38.1.0`)** and shared with the WHOOP official app. Anything that app ACKs is gone for Pigeon too. Sync History only catches what's accumulated since the last drain by either client; it does not backfill multi-day gaps.
- **Realtime never pauses during the drain.** K2 frames keep flowing at ~1 Hz interleaved with the K=18/20/21 burst on the same characteristic. No need to disable realtime before tapping Sync History; no need to re-enable it after.
- **Flags bytes in the V5 header**: `00 01` = app→strap, `01 00` = strap→app. The header CRC covers them.
- **`PacketParser.swift` and the legacy heuristic HR scanner are deleted** — `2A37` is no longer subscribed (it double-counted RR into HRV) and the heuristic was a foot-gun (matched any byte in 40-200 → on V5 frames, the SOF byte `0xaa` became HR=170).

## Logging conventions

```swift
logTX("REALTIME_HR_ON seq=\(seq)", tag: "CMD", hex: hexStr)
logRX("type=\(typeHex) len=\(len)", tag: shortUUID, hex: hexString)
logOK("Authenticated", tag: "AUTH")
logInfo("Manufacturer: \(name)", tag: "INFO")
logWarn("Non-V5 chunk dropped (\(n) B)", tag: shortUUID)
logError("Subscribe failed: \(error)", tag: tag)
```

Tags are short uppercase tokens — `AUTH`, `BLE`, `CMD`, `HR`, `HRV`, `BATT`, `INFO`, or a 4-char char ID like `0003` / `0005`. One log call per logical event — don't split header + hex into two entries; pass `hex:` instead.

## Settings UI structure

```
Home
├── Heart Rate card
├── Heart Rate Variability card
└── Motion card  (12h stillness %, sparkline; detail has D / W / M)

Settings
├── WHOOP card  (NavigationLink → WhoopDetailView with scan/disconnect)
├── General     (NavigationLink → device info from 0x180A)
├── Battery     (NavigationLink → battery level from 0x180F)
├── Samples     (NavigationLink → SamplesListView)
│     ├── Heart Rate                (→ HeartRateChartView, red bars)
│     └── Heart Rate Variability    (→ HRVChartView, purple bars)
├── Local Storage
│     └── MotionSample              (compact Raw43 accel aggregate rows)
└── Debug       (NavigationLink → typed log with filter + share)
```

Apple-Settings vocabulary: colored rounded-square icons (`gearshape.fill` gray, `battery.100` green, `chart.bar.fill` pink, `hammer.fill` gray, `heart.fill` red, `waveform.path.ecg` purple), `.insetGrouped` lists, destructive actions live on detail pages.

Chart views follow this pattern: outer view owns the segmented `Picker` for the range; inner `*ChartBody` view holds the `@Query` (initialized from `range.seconds`), and the outer wraps `.id(range)` to force re-init when the picker changes. Motion detail buckets `MotionSample.meanDeltaG` to keep overnight / multi-day charts readable.

## SwiftData specifics

- `PigeonApp` creates a single `ModelContainer(for: HRSample.self, RRSample.self, HRVSample.self, MotionSample.self, HourlySummary.self, DailySummary.self, MonthlySummary.self)` and:
  - attaches it to the scene with `.modelContainer(modelContainer)` so views get it via `@Environment`,
  - passes it into `ContentView(modelContainer:)` so `BluetoothManager` can use it for writes.
- `BluetoothManager` owns a **non-MainActor** `ModelContext` constructed directly from the container (not `container.mainContext`, which is `@MainActor`-isolated and would conflict with `CBCentralManagerDelegate`'s nonisolated requirements). This is safe because every BLE callback hits us on the `.main` queue (we hand `queue: .main` to CBCentralManager), so the context is only ever used from one thread.
- No manual `save()` calls — SwiftData's autosave handles persistence.
- **Schema is fixed once shipped.** Use `VersionedSchema` for any migration. During dev, deleting the app from the device clears the store.

## Motion specifics

- `MotionSample` stores compact aggregates only: `sampleCount`, mean/min/max X/Y/Z in g, `magnitudeG`, `rmsDeviationG`, `meanDeltaG`, `maxDeltaG`, and `sourceKey`.
- Stillness v1 heuristic in `HomeView.swift`: still if `meanDeltaG < 0.03 g` and `rmsDeviationG < 0.08 g`. This is provisional and should be tuned after overnight data.
- Motion home card intentionally stays clean: title, 12h stillness %, and a sparkline only. Detail view uses `D / W / M`, Health-style x-axis ticks, and shows samples, avg motion, max spike, coverage window, and a Show All Data link to `MotionSampleTableView`.
- Debug top strip has four cards: RR sample count, historical sync packet count, Motion Probe frame count (tap to run bounded probe), and stop card (visible while probe runs).

## End of session

Always run `./build.sh` from the repo root at the end of every session. It builds for the real device (id `779DF284-71E3-578E-A480-345C7F19CD39`) and installs the app via `xcrun devicectl`. This is the only accepted build verification — don't substitute a simulator `xcodebuild` invocation.

## Don't

- Don't read or write bytes outside `BluetoothManager`. Parsing lives there; views observe `@Published` properties or `@Query` SwiftData.
- Don't add CRC tweaks without verifying the change still produces the known-good `CLIENT_HELLO` bytes `aa 01 08 00 00 01 e6 71 23 01 91 01 36 3e 5c 8d`.
- Don't call `addDebugLog` (deleted). Use the typed `log*` helpers.
- Don't subscribe to `0x2A37` (standard HR Measurement) — it duplicates RR into the HRV window. We unsubscribed for a reason.
- Don't re-enable the legacy heuristic HR scanner (also deleted). On V5 frames it reads SOF byte `0xaa` as HR=170.
- Don't mark `BluetoothManager` `@MainActor` — it breaks `CBCentralManagerDelegate` conformance. Use a non-isolated `ModelContext` instead.
- Don't recreate dead UI structs in `ContentView.swift` — only the `TabView` shell belongs there.
- Don't reach for `container.mainContext` from `BluetoothManager` — it's `@MainActor`-isolated and won't compile cleanly from the BLE delegate methods.
- Don't persist all 100 Raw43 samples per axis unless the user explicitly asks for raw-capture/export. The app currently stores compact `MotionSample` aggregates by design.

## Conventions for new commands

If asked to send a new WHOOP command:

1. Look up the command number + payload shape in `~/goose/GooseSwift/GooseBLEClient.swift` (`SensorStreamCommandKind` or `debugResearchCommandDefinitions`).
2. Use `BluetoothManager.buildV5CommandFrame(sequence:command:data:)` — don't hand-build the header.
3. Send via `writeCommand(_:to:characteristic:)` after `isAuthenticated == true`.
4. Log the send with `logTX("<NAME> seq=\(seq)", tag: "CMD", hex: <hex>)`.
5. The response will land on `fd4b0003` as an `aa 01 …` frame with packet type `0x24` (COMMAND_RESPONSE). `handleCommandResponse` already decodes the result code via `commandResultName` — your new command will get `OK CMD ack cmd=0xNN → SUCCESS/UNSUPPORTED/…` for free.

## Open questions for the next agent

- **HRV during activity** — currently relies on K2 RR which is firmware-gated. Historical sync (K=18) doesn't help — Goose's notes and our investigation both confirm K=18 carries only HR. The R17 PPG stream (cmd 107, payload `[1, 1]`) would give beat-by-beat data even during exercise; untried because Gen5 might respond `UNSUPPORTED`.
- **K=20 (2140 B) decoder** — arrives during historical drains alongside K=18, currently dropped. Not in Goose. Likely sleep / per-page aggregates; would need a packet capture and reverse-engineering pass.
- **K=18 body beyond [14]** — we extract HR only. Remaining 97 bytes carry other aggregates (respiratory rate, body temp markers) per Goose's `parse_data_packet_body_summary`. Decoding these would broaden what Sync History contributes per page.
- **Apple HealthKit mirror** — would make samples visible in the Health app. Adds entitlement + permission flow.
- **Persistence migration story** — schema is fixed once a user starts collecting. Add `VersionedSchema` before any model field changes.
