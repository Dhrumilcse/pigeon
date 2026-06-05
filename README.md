# Pigeon

A minimal iOS app that reads live data from a WHOOP 5.0 strap over BLE — including the custom WHOOP service, not just the public GATT characteristics.

## What it does

- Scans for WHOOP devices (Gen5 service `fd4b0001-…`, Gen4 `61080001-…`).
- Auto-reconnects to the last-known WHOOP on launch.
- Surfaces devices already connected to the system, so you don't have to toggle Bluetooth.
- Authenticates with the WHOOP using the `CLIENT_HELLO` (command `0x91`) handshake.
- Sends `TOGGLE_REALTIME_HR_ON` (command `0x03`, payload `[1]`) to start the realtime stream.
- Decodes the resulting V5 realtime-data frames on `fd4b0005` for heart rate and RR intervals.
- Reads standard `0x180A` Device Information + `0x180F` Battery Level for the General / Battery pages.
- Renders a categorized debug log (TX / RX / OK / INFO / WARN / ERR) with filters and share-as-text.

## WHOOP BLE protocol notes (what we found)

The custom WHOOP service `fd4b0001-cce1-4033-93ce-002d5875f58a` exposes:

| Characteristic         | Role                                              |
|------------------------|---------------------------------------------------|
| `fd4b0002` (write)     | Command channel — write V5 command frames here    |
| `fd4b0003` (notify)    | Command responses + auth replies                  |
| `fd4b0004` (notify)    | (subscribed, unused so far)                       |
| `fd4b0005` (notify)    | Realtime data stream (HR, RR, etc.)               |

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
  byte 0        packet type (0x23=COMMAND, 0x24=COMMAND_RESPONSE, 0x28=REALTIME_DATA, 0x30=EVENT, …)
  byte 1        sequence (COMMAND) or K-value (DATA)
  byte 2..n-5   command/data bytes
  byte n-4..n-1 CRC32 (IEEE 802.3) over the padded payload bytes
```

### Realtime HR stream (K2 frame)

`fd4b0005` emits 32-byte V5 frames at ~1 Hz once `TOGGLE_REALTIME_HR_ON` is sent. Empirically (Goose's Rust parser doesn't decode K2 specifically), the 20-byte payload looks like:

```
[0]  0x28  packet type (REALTIME_DATA)
[1]  0x02  K-value (K2)
[2]        sequence counter, +1 per frame
[3..6]     u32 LE counter (constant within a short window)
[7]  0x4e  constant marker
[8]        HR in BPM (matches public 0x2A37 exactly)
[9]        RR interval count (0–2 observed)
[10..n]    RR intervals, u16 LE in 1/1024-second units
[..]       padding / status bytes (last observed 0x01 at offset 18)
```

The standard heart-rate measurement on `0x2A37` carries the same HR byte and RR intervals using the standard GATT layout (flags byte + HR + RR pairs). The custom 0005 stream is just WHOOP's framed version of the same data.

### Command IDs (Goose-derived)

| ID  | Name                          |
|-----|-------------------------------|
| 3   | TOGGLE_REALTIME_HR            |
| 63  | SEND_R10_R11_REALTIME         |
| 91  | GET_HELLO (auth handshake)    |
| 96  | ENTER_HIGH_FREQ_SYNC          |
| 97  | EXIT_HIGH_FREQ_SYNC           |
| 106 | TOGGLE_IMU_MODE               |
| 107 | ENABLE_OPTICAL_DATA           |
| 108 | TOGGLE_OPTICAL_MODE           |
| 153 | TOGGLE_PERSISTENT_R20         |
| 154 | TOGGLE_PERSISTENT_R21         |

Only `91` and `3` are wired up in Pigeon today. The rest are documented in `~/goose/GooseSwift/GooseBLEClient.swift` (search `SensorStreamCommandKind`).

## File map

```
Pigeon/
├── PigeonApp.swift           SwiftUI app entry
├── ContentView.swift         TabView shell (Home + Settings)
├── HomeView.swift            Live HR display + stats grid
├── SettingsView.swift        iOS-Settings-style stack: WHOOP card → detail / General / Battery / Debug
├── BluetoothManager.swift    All BLE state + V5 framing + parsing + typed debug log
├── PacketParser.swift        Legacy heuristic parsers (used for non-V5 characteristics)
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

## References

- `~/goose/` — full reference WHOOP client (Swift + Rust). The protocol code in Pigeon mirrors `GooseSwift/GooseBLEClient+Parsing.swift` (frame builder, CRCs) and `Rust/core/src/protocol.rs` (packet type table).
- WHOOP service UUIDs and command names come from Goose's `SensorStreamCommandKind` catalog.
