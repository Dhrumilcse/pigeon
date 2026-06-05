# Pigeon — agent orientation

You're working on an iOS app that talks to a WHOOP 5.0 strap over BLE. The user iterates fast and prefers minimal, focused changes — don't refactor what they didn't ask about.

## What's already working

- Scan + connect (with `retrieveConnectedPeripherals` so already-connected straps still appear).
- Auto-reconnect to last device on launch (`UserDefaults` key `pigeon.rememberedDeviceID`).
- `CLIENT_HELLO` (cmd `0x91`) auth handshake — hardcoded 16-byte frame, verified.
- `TOGGLE_REALTIME_HR_ON` (cmd `3`, payload `[1]`) — built dynamically via `BluetoothManager.buildV5CommandFrame`.
- V5 frame parser for the realtime data stream on `fd4b0005` — extracts HR + RR intervals from K2 frames.
- Standard `0x180A` device info + `0x180F` battery surfaced on the General / Battery pages.
- Typed debug log (`DebugLogEntry`) with TX/RX/OK/INFO/WARN/ERR levels, tags, optional hex, filter chips, and share-as-text.

## File map

| File                       | What it owns                                                                 |
|----------------------------|------------------------------------------------------------------------------|
| `BluetoothManager.swift`   | All BLE state machine, V5 framing/parsing, CRC16/CRC32, the typed debug log |
| `PacketParser.swift`       | Heuristic parsers (legacy) — used only for non-V5 characteristics like 2A37  |
| `WhoopIdentification.swift`| WHOOP service UUIDs + name/advertisement helpers                             |
| `SettingsView.swift`       | Whole Settings stack: top WHOOP card → `WhoopDetailView`, General, Battery, Debug |
| `HomeView.swift`           | Live HR readout + stats grid                                                 |
| `ContentView.swift`        | TabView shell only — Home + Settings tabs                                    |

## The single most important external reference

`/Users/dhrumil/goose/` is a working WHOOP client in Swift + Rust. **Use it as the source of truth for protocol questions before guessing.** Pigeon is a from-scratch reimplementation but speaks the same protocol.

| Question                                 | Where in Goose                                                                 |
|------------------------------------------|--------------------------------------------------------------------------------|
| How is a V5 frame built?                 | `GooseSwift/GooseBLEClient+Parsing.swift` → `buildV5CommandFrame`, CRCs        |
| What packet types exist?                 | `Rust/core/src/protocol.rs` → `PACKET_TYPE_*` constants                        |
| Which command IDs are real?              | `GooseSwift/GooseBLEClient.swift` → `SensorStreamCommandKind` catalog          |
| How is a K-something packet decoded?     | `Rust/core/src/protocol.rs` → `parse_data_packet_body_summary`, `parse_k10_…`  |
| What's the auth handshake?               | `GooseSwift/GooseBLEClient+UserActions.swift` → `sendClientHello`              |

## The flow

```
scan/retrieve → connect → discoverServices(nil) → discoverCharacteristics(nil, for: each)
            ↓
on fd4b0002 found:  setNotifyValue(true) → send CLIENT_HELLO (cmd 0x91)
            ↓
on RX with [0]=aa [1]=01 [10]=0x91:  isAuthenticated = true → send REALTIME_HR_ON (cmd 3)
            ↓
on fd4b0005 RX:  parseV5RealtimeData(data) → currentHeartRate, lastRRIntervalsMS
```

`didUpdateValueFor` short-circuits in this order:

1. `handleStandardCharacteristic` — public GATT chars (`2A29`…`2A50`, `2A19`).
2. CLIENT_HELLO response detection — flips `isAuthenticated`, schedules the realtime-HR send.
3. V5 parse for `aa 01`-framed bytes — extracts HR/RR, then `return`. (Important: this bypasses the heuristic scanner so the SOF byte `0xaa` doesn't get misread as HR=170.)
4. Legacy heuristic parsing (`PacketParser`) — only runs for non-V5 frames like standard `2A37`.

## Empirical findings worth knowing

- **K2 frames on `fd4b0005`**: `payload[8]` = HR in BPM (matches `0x2A37`). `payload[9]` = RR count. `payload[10+]` = RR intervals as u16 LE in 1/1024-second units. Goose's Rust parser doesn't have a K2 decoder — this layout was reverse-engineered by diffing the custom stream against the public HR characteristic.
- **Flags bytes in the V5 header**: `00 01` = app→strap, `01 00` = strap→app. (Don't change the header CRC when only those swap — the CRC is over all 6 header bytes including these.)
- **`PacketParser.extractHeartRate` is a heuristic** — it scans for the first byte in 40–200. Correct by accident for `0x2A37` (HR is at byte 1), wrong for V5 frames (returns `0xAA` = 170). The V5 path skips it intentionally.

## Logging conventions

When emitting debug log entries from `BluetoothManager`, use the typed helpers, not raw strings:

```swift
logTX("REALTIME_HR_ON seq=\(seq)", tag: "CMD", hex: hexStr)
logRX("type=\(typeHex) len=\(len)", tag: shortUUID, hex: hexString)
logOK("Authenticated", tag: "AUTH")
logInfo("Manufacturer: \(name)", tag: "INFO")
logWarn("Empty characteristic update", tag: "BLE")
logError("Subscribe failed: \(error)", tag: tag)
```

Tags are short uppercase tokens — `AUTH`, `BLE`, `CMD`, `HR`, `BATT`, `INFO`, or a 4-char char ID like `0005`. One log call per logical event — don't split header + hex into two entries; pass `hex:` instead.

## Settings UI structure

```
Settings
├── WHOOP card  (NavigationLink → WhoopDetailView with scan/disconnect)
├── General     (NavigationLink → device info from 0x180A)
├── Battery     (NavigationLink → battery level from 0x180F)
└── Debug       (NavigationLink → typed log with filter + share)
```

Apple-Settings vocabulary: colored rounded-square icons (`gearshape.fill` gray, `battery.100` green, `hammer.fill` gray), `.insetGrouped` lists, destructive actions live on detail pages (Disconnect on `WhoopDetailView`), not the parent list.

## Don't

- Don't read or write bytes outside `BluetoothManager`. Parsing lives there; views observe `@Published` properties only.
- Don't add CRC tweaks without verifying the change still produces the known-good `CLIENT_HELLO` bytes `aa 01 08 00 00 01 e6 71 23 01 91 01 36 3e 5c 8d`.
- Don't call `addDebugLog` (deleted) — always use the typed `log*` helpers.
- Don't recreate dead UI structs in `ContentView.swift` — only the `TabView` shell belongs there.

## Conventions for new commands

If asked to send a new WHOOP command, the pattern is:

1. Look up the command number + payload shape in `~/goose/GooseSwift/GooseBLEClient.swift` (`SensorStreamCommandKind` or `debugResearchCommandDefinitions`).
2. Use `BluetoothManager.buildV5CommandFrame(sequence:command:data:)` — don't hand-build the header.
3. Send via the saved `commandCharacteristic` (the `fd4b0002` write char), after `isAuthenticated == true`.
4. Log the send with `logTX(<NAME> seq=<seq>, tag: "CMD", hex: <hex>)`.
5. The response will land on `fd4b0003` as an `aa 01 …` frame with packet type `0x24` (COMMAND_RESPONSE).
