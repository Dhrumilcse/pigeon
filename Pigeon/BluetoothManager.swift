import CoreBluetooth
import Foundation
import Combine
import SwiftData

class BluetoothManager: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedDevice: DiscoveredDevice?
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var currentHeartRate: Int?
    @Published var lastHeartRateUpdate: Date?
    @Published var lastRRReceivedAt: Date?
    @Published var currentHRV: Double?
    @Published var lastHRVUpdate: Date?
    @Published var debugLog: [DebugLogEntry] = []

    // Standard public-service info (read from 0x180A / 0x180F)
    @Published var manufacturerName: String?
    @Published var modelNumber: String?
    @Published var serialNumber: String?
    @Published var hardwareRevision: String?
    @Published var firmwareRevision: String?
    @Published var softwareRevision: String?
    @Published var systemID: String?
    @Published var pnpID: String?
    @Published var batteryLevel: Int?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var deviceMap: [UUID: CBPeripheral] = [:]
    private var commandCharacteristic: CBCharacteristic?
    private var isAuthenticated = false
    private var hasAttemptedAutoReconnect = false

    // V5 frame reassembly state, keyed by characteristic. iOS notifications are
    // MTU-capped (~244 B), so long frames like the K21 raw-motion stream arrive
    // in several pieces and have to be stitched back together before parsing.
    private struct V5ReassemblyState {
        var bytes: [UInt8] = []
        var declaredTotal: Int = 0
        var chunkCount: Int = 0
    }
    private var v5Reassembly: [CBUUID: V5ReassemblyState] = [:]

    private struct V5CompleteFrame {
        let bytes: Data
        let chunkCount: Int
    }

    private static let rememberedDeviceKey = "pigeon.rememberedDeviceID"

    // WHOOP service UUIDs
    // Gen5 (WHOOP 5.0)
    private let whoopServiceGen5 = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    // Gen4 (WHOOP 4.0) - for reference
    private let whoopServiceGen4 = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")

    private let commandCharacteristicUUID = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    private let responseCharacteristicUUID = CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a")
    private let dataCharacteristicUUID = CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a")

    // Standard GATT characteristics (Device Information 0x180A, Battery 0x180F)
    private let manufacturerNameUUID = CBUUID(string: "2A29")
    private let modelNumberUUID = CBUUID(string: "2A24")
    private let serialNumberUUID = CBUUID(string: "2A25")
    private let hardwareRevisionUUID = CBUUID(string: "2A27")
    private let firmwareRevisionUUID = CBUUID(string: "2A26")
    private let softwareRevisionUUID = CBUUID(string: "2A28")
    private let systemIDUUID = CBUUID(string: "2A23")
    private let pnpIDUUID = CBUUID(string: "2A50")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")
    private let notificationCharacteristicUUIDs = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a")
    ]

    // CLIENT_HELLO authentication frame (from Goose)
    // Command 0x91 (GET_HELLO) - required before accessing protected characteristics
    private let clientHelloFrame: [UInt8] = [
        0xaa, 0x01, 0x08, 0x00, 0x00, 0x01, 0xe6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3e, 0x5c, 0x8d
    ]

    private var nextSequence: UInt8 = 2

    // Rolling RR-interval window for RMSSD HRV computation. Distinct from the
    // SwiftData @Model `RRSample` — this is the in-memory cache the math uses.
    private struct RRWindowEntry {
        let timestamp: Date
        let intervalMS: Double
    }
    private var rrWindow: [RRWindowEntry] = []
    private static let hrvWindowSeconds: TimeInterval = 60
    private static let hrvMinSamples = 5
    private static let rrIntervalMinMS: Double = 300   // 200 bpm — reject anything tighter as an artifact
    private static let rrIntervalMaxMS: Double = 2000  // 30 bpm — reject anything looser
    // Successive-difference filter for ectopic / missed beats. Real beat-to-beat
    // variation rarely exceeds ~200 ms; larger jumps almost always mean the strap
    // skipped a beat or double-counted one, and squaring them blows up RMSSD.
    private static let rrMaxSuccessiveDiffMS: Double = 200
    private static let hrvMinValidDiffs = 4

    // If RR has been gated by the strap for this long, re-send REALTIME_HR_ON
    // to prod WHOOP into refreshing its beat-detection state. Throttled by the
    // same interval so we don't spam the radio.
    private static let rrSilenceNudgeSeconds: TimeInterval = 300
    private var lastRealtimeHRNudgeAt: Date?

    private var whoopServiceUUIDs: [CBUUID] {
        [whoopServiceGen5, whoopServiceGen4]
    }

    // SwiftData persistence. We own a non-MainActor context backed by the
    // same container the views read from — safe because every BLE callback
    // hits us on `.main` (the queue we hand to CBCentralManager), so the
    // context is only ever used from one thread.
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    // State-restoration identifier. iOS uses this to wake us up in the background
    // when the connected peripheral sends data, even if the app was force-quit.
    private static let centralRestoreIdentifier = "pigeon.central"

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }

        discoveredDevices.removeAll()
        deviceMap.removeAll()

        // A WHOOP that is already connected (to the system, the WHOOP app, or our
        // own previous session) stops advertising, so a plain scan won't see it.
        // Surface those peripherals up front so the user doesn't have to toggle Bluetooth.
        let alreadyConnected = centralManager.retrieveConnectedPeripherals(withServices: whoopServiceUUIDs)
        for peripheral in alreadyConnected {
            logInfo("Found already-connected peripheral: \(peripheral.name ?? "unknown")", tag: "BLE")
            let device = DiscoveredDevice(
                id: peripheral.identifier,
                name: peripheral.name ?? "WHOOP",
                rssi: nil
            )
            deviceMap[peripheral.identifier] = peripheral
            if !discoveredDevices.contains(where: { $0.id == device.id }) {
                discoveredDevices.append(device)
            }
        }

        isScanning = true
        centralManager.scanForPeripherals(withServices: whoopServiceUUIDs, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }

    func connect(to device: DiscoveredDevice) {
        guard let peripheral = deviceMap[device.id] else { return }

        connectionState = .connecting
        connectedDevice = device
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        connectedDevice = nil
        isAuthenticated = false
        commandCharacteristic = nil
    }

    // Realtime HR On: command 3 with payload [1] (Goose: TOGGLE_REALTIME_HR_ON)
    private func sendRealtimeHROn(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: 3, data: [1])
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("REALTIME_HR_ON seq=\(seq)", tag: "CMD", hex: hexStr)
        writeCommand(frame, to: peripheral, characteristic: characteristic)
    }

    // Exit High Frequency History Sync: command 97 with empty payload
    // (Goose: EXIT_HIGH_FREQ_SYNC). Tells the strap to stop dumping historical
    // K18/K20/K21 packets so realtime HR/RR have the airtime to flow cleanly.
    private func sendExitHighFreqSync(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: 97, data: [])
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("EXIT_HIGH_FREQ_SYNC seq=\(seq)", tag: "CMD", hex: hexStr)
        writeCommand(frame, to: peripheral, characteristic: characteristic)
    }

    private func writeCommand(_ frame: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        if characteristic.properties.contains(.write) {
            peripheral.writeValue(frame, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
        } else {
            logError("Command characteristic doesn't support write", tag: "CMD")
        }
    }

    // Build a V5 command frame (mirrors Goose's buildV5CommandFrame).
    // Header: aa 01 LEN_LO LEN_HI 00 01 + CRC16-Modbus(header)
    // Payload: 0x23 SEQ CMD DATA... [pad to 4-byte boundary] + CRC32 IEEE
    static func buildV5CommandFrame(sequence: UInt8, command: UInt8, data: [UInt8]) -> Data {
        var payload: [UInt8] = [0x23, sequence, command]
        payload.append(contentsOf: data)
        let padding = payload.count % 4 == 0 ? 0 : 4 - payload.count % 4
        if padding > 0 {
            payload.append(contentsOf: repeatElement(UInt8(0), count: padding))
        }

        let payloadCRC = crc32(payload)
        let declaredLength = UInt16(payload.count + 4)
        var frame: [UInt8] = [
            0xaa,
            0x01,
            UInt8(declaredLength & 0xff),
            UInt8((declaredLength >> 8) & 0xff),
            0x00,
            0x01,
        ]
        let headerCRC = crc16Modbus(frame)
        frame.append(UInt8(headerCRC & 0xff))
        frame.append(UInt8((headerCRC >> 8) & 0xff))
        frame.append(contentsOf: payload)
        frame.append(UInt8(payloadCRC & 0xff))
        frame.append(UInt8((payloadCRC >> 8) & 0xff))
        frame.append(UInt8((payloadCRC >> 16) & 0xff))
        frame.append(UInt8((payloadCRC >> 24) & 0xff))
        return Data(frame)
    }

    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc = UInt16(0xffff)
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xa001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32(0xffffffff)
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xedb88320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    func sendSetAdvertisingName(_ name: String, completion: ((Bool) -> Void)? = nil) {
        guard isAuthenticated,
              let peripheral = connectedPeripheral,
              let cmd = commandCharacteristic else {
            logError("Cannot rename — not authenticated", tag: "CMD")
            completion?(false)
            return
        }
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty else { return }
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: 140, data: nameBytes)
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("SET_ADVERTISING_NAME \"\(name)\" seq=\(seq)", tag: "CMD", hex: hexStr)
        pendingRenameCompletion = completion
        writeCommand(frame, to: peripheral, characteristic: cmd)
    }

    private var pendingRenameCompletion: ((Bool) -> Void)?

    private func sendClientHello(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let data = Data(clientHelloFrame)
        let hexStr = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("CLIENT_HELLO", tag: "AUTH", hex: hexStr)

        if characteristic.properties.contains(.write) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            logError("Command characteristic doesn't support write", tag: "AUTH")
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    // Called by iOS before `centralManagerDidUpdateState` when the system
    // relaunches the app to deliver BLE events. We re-attach our delegate
    // to any peripherals iOS handed back and resume bookkeeping; everything
    // else (auth, characteristic discovery) flows through the same delegate
    // methods as a fresh connection.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else {
            logInfo("State restored with no peripherals", tag: "BLE")
            return
        }
        logInfo("State restored with \(peripherals.count) peripheral(s)", tag: "BLE")

        for peripheral in peripherals {
            peripheral.delegate = self
            deviceMap[peripheral.identifier] = peripheral

            if peripheral.state == .connected {
                connectedPeripheral = peripheral
                connectionState = .connected
                connectedDevice = DiscoveredDevice(
                    id: peripheral.identifier,
                    name: peripheral.name ?? "WHOOP",
                    rssi: nil
                )
                // Kick characteristic discovery to re-wire commandCharacteristic
                // and trigger CLIENT_HELLO; idempotent if iOS preserved services.
                peripheral.discoverServices(nil)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state

        if central.state != .poweredOn {
            isScanning = false
            connectionState = .disconnected
            return
        }

        attemptAutoReconnectIfNeeded(central: central)
    }

    private func attemptAutoReconnectIfNeeded(central: CBCentralManager) {
        guard !hasAttemptedAutoReconnect else { return }
        hasAttemptedAutoReconnect = true

        guard let stored = UserDefaults.standard.string(forKey: Self.rememberedDeviceKey),
              let rememberedID = UUID(uuidString: stored) else {
            return
        }
        let retrieved = central.retrievePeripherals(withIdentifiers: [rememberedID])
        guard let peripheral = retrieved.first else { return }

        logInfo("Auto-reconnecting to \(peripheral.name ?? "unknown")", tag: "BLE")
        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: peripheral.name ?? "WHOOP",
            rssi: nil
        )
        deviceMap[peripheral.identifier] = peripheral
        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
        }
        connect(to: device)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown Device"
        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )

        deviceMap[peripheral.identifier] = peripheral

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        connectedPeripheral = peripheral
        peripheral.delegate = self

        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedDeviceKey)

        logOK("Connected to \(peripheral.name ?? "unknown")", tag: "BLE")

        // Discover all services (not just WHOOP specific)
        peripheral.discoverServices(nil)
    }

    private func appendDebugEntry(_ entry: DebugLogEntry) {
        debugLog.append(entry)
        if debugLog.count > 200 {
            debugLog.removeFirst(debugLog.count - 200)
        }
    }

    func logInfo(_ message: String, tag: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .info, tag: tag, message: message))
    }

    func logOK(_ message: String, tag: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .ok, tag: tag, message: message))
    }

    func logTX(_ message: String, tag: String? = nil, hex: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .tx, tag: tag, message: message, hex: hex))
    }

    func logRX(_ message: String, tag: String? = nil, hex: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .rx, tag: tag, message: message, hex: hex))
    }

    func logWarn(_ message: String, tag: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .warn, tag: tag, message: message))
    }

    func logError(_ message: String, tag: String? = nil) {
        appendDebugEntry(DebugLogEntry(level: .err, tag: tag, message: message))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        connectedDevice = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        connectedDevice = nil
        connectedPeripheral = nil
        isAuthenticated = false
        commandCharacteristic = nil

        manufacturerName = nil
        modelNumber = nil
        serialNumber = nil
        hardwareRevision = nil
        firmwareRevision = nil
        softwareRevision = nil
        systemID = nil
        pnpID = nil
        batteryLevel = nil

        rrWindow.removeAll()
        currentHRV = nil
        lastHRVUpdate = nil
        lastRRReceivedAt = nil
        lastRealtimeHRNudgeAt = nil

        v5Reassembly.removeAll()
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Failed to discover services: \(error.localizedDescription)", tag: "BLE")
            return
        }

        guard let services = peripheral.services else {
            logWarn("No services found", tag: "BLE")
            return
        }

        logOK("Discovered \(services.count) services", tag: "BLE")

        // Discover characteristics for all services
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Failed to discover characteristics: \(error.localizedDescription)", tag: "BLE")
            return
        }

        guard let characteristics = service.characteristics else {
            return
        }

        for characteristic in characteristics {
            // Skip the public Heart Rate Measurement (0x2A37). We get the same
            // HR + RR from the custom WHOOP K2 stream; ingesting both channels
            // doubles RR samples into the HRV window and biases the math.
            if characteristic.uuid == heartRateMeasurementUUID {
                continue
            }

            // Check if this is the command characteristic
            if characteristic.uuid == commandCharacteristicUUID {
                logOK("Found WHOOP command characteristic", tag: "BLE")
                commandCharacteristic = characteristic

                // Subscribe to command responses first
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                // Send CLIENT_HELLO authentication after subscribing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.sendClientHello(to: peripheral, characteristic: characteristic)
                }
                continue
            }

            // Subscribe to ALL notification characteristics immediately
            // iOS will handle auth requirements transparently
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            // Also try to read if possible
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Read failed: \(error.localizedDescription)", tag: "BLE")
            return
        }

        guard let data = characteristic.value else {
            logWarn("Empty characteristic update", tag: "BLE")
            return
        }

        // 1. Standard public-service characteristics short-circuit (info, battery).
        //    They self-log via logInfo from inside the handler.
        if handleStandardCharacteristic(characteristic, data: data) {
            return
        }

        // 2. Custom WHOOP characteristics (fd4b…): run V5 reassembly. iOS BLE
        //    notifications are MTU-capped, so long frames (K21 raw motion is
        //    1244+ bytes) arrive in several chunks and need stitching.
        if isCustomWhoopCharacteristic(characteristic) {
            guard let complete = processV5Chunk(data, characteristic: characteristic) else {
                return // still accumulating, or chunk wasn't a valid V5 start
            }
            handleCompleteV5Frame(complete, characteristic: characteristic, peripheral: peripheral)
            return
        }

        // Anything else (e.g. an unexpected notification on a char we didn't
        // intentionally subscribe to) is intentionally ignored.
    }

    // MARK: V5 reassembly + dispatch

    private func isCustomWhoopCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.uuid.uuidString.lowercased().hasPrefix("fd4b")
    }

    private func shortTag(_ uuid: CBUUID) -> String {
        if uuid == commandCharacteristicUUID { return "0002" }
        if uuid == responseCharacteristicUUID { return "0003" }
        if uuid == dataCharacteristicUUID { return "0005" }
        return String(uuid.uuidString.lowercased().prefix(8))
    }

    private func processV5Chunk(_ data: Data, characteristic: CBCharacteristic) -> V5CompleteFrame? {
        let uuid = characteristic.uuid
        var state = v5Reassembly[uuid] ?? V5ReassemblyState()

        if state.bytes.isEmpty {
            // Expecting the start of a new frame: must begin with aa 01.
            guard data.count >= 8, data[0] == 0xaa, data[1] == 0x01 else {
                logWarn("Non-V5 chunk dropped (\(data.count) B)", tag: shortTag(uuid))
                return nil
            }
            let declaredLength = Int(UInt16(data[2]) | UInt16(data[3]) << 8)
            state.declaredTotal = declaredLength + 8
            state.chunkCount = 0
        }

        state.bytes.append(contentsOf: data)
        state.chunkCount += 1

        if state.bytes.count >= state.declaredTotal {
            let frame = Data(state.bytes.prefix(state.declaredTotal))
            let chunks = state.chunkCount
            v5Reassembly[uuid] = V5ReassemblyState()
            return V5CompleteFrame(bytes: frame, chunkCount: chunks)
        }

        v5Reassembly[uuid] = state
        return nil
    }

    // Focused dispatcher: we care about K2 (HR + RR) and command responses (acks).
    // Everything else the strap emits — historical sync, raw IMU, metadata, console
    // logs — is silently dropped so the log stays useful.
    private func handleCompleteV5Frame(_ complete: V5CompleteFrame, characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let frame = complete.bytes
        let payload = Array(frame[8..<(frame.count - 4)])
        guard let packetType = payload.first else { return }

        switch packetType {
        case 0x24:
            handleCommandResponse(payload: payload, peripheral: peripheral)
        case 0x28:
            handleRealtimeHR(frame: frame, peripheral: peripheral)
        default:
            break // silently dropped — not subscribed to anything else right now
        }
    }

    private func handleCommandResponse(payload: [UInt8], peripheral: CBPeripheral) {
        guard payload.count >= 5 else { return }
        let respondedCmd = payload[2]
        let originSeq = payload[3]
        let resultCode = payload[4]

        // CLIENT_HELLO ack → flip auth, fire realtime command sequence.
        if !isAuthenticated, respondedCmd == 0x91 {
            logOK("Authenticated", tag: "AUTH")
            isAuthenticated = true
            guard let cmd = commandCharacteristic else {
                logError("No command characteristic to send realtime commands", tag: "CMD")
                return
            }
            // Order matters: stop the historical firehose first, then enable HR.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendExitHighFreqSync(to: peripheral, characteristic: cmd)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.sendRealtimeHROn(to: peripheral, characteristic: cmd)
            }
            return
        }

        // SET_ADVERTISING_NAME ack (command 140 = 0x8C)
        if respondedCmd == 140 {
            let success = resultCode == 1
            logOK("SET_ADVERTISING_NAME → \(Self.commandResultName(resultCode))", tag: "CMD")
            let cb = pendingRenameCompletion
            pendingRenameCompletion = nil
            cb?(success)
            return
        }

        // Any other ack: just record the outcome so debug shows command health.
        let resultName = Self.commandResultName(resultCode)
        logOK("ack cmd=0x\(String(format: "%02x", respondedCmd)) seq=\(originSeq) → \(resultName)", tag: "CMD")
    }

    private func handleRealtimeHR(frame: Data, peripheral: CBPeripheral) {
        guard let v5 = Self.parseV5RealtimeData(frame) else { return }

        let rrSummary = v5.rrIntervalsMS.isEmpty
            ? "—"
            : v5.rrIntervalsMS.map { String(format: "%.0f", $0) }.joined(separator: ",") + "ms"
        logOK("K\(v5.k) seq=\(v5.sequence) HR=\(v5.hr) RR=[\(rrSummary)]", tag: "HR")

        if (30...220).contains(v5.hr) {
            currentHeartRate = v5.hr
            lastHeartRateUpdate = Date()
            persistHeartRateSample(v5.hr)
        }
        if v5.rrIntervalsMS.isEmpty {
            maybeNudgeRealtimeHR(on: peripheral)
        } else {
            lastRRReceivedAt = Date()
            ingestRRIntervals(v5.rrIntervalsMS)
        }
    }

    private static func commandResultName(_ code: UInt8) -> String {
        switch code {
        case 0: return "FAILURE"
        case 1: return "SUCCESS"
        case 2: return "PENDING"
        case 3: return "UNSUPPORTED"
        default: return "RESULT_\(code)"
        }
    }

    struct V5RealtimeData {
        let k: UInt8
        let sequence: UInt8
        let hr: Int
        let rrIntervalsMS: [Double]
        let bodyHex: String
    }

    // Parses a V5-framed REALTIME_DATA packet (type 0x28) from the data
    // characteristic. Empirically, for K2 frames (the realtime HR stream from
    // command 3), payload[8] is the HR in BPM (matches the standard 0x2A37
    // Heart Rate Measurement byte-for-byte) and payload[9] is the count of
    // following u16-LE RR intervals in 1/1024-second units.
    static func parseV5RealtimeData(_ data: Data) -> V5RealtimeData? {
        guard data.count >= 12, data[0] == 0xaa, data[1] == 0x01 else { return nil }
        let declaredLength = Int(UInt16(data[2]) | UInt16(data[3]) << 8)
        let expectedLength = declaredLength + 8
        guard data.count == expectedLength, declaredLength >= 4 else { return nil }

        let payload = Array(data[8..<(data.count - 4)])
        guard payload.count >= 10 else { return nil }
        // REALTIME_DATA packet type
        guard payload[0] == 0x28 else { return nil }

        let k = payload[1]
        let sequence = payload[2]
        let hr = Int(payload[8])

        var rr: [Double] = []
        let rrCount = Int(payload[9])
        let rrStart = 10
        let rrEnd = rrStart + rrCount * 2
        if rrCount > 0 && rrEnd <= payload.count {
            for i in 0..<rrCount {
                let lo = UInt16(payload[rrStart + i * 2])
                let hi = UInt16(payload[rrStart + i * 2 + 1])
                let raw = lo | (hi << 8)
                // 1/1024-second units → ms
                rr.append(Double(raw) * 1000.0 / 1024.0)
            }
        }

        let body = payload.suffix(from: 9)
        let bodyHex = body.map { String(format: "%02x", $0) }.joined(separator: " ")

        return V5RealtimeData(k: k, sequence: sequence, hr: hr, rrIntervalsMS: rr, bodyHex: bodyHex)
    }

    // Persist one HR sample to SwiftData. The main context autosaves, so we
    // just insert; we don't `save()` per-call. Retention is "forever" — no
    // trimming. If storage ever feels heavy, switch to hourly roll-ups for
    // data older than ~30 days.
    private func persistHeartRateSample(_ bpm: Int) {
        modelContext.insert(HRSample(timestamp: Date(), bpm: bpm))
        updateDailySummary(bpm: bpm)
    }

    // MARK: - Summary aggregation

    private func updateDailySummary(bpm: Int) {
        let today = Calendar.current.startOfDay(for: Date())
        let summary = fetchOrCreateDailySummary(for: today)
        if summary.hrSampleCount == 0 {
            summary.minHR = bpm
            summary.maxHR = bpm
        } else {
            summary.minHR = min(summary.minHR, bpm)
            summary.maxHR = max(summary.maxHR, bpm)
        }
        summary.sumHR += Double(bpm)
        summary.hrSampleCount += 1
        rebuildMonthlySummary(for: today)
    }

    private func updateDailySummaryHRV(_ rmssd: Double) {
        let today = Calendar.current.startOfDay(for: Date())
        let summary = fetchOrCreateDailySummary(for: today)
        summary.sumHRV += rmssd
        summary.hrvSampleCount += 1
        rebuildMonthlySummary(for: today)
    }

    private func fetchOrCreateDailySummary(for startOfDay: Date) -> DailySummary {
        let descriptor = FetchDescriptor<DailySummary>(
            predicate: #Predicate { $0.date == startOfDay }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            return existing
        }
        let summary = DailySummary(date: startOfDay)
        modelContext.insert(summary)
        return summary
    }

    private func rebuildMonthlySummary(for day: Date) {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: day)
        guard let firstOfMonth = calendar.date(from: comps),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: firstOfMonth)
        else { return }

        let dailyDescriptor = FetchDescriptor<DailySummary>(
            predicate: #Predicate { $0.date >= firstOfMonth && $0.date < nextMonth }
        )
        guard let dailies = try? modelContext.fetch(dailyDescriptor), !dailies.isEmpty else { return }

        let monthDescriptor = FetchDescriptor<MonthlySummary>(
            predicate: #Predicate { $0.yearMonth == firstOfMonth }
        )
        let monthly: MonthlySummary
        if let existing = (try? modelContext.fetch(monthDescriptor))?.first {
            monthly = existing
        } else {
            monthly = MonthlySummary(yearMonth: firstOfMonth)
            modelContext.insert(monthly)
        }

        let withHR = dailies.filter { $0.hrSampleCount > 0 }
        monthly.dayCount = withHR.count
        monthly.avgHR = withHR.isEmpty ? 0 : withHR.map(\.avgHR).reduce(0, +) / Double(withHR.count)
        monthly.minHR = withHR.map(\.minHR).min() ?? 0
        monthly.maxHR = withHR.map(\.maxHR).max() ?? 0

        let withHRV = dailies.filter { $0.hrvSampleCount > 0 }
        monthly.daysWithHRV = withHRV.count
        monthly.avgHRV = withHRV.isEmpty ? 0 : withHRV.compactMap(\.avgHRV).reduce(0, +) / Double(withHRV.count)
    }

    // Adds new RR intervals to a 60-second rolling window and republishes
    // currentHRV as the RMSSD (Root Mean Square of Successive Differences)
    // over the window. Outlier RR values (likely missed or doubled beats)
    // are filtered before they reach the window so they don't fake jitter.
    private func ingestRRIntervals(_ intervals: [Double]) {
        let now = Date()

        for ms in intervals {
            guard ms >= Self.rrIntervalMinMS, ms <= Self.rrIntervalMaxMS else { continue }
            rrWindow.append(RRWindowEntry(timestamp: now, intervalMS: ms))
            // Persist the raw R-R interval — sparse and cheap.
            modelContext.insert(RRSample(timestamp: now, intervalMS: ms))
        }

        let cutoff = now.addingTimeInterval(-Self.hrvWindowSeconds)
        rrWindow.removeAll { $0.timestamp < cutoff }

        guard rrWindow.count >= Self.hrvMinSamples else { return }

        let series = rrWindow.map { $0.intervalMS }
        var sumSquaredDiffs: Double = 0
        var validDiffs = 0
        var skippedDiffs = 0
        for i in 1..<series.count {
            let delta = series[i] - series[i - 1]
            if abs(delta) > Self.rrMaxSuccessiveDiffMS {
                skippedDiffs += 1
                continue
            }
            sumSquaredDiffs += delta * delta
            validDiffs += 1
        }

        guard validDiffs >= Self.hrvMinValidDiffs else {
            logInfo("HRV deferred: only \(validDiffs) valid diffs (\(skippedDiffs) ectopic)", tag: "HRV")
            return
        }

        let rmssd = (sumSquaredDiffs / Double(validDiffs)).squareRoot()
        currentHRV = rmssd
        lastHRVUpdate = now
        modelContext.insert(HRVSample(timestamp: now, rmssdMS: rmssd))
        updateDailySummaryHRV(rmssd)
        let skippedTag = skippedDiffs > 0 ? " skipped=\(skippedDiffs)" : ""
        logOK("RMSSD=\(String(format: "%.1f", rmssd))ms n=\(rrWindow.count)\(skippedTag)", tag: "HRV")
    }

    // If RR has been gated for 5+ minutes (and we've previously had RR this session),
    // re-send REALTIME_HR_ON to nudge WHOOP into refreshing the realtime stream.
    // We only nudge after having seen RR before — a session that never produced any
    // RR is probably a sensor-contact issue we can't fix by toggling commands.
    private func maybeNudgeRealtimeHR(on peripheral: CBPeripheral) {
        guard isAuthenticated, let cmd = commandCharacteristic else { return }
        guard let lastRR = lastRRReceivedAt else { return }

        let silence = Date().timeIntervalSince(lastRR)
        guard silence > Self.rrSilenceNudgeSeconds else { return }

        if let lastNudge = lastRealtimeHRNudgeAt,
           Date().timeIntervalSince(lastNudge) < Self.rrSilenceNudgeSeconds {
            return
        }

        logInfo("RR silent \(Int(silence))s — nudging with REALTIME_HR_ON", tag: "HRV")
        sendRealtimeHROn(to: peripheral, characteristic: cmd)
        lastRealtimeHRNudgeAt = Date()
    }

    private func handleStandardCharacteristic(_ characteristic: CBCharacteristic, data: Data) -> Bool {
        let uuid = characteristic.uuid

        if uuid == manufacturerNameUUID {
            manufacturerName = String(data: data, encoding: .utf8)
            logInfo("Manufacturer: \(manufacturerName ?? "?")", tag: "INFO")
            return true
        }
        if uuid == modelNumberUUID {
            modelNumber = String(data: data, encoding: .utf8)
            logInfo("Model: \(modelNumber ?? "?")", tag: "INFO")
            return true
        }
        if uuid == serialNumberUUID {
            serialNumber = String(data: data, encoding: .utf8)
            logInfo("Serial: \(serialNumber ?? "?")", tag: "INFO")
            return true
        }
        if uuid == hardwareRevisionUUID {
            hardwareRevision = String(data: data, encoding: .utf8)
            logInfo("Hardware: \(hardwareRevision ?? "?")", tag: "INFO")
            return true
        }
        if uuid == firmwareRevisionUUID {
            firmwareRevision = String(data: data, encoding: .utf8)
            logInfo("Firmware: \(firmwareRevision ?? "?")", tag: "INFO")
            return true
        }
        if uuid == softwareRevisionUUID {
            softwareRevision = String(data: data, encoding: .utf8)
            logInfo("Software: \(softwareRevision ?? "?")", tag: "INFO")
            return true
        }
        if uuid == systemIDUUID {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: ":")
            systemID = hex
            logInfo("System ID: \(hex)", tag: "INFO")
            return true
        }
        if uuid == pnpIDUUID {
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: ":")
            pnpID = hex
            logInfo("PnP ID: \(hex)", tag: "INFO")
            return true
        }
        if uuid == batteryLevelUUID {
            if let byte = data.first {
                batteryLevel = Int(byte)
                logInfo("\(byte)%", tag: "BATT")
            }
            return true
        }
        return false
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let tag = shortTag(characteristic.uuid)

        if let error = error {
            logError("Subscribe failed: \(error.localizedDescription)", tag: tag)
            return
        }

        if characteristic.isNotifying {
            logOK("Notifications on", tag: tag)
        }
    }
}

// MARK: - Models
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
}

enum ConnectionState {
    case disconnected
    case connecting
    case connected
}

struct DebugLogEntry: Identifiable {
    enum Level {
        case info, ok, tx, rx, warn, err
    }

    let id = UUID()
    let timestamp = Date()
    let level: Level
    let tag: String?
    let message: String
    let hex: String?

    init(level: Level, tag: String? = nil, message: String, hex: String? = nil) {
        self.level = level
        self.tag = tag
        self.message = message
        self.hex = hex
    }

    var isError: Bool { level == .err }
    var isWarning: Bool { level == .warn }
}
