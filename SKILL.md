# Pigeon — agent orientation

You're working on an iOS app that talks to a WHOOP 5.0 strap over BLE, persists samples to SwiftData, and renders Apple-Health-style charts. The user iterates fast and prefers minimal, focused changes — don't refactor what they didn't ask about.

## What's already working

- **Scan / connect / reconnect** — scan filters on WHOOP service UUIDs, `retrieveConnectedPeripherals` surfaces system-connected straps, `retrievePeripherals(withIdentifiers:)` auto-reconnects to the last device (UUID stored in `UserDefaults` key `pigeon.rememberedDeviceID`).
- **`CLIENT_HELLO`** (cmd `0x91`) — hardcoded 16-byte auth frame, verified against Goose.
- **After-auth command sequence**: `EXIT_HIGH_FREQ_SYNC` (cmd `0x61`) to stop the historical firehose, then `TOGGLE_REALTIME_HR_ON` (cmd `0x03` payload `[1]`) to start the K2 stream. Both built dynamically via `buildV5CommandFrame`.
- **V5 reassembly** — long frames (K20 = 2140 B, K21 = 1244 B) arrive as multiple ~244 B BLE notifications; `processV5Chunk` stitches them back into a single logical frame keyed by characteristic UUID.
- **V5 dispatcher (focused)** — `handleCompleteV5Frame` only handles `0x24` COMMAND_RESPONSE and `0x28` REALTIME_DATA (K2). Everything else (historical, raw, metadata, console logs) is silently dropped — we told the strap not to send it.
- **HR + RR + HRV computation** — K2 byte `[8]` = HR, byte `[9]` = RR count, bytes `[10+]` = RR intervals (u16 LE in 1/1024 s → ms). `ingestRRIntervals` keeps a 60 s rolling window with min/max RR filter (300-2000 ms) and ectopic-diff filter (max 200 ms successive delta), publishes RMSSD.
- **Persistence (SwiftData)** — `HRSample`, `RRSample`, `HRVSample` are `@Model` classes in `Models.swift`. Every valid HR, every filtered R-R, and every RMSSD is inserted via a `ModelContext` the `BluetoothManager` owns. Retention = forever.
- **Background BLE** — `Info.plist` declares `UIBackgroundModes: bluetooth-central`. Connection survives backgrounding.
- **State restoration** — `CBCentralManager` initialized with `CBCentralManagerOptionRestoreIdentifierKey: "pigeon.central"`. `centralManager(_:willRestoreState:)` re-attaches the delegate to restored peripherals and re-runs service discovery so the auth + realtime sequence flows again.
- **Standard public services** — `0x180A` device info (manufacturer, model, serial, FW, HW) + `0x180F` battery surfaced on the General / Battery pages.
- **Typed debug log** (`DebugLogEntry`) with `info/ok/tx/rx/warn/err` levels, tags, optional hex, filter chips (`All / Transmit / Receive / Errors`), RR status banner, share-as-text. Entries are emitted via `logInfo / logOK / logTX / logRX / logWarn / logError`.
- **Charts (Apple-Health-style)** — Settings → Samples → Heart Rate / Heart Rate Variability. Segmented picker for `30m / 1h / 4h / 8h / 1d / 4d`. Y-axis on trailing edge, X-axis hidden, fixed-width red/purple bars. `@Query` with a `#Predicate<Sample>` on timestamp powers each chart.

## File map

| File                       | What it owns                                                                                                  |
|----------------------------|---------------------------------------------------------------------------------------------------------------|
| `PigeonApp.swift`          | App entry; creates the `ModelContainer` for the three sample models and attaches it via `.modelContainer(...)` |
| `ContentView.swift`        | TabView shell; receives the `ModelContainer` and injects it into `BluetoothManager`'s init                    |
| `HomeView.swift`           | Live HR readout + HRV / Battery metric cards                                                                  |
| `SettingsView.swift`       | WHOOP card → detail, General, Battery, Samples (HR + HRV charts), Debug                                       |
| `BluetoothManager.swift`   | BLE state machine, V5 framing + parsing + reassembly, CRC, HRV math, SwiftData inserts, state-restoration delegate, typed debug log |
| `Models.swift`             | SwiftData `@Model` classes: `HRSample`, `RRSample`, `HRVSample`                                               |
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
            ↓
on fd4b0005 K2 frame:  parseV5RealtimeData → currentHeartRate / RR / HRV
                       + SwiftData inserts (HRSample, RRSample, HRVSample)
```

`didUpdateValueFor` has three branches (in order):

1. `handleStandardCharacteristic` — public GATT (`0x180A` info, `0x180F` battery). Returns true → handled.
2. `isCustomWhoopCharacteristic` (`fd4b…`) → `processV5Chunk` accumulates; once a frame completes, `handleCompleteV5Frame` dispatches by packet type.
3. Anything else — silently ignored (we don't subscribe to `0x2A37` anymore).

`handleCompleteV5Frame` dispatches:

- `0x24` COMMAND_RESPONSE → `handleCommandResponse` (auth-ack triggers the EXIT + REALTIME_HR sequence; everything else just logs `ack cmd=… → RESULT_NAME`).
- `0x28` REALTIME_DATA → `handleRealtimeHR` (parses K2, updates published state, persists samples).
- default → drop silently.

## Empirical findings worth knowing

- **K2 frames on `fd4b0005`**: `payload[8]` = HR in BPM (validated byte-for-byte against `0x2A37` in an early session). `payload[9]` = RR count. `payload[10+]` = RR intervals u16 LE in 1/1024-s units. Goose's Rust parser doesn't have a K2 decoder — this layout was reverse-engineered.
- **RR is firmware-gated**: the strap's beat detector applies a confidence gate at the source. When optical signal is noisy (motion, slack contact), it emits HR but withholds the R-peak marks. Missed RR is **not** recoverable — the strap doesn't buffer beat-by-beat data for later sync. Goose's investigation confirms historical packets (K18/K24) carry only aggregated respiratory rate, not beat-by-beat RR.
- **Beat-by-beat data lives in R17 (K17) optical/PPG packets** — not enabled in Pigeon. Goose enables it with `cmd 107` (`ENABLE_OPTICAL_DATA_ON`) using `[1, 1]` payload (the Gen5 "revision boolean" format). This is the path to making HRV robust across activity levels, deferred for now.
- **Cmd 63 (`SEND_R10_R11_REALTIME_ON`) is `UNSUPPORTED` on Gen5 firmware `50.38.1.0`**. Returns `result_code = 3` in the ack. Removed from Pigeon's command sequence.
- **The strap's internal subsystems emit `cmd 22 / cmd 23` acks** during historical-sync mode — those are `SEND_HISTORICAL_DATA` and `HISTORICAL_DATA_RESULT` (we don't send them; they're strap-side internals visible on `fd4b0003`). Pre-`EXIT_HIGH_FREQ_SYNC` you'll see them in the log; after, they typically taper off.
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
Settings
├── WHOOP card  (NavigationLink → WhoopDetailView with scan/disconnect)
├── General     (NavigationLink → device info from 0x180A)
├── Battery     (NavigationLink → battery level from 0x180F)
├── Samples     (NavigationLink → SamplesListView)
│     ├── Heart Rate                (→ HeartRateChartView, red bars)
│     └── Heart Rate Variability    (→ HRVChartView, purple bars)
└── Debug       (NavigationLink → typed log with filter + share)
```

Apple-Settings vocabulary: colored rounded-square icons (`gearshape.fill` gray, `battery.100` green, `chart.bar.fill` pink, `hammer.fill` gray, `heart.fill` red, `waveform.path.ecg` purple), `.insetGrouped` lists, destructive actions live on detail pages.

Chart views follow this pattern: outer view owns the segmented `Picker` for the range; inner `*ChartBody` view holds the `@Query` (initialized from `range.seconds`), and the outer wraps `.id(range)` to force re-init when the picker changes.

## SwiftData specifics

- `PigeonApp` creates a single `ModelContainer(for: HRSample.self, RRSample.self, HRVSample.self)` and:
  - attaches it to the scene with `.modelContainer(modelContainer)` so views get it via `@Environment`,
  - passes it into `ContentView(modelContainer:)` so `BluetoothManager` can use it for writes.
- `BluetoothManager` owns a **non-MainActor** `ModelContext` constructed directly from the container (not `container.mainContext`, which is `@MainActor`-isolated and would conflict with `CBCentralManagerDelegate`'s nonisolated requirements). This is safe because every BLE callback hits us on the `.main` queue (we hand `queue: .main` to CBCentralManager), so the context is only ever used from one thread.
- No manual `save()` calls — SwiftData's autosave handles persistence.
- **Schema is fixed once shipped.** Use `VersionedSchema` for any migration. During dev, deleting the app from the device clears the store.

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

## Conventions for new commands

If asked to send a new WHOOP command:

1. Look up the command number + payload shape in `~/goose/GooseSwift/GooseBLEClient.swift` (`SensorStreamCommandKind` or `debugResearchCommandDefinitions`).
2. Use `BluetoothManager.buildV5CommandFrame(sequence:command:data:)` — don't hand-build the header.
3. Send via `writeCommand(_:to:characteristic:)` after `isAuthenticated == true`.
4. Log the send with `logTX("<NAME> seq=\(seq)", tag: "CMD", hex: <hex>)`.
5. The response will land on `fd4b0003` as an `aa 01 …` frame with packet type `0x24` (COMMAND_RESPONSE). `handleCommandResponse` already decodes the result code via `commandResultName` — your new command will get `OK CMD ack cmd=0xNN → SUCCESS/UNSUPPORTED/…` for free.

## Open questions for the next agent

- **HRV during activity** — currently relies on K2 RR which is firmware-gated. The R17 PPG stream (cmd 107, payload `[1, 1]`) would give beat-by-beat data even during exercise. Untried because Gen5 might respond `UNSUPPORTED`.
- **K20 (~2140 B) decoder** — not in Goose. Could carry sleep aggregates or something else. Currently dropped.
- **Apple HealthKit mirror** — would make samples visible in the Health app. Adds entitlement + permission flow.
- **Persistence migration story** — schema is fixed once a user starts collecting. Add `VersionedSchema` before any model field changes.
