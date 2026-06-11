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
    @Published private(set) var rrSessionSamples = 0
    @Published var currentHRV: Double?
    @Published var lastHRVUpdate: Date?
    @Published var debugLog: [DebugLogEntry] = []
    @Published private(set) var motionProbeInProgress = false
    @Published private(set) var motionProbeFrames = 0

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
    private var userInitiatedDisconnect = false
    private var autoHistoricalSyncWorkItem: DispatchWorkItem?

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

    // Historical sync state. Set on tap of "Sync History", cleared in
    // finalizeHistoricalSync once we've ACKed all HistoryEnds and rebuilt
    // summaries. One SEND_HISTORICAL_DATA can produce multiple HistoryStart →
    // HistoryEnd batches; we ACK each batch and only finalize when an idle
    // timer fires (or HistoryComplete arrives) signalling the strap is empty.
    @Published private(set) var historicalSyncInProgress = false
    @Published private(set) var historicalSyncPackets = 0
    @Published private(set) var historicalTemperaturePackets = 0
    @Published private(set) var lastHistoricalSyncAt: Date?
    private var historyEndAckedThisBatch = false
    private var historicalUnsavedSincePersist = 0
    private var historicalTouchedHours: Set<Date> = []
    private var historicalTouchedDays: Set<Date> = []
    private var historicalIdleTimer: DispatchWorkItem?
    private static let historicalSaveChunkSize = 500
    private static let historicalIdleSeconds: TimeInterval = 3
    private static let autoHistoricalSyncDelay: TimeInterval = 1.5
    private static let lastHistoricalSyncKey = "pigeon.lastHistoricalSyncAt"
    private static let skinTemperatureCleanupKey = "pigeon.skinTemperatureCleanupVersion"
    private static let skinTemperatureCleanupVersion = 2
    private static let skinTemperatureHourlyBackfillKey = "pigeon.skinTemperatureHourlyBackfillVersion"
    private static let skinTemperatureHourlyBackfillVersion = 1
    private static let skinTemperatureSchemaField = "whoop5_v18_frame_73_skin_temp_raw"

    // Step 2a — dump one K=18 body hex per drain so we can keep eyeballing
    // header layout vs Goose's protocol.rs:496-510 if anything looks off.
    private var awaitingFirstK18Dump = false

    // Debug-only bounded accelerometer probe. This deliberately does not
    // persist anything; it only observes complete V5 frames after reassembly.
    private var motionProbeStopWorkItem: DispatchWorkItem?
    private var motionProbeStopVerificationWorkItem: DispatchWorkItem?
    private var motionProbeStartedAt: Date?
    private var motionProbeTypeCounts: [UInt8: Int] = [:]
    private var motionProbeKCounts: [UInt8: Int] = [:]
    private var motionProbeRawFrameCount = 0
    private var motionProbePostStopRawFrames = 0
    private var motionProbeCandidateLogs = 0
    private var motionProbeFirstFrameLogged = false
    private var motionProbeRejectedCandidateCount = 0
    private static let motionProbeDefaultSeconds: TimeInterval = 30
    private static let motionProbeMaxCandidateLogs = 8
    private static let motionProbeStopVerificationSeconds: TimeInterval = 3

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
    private static let motionBucketSeconds = [10 * 60, 60 * 60, 6 * 60 * 60]
    private static let sleepWindowBackfillKey = "pigeon.sleepWindowBackfillVersion"
    private static let sleepWindowBackfillVersion = 5
    private static let recoveryBackfillKey = "pigeon.recoveryBackfillVersion"
    private static let recoveryBackfillVersion = 1
    private static let sleepWindowBucketSeconds = 10 * 60
    private static let sleepSearchStartOffset: TimeInterval = -6 * 60 * 60
    private static let sleepSearchEndOffset: TimeInterval = 14 * 60 * 60
    private static let sleepStillFraction = 0.70
    private static let sleepMergeGapSeconds: TimeInterval = 20 * 60
    private static let sleepMinimumDurationSeconds: TimeInterval = 60 * 60
    private static let sleepHRBaselineMultiplier = 1.05
    private static let sleepRefreshThrottleSeconds: TimeInterval = 15 * 60
    private static let sleepEdgeOutsideSeconds: TimeInterval = 15 * 60
    private static let sleepEdgeInsideSeconds: TimeInterval = 30 * 60
    private static let sleepEdgeRollingWindowSeconds: TimeInterval = 3 * 60
    private static let sleepEdgeMinimumRawFrames = 4
    private static let sleepStartHRInsideSeconds: TimeInterval = 45 * 60
    private static let sleepStartHRRollingWindowSeconds: TimeInterval = 5 * 60
    private static let sleepStartMinimumHRSamples = 20
    private static let sleepOnsetInBedHRVBaselineSeconds: TimeInterval = 20 * 60
    private static let sleepOnsetScanMaxSeconds: TimeInterval = 90 * 60
    private static let sleepOnsetHRVMultiplier = 1.15
    private static let sleepOnsetHRVSustainedSeconds: TimeInterval = 10 * 60
    private static let sleepOnsetMinimumHRVSamples = 3
    private static let sleepOnsetHRRollingWindowSeconds: TimeInterval = 10 * 60
    private static let sleepWakeHRRiseMultiplier = 1.08
    private static let sleepWakeHRRiseToleranceBPM = 5.0
    private static let sleepWakeHRSustainedSeconds: TimeInterval = 8 * 60
    private var lastRealtimeHRNudgeAt: Date?
    private var lastSleepWindowRefreshAt: Date?

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
        lastHistoricalSyncAt = UserDefaults.standard.object(forKey: Self.lastHistoricalSyncKey) as? Date
        backfillHourlySummariesIfNeeded()
        backfillMotionBucketSummariesIfNeeded()
        backfillSleepWindowSummariesIfNeeded()
        backfillRecoverySummariesIfNeeded()
        purgeImplausibleSkinTemperatureSamplesIfNeeded()
        backfillSkinTemperatureHourlySummariesIfNeeded()
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
        userInitiatedDisconnect = true
        if motionProbeInProgress {
            finishMotionProbe(reason: "disconnect", sendStopCommand: true)
        }
        cancelAutoHistoricalSync()
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

    private func sendRawDataStart(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        sendDebugCommand(name: "START_RAW_DATA", command: 81, payload: [1], to: peripheral, characteristic: characteristic)
    }

    private func sendRawDataStop(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        sendDebugCommand(name: "STOP_RAW_DATA", command: 82, payload: [1], to: peripheral, characteristic: characteristic)
    }

    private func sendDebugCommand(
        name: String,
        command: UInt8,
        payload: [UInt8],
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: command, data: payload)
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("\(name) seq=\(seq)", tag: "MOTION", hex: hexStr)
        writeCommand(frame, to: peripheral, characteristic: characteristic)
    }

    func startMotionProbe(seconds: TimeInterval? = nil) {
        guard isAuthenticated,
              let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic else {
            logWarn("Motion probe ignored — not authenticated", tag: "MOTION")
            return
        }
        guard !motionProbeInProgress else {
            logWarn("Motion probe already running — ignoring tap", tag: "MOTION")
            return
        }

        let requestedSeconds = seconds ?? Self.motionProbeDefaultSeconds
        let duration = min(max(requestedSeconds, 5), 60)
        motionProbeInProgress = true
        motionProbeFrames = 0
        motionProbeTypeCounts.removeAll()
        motionProbeKCounts.removeAll()
        motionProbeRawFrameCount = 0
        motionProbePostStopRawFrames = 0
        motionProbeCandidateLogs = 0
        motionProbeFirstFrameLogged = false
        motionProbeRejectedCandidateCount = 0
        motionProbeStartedAt = Date()
        motionProbeStopWorkItem?.cancel()
        motionProbeStopVerificationWorkItem?.cancel()
        motionProbeStopVerificationWorkItem = nil

        logInfo("Motion probe started for \(Int(duration))s — no samples will be persisted", tag: "MOTION")
        sendRawDataStart(to: peripheral, characteristic: characteristic)

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishMotionProbe(reason: "timer", sendStopCommand: true)
        }
        motionProbeStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func stopMotionProbe() {
        finishMotionProbe(reason: "manual", sendStopCommand: true)
    }

    private func finishMotionProbe(reason: String, sendStopCommand: Bool) {
        guard motionProbeInProgress else { return }
        motionProbeStopWorkItem?.cancel()
        motionProbeStopWorkItem = nil

        if sendStopCommand,
           let peripheral = connectedPeripheral,
           let characteristic = commandCharacteristic {
            sendRawDataStop(to: peripheral, characteristic: characteristic)
            startMotionProbeStopVerification()
        }

        let elapsed = motionProbeStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let typeSummary = motionProbeTypeCounts
            .sorted { $0.key < $1.key }
            .map { "0x\(String(format: "%02x", $0.key)):\($0.value)" }
            .joined(separator: " ")
        let kSummary = motionProbeKCounts
            .sorted { $0.key < $1.key }
            .map { "K\($0.key):\($0.value)" }
            .joined(separator: " ")
        let kText = kSummary.isEmpty ? "none" : kSummary
        let typeText = typeSummary.isEmpty ? "none" : typeSummary
        logOK("Motion probe complete (\(reason)) — \(motionProbeFrames) frames in \(String(format: "%.1f", elapsed))s; types \(typeText); historical \(kText); raw43 \(motionProbeRawFrameCount); rejected \(motionProbeRejectedCandidateCount)", tag: "MOTION")

        motionProbeInProgress = false
        motionProbeStartedAt = nil
    }

    private func startMotionProbeStopVerification() {
        motionProbePostStopRawFrames = 0
        motionProbeStopVerificationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let frames = self.motionProbePostStopRawFrames
            if frames == 0 {
                self.logOK("STOP_RAW_DATA verified — no Raw43 frames for \(Int(Self.motionProbeStopVerificationSeconds))s", tag: "MOTION")
            } else {
                self.logWarn("STOP_RAW_DATA may still be active — \(frames) Raw43 frame\(frames == 1 ? "" : "s") after stop", tag: "MOTION")
            }
            self.motionProbeStopVerificationWorkItem = nil
        }
        motionProbeStopVerificationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.motionProbeStopVerificationSeconds, execute: workItem)
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

    // Send Historical Data: command 22 with empty payload (Goose:
    // SEND_HISTORICAL_DATA). Asks the strap to dump its buffered K18 / K20 /
    // K21 pages. K=18 carries one HR reading per ~17 s of strap time; we
    // decode + persist those, ACK HistoryEnd once, then rebuild the affected
    // hourly / daily / monthly summaries in a single batch.
    func sendHistoricalSync() {
        guard isAuthenticated,
              let peripheral = connectedPeripheral,
              let characteristic = commandCharacteristic else {
            logWarn("Historical sync ignored — not authenticated", tag: "SYNC")
            return
        }
        guard !historicalSyncInProgress else {
            logWarn("Historical sync already in progress — ignoring tap", tag: "SYNC")
            return
        }
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: 22, data: [])
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("SEND_HISTORICAL_DATA seq=\(seq)", tag: "SYNC", hex: hexStr)
        historicalSyncInProgress = true
        historicalSyncPackets = 0
        historicalTemperaturePackets = 0
        historyEndAckedThisBatch = false
        historicalUnsavedSincePersist = 0
        historicalTouchedHours.removeAll()
        historicalTouchedDays.removeAll()
        historicalIdleTimer?.cancel()
        historicalIdleTimer = nil
        awaitingFirstK18Dump = true
        writeCommand(frame, to: peripheral, characteristic: characteristic)
    }

    private func scheduleAutoHistoricalSync(for peripheral: CBPeripheral) {
        cancelAutoHistoricalSync()
        let peripheralID = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.autoHistoricalSyncWorkItem = nil
            guard self.connectedPeripheral?.identifier == peripheralID,
                  self.connectionState == .connected,
                  self.isAuthenticated else {
                return
            }
            self.sendHistoricalSync()
        }
        autoHistoricalSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHistoricalSyncDelay, execute: workItem)
    }

    private func cancelAutoHistoricalSync() {
        autoHistoricalSyncWorkItem?.cancel()
        autoHistoricalSyncWorkItem = nil
    }

    // Step 2a — dump the first K=18 payload of a drain so we can verify the
    // header layout (counter_or_page u32 LE at [3], timestamp_seconds u32 LE at
    // [7], timestamp_subseconds u16 LE at [11], body at [13..]) per Goose's
    // protocol.rs:496-510 against this firmware before trusting the decoder.
    private func dumpFirstK18ForVerification(payload: [UInt8]) {
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        logRX("K18 raw payload (\(payload.count) B)", tag: "SYNC", hex: hex)
        guard payload.count >= 13 else {
            logWarn("K18 payload too short to decode header", tag: "SYNC")
            return
        }
        let page = UInt32(payload[3]) | UInt32(payload[4]) << 8
            | UInt32(payload[5]) << 16 | UInt32(payload[6]) << 24
        let ts = UInt32(payload[7]) | UInt32(payload[8]) << 8
            | UInt32(payload[9]) << 16 | UInt32(payload[10]) << 24
        let sub = UInt16(payload[11]) | UInt16(payload[12]) << 8
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let dateStr = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        logInfo("K18 header: page=\(page) ts=\(ts) (\(dateStr)) sub=\(sub)", tag: "SYNC")
    }

    // Decode one K=18 historical packet → HRSample insert + bucket bookkeeping.
    // Header layout (verified against this firmware in Step 2a):
    //   payload[7..10] u32 LE = unix seconds, payload[14] u8 = HR (bpm).
    // Inserts go directly into the model context. We flush every N packets so
    // memory stays bounded regardless of drain size; the final flush + summary
    // rebuild happens in finalizeHistoricalSync.
    private func ingestHistoricalK18(payload: [UInt8]) {
        guard payload.count > 14 else { return }
        let page = UInt32(payload[3]) | UInt32(payload[4]) << 8
            | UInt32(payload[5]) << 16 | UInt32(payload[6]) << 24
        let ts = UInt32(payload[7]) | UInt32(payload[8]) << 8
            | UInt32(payload[9]) << 16 | UInt32(payload[10]) << 24
        let bpm = Int(payload[14])
        // HR=0 means "no marker recorded this page" (firmware confidence gate);
        // skip rather than poisoning min/avg with zeros. Out-of-range guards
        // mirror the realtime path (30–220 bpm).
        guard (30...220).contains(bpm) else { return }
        let timestamp = Date(timeIntervalSince1970: TimeInterval(ts))

        // Dedup: if we've already persisted this page, skip. Cheap because
        // each drain is small (~hundreds of packets) and SwiftData indexes
        // sourceKey lookups well enough for one fetch per insert.
        let key = "k18:\(page)"
        let descriptor = FetchDescriptor<HRSample>(predicate: #Predicate { $0.sourceKey == key })
        if let existingCount = try? modelContext.fetchCount(descriptor), existingCount > 0 {
            return
        }

        modelContext.insert(HRSample(timestamp: timestamp, bpm: bpm, sourceKey: key))
        historicalTouchedHours.insert(hourStart(of: timestamp))
        historicalTouchedDays.insert(Calendar.current.startOfDay(for: timestamp))
        historicalSyncPackets += 1
        historicalUnsavedSincePersist += 1

        if historicalUnsavedSincePersist >= Self.historicalSaveChunkSize {
            try? modelContext.save()
            historicalUnsavedSincePersist = 0
        }
        scheduleHistoricalIdleFinalize()
    }

    private struct HistoricalSkinTemperatureCandidate {
        let packetK: Int
        let schemaField: String
        let rawBodyOffset: Int
        let encoding: String
        let rawHex: String
        let rawI16LE: Int?
        let rawU16LE: Int?
        let celsius: Double
        let semanticStatus: String
    }

    private func ingestHistoricalSkinTemperature(payload: [UInt8], packetK: Int) {
        guard let page = Self.u32LE(payload, offset: 3),
              let timestampSeconds = Self.u32LE(payload, offset: 7),
              let candidate = Self.parseHistoricalSkinTemperature(payload: payload, packetK: packetK),
              candidate.semanticStatus == "plausible_unverified_scale" else {
            return
        }

        let key = "temp:k\(packetK):\(page):\(candidate.schemaField)"
        let descriptor = FetchDescriptor<SkinTemperatureSample>(
            predicate: #Predicate { $0.sourceKey == key }
        )
        if let existingCount = try? modelContext.fetchCount(descriptor), existingCount > 0 {
            return
        }

        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
        modelContext.insert(SkinTemperatureSample(
            timestamp: timestamp,
            celsius: candidate.celsius,
            packetK: candidate.packetK,
            schemaField: candidate.schemaField,
            rawBodyOffset: candidate.rawBodyOffset,
            encoding: candidate.encoding,
            rawHex: candidate.rawHex,
            rawI16LE: candidate.rawI16LE,
            rawU16LE: candidate.rawU16LE,
            semanticStatus: candidate.semanticStatus,
            sourceKey: key
        ))
        updateSkinTemperatureHourlySummary(celsius: candidate.celsius, rawU16: candidate.rawU16LE, at: timestamp)

        historicalTemperaturePackets += 1
        historicalUnsavedSincePersist += 1

        if historicalUnsavedSincePersist >= Self.historicalSaveChunkSize {
            try? modelContext.save()
            historicalUnsavedSincePersist = 0
        }
        scheduleHistoricalIdleFinalize()
    }

    private static func parseHistoricalSkinTemperature(
        payload: [UInt8],
        packetK: Int
    ) -> HistoricalSkinTemperatureCandidate? {
        guard payload.count >= 13 else { return nil }

        let schemaField: String
        let rawBodyOffset: Int
        let encoding: String
        let scale: Double
        let signed: Bool

        switch packetK {
        case 18:
            schemaField = Self.skinTemperatureSchemaField
            // Noop's WHOOP5 v18 decoder maps skin_temp_raw at full-frame
            // offset 73. Pigeon passes the inner payload beginning at full
            // frame offset 8, so the payload-relative offset is 65.
            rawBodyOffset = 65
            encoding = "u16_le_as6221_raw_x128_candidate"
            scale = 128.0
            signed = false
        default:
            return nil
        }

        let absoluteOffset = rawBodyOffset
        guard let rawU16 = u16LE(payload, offset: absoluteOffset),
              let rawI16 = i16LE(payload, offset: absoluteOffset) else {
            return nil
        }

        let signedValue = Int(rawI16)
        let unsignedValue = Int(rawU16)
        let celsius = signed ? Double(signedValue) / scale : Double(unsignedValue) / scale
        let rawHex = "\(String(format: "%02x", payload[absoluteOffset])) \(String(format: "%02x", payload[absoluteOffset + 1]))"

        return HistoricalSkinTemperatureCandidate(
            packetK: packetK,
            schemaField: schemaField,
            rawBodyOffset: rawBodyOffset,
            encoding: encoding,
            rawHex: rawHex,
            rawI16LE: signedValue,
            rawU16LE: unsignedValue,
            celsius: celsius,
            semanticStatus: skinTemperatureSemanticStatus(for: celsius)
        )
    }

    private static func skinTemperatureSemanticStatus(for celsius: Double) -> String {
        if celsius == 0 {
            return "zero_candidate_unresolved"
        }
        if (5.0...45.0).contains(celsius) {
            return "plausible_unverified_scale"
        }
        return "outside_plausible_sensor_temperature_range"
    }

    // Reset the "strap went quiet" timer. We can't trust HistoryComplete to
    // arrive (Step 1 + 2b runs showed it doesn't on this firmware), so this
    // idle window is our actual end-of-stream signal. Called after every K=18
    // ingest and every HistoryStart/HistoryEnd.
    private func scheduleHistoricalIdleFinalize() {
        historicalIdleTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeHistoricalSync()
        }
        historicalIdleTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historicalIdleSeconds, execute: workItem)
    }

    // Acknowledge the strap's HistoryEnd so it advances its read pointer and
    // stops retransmitting kind=2. Payload mirrors Goose's parser
    // (Parsing.swift:833-842): [0x01] + 8 bytes from offset 13..21 of the
    // HistoryEnd metadata payload.
    private func sendHistoryEndACK(historyEndPayload payload: [UInt8], peripheral: CBPeripheral) {
        guard let characteristic = commandCharacteristic else { return }
        guard payload.count >= 21 else {
            logWarn("HistoryEnd payload too short for ACK (\(payload.count) B)", tag: "SYNC")
            return
        }
        var ackPayload: [UInt8] = [0x01]
        ackPayload.append(contentsOf: payload[13..<21])
        let seq = nextSequence
        nextSequence &+= 1
        let frame = Self.buildV5CommandFrame(sequence: seq, command: 23, data: ackPayload)
        let hexStr = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
        logTX("HISTORICAL_DATA_RESULT seq=\(seq)", tag: "SYNC", hex: hexStr)
        writeCommand(frame, to: peripheral, characteristic: characteristic)
    }

    // Final flush + summary rebuild for the touched hours / days / months,
    // then clear drain state. Called either when the strap goes idle for
    // `historicalIdleSeconds` after the last batch ACK, or (defensively) when
    // a HistoryComplete (kind=3) actually shows up. Idempotent — guarded so
    // the idle timer and a late kind=3 can't double-finalize.
    private func finalizeHistoricalSync() {
        guard historicalSyncInProgress else { return }
        historicalIdleTimer?.cancel()
        historicalIdleTimer = nil
        let packets = historicalSyncPackets
        let hours = historicalTouchedHours
        let days = historicalTouchedDays
        try? modelContext.save()
        historicalUnsavedSincePersist = 0

        for hour in hours {
            rebuildHourlySummaryFromSamples(for: hour)
        }
        let months: Set<Date> = Set(days.compactMap { day -> Date? in
            let comps = Calendar.current.dateComponents([.year, .month], from: day)
            return Calendar.current.date(from: comps)
        })
        for day in days {
            rebuildDailySummaryFromSamples(for: day)
            refreshSleepWindowSummariesAround(day, force: true)
            rebuildMonthlySummary(for: day)
        }
        try? modelContext.save()

        historicalSyncInProgress = false
        historicalTouchedHours.removeAll()
        historicalTouchedDays.removeAll()
        let completedAt = Date()
        lastHistoricalSyncAt = completedAt
        UserDefaults.standard.set(completedAt, forKey: Self.lastHistoricalSyncKey)
        logOK("Historical sync complete — \(packets) HR samples, \(hours.count) hours, \(days.count) days, \(months.count) months", tag: "SYNC")
        if historicalTemperaturePackets > 0 {
            logOK("Historical temperature candidates — \(historicalTemperaturePackets) stored (units unverified)", tag: "SYNC")
        }
    }

    // Rebuild a HourlySummary row from every HRSample inside [hourStart, +1h).
    // Idempotent — safe to run after partial realtime + historical inserts.
    private func rebuildHourlySummaryFromSamples(for hourStart: Date) {
        guard let hourEnd = Calendar.current.date(byAdding: .hour, value: 1, to: hourStart) else { return }
        let descriptor = FetchDescriptor<HRSample>(
            predicate: #Predicate { $0.timestamp >= hourStart && $0.timestamp < hourEnd }
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        let summary = fetchOrCreateHourlySummary(for: hourStart)
        summary.hrSampleCount = samples.count
        summary.sumHR = samples.reduce(0.0) { $0 + Double($1.bpm) }
        summary.minHR = samples.map(\.bpm).min() ?? 0
        summary.maxHR = samples.map(\.bpm).max() ?? 0
    }

    // Rebuild a DailySummary row from every HRSample + HRVSample inside the
    // day. HRV is left alone if no historical HRV exists (Step 2 only writes
    // historical HR; HRV stays realtime-only for now).
    private func rebuildDailySummaryFromSamples(for dayStart: Date) {
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let hrDescriptor = FetchDescriptor<HRSample>(
            predicate: #Predicate { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        )
        let hrvDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= dayStart && $0.timestamp < dayEnd }
        )
        let hrSamples = (try? modelContext.fetch(hrDescriptor)) ?? []
        let hrvSamples = (try? modelContext.fetch(hrvDescriptor)) ?? []
        let summary = fetchOrCreateDailySummary(for: dayStart)
        summary.hrSampleCount = hrSamples.count
        summary.sumHR = hrSamples.reduce(0.0) { $0 + Double($1.bpm) }
        summary.minHR = hrSamples.map(\.bpm).min() ?? 0
        summary.maxHR = hrSamples.map(\.bpm).max() ?? 0
        summary.hrvSampleCount = hrvSamples.count
        summary.sumHRV = hrvSamples.reduce(0.0) { $0 + $1.rmssdMS }
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
            cancelAutoHistoricalSync()
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
        cancelAutoHistoricalSync()
        connectionState = .disconnected
        connectedDevice = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelAutoHistoricalSync()
        motionProbeStopWorkItem?.cancel()
        motionProbeStopWorkItem = nil
        motionProbeStopVerificationWorkItem?.cancel()
        motionProbeStopVerificationWorkItem = nil
        motionProbeInProgress = false
        motionProbeStartedAt = nil
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
        rrSessionSamples = 0
        currentHRV = nil
        lastHRVUpdate = nil
        lastRRReceivedAt = nil
        lastRealtimeHRNudgeAt = nil

        v5Reassembly.removeAll()

        if userInitiatedDisconnect {
            userInitiatedDisconnect = false
            connectionState = .disconnected
            connectedDevice = nil
            connectedPeripheral = nil
            return
        }

        // Unexpected drop. CoreBluetooth holds the connect request until the
        // peripheral is reachable again, so no retry loop is needed here.
        if let error = error {
            logWarn("Unexpected disconnect: \(error.localizedDescription), reconnecting", tag: "BLE")
        } else {
            logWarn("Unexpected disconnect, reconnecting", tag: "BLE")
        }
        connectionState = .connecting
        central.connect(peripheral, options: nil)
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
        observeMotionProbeFrame(
            frame: frame,
            payload: payload,
            packetType: packetType,
            characteristic: characteristic,
            chunkCount: complete.chunkCount
        )

        switch packetType {
        case 0x24:
            handleCommandResponse(payload: payload, peripheral: peripheral)
        case 0x28:
            handleRealtimeHR(frame: frame, peripheral: peripheral)
        case 0x2B:
            handleRealtimeRawMotion(payload: payload)
        case 0x2F:
            // HISTORICAL_DATA — payload[1] is the K-value (typically 18 on Gen5).
            let k = payload.count > 1 ? payload[1] : 0
            logRX("HIST K=\(k) len=\(frame.count)", tag: "SYNC")
            if k == 18, awaitingFirstK18Dump {
                awaitingFirstK18Dump = false
                dumpFirstK18ForVerification(payload: payload)
            }
            if historicalSyncInProgress {
                if k == 18 {
                    ingestHistoricalK18(payload: payload)
                }
                if k == 18 {
                    ingestHistoricalSkinTemperature(payload: payload, packetK: Int(k))
                }
            }
        case 0x31:
            // METADATA — payload[2] is the kind (1=HistoryStart, 2=HistoryEnd,
            // 3=HistoryComplete per Goose's HistoricalMetadataKind).
            let kind = payload.count > 2 ? payload[2] : 0
            logRX("META kind=\(kind) len=\(frame.count)", tag: "SYNC")
            if historicalSyncInProgress {
                switch kind {
                case 1:
                    // New batch beginning — reset the per-batch ACK gate.
                    historyEndAckedThisBatch = false
                    scheduleHistoricalIdleFinalize()
                case 2:
                    if !historyEndAckedThisBatch {
                        historyEndAckedThisBatch = true
                        sendHistoryEndACK(historyEndPayload: payload, peripheral: peripheral)
                    }
                    scheduleHistoricalIdleFinalize()
                case 3:
                    finalizeHistoricalSync()
                default:
                    break
                }
            }
        default:
            break // silently dropped — not subscribed to anything else right now
        }
    }

    private func handleRealtimeRawMotion(payload: [UInt8]) {
        guard let accel = Self.parseGen5RawAccelPayload(payload) else { return }
        persistMotionSample(accel)
    }

    private func observeMotionProbeFrame(
        frame: Data,
        payload: [UInt8],
        packetType: UInt8,
        characteristic: CBCharacteristic,
        chunkCount: Int
    ) {
        if !motionProbeInProgress, packetType == 0x2B, motionProbeStopVerificationWorkItem != nil {
            motionProbePostStopRawFrames += 1
        }

        guard motionProbeInProgress else { return }

        motionProbeFrames += 1
        motionProbeTypeCounts[packetType, default: 0] += 1

        let k = payload.count > 1 ? payload[1] : nil
        if packetType == 0x2F, let k, k == 20 || k == 21 {
            motionProbeKCounts[k, default: 0] += 1
        }

        let isMotionDataFrame = packetType == 0x2B || (packetType == 0x2F && k.map { $0 == 20 || $0 == 21 } == true)
        if isMotionDataFrame, !motionProbeFirstFrameLogged {
            motionProbeFirstFrameLogged = true
            let kText = k.map { " K=\($0)" } ?? ""
            let hex = frame.map { String(format: "%02x", $0) }.joined(separator: " ")
            logRX("Motion first frame type=0x\(String(format: "%02x", packetType))\(kText) len=\(frame.count) chunks=\(chunkCount) char=\(shortTag(characteristic.uuid))", tag: "MOTION", hex: hex)
        }

        switch packetType {
        case 0x2B:
            motionProbeRawFrameCount += 1
            if let accel = Self.parseGen5RawAccelPayload(payload) {
                logMotionProbeCandidate(accel.debugSummary)
            } else {
                motionProbeRejectedCandidateCount += 1
            }
        case 0x2F:
            guard let k, k == 20 || k == 21 else { return }
            if let summary = Self.classifyHistoricalGravityPayload(payload) {
                logMotionProbeCandidate("HIST K\(k) \(summary)")
            } else {
                motionProbeRejectedCandidateCount += 1
            }
        default:
            break
        }
    }

    private func logMotionProbeCandidate(_ summary: String) {
        guard motionProbeCandidateLogs < Self.motionProbeMaxCandidateLogs else { return }
        motionProbeCandidateLogs += 1
        logRX(summary, tag: "MOTION")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.sendRawDataStart(to: peripheral, characteristic: cmd)
            }
            scheduleAutoHistoricalSync(for: peripheral)
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

    struct MotionAxisSummary {
        let meanG: Double
        let minG: Double
        let maxG: Double
    }

    struct Gen5RawAccelFrame {
        let k: UInt8
        let subtype: UInt8
        let recordHeader: UInt32
        let deviceTimestamp: UInt32
        let subseconds: UInt16
        let sampleCount: Int
        let x: MotionAxisSummary
        let y: MotionAxisSummary
        let z: MotionAxisSummary
        let rmsDeviationG: Double
        let meanDeltaG: Double
        let maxDeltaG: Double

        var wallClockEstimate: Date {
            Date(timeIntervalSince1970: TimeInterval(deviceTimestamp) + TimeInterval(subseconds) / 32768.0)
        }

        var magnitudeG: Double {
            (x.meanG * x.meanG + y.meanG * y.meanG + z.meanG * z.meanG).squareRoot()
        }

        var debugSummary: String {
            let ts = DateFormatter.localizedString(from: wallClockEstimate, dateStyle: .none, timeStyle: .medium)
            return "Raw43 Gen5 accel K\(k) sub=0x\(String(format: "%02x", subtype)) ts=\(ts) n=\(sampleCount) mean/range g x=\(Self.formatAxis(x)) y=\(Self.formatAxis(y)) z=\(Self.formatAxis(z)) |g|=\(BluetoothManager.formatMotion(magnitudeG)) rms=\(BluetoothManager.formatMotion(rmsDeviationG)) delta=\(BluetoothManager.formatMotion(meanDeltaG))"
        }

        private static func formatAxis(_ axis: MotionAxisSummary) -> String {
            "\(BluetoothManager.formatMotion(axis.meanG))[\(BluetoothManager.formatMotion(axis.minG))...\(BluetoothManager.formatMotion(axis.maxG))]"
        }
    }

    private static func parseGen5RawAccelPayload(_ payload: [UInt8]) -> Gen5RawAccelFrame? {
        guard payload.first == 0x2B else { return nil }
        guard payload.count >= 620 else { return nil }

        // Observed on WHOOP 5.0 raw type-43/K21 frames: three contiguous
        // 100-sample signed i16 accel blocks, scaled by 1/4096 g. This mirrors
        // Noop's Gen4 scale, but the offsets are Gen5 payload-relative.
        guard let xSamples = u16LE(payload, offset: 14),
              let ySamples = u16LE(payload, offset: 16),
              let axisCount = u16LE(payload, offset: 18),
              xSamples == 100,
              ySamples == 100,
              axisCount == 3 else {
            return nil
        }

        let sampleCount = Int(xSamples)
        let accelScale = 1.0 / 4096.0
        guard let xValues = axisValues(payload, offset: 20, count: sampleCount, scale: accelScale),
              let yValues = axisValues(payload, offset: 220, count: sampleCount, scale: accelScale),
              let zValues = axisValues(payload, offset: 420, count: sampleCount, scale: accelScale),
              let recordHeader = u32LE(payload, offset: 3),
              let deviceTimestamp = u32LE(payload, offset: 7),
              let subseconds = u16LE(payload, offset: 11) else {
            return nil
        }
        let x = axisSummary(xValues)
        let y = axisSummary(yValues)
        let z = axisSummary(zValues)
        let motion = motionSummary(x: xValues, y: yValues, z: zValues, meanX: x.meanG, meanY: y.meanG, meanZ: z.meanG)

        let frame = Gen5RawAccelFrame(
            k: payload[1],
            subtype: payload[2],
            recordHeader: recordHeader,
            deviceTimestamp: deviceTimestamp,
            subseconds: subseconds,
            sampleCount: sampleCount,
            x: x,
            y: y,
            z: z,
            rmsDeviationG: motion.rmsDeviationG,
            meanDeltaG: motion.meanDeltaG,
            maxDeltaG: motion.maxDeltaG
        )
        guard (0.8...1.2).contains(frame.magnitudeG) else { return nil }
        return frame
    }

    private static func classifyHistoricalGravityPayload(_ payload: [UInt8]) -> String? {
        guard payload.first == 0x2F else { return nil }
        guard let x = f32LE(payload, offset: 36),
              let y = f32LE(payload, offset: 40),
              let z = f32LE(payload, offset: 44) else {
            return nil
        }
        let magnitude = (x * x + y * y + z * z).squareRoot()
        guard x.isFinite, y.isFinite, z.isFinite, magnitude.isFinite else { return nil }
        guard (0.8...1.2).contains(magnitude) else { return nil }
        return "v24 gravity candidate x=\(formatMotion(x)) y=\(formatMotion(y)) z=\(formatMotion(z)) |g|=\(formatMotion(magnitude))"
    }

    private static func i16Block(_ bytes: [UInt8], offset: Int, count: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let o = offset + i * 2
            guard let value = i16LE(bytes, offset: o) else { break }
            out.append(Int(value))
        }
        return out
    }

    private static func axisValues(_ bytes: [UInt8], offset: Int, count: Int, scale: Double) -> [Double]? {
        let raw = i16Block(bytes, offset: offset, count: count)
        guard raw.count == count else { return nil }
        return raw.map { Double($0) * scale }
    }

    private static func axisSummary(_ values: [Double]) -> MotionAxisSummary {
        let mean = values.reduce(0, +) / Double(values.count)
        return MotionAxisSummary(
            meanG: mean,
            minG: values.min() ?? 0,
            maxG: values.max() ?? 0
        )
    }

    private static func motionSummary(
        x: [Double],
        y: [Double],
        z: [Double],
        meanX: Double,
        meanY: Double,
        meanZ: Double
    ) -> (rmsDeviationG: Double, meanDeltaG: Double, maxDeltaG: Double) {
        guard x.count == y.count, y.count == z.count, !x.isEmpty else {
            return (0, 0, 0)
        }

        var squaredDeviationSum = 0.0
        var deltaSum = 0.0
        var maxDelta = 0.0

        for i in x.indices {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            let dz = z[i] - meanZ
            squaredDeviationSum += dx * dx + dy * dy + dz * dz

            if i > x.startIndex {
                let stepX = x[i] - x[i - 1]
                let stepY = y[i] - y[i - 1]
                let stepZ = z[i] - z[i - 1]
                let delta = (stepX * stepX + stepY * stepY + stepZ * stepZ).squareRoot()
                deltaSum += delta
                maxDelta = max(maxDelta, delta)
            }
        }

        let rms = (squaredDeviationSum / Double(x.count)).squareRoot()
        let meanDelta = x.count > 1 ? deltaSum / Double(x.count - 1) : 0
        return (rms, meanDelta, maxDelta)
    }

    private static func i16LE(_ bytes: [UInt8], offset: Int) -> Int16? {
        guard offset + 1 < bytes.count else { return nil }
        let raw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        return Int16(bitPattern: raw)
    }

    private static func u16LE(_ bytes: [UInt8], offset: Int) -> UInt16? {
        guard offset + 1 < bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32LE(_ bytes: [UInt8], offset: Int) -> UInt32? {
        guard offset + 3 < bytes.count else { return nil }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func f32LE(_ bytes: [UInt8], offset: Int) -> Double? {
        guard offset + 3 < bytes.count else { return nil }
        let raw = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Double(Float(bitPattern: raw))
    }

    private static func formatMotion(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // Persist one HR sample to SwiftData. The main context autosaves, so we
    // just insert; we don't `save()` per-call. Retention is "forever" — no
    // trimming. If storage ever feels heavy, switch to hourly roll-ups for
    // data older than ~30 days.
    private func persistHeartRateSample(_ bpm: Int) {
        let now = Date()
        modelContext.insert(HRSample(timestamp: now, bpm: bpm))
        updateHourlySummary(bpm: bpm, at: now)
        updateDailySummary(bpm: bpm, at: now)
        refreshSleepWindowSummariesAround(now)
    }

    private func persistMotionSample(_ frame: Gen5RawAccelFrame) {
        let timestamp = frame.wallClockEstimate
        modelContext.insert(MotionSample(
            timestamp: timestamp,
            sampleCount: frame.sampleCount,
            meanXG: frame.x.meanG,
            meanYG: frame.y.meanG,
            meanZG: frame.z.meanG,
            magnitudeG: frame.magnitudeG,
            minXG: frame.x.minG,
            maxXG: frame.x.maxG,
            minYG: frame.y.minG,
            maxYG: frame.y.maxG,
            minZG: frame.z.minG,
            maxZG: frame.z.maxG,
            rmsDeviationG: frame.rmsDeviationG,
            meanDeltaG: frame.meanDeltaG,
            maxDeltaG: frame.maxDeltaG,
            sourceKey: "raw43:\(frame.deviceTimestamp):\(frame.subseconds):\(frame.recordHeader)"
        ))
        updateMotionBucketSummaries(
            timestamp: timestamp,
            meanDeltaG: frame.meanDeltaG,
            rmsDeviationG: frame.rmsDeviationG,
            maxDeltaG: frame.maxDeltaG
        )
        refreshSleepWindowSummariesAround(timestamp)
    }

    // MARK: - Summary aggregation

    private func updateMotionBucketSummaries(
        timestamp: Date,
        meanDeltaG: Double,
        rmsDeviationG: Double,
        maxDeltaG: Double
    ) {
        let isStill = MotionStillness.isStill(meanDeltaG: meanDeltaG, rmsDeviationG: rmsDeviationG)
        for seconds in Self.motionBucketSeconds {
            let bucketStart = motionBucketStart(of: timestamp, seconds: seconds)
            let summary = fetchOrCreateMotionBucketSummary(bucketStart: bucketStart, seconds: seconds)
            summary.sampleCount += 1
            summary.sumMeanDeltaG += meanDeltaG
            summary.maxDeltaG = max(summary.maxDeltaG, maxDeltaG)
            if isStill {
                summary.stillCount += 1
            }

            if let first = summary.firstSampleAt {
                summary.firstSampleAt = min(first, timestamp)
            } else {
                summary.firstSampleAt = timestamp
            }

            if let last = summary.lastSampleAt {
                summary.lastSampleAt = max(last, timestamp)
            } else {
                summary.lastSampleAt = timestamp
            }
        }
    }

    private func fetchOrCreateMotionBucketSummary(bucketStart: Date, seconds: Int) -> MotionBucketSummary {
        let descriptor = FetchDescriptor<MotionBucketSummary>(
            predicate: #Predicate {
                $0.bucketStart == bucketStart && $0.bucketSeconds == seconds
            }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            return existing
        }
        let summary = MotionBucketSummary(bucketStart: bucketStart, bucketSeconds: seconds)
        modelContext.insert(summary)
        return summary
    }

    private func motionBucketStart(of date: Date, seconds: Int) -> Date {
        let dayStart = Calendar.current.startOfDay(for: date)
        let offset = max(0, date.timeIntervalSince(dayStart))
        let bucketOffset = floor(offset / Double(seconds)) * Double(seconds)
        return dayStart.addingTimeInterval(bucketOffset)
    }

    private func updateDailySummary(bpm: Int, at timestamp: Date) {
        let today = Calendar.current.startOfDay(for: timestamp)
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

    private func updateHourlySummary(bpm: Int, at timestamp: Date) {
        let hourStart = hourStart(of: timestamp)
        let summary = fetchOrCreateHourlySummary(for: hourStart)
        if summary.hrSampleCount == 0 {
            summary.minHR = bpm
            summary.maxHR = bpm
        } else {
            summary.minHR = min(summary.minHR, bpm)
            summary.maxHR = max(summary.maxHR, bpm)
        }
        summary.sumHR += Double(bpm)
        summary.hrSampleCount += 1
    }

    private func updateHourlySummaryHRV(_ rmssd: Double, at timestamp: Date) {
        let hourStart = hourStart(of: timestamp)
        let summary = fetchOrCreateHourlySummary(for: hourStart)
        summary.sumHRV += rmssd
        summary.hrvSampleCount += 1
    }

    private func fetchOrCreateHourlySummary(for hourStart: Date) -> HourlySummary {
        let descriptor = FetchDescriptor<HourlySummary>(
            predicate: #Predicate { $0.hourStart == hourStart }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            return existing
        }
        let summary = HourlySummary(hourStart: hourStart)
        modelContext.insert(summary)
        return summary
    }

    private func updateSkinTemperatureHourlySummary(celsius: Double, rawU16: Int?, at timestamp: Date) {
        guard let rawU16 else { return }
        let hourStart = hourStart(of: timestamp)
        let summary = fetchOrCreateSkinTemperatureHourlySummary(for: hourStart)
        if summary.sampleCount == 0 {
            summary.minCelsius = celsius
            summary.maxCelsius = celsius
            summary.minRawU16 = rawU16
            summary.maxRawU16 = rawU16
        } else {
            summary.minCelsius = min(summary.minCelsius, celsius)
            summary.maxCelsius = max(summary.maxCelsius, celsius)
            summary.minRawU16 = min(summary.minRawU16, rawU16)
            summary.maxRawU16 = max(summary.maxRawU16, rawU16)
        }
        summary.sumCelsius += celsius
        summary.sumRawU16 += Double(rawU16)
        summary.sampleCount += 1
    }

    private func fetchOrCreateSkinTemperatureHourlySummary(for hourStart: Date) -> SkinTemperatureHourlySummary {
        let descriptor = FetchDescriptor<SkinTemperatureHourlySummary>(
            predicate: #Predicate { $0.hourStart == hourStart }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            return existing
        }
        let summary = SkinTemperatureHourlySummary(hourStart: hourStart)
        modelContext.insert(summary)
        return summary
    }

    private func hourStart(of date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps) ?? date
    }

    // Backfill HourlySummary rows from existing samples. Each metric is
    // backfilled independently — added later means earlier installs still
    // catch up on missing HRV without redoing HR.
    private func backfillHourlySummariesIfNeeded() {
        let hadHourlyAlready = (try? modelContext.fetchCount(FetchDescriptor<HourlySummary>())) ?? 0 > 0

        var rowCache: [Date: HourlySummary] = [:]
        func row(for hour: Date) -> HourlySummary {
            if let r = rowCache[hour] { return r }
            let descriptor = FetchDescriptor<HourlySummary>(predicate: #Predicate { $0.hourStart == hour })
            if let existing = (try? modelContext.fetch(descriptor))?.first {
                rowCache[hour] = existing
                return existing
            }
            let r = HourlySummary(hourStart: hour)
            modelContext.insert(r)
            rowCache[hour] = r
            return r
        }

        // HR backfill: skip if any HourlySummary rows already exist
        // (we always touch the current hour when a sample arrives, so any
        // existing rows mean the HR pass already ran).
        if !hadHourlyAlready {
            let hrSamples = (try? modelContext.fetch(FetchDescriptor<HRSample>(sortBy: [SortDescriptor(\.timestamp)]))) ?? []
            for s in hrSamples {
                let r = row(for: hourStart(of: s.timestamp))
                if r.hrSampleCount == 0 {
                    r.minHR = s.bpm
                    r.maxHR = s.bpm
                } else {
                    r.minHR = min(r.minHR, s.bpm)
                    r.maxHR = max(r.maxHR, s.bpm)
                }
                r.sumHR += Double(s.bpm)
                r.hrSampleCount += 1
            }
        }

        // HRV backfill: skip if any HourlySummary already has HRV data.
        let hrvDescriptor = FetchDescriptor<HourlySummary>(predicate: #Predicate { $0.hrvSampleCount > 0 })
        let hadHRV = (try? modelContext.fetchCount(hrvDescriptor)) ?? 0 > 0
        if !hadHRV {
            let hrvSamples = (try? modelContext.fetch(FetchDescriptor<HRVSample>(sortBy: [SortDescriptor(\.timestamp)]))) ?? []
            for s in hrvSamples {
                let r = row(for: hourStart(of: s.timestamp))
                r.sumHRV += s.rmssdMS
                r.hrvSampleCount += 1
            }
        }

        try? modelContext.save()
    }

    private func backfillMotionBucketSummariesIfNeeded() {
        let missingBucketSizes = Self.motionBucketSeconds.filter { seconds in
            let descriptor = FetchDescriptor<MotionBucketSummary>(
                predicate: #Predicate { $0.bucketSeconds == seconds }
            )
            return ((try? modelContext.fetchCount(descriptor)) ?? 0) == 0
        }
        guard !missingBucketSizes.isEmpty else { return }

        let descriptor = FetchDescriptor<MotionSample>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let samples = try? modelContext.fetch(descriptor), !samples.isEmpty else { return }

        for seconds in missingBucketSizes {
            var summaries: [Date: MotionBucketSummary] = [:]

            for sample in samples {
                let bucketStart = motionBucketStart(of: sample.timestamp, seconds: seconds)
                let summary: MotionBucketSummary
                if let existing = summaries[bucketStart] {
                    summary = existing
                } else {
                    let created = MotionBucketSummary(bucketStart: bucketStart, bucketSeconds: seconds)
                    modelContext.insert(created)
                    summaries[bucketStart] = created
                    summary = created
                }

                summary.sampleCount += 1
                summary.sumMeanDeltaG += sample.meanDeltaG
                summary.maxDeltaG = max(summary.maxDeltaG, sample.maxDeltaG)
                if MotionStillness.isStill(meanDeltaG: sample.meanDeltaG, rmsDeviationG: sample.rmsDeviationG) {
                    summary.stillCount += 1
                }

                if let first = summary.firstSampleAt {
                    summary.firstSampleAt = min(first, sample.timestamp)
                } else {
                    summary.firstSampleAt = sample.timestamp
                }

                if let last = summary.lastSampleAt {
                    summary.lastSampleAt = max(last, sample.timestamp)
                } else {
                    summary.lastSampleAt = sample.timestamp
                }
            }
        }

        try? modelContext.save()
    }

    private struct SleepMotionBucket {
        let start: Date
        let end: Date
        let isStill: Bool
        let stillFraction: Double
    }

    private struct SleepCandidate {
        let start: Date
        let end: Date
        let durationSeconds: TimeInterval
        let motionBucketCount: Int
        let stillBucketCount: Int
        let avgStillFraction: Double
    }

    private struct DetectedSleepWindow {
        let start: Date
        let end: Date
        let durationSeconds: TimeInterval
        let confidence: Double
        let motionBucketCount: Int
        let stillBucketCount: Int
        let hrSampleCount: Int
        let avgHR: Double?
        let qualityFlags: String
    }

    private struct SleepEdgeRefinement {
        let start: Date
        let end: Date
        let flags: [String]
    }

    private struct RawMotionWindow {
        let start: Date
        let end: Date
        let sampleCount: Int
        let stillFraction: Double
        let avgMeanDeltaG: Double

        var isStill: Bool {
            stillFraction >= BluetoothManager.sleepStillFraction ||
                avgMeanDeltaG <= MotionStillness.meanDeltaThresholdG
        }

        var isDeepStill: Bool {
            MotionStillness.isDeepStill(stillFraction: stillFraction, avgMeanDeltaG: avgMeanDeltaG)
        }
    }

    private struct HRRollingWindow {
        let start: Date
        let end: Date
        let sampleCount: Int
        let avgBPM: Double
    }

    private struct HRVRollingWindow {
        let start: Date
        let end: Date
        let sampleCount: Int
        let avgRMSSD: Double
    }

    private func refreshSleepWindowSummariesAround(_ timestamp: Date, force: Bool = false) {
        let now = Date()
        if !force,
           let last = lastSleepWindowRefreshAt,
           now.timeIntervalSince(last) < Self.sleepRefreshThrottleSeconds {
            return
        }
        if !force {
            lastSleepWindowRefreshAt = now
        }

        let dayStart = Calendar.current.startOfDay(for: timestamp)
        refreshSleepWindowSummary(forWakeDay: dayStart)
        if let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) {
            refreshSleepWindowSummary(forWakeDay: nextDay)
        }
    }

    private func refreshSleepWindowSummary(forWakeDay wakeDay: Date) {
        let searchStart = wakeDay.addingTimeInterval(Self.sleepSearchStartOffset)
        let searchEnd = wakeDay.addingTimeInterval(Self.sleepSearchEndOffset)
        let bucketSeconds = Self.sleepWindowBucketSeconds
        let descriptor = FetchDescriptor<MotionBucketSummary>(
            predicate: #Predicate {
                $0.bucketSeconds == bucketSeconds &&
                $0.bucketStart >= searchStart &&
                $0.bucketStart < searchEnd
            },
            sortBy: [SortDescriptor(\.bucketStart)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard let detected = detectSleepWindow(from: rows, wakeDay: wakeDay) else {
            if let existing = fetchSleepWindowSummary(forWakeDay: wakeDay) {
                modelContext.delete(existing)
            }
            deleteRecoverySummary(forWakeDay: wakeDay)
            return
        }

        upsertSleepWindowSummary(day: wakeDay, detected: detected)
        rebuildRecoverySummary(forWakeDay: wakeDay)
        rebuildMonthlySummary(for: wakeDay)
    }

    private func detectSleepWindow(from rows: [MotionBucketSummary], wakeDay: Date) -> DetectedSleepWindow? {
        let buckets = rows.compactMap { row -> SleepMotionBucket? in
            guard row.sampleCount > 0 else { return nil }
            let stillFraction = Double(row.stillCount) / Double(row.sampleCount)
            let isStill = stillFraction >= Self.sleepStillFraction ||
                row.avgMeanDeltaG <= MotionStillness.meanDeltaThresholdG
            return SleepMotionBucket(
                start: row.bucketStart,
                end: row.bucketStart.addingTimeInterval(Double(row.bucketSeconds)),
                isStill: isStill,
                stillFraction: stillFraction
            )
        }
        guard !buckets.isEmpty else { return nil }

        let candidates = sleepCandidates(from: buckets)
            .filter { $0.durationSeconds >= Self.sleepMinimumDurationSeconds }
        guard !candidates.isEmpty else { return nil }

        let searchStart = wakeDay.addingTimeInterval(Self.sleepSearchStartOffset)
        let searchEnd = wakeDay.addingTimeInterval(Self.sleepSearchEndOffset)
        let searchHR = fetchHeartRateBPMs(start: searchStart, end: searchEnd)
        let baselineHR = median(searchHR)
        let nightStart = wakeDay.addingTimeInterval(-3 * 60 * 60)
        let nightEnd = wakeDay.addingTimeInterval(11 * 60 * 60)

        return candidates.compactMap { candidate -> DetectedSleepWindow? in
            let refined = refineSleepCandidateEdges(candidate)
            let durationSeconds = refined.end.timeIntervalSince(refined.start)
            let hr = fetchHeartRateBPMs(start: refined.start, end: refined.end)
            let avgHR = hr.isEmpty ? nil : hr.reduce(0.0) { $0 + Double($1) } / Double(hr.count)
            var flags = refined.flags

            let hrScore: Double
            if hr.count < 30 {
                hrScore = 0.55
                flags.append("hr_sparse")
            } else if let baseline = baselineHR, let avg = avgHR {
                let confirmed = avg <= baseline * Self.sleepHRBaselineMultiplier
                hrScore = confirmed ? 1.0 : 0.25
                if !confirmed {
                    flags.append("hr_above_baseline")
                }
            } else {
                hrScore = 0.65
                flags.append("hr_baseline_missing")
            }

            let durationScore = min(durationSeconds / (8 * 60 * 60), 1.0)
            let motionBucketCount = max(1, Int(round(durationSeconds / Double(Self.sleepWindowBucketSeconds))))
            let stillDensity = Double(candidate.stillBucketCount) / Double(max(1, motionBucketCount))
            let stillScore = min(max(stillDensity, 0.0), 1.0)
            let overnightScore = min(overlapSeconds(refined.start, refined.end, nightStart, nightEnd) / durationSeconds, 1.0)
            let confidence = min(max(
                durationScore * 0.25 +
                stillScore * 0.35 +
                hrScore * 0.25 +
                overnightScore * 0.15,
                0.0
            ), 1.0)

            if confidence < SleepWindowDetection.minimumConfidence {
                flags.append("low_confidence")
            }

            return DetectedSleepWindow(
                start: refined.start,
                end: refined.end,
                durationSeconds: durationSeconds,
                confidence: confidence,
                motionBucketCount: motionBucketCount,
                stillBucketCount: candidate.stillBucketCount,
                hrSampleCount: hr.count,
                avgHR: avgHR,
                qualityFlags: flags.isEmpty ? "ok" : flags.joined(separator: ",")
            )
        }
        .max {
            if abs($0.confidence - $1.confidence) > 0.001 {
                return $0.confidence < $1.confidence
            }
            return $0.durationSeconds < $1.durationSeconds
        }
    }

    private func sleepCandidates(from buckets: [SleepMotionBucket]) -> [SleepCandidate] {
        var candidates: [SleepCandidate] = []
        var start: Date?
        var end: Date?
        var stillCount = 0
        var stillFractionSum = 0.0

        func closeCurrent() {
            guard let s = start, let e = end else { return }
            let duration = e.timeIntervalSince(s)
            let expectedBuckets = max(1, Int(round(duration / Double(Self.sleepWindowBucketSeconds))))
            candidates.append(SleepCandidate(
                start: s,
                end: e,
                durationSeconds: duration,
                motionBucketCount: expectedBuckets,
                stillBucketCount: stillCount,
                avgStillFraction: stillCount > 0 ? stillFractionSum / Double(stillCount) : 0
            ))
            start = nil
            end = nil
            stillCount = 0
            stillFractionSum = 0
        }

        for bucket in buckets where bucket.isStill {
            if let currentEnd = end,
               bucket.start.timeIntervalSince(currentEnd) <= Self.sleepMergeGapSeconds {
                end = max(currentEnd, bucket.end)
                stillCount += 1
                stillFractionSum += bucket.stillFraction
            } else {
                closeCurrent()
                start = bucket.start
                end = bucket.end
                stillCount = 1
                stillFractionSum = bucket.stillFraction
            }
        }
        closeCurrent()
        return candidates
    }

    private func refineSleepCandidateEdges(_ candidate: SleepCandidate) -> SleepEdgeRefinement {
        let inBedStart = refineInBedStart(around: candidate.start) ?? candidate.start
        var flags: [String] = []

        if abs(inBedStart.timeIntervalSince(candidate.start)) >= 60 {
            flags.append("raw_start_refined")
        }

        let asleepStart: Date
        if let refined = refineAsleepStart(after: inBedStart, before: candidate.end, flags: &flags) {
            asleepStart = refined
        } else {
            asleepStart = inBedStart
            flags.append("onset_unrefined")
        }

        let motionEnd = refineSleepEnd(around: candidate.end) ?? candidate.end
        var refinedEnd = motionEnd
        if abs(motionEnd.timeIntervalSince(candidate.end)) >= 60 {
            flags.append("raw_end_refined")
        }

        if let hrWake = refineSleepEndWithHeartRate(
            around: candidate.end,
            sleepStart: asleepStart,
            motionEnd: motionEnd
        ), hrWake < refinedEnd {
            refinedEnd = hrWake
            flags.append("hr_wake_refined")
        }

        guard refinedEnd.timeIntervalSince(asleepStart) >= Self.sleepMinimumDurationSeconds else {
            flags.append("raw_edges_invalid")
            return SleepEdgeRefinement(start: candidate.start, end: candidate.end, flags: flags)
        }

        return SleepEdgeRefinement(start: asleepStart, end: refinedEnd, flags: flags)
    }

    private func refineInBedStart(around coarseStart: Date) -> Date? {
        let scanStart = coarseStart.addingTimeInterval(-Self.sleepEdgeOutsideSeconds)
        let scanEnd = coarseStart.addingTimeInterval(max(Self.sleepEdgeInsideSeconds, Self.sleepStartHRInsideSeconds))
        let windows = rawMotionWindows(start: scanStart, end: scanEnd)
        guard !windows.isEmpty else { return nil }

        return windows.first(where: { $0.start >= coarseStart && $0.isStill })?.start ??
            windows.first(where: \.isStill)?.start
    }

    private func refineAsleepStart(
        after inBedStart: Date,
        before candidateEnd: Date,
        flags: inout [String]
    ) -> Date? {
        let maxScan = inBedStart.addingTimeInterval(Self.sleepOnsetScanMaxSeconds)
        let scanEnd = min(candidateEnd, maxScan)
        guard scanEnd.timeIntervalSince(inBedStart) >= Self.sleepEdgeRollingWindowSeconds else {
            return nil
        }

        let hrvOnset = refineAsleepStartWithHRV(after: inBedStart, before: scanEnd)
        let motionOnset = refineAsleepStartWithDeepMotion(after: inBedStart, before: scanEnd)

        switch (hrvOnset, motionOnset) {
        case let (hrv?, motion?):
            flags.append("onset_dual_signal")
            return max(hrv, motion)
        case let (hrv?, nil):
            flags.append("hrv_onset_refined")
            return hrv
        case let (nil, motion?):
            flags.append("deep_still_onset_refined")
            return motion
        case (nil, nil):
            return nil
        }
    }

    private func refineAsleepStartWithHRV(after inBedStart: Date, before scanEnd: Date) -> Date? {
        let baselineEnd = min(
            inBedStart.addingTimeInterval(Self.sleepOnsetInBedHRVBaselineSeconds),
            scanEnd
        )
        let baselineValues = fetchHRVValues(start: inBedStart, end: baselineEnd)
        guard baselineValues.count >= Self.sleepOnsetMinimumHRVSamples,
              let inBedHRV = median(baselineValues) else {
            return nil
        }

        let threshold = inBedHRV * Self.sleepOnsetHRVMultiplier
        let windows = hrvRollingWindows(start: inBedStart, end: scanEnd)
        guard !windows.isEmpty else { return nil }

        return windows.first { window in
            let sustainedEnd = window.start.addingTimeInterval(Self.sleepOnsetHRVSustainedSeconds)
            return window.start >= inBedStart &&
                window.avgRMSSD >= threshold &&
                sustainedEnd <= scanEnd &&
                hrvStaysElevated(start: window.start, end: sustainedEnd, threshold: threshold)
        }?.start
    }

    private func refineAsleepStartWithDeepMotion(after inBedStart: Date, before scanEnd: Date) -> Date? {
        let windows = rawMotionWindows(start: inBedStart, end: scanEnd)
        return windows.first { window in
            window.start >= inBedStart && window.isDeepStill
        }?.start
    }

    private func refineSleepEndWithHeartRate(
        around coarseEnd: Date,
        sleepStart: Date,
        motionEnd: Date
    ) -> Date? {
        let duration = motionEnd.timeIntervalSince(sleepStart)
        guard duration > 0 else { return nil }

        let baselineStart = sleepStart.addingTimeInterval(duration / 3)
        let baselineEnd = sleepStart.addingTimeInterval(2 * duration / 3)
        guard let sleepBaselineHR = median(fetchHeartRateBPMs(start: baselineStart, end: baselineEnd)) else {
            return nil
        }

        let threshold = max(
            sleepBaselineHR * Self.sleepWakeHRRiseMultiplier,
            sleepBaselineHR + Self.sleepWakeHRRiseToleranceBPM
        )

        let scanStart = coarseEnd.addingTimeInterval(-Self.sleepEdgeInsideSeconds)
        let scanEnd = coarseEnd.addingTimeInterval(Self.sleepEdgeOutsideSeconds)
        let hrWindows = heartRateRollingWindows(start: scanStart, end: scanEnd)
        guard !hrWindows.isEmpty else { return nil }

        return hrWindows.first { window in
            let sustainedEnd = window.start.addingTimeInterval(Self.sleepWakeHRSustainedSeconds)
            return window.start >= scanStart &&
                window.avgBPM >= threshold &&
                sustainedEnd <= scanEnd &&
                heartRateStaysElevated(start: window.start, end: sustainedEnd, threshold: threshold)
        }?.start
    }

    private func refineSleepEnd(around coarseEnd: Date) -> Date? {
        let scanStart = coarseEnd.addingTimeInterval(-Self.sleepEdgeInsideSeconds)
        let scanEnd = coarseEnd.addingTimeInterval(Self.sleepEdgeOutsideSeconds)
        let windows = rawMotionWindows(start: scanStart, end: scanEnd)
        guard !windows.isEmpty else { return nil }

        var sawStill = false
        var lastStillEnd: Date?
        for window in windows {
            if window.isStill {
                sawStill = true
                lastStillEnd = window.end
            } else if sawStill {
                return window.start
            }
        }
        return lastStillEnd
    }

    private func rawMotionWindows(start: Date, end: Date) -> [RawMotionWindow] {
        let samples = fetchMotionSamples(start: start, end: end)
        guard samples.count >= Self.sleepEdgeMinimumRawFrames else { return [] }

        var windows: [RawMotionWindow] = []
        var endIndex = 0
        var stillCount = 0
        var meanDeltaSum = 0.0

        for startIndex in samples.indices {
            let windowStart = samples[startIndex].timestamp
            let windowEnd = windowStart.addingTimeInterval(Self.sleepEdgeRollingWindowSeconds)

            while endIndex < samples.count && samples[endIndex].timestamp < windowEnd {
                let sample = samples[endIndex]
                if MotionStillness.isStill(meanDeltaG: sample.meanDeltaG, rmsDeviationG: sample.rmsDeviationG) {
                    stillCount += 1
                }
                meanDeltaSum += sample.meanDeltaG
                endIndex += 1
            }

            let count = endIndex - startIndex
            if count >= Self.sleepEdgeMinimumRawFrames {
                windows.append(RawMotionWindow(
                    start: windowStart,
                    end: windowEnd,
                    sampleCount: count,
                    stillFraction: Double(stillCount) / Double(count),
                    avgMeanDeltaG: meanDeltaSum / Double(count)
                ))
            }

            let outgoing = samples[startIndex]
            if MotionStillness.isStill(meanDeltaG: outgoing.meanDeltaG, rmsDeviationG: outgoing.rmsDeviationG) {
                stillCount -= 1
            }
            meanDeltaSum -= outgoing.meanDeltaG
        }

        return windows
    }

    private func heartRateStaysElevated(start: Date, end: Date, threshold: Double) -> Bool {
        let samples = fetchHeartRateBPMs(start: start, end: end)
        let minimumSamples = Self.sleepStartMinimumHRSamples * 2
        guard samples.count >= minimumSamples else { return false }
        let avg = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        return avg >= threshold
    }

    private func hrvStaysElevated(start: Date, end: Date, threshold: Double) -> Bool {
        let values = fetchHRVValues(start: start, end: end)
        guard values.count >= Self.sleepOnsetMinimumHRVSamples else { return false }
        let avg = values.reduce(0.0, +) / Double(values.count)
        return avg >= threshold
    }

    private func heartRateRollingWindows(start: Date, end: Date) -> [HRRollingWindow] {
        let samples = fetchHeartRateSamples(start: start, end: end)
        guard samples.count >= Self.sleepStartMinimumHRSamples else { return [] }

        var windows: [HRRollingWindow] = []
        var endIndex = 0
        var bpmSum = 0

        for startIndex in samples.indices {
            let windowStart = samples[startIndex].timestamp
            let windowEnd = windowStart.addingTimeInterval(Self.sleepStartHRRollingWindowSeconds)

            while endIndex < samples.count && samples[endIndex].timestamp < windowEnd {
                bpmSum += samples[endIndex].bpm
                endIndex += 1
            }

            let count = endIndex - startIndex
            if count >= Self.sleepStartMinimumHRSamples {
                windows.append(HRRollingWindow(
                    start: windowStart,
                    end: windowEnd,
                    sampleCount: count,
                    avgBPM: Double(bpmSum) / Double(count)
                ))
            }

            bpmSum -= samples[startIndex].bpm
        }

        return windows
    }

    private func hrvRollingWindows(start: Date, end: Date) -> [HRVRollingWindow] {
        let samples = fetchHRVSamples(start: start, end: end)
        guard samples.count >= Self.sleepOnsetMinimumHRVSamples else { return [] }

        var windows: [HRVRollingWindow] = []
        var endIndex = 0
        var rmssdSum = 0.0

        for startIndex in samples.indices {
            let windowStart = samples[startIndex].timestamp
            let windowEnd = windowStart.addingTimeInterval(Self.sleepOnsetHRRollingWindowSeconds)

            while endIndex < samples.count && samples[endIndex].timestamp < windowEnd {
                rmssdSum += samples[endIndex].rmssdMS
                endIndex += 1
            }

            let count = endIndex - startIndex
            if count >= Self.sleepOnsetMinimumHRVSamples {
                windows.append(HRVRollingWindow(
                    start: windowStart,
                    end: windowEnd,
                    sampleCount: count,
                    avgRMSSD: rmssdSum / Double(count)
                ))
            }

            rmssdSum -= samples[startIndex].rmssdMS
        }

        return windows
    }

    private func fetchHeartRateBPMs(start: Date, end: Date) -> [Int] {
        let descriptor = FetchDescriptor<HRSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).map(\.bpm)
    }

    private func fetchHeartRateSamples(start: Date, end: Date) -> [HRSample] {
        let descriptor = FetchDescriptor<HRSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchMotionSamples(start: Date, end: Date) -> [MotionSample] {
        let descriptor = FetchDescriptor<MotionSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchHRVSamples(start: Date, end: Date) -> [HRVSample] {
        let descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func fetchHRVValues(start: Date, end: Date) -> [Double] {
        fetchHRVSamples(start: start, end: end).map(\.rmssdMS)
    }

    private func median(_ values: [Int]) -> Double? {
        median(values.map(Double.init))
    }

    private func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }

    private func overlapSeconds(_ start: Date, _ end: Date, _ otherStart: Date, _ otherEnd: Date) -> TimeInterval {
        let lower = max(start, otherStart)
        let upper = min(end, otherEnd)
        return max(0, upper.timeIntervalSince(lower))
    }

    private func fetchSleepWindowSummary(forWakeDay day: Date) -> SleepWindowSummary? {
        let descriptor = FetchDescriptor<SleepWindowSummary>(
            predicate: #Predicate { $0.day == day }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func rhrForSleepWindow(_ detected: DetectedSleepWindow) -> Double? {
        guard detected.confidence >= SleepWindowDetection.minimumConfidence else { return nil }
        return detected.avgHR
    }

    private func upsertSleepWindowSummary(day: Date, detected: DetectedSleepWindow) {
        let rhr = rhrForSleepWindow(detected)
        let summary = fetchSleepWindowSummary(forWakeDay: day) ?? {
            let created = SleepWindowSummary(
                day: day,
                start: detected.start,
                end: detected.end,
                durationMinutes: detected.durationSeconds / 60.0,
                confidence: detected.confidence,
                method: "motion_hr_hrv_asleep_v4",
                motionBucketCount: detected.motionBucketCount,
                stillBucketCount: detected.stillBucketCount,
                hrSampleCount: detected.hrSampleCount,
                avgHR: rhr,
                qualityFlags: detected.qualityFlags
            )
            modelContext.insert(created)
            return created
        }()

        summary.start = detected.start
        summary.end = detected.end
        summary.durationMinutes = detected.durationSeconds / 60.0
        summary.confidence = detected.confidence
        summary.method = "motion_hr_hrv_asleep_v4"
        summary.motionBucketCount = detected.motionBucketCount
        summary.stillBucketCount = detected.stillBucketCount
        summary.hrSampleCount = detected.hrSampleCount
        summary.avgHR = rhr
        summary.qualityFlags = detected.qualityFlags
    }

    private func fetchRecoverySummary(forWakeDay day: Date) -> RecoverySummary? {
        let descriptor = FetchDescriptor<RecoverySummary>(
            predicate: #Predicate { $0.day == day }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func deleteRecoverySummary(forWakeDay day: Date) {
        if let existing = fetchRecoverySummary(forWakeDay: day) {
            modelContext.delete(existing)
        }
    }

    private func computeRecoveryBaseline(before wakeDay: Date) -> RecoveryScore.Baseline {
        let lookbackStart = Calendar.current.date(
            byAdding: .day,
            value: -RecoveryScore.baselineLookbackDays,
            to: wakeDay
        ) ?? wakeDay
        let minimumHRVSamples = RecoveryScore.minimumHRVSamples
        let descriptor = FetchDescriptor<RecoverySummary>(
            predicate: #Predicate<RecoverySummary> {
                $0.day >= lookbackStart &&
                $0.day < wakeDay &&
                $0.hrvSampleCount >= minimumHRVSamples
            }
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        let eligible = rows.filter { $0.rhrBPM > 0 && $0.sleepMinutes > 0 && $0.hrvMS > 0 }
        guard !eligible.isEmpty else {
            return RecoveryScore.Baseline(hrvMS: 0, rhrBPM: 0, sleepMinutes: 0, dayCount: 0)
        }
        return RecoveryScore.Baseline(
            hrvMS: RecoveryScore.median(eligible.map(\.hrvMS)) ?? 0,
            rhrBPM: RecoveryScore.median(eligible.map(\.rhrBPM)) ?? 0,
            sleepMinutes: RecoveryScore.median(eligible.map(\.sleepMinutes)) ?? 0,
            dayCount: eligible.count
        )
    }

    private func rebuildRecoverySummary(forWakeDay wakeDay: Date) {
        guard let window = fetchSleepWindowSummary(forWakeDay: wakeDay),
              window.confidence >= SleepWindowDetection.minimumConfidence,
              let rhr = window.avgHR else {
            deleteRecoverySummary(forWakeDay: wakeDay)
            return
        }

        let hrvValues = fetchHRVValues(start: window.start, end: window.end)
        let hrvMS = hrvValues.isEmpty ? 0 : hrvValues.reduce(0, +) / Double(hrvValues.count)
        let baseline = computeRecoveryBaseline(before: wakeDay)
        let nightly = RecoveryScore.NightlyMetrics(
            hrvMS: hrvMS,
            rhrBPM: rhr,
            sleepMinutes: window.durationMinutes,
            hrvSampleCount: hrvValues.count
        )
        let computed = RecoveryScore.compute(today: nightly, baseline: baseline)

        let summary = fetchRecoverySummary(forWakeDay: wakeDay) ?? {
            let created = RecoverySummary(
                day: wakeDay,
                score: computed?.score,
                zone: computed?.zone ?? .unavailable,
                method: RecoveryScore.method,
                hrvMS: hrvMS,
                rhrBPM: rhr,
                sleepMinutes: window.durationMinutes,
                hrvSampleCount: hrvValues.count,
                baselineDayCount: baseline.dayCount,
                baselineHRVMS: baseline.dayCount > 0 ? baseline.hrvMS : nil,
                baselineRHRBPM: baseline.dayCount > 0 ? baseline.rhrBPM : nil,
                baselineSleepMinutes: baseline.dayCount > 0 ? baseline.sleepMinutes : nil,
                hrvComponent: computed?.hrvComponent ?? 0,
                rhrComponent: computed?.rhrComponent ?? 0,
                sleepComponent: computed?.sleepComponent ?? 0
            )
            modelContext.insert(created)
            return created
        }()

        summary.score = computed?.score
        summary.zone = (computed?.zone ?? .unavailable).rawValue
        summary.method = RecoveryScore.method
        summary.hrvMS = hrvMS
        summary.rhrBPM = rhr
        summary.sleepMinutes = window.durationMinutes
        summary.hrvSampleCount = hrvValues.count
        summary.baselineDayCount = baseline.dayCount
        summary.baselineHRVMS = baseline.dayCount > 0 ? baseline.hrvMS : nil
        summary.baselineRHRBPM = baseline.dayCount > 0 ? baseline.rhrBPM : nil
        summary.baselineSleepMinutes = baseline.dayCount > 0 ? baseline.sleepMinutes : nil
        summary.hrvComponent = computed?.hrvComponent ?? 0
        summary.rhrComponent = computed?.rhrComponent ?? 0
        summary.sleepComponent = computed?.sleepComponent ?? 0
    }

    private func backfillRecoverySummariesIfNeeded() {
        let version = UserDefaults.standard.integer(forKey: Self.recoveryBackfillKey)
        guard version < Self.recoveryBackfillVersion else { return }

        let descriptor = FetchDescriptor<SleepWindowSummary>(
            sortBy: [SortDescriptor(\.day)]
        )
        guard let windows = try? modelContext.fetch(descriptor), !windows.isEmpty else { return }

        for window in windows {
            rebuildRecoverySummary(forWakeDay: window.day)
        }
        try? modelContext.save()
        UserDefaults.standard.set(Self.recoveryBackfillVersion, forKey: Self.recoveryBackfillKey)
    }

    private func purgeImplausibleSkinTemperatureSamplesIfNeeded() {
        let version = UserDefaults.standard.integer(forKey: Self.skinTemperatureCleanupKey)
        guard version < Self.skinTemperatureCleanupVersion else { return }

        let descriptor = FetchDescriptor<SkinTemperatureSample>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        var deleted = 0
        for row in rows where row.semanticStatus != "plausible_unverified_scale" || row.schemaField != Self.skinTemperatureSchemaField {
            modelContext.delete(row)
            deleted += 1
        }
        if deleted > 0 {
            deleteSkinTemperatureHourlySummaries()
            UserDefaults.standard.set(0, forKey: Self.skinTemperatureHourlyBackfillKey)
            try? modelContext.save()
            logInfo("Removed \(deleted) implausible skin temperature candidate\(deleted == 1 ? "" : "s")", tag: "SYNC")
        }
        UserDefaults.standard.set(Self.skinTemperatureCleanupVersion, forKey: Self.skinTemperatureCleanupKey)
    }

    private func backfillSkinTemperatureHourlySummariesIfNeeded() {
        let version = UserDefaults.standard.integer(forKey: Self.skinTemperatureHourlyBackfillKey)
        guard version < Self.skinTemperatureHourlyBackfillVersion else { return }

        deleteSkinTemperatureHourlySummaries()

        let descriptor = FetchDescriptor<SkinTemperatureSample>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        for row in rows where row.semanticStatus == "plausible_unverified_scale" && row.schemaField == Self.skinTemperatureSchemaField {
            guard let celsius = row.celsius else { continue }
            updateSkinTemperatureHourlySummary(celsius: celsius, rawU16: row.rawU16LE, at: row.timestamp)
        }

        try? modelContext.save()
        UserDefaults.standard.set(Self.skinTemperatureHourlyBackfillVersion, forKey: Self.skinTemperatureHourlyBackfillKey)
    }

    private func deleteSkinTemperatureHourlySummaries() {
        let descriptor = FetchDescriptor<SkinTemperatureHourlySummary>()
        let summaries = (try? modelContext.fetch(descriptor)) ?? []
        for summary in summaries {
            modelContext.delete(summary)
        }
    }

    private func backfillSleepWindowSummariesIfNeeded() {
        let version = UserDefaults.standard.integer(forKey: Self.sleepWindowBackfillKey)
        guard version < Self.sleepWindowBackfillVersion else { return }

        let bucketSeconds = Self.sleepWindowBucketSeconds
        let descriptor = FetchDescriptor<MotionBucketSummary>(
            predicate: #Predicate { $0.bucketSeconds == bucketSeconds },
            sortBy: [SortDescriptor(\.bucketStart)]
        )
        let buckets = (try? modelContext.fetch(descriptor)) ?? []
        guard !buckets.isEmpty else { return }

        let calendar = Calendar.current
        var days = Set<Date>()
        for bucket in buckets {
            let day = calendar.startOfDay(for: bucket.bucketStart)
            days.insert(day)
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: day) {
                days.insert(nextDay)
            }
        }

        for day in days.sorted() {
            refreshSleepWindowSummary(forWakeDay: day)
            rebuildMonthlySummary(for: day)
        }
        try? modelContext.save()
        UserDefaults.standard.set(Self.sleepWindowBackfillVersion, forKey: Self.sleepWindowBackfillKey)
        backfillRecoverySummariesIfNeeded()
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
            rrSessionSamples += 1
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
        updateHourlySummaryHRV(rmssd, at: now)
        refreshSleepWindowSummariesAround(now)
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
