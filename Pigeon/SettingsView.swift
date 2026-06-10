import SwiftUI

struct SettingsView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WhoopDetailView(bluetooth: bluetooth)
                    } label: {
                        ConnectionRow(bluetooth: bluetooth)
                    }
                }

                Section {
                    NavigationLink {
                        GeneralView(bluetooth: bluetooth)
                    } label: {
                        SettingsRow(icon: "gearshape.fill", iconColor: .gray, title: "General")
                    }

                    NavigationLink {
                        BatteryView(bluetooth: bluetooth)
                    } label: {
                        SettingsRow(icon: "battery.100", iconColor: .green, title: "Battery")
                    }
                }

                Section("Calculations") {
                    NavigationLink {
                        HeartRateAboutView()
                    } label: {
                        SettingsRow(icon: "heart.fill", iconColor: .red, title: "Heart Rate")
                    }

                    NavigationLink {
                        HRVAboutView()
                    } label: {
                        SettingsRow(icon: "waveform.path.ecg", iconColor: .purple, title: "Heart Rate Variability")
                    }

                    NavigationLink {
                        SleepWindowAboutView()
                    } label: {
                        SettingsRow(icon: "moon.zzz.fill", iconColor: .indigo, title: "Sleep Window")
                    }
                }

                Section {
                    NavigationLink {
                        LocalStorageView()
                    } label: {
                        SettingsRow(icon: "cylinder.split.1x2", iconColor: .blue, title: "Local Storage")
                    }

                    NavigationLink {
                        DebugView(bluetooth: bluetooth)
                    } label: {
                        SettingsRow(icon: "hammer.fill", iconColor: .gray, title: "Debug")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - WHOOP detail (connect / scan / disconnect)

struct WhoopDetailView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        List {
            Section {
                ConnectionRow(bluetooth: bluetooth)
            }

            if bluetooth.connectionState == .connected {
                Section {
                    Button {
                        bluetooth.sendHistoricalSync()
                    } label: {
                        HStack {
                            Label(syncButtonTitle, systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if bluetooth.historicalSyncInProgress {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(bluetooth.historicalSyncInProgress)
                } footer: {
                    Text(syncFooterText)
                }

                Section {
                    Button(role: .destructive) {
                        bluetooth.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            } else {
                if bluetooth.bluetoothState != .poweredOn {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(bluetoothStatusText)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        if bluetooth.isScanning {
                            bluetooth.stopScanning()
                        } else {
                            bluetooth.startScanning()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if bluetooth.isScanning {
                                ProgressView().controlSize(.small)
                                Text("Scanning…")
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Scan for Devices")
                            }
                        }
                    }
                    .disabled(bluetooth.bluetoothState != .poweredOn)
                }

                if !bluetooth.discoveredDevices.isEmpty {
                    Section("Devices") {
                        ForEach(bluetooth.discoveredDevices) { device in
                            DiscoveredDeviceRow(device: device) {
                                bluetooth.stopScanning()
                                bluetooth.connect(to: device)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("WHOOP")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var syncButtonTitle: String {
        if bluetooth.historicalSyncInProgress {
            return "Syncing… \(bluetooth.historicalSyncPackets) packet\(bluetooth.historicalSyncPackets == 1 ? "" : "s")"
        }
        return "Sync History"
    }

    private var syncFooterText: String {
        if bluetooth.historicalSyncInProgress {
            return "Draining buffered K=18 pages from the strap. Watch the debug log for HIST/META."
        }
        if let last = bluetooth.lastHistoricalSyncAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Last synced \(formatter.localizedString(for: last, relativeTo: Date()))."
        }
        return "Never synced. Asks the strap to dump buffered history."
    }

    private var bluetoothStatusText: String {
        switch bluetooth.bluetoothState {
        case .poweredOff: return "Bluetooth is turned off"
        case .unsupported: return "Bluetooth is not supported"
        default: return "Bluetooth unavailable"
        }
    }
}

// MARK: - Row primitives

struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(iconColor)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                )

            Text(title)
                .font(.system(size: 17))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }
}

struct ConnectionRow: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: 48, height: 48)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                Text(secondaryText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusDot
        }
        .padding(.vertical, 6)
    }

    private var primaryText: String {
        if let device = bluetooth.connectedDevice {
            return device.name
        }
        return "WHOOP"
    }

    private var secondaryText: String {
        switch bluetooth.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        }
    }

    private var statusDot: some View {
        let color: Color = {
            switch bluetooth.connectionState {
            case .connected: return .green
            case .connecting: return .orange
            case .disconnected: return .secondary.opacity(0.4)
            }
        }()
        return Circle().fill(color).frame(width: 10, height: 10)
    }
}

struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                    Text(detailText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var detailText: String {
        if let rssi = device.rssi {
            return "\(rssi) dBm"
        }
        return "Already connected"
    }
}

// MARK: - General (device info + battery)

struct GeneralView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        List {
            Section("Device") {
                LabeledRow(label: "Name", value: bluetooth.connectedDevice?.name ?? "—")
                LabeledRow(label: "Manufacturer", value: bluetooth.manufacturerName ?? "—")
                LabeledRow(label: "Model", value: bluetooth.modelNumber ?? "—")
                LabeledRow(label: "Serial Number", value: bluetooth.serialNumber ?? "—")
            }

            Section("Versions") {
                LabeledRow(label: "Hardware", value: bluetooth.hardwareRevision ?? "—")
                LabeledRow(label: "Firmware", value: bluetooth.firmwareRevision ?? "—")
                LabeledRow(label: "Software", value: bluetooth.softwareRevision ?? "—")
            }

            Section("Identifiers") {
                LabeledRow(label: "System ID", value: bluetooth.systemID ?? "—")
                LabeledRow(label: "PnP ID", value: bluetooth.pnpID ?? "—")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Battery

struct BatteryView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        List {
            Section {
                LabeledRow(
                    label: "Level",
                    value: bluetooth.batteryLevel.map { "\($0)%" } ?? "—"
                )
            } footer: {
                Text("Read from the standard Battery Service (0x180F) on the WHOOP.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Debug

enum DebugLogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case tx = "Transmit"
    case rx = "Receive"
    case errors = "Errors"

    var id: String { rawValue }

    func matches(_ entry: DebugLogEntry) -> Bool {
        switch self {
        case .all: return true
        case .tx: return entry.level == .tx
        case .rx: return entry.level == .rx
        case .errors: return entry.level == .err || entry.level == .warn
        }
    }
}

struct DebugView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var filter: DebugLogFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(DebugLogFilter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))

            DebugMetricCards(bluetooth: bluetooth)

            List {
                let entries = filteredEntries
                if entries.isEmpty {
                    Section {
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                } else {
                    Section {
                        ForEach(entries) { entry in
                            DebugLogRow(entry: entry)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(rowBackground(for: entry.level))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportedLog, preview: SharePreview("Pigeon debug log")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(bluetooth.debugLog.isEmpty)
            }
        }
    }

    private func rowBackground(for level: DebugLogEntry.Level) -> Color {
        switch level {
        case .err: return Color.red.opacity(0.08)
        case .warn: return Color.orange.opacity(0.08)
        default: return Color(.secondarySystemGroupedBackground)
        }
    }

    private var filteredEntries: [DebugLogEntry] {
        bluetooth.debugLog.reversed().filter(filter.matches)
    }

    private var emptyText: String {
        bluetooth.debugLog.isEmpty ? "No debug messages yet" : "No entries match \(filter.rawValue)"
    }

    private var exportedLog: String {
        bluetooth.debugLog.map { entry in
            let time = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
            let tag = entry.tag.map { " [\($0)]" } ?? ""
            let hex = entry.hex.map { "\n    \($0)" } ?? ""
            return "\(time) \(levelToken(entry.level))\(tag) \(entry.message)\(hex)"
        }.joined(separator: "\n")
    }

    private func levelToken(_ level: DebugLogEntry.Level) -> String {
        switch level {
        case .info: return "INFO    "
        case .ok:   return "OK      "
        case .tx:   return "TRANSMIT"
        case .rx:   return "RECEIVE "
        case .warn: return "WARN    "
        case .err:  return "ERR     "
        }
    }
}

private struct DebugMetricCards: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        HStack(spacing: 10) {
            DebugMetricCard(icon: "waveform.path.ecg", value: "\(bluetooth.rrSessionSamples)", tint: .purple)
                .accessibilityLabel("RR samples")
                .accessibilityValue("\(bluetooth.rrSessionSamples)")

            DebugMetricCard(icon: "clock.arrow.circlepath", value: "\(bluetooth.historicalSyncPackets)", tint: .blue)
                .accessibilityLabel("Historical sync packets")
                .accessibilityValue("\(bluetooth.historicalSyncPackets)")

            Button {
                bluetooth.startMotionProbe()
            } label: {
                DebugMetricCard(icon: "figure.walk.motion", value: "\(bluetooth.motionProbeFrames)", tint: .orange)
            }
            .buttonStyle(.plain)
            .disabled(bluetooth.connectionState != .connected || bluetooth.motionProbeInProgress)
            .accessibilityLabel("Motion probe frames")
            .accessibilityValue("\(bluetooth.motionProbeFrames)")

            Button {
                bluetooth.stopMotionProbe()
            } label: {
                DebugMetricCard(icon: bluetooth.motionProbeInProgress ? "stop.fill" : nil, value: nil, tint: .red)
            }
            .buttonStyle(.plain)
            .disabled(!bluetooth.motionProbeInProgress)
            .accessibilityLabel("Stop motion probe")
        }
        .padding(.horizontal, Layout.screenHMargin)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
    }
}

private struct DebugMetricCard: View {
    let icon: String?
    let value: String?
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }

            if let value {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct DebugLogRow: View {
    let entry: DebugLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(levelColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    LevelPill(level: entry.level)
                    if let tag = entry.tag {
                        Text(tag)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(timestampText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Text(entry.message)
                    .font(.system(size: 14))
                    .foregroundColor(messageColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                if let hex = entry.hex {
                    Text(hex)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
        }
    }

    private var timestampText: String {
        DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: return Color(.systemGray3)
        case .ok: return .green
        case .tx: return .blue
        case .rx: return Color(.systemTeal)
        case .warn: return .orange
        case .err: return .red
        }
    }

    private var messageColor: Color {
        switch entry.level {
        case .err: return .red
        case .warn: return .orange
        default: return .primary
        }
    }
}

private struct LevelPill: View {
    let level: DebugLogEntry.Level

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
            )
    }

    private var label: String {
        switch level {
        case .info: return "INFO"
        case .ok: return "OK"
        case .tx: return "TRANSMIT"
        case .rx: return "RECEIVE"
        case .warn: return "WARN"
        case .err: return "ERR"
        }
    }

    private var background: Color {
        switch level {
        case .info: return Color(.systemGray)
        case .ok: return .green
        case .tx: return .blue
        case .rx: return Color(.systemTeal)
        case .warn: return .orange
        case .err: return .red
        }
    }
}

// MARK: - About Heart Rate

struct HeartRateAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("About Heart Rate")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Heart rate is the number of times your heart beats per minute, shown as BPM. It rises and falls throughout the day as your body responds to movement, recovery, stress, sleep, temperature, and hydration.")

                    Text("Pigeon reads heart rate from the WHOOP realtime stream while the strap is connected. Each valid reading is saved as an HR sample, then rolled into hourly, daily, and monthly summaries for charts.")

                    Text("The Sync History action can also import heart rate readings stored on the strap. Those historical readings help fill gaps from times when the app was not actively connected.")

                    Text("Average heart rate is calculated from the samples in the selected time period. Short ranges use raw samples, while longer ranges use the precomputed summary rows so charts stay fast.")

                    Text("Because wrist optical sensors estimate heart rate from blood-flow changes, readings can lag during sudden effort or be noisier when the strap is loose, moving, or not making consistent contact.")
                }
                .font(.system(size: 17))
                .foregroundColor(.primary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About HRV

struct HRVAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("About Heart Rate Variability")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Heart rate variability (HRV) is the variation in time between consecutive heartbeats, measured in milliseconds. Even at a steady resting heart rate, the interval between beats is constantly fluctuating.")

                    Text("A higher HRV generally indicates a well-recovered, adaptable nervous system, while a lower HRV can reflect stress, fatigue, illness, or under-recovery.")

                    Text("HRV is driven by the balance between your sympathetic (\u{201C}fight or flight\u{201D}) and parasympathetic (\u{201C}rest and digest\u{201D}) nervous systems. The parasympathetic side, acting through the vagus nerve, is what produces most of the beat-to-beat variation you see in HRV.")

                    Text("Pigeon computes HRV using RMSSD — the root mean square of successive R-R interval differences — over the most recent valid beats reported by the strap. RMSSD is the standard short-window HRV metric and primarily reflects parasympathetic activity.")

                    Text("HRV is highly personal. Absolute values vary widely between individuals based on age, fitness, genetics, and sensor placement, so trends over time for the same person are far more meaningful than comparisons to others.")

                    Text("For the most consistent readings, HRV is best measured under similar conditions each day — for example, during sleep or in a quiet moment shortly after waking, before caffeine or activity.")
                }
                .font(.system(size: 17))
                .foregroundColor(.primary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate Variability")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About Sleep Window

struct SleepWindowAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("About Sleep Window")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Pigeon detects the main overnight sleep window as the longest high-confidence rest period that ends on the wake day. It is currently a sleep/rest window detector, not a sleep-stage classifier.")

                    Text("The detector starts from 10-minute motion summary buckets so it can stay fast. For each wake day, it searches from the previous evening through late morning, marks quiet buckets, merges short restless gaps, refines the edges with raw motion, and then uses heart rate as a confirmation signal.")

                    CalculationStep(title: "Search window", text: "For a given wake day, scan motion buckets from 6 hours before midnight through 14 hours after midnight. This catches sleep that starts the night before and ends in the morning.")

                    CalculationStep(title: "Quiet buckets", text: "A 10-minute bucket is considered still when at least 70% of its motion samples are still, or when its average movement is below the stillness threshold.")

                    CalculationStep(title: "Candidate windows", text: "Consecutive still buckets are merged into candidate windows. Short restless gaps up to 20 minutes are allowed so brief movement does not split the night. Candidates shorter than 60 minutes are ignored.")

                    CalculationStep(title: "Edge refinement", text: "For each candidate, Pigeon scans raw motion near the coarse start and end. It uses 3-minute rolling stillness windows to tighten the motion boundary, then can move the start later until heart rate and stillness remain settled for 15 minutes.")

                    CalculationStep(title: "Heart-rate check", text: "For each candidate, Pigeon compares the average heart rate inside the window against the median heart rate across the full overnight search period. Lower, steady heart rate improves confidence.")

                    CalculationStep(title: "Final score", text: "Candidates are scored using duration, stillness density, heart-rate confirmation, and overlap with the expected overnight period. The highest-confidence candidate becomes the stored SleepWindowSummary row.")

                    Text("The first pass still uses 10-minute buckets, but only the candidate edges scan raw motion. This keeps the detector efficient while reducing the 10-minute bucket-boundary fuzz.")
                }
                .font(.system(size: 17))
                .foregroundColor(.primary)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Core Logic")
                        .font(.system(size: 20, weight: .semibold))
                    Text(Self.pseudocode)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.tertiarySystemGroupedBackground))
                        )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sleep Window")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let pseudocode = """
for each wake_day:
  search_start = wake_day_midnight - 6h
  search_end   = wake_day_midnight + 14h

  buckets = fetch 10-minute motion summaries

  for each bucket:
    still_fraction = still_count / sample_count
    is_still = still_fraction >= 70%
            or avg_motion <= stillness_threshold

  candidates = merge consecutive still buckets
    allow gaps/restlessness up to 20 minutes
    discard windows shorter than 60 minutes

  for each candidate:
    refine start with raw motion near coarse start
    refine start later until HR + stillness settle for 15m
    refine end with raw motion near coarse end

  baseline_hr = median HR across search window

  for each candidate:
    candidate_hr = HR samples inside refined candidate
    avg_hr = mean(candidate_hr)

    score =
      duration_score * 25% +
      stillness_score * 35% +
      heart_rate_score * 25% +
      overnight_overlap_score * 15%

  store the highest-scoring candidate
"""
}

private struct CalculationStep: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}
