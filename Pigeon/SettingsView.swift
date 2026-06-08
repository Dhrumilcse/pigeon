import SwiftUI
import CoreBluetooth
import Charts
import SwiftData

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
                        HRVAboutView()
                    } label: {
                        SettingsRow(icon: "waveform.path.ecg", iconColor: .purple, title: "Heart Rate Variability")
                    }
                }

                Section {
                    NavigationLink {
                        SamplesListView(bluetooth: bluetooth)
                    } label: {
                        SettingsRow(icon: "chart.bar.fill", iconColor: .pink, title: "Samples")
                    }

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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                RRStatusBanner(bluetooth: bluetooth, now: context.date)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let entries = filteredEntries
                    if entries.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(entries) { entry in
                            DebugLogRow(entry: entry)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground))
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

private struct RRStatusBanner: View {
    @ObservedObject var bluetooth: BluetoothManager
    let now: Date

    private static let rrFreshnessSeconds: TimeInterval = 5
    private static let hrFreshnessSeconds: TimeInterval = 5

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text("RR")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var rrAge: TimeInterval? {
        bluetooth.lastRRReceivedAt.map { now.timeIntervalSince($0) }
    }

    private var hrAge: TimeInterval? {
        bluetooth.lastHeartRateUpdate.map { now.timeIntervalSince($0) }
    }

    private var dotColor: Color {
        if let age = rrAge, age < Self.rrFreshnessSeconds { return .green }
        if let age = hrAge, age < Self.hrFreshnessSeconds { return .orange }
        return Color(.systemGray3)
    }

    private var statusText: String {
        switch (rrAge, hrAge) {
        case (let rr?, _) where rr < Self.rrFreshnessSeconds:
            return "flowing"
        case (let rr?, let hr?) where hr < Self.hrFreshnessSeconds:
            return "gated by strap (last seen \(formatAge(rr)))"
        case (nil, let hr?) where hr < Self.hrFreshnessSeconds:
            return "gated by strap (no RR yet this session)"
        case (_, nil), (_, _?):
            return "waiting — no HR stream"
        }
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s ago" }
        let m = Int(seconds / 60)
        return "\(m)m ago"
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
        .background(rowBackground)
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

    private var rowBackground: Color {
        switch entry.level {
        case .err: return Color.red.opacity(0.06)
        case .warn: return Color.orange.opacity(0.06)
        default: return .clear
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

// MARK: - Samples

struct SamplesListView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        List {
            Section {
                NavigationLink {
                    HeartRateChartView(bluetooth: bluetooth)
                } label: {
                    SettingsRow(icon: "heart.fill", iconColor: .red, title: "Heart Rate")
                }
                NavigationLink {
                    HRVChartView(bluetooth: bluetooth)
                } label: {
                    SettingsRow(icon: "waveform.path.ecg", iconColor: .purple, title: "Heart Rate Variability")
                }
            } footer: {
                Text("Sample streams collected by the app. HR is captured every second the strap is connected; HRV (RMSSD) is computed from R-R intervals when the strap is confident in beat detection.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Samples")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum SampleTimeRange: String, CaseIterable, Identifiable {
    // Raw HRSample / HRVSample — sub-day resolution
    case thirtyMin  = "30m"
    case oneHour    = "1h"
    case fourHours  = "4h"
    case eightHours = "8h"
    // DailySummary — one bar per calendar day
    case sevenDays   = "7d"
    case thirtyDays  = "30d"
    // MonthlySummary — one bar per calendar month
    case twelveMonths = "12m"

    var id: String { rawValue }

    enum Granularity { case raw, daily, monthly }
    var granularity: Granularity {
        switch self {
        case .thirtyMin, .oneHour, .fourHours, .eightHours: return .raw
        case .sevenDays, .thirtyDays:                        return .daily
        case .twelveMonths:                                  return .monthly
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .thirtyMin:    return 30 * 60
        case .oneHour:      return 60 * 60
        case .fourHours:    return 4 * 60 * 60
        case .eightHours:   return 8 * 60 * 60
        case .sevenDays:    return 7 * 24 * 60 * 60
        case .thirtyDays:   return 30 * 24 * 60 * 60
        case .twelveMonths: return 365 * 24 * 60 * 60
        }
    }

    var bucketCount: Int {
        switch self {
        case .thirtyMin:  return 30
        case .oneHour:    return 30
        case .fourHours:  return 24
        case .eightHours: return 32
        case .sevenDays, .thirtyDays, .twelveMonths: return 0 // unused — summary rows are already bucketed
        }
    }
}

struct HRBucket: Identifiable {
    let start: Date
    let bpm: Double
    let sampleCount: Int
    var id: Date { start }
}

struct HeartRateChartView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var range: SampleTimeRange = .thirtyMin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Range", selection: $range) {
                    ForEach(SampleTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                switch range.granularity {
                case .raw:
                    HRChartBody(range: range).id(range)
                case .daily:
                    DailyHRChartBody(range: range).id(range)
                case .monthly:
                    MonthlyHRChartBody().id(range)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HRChartBody: View {
    let range: SampleTimeRange
    let rangeStart: Date
    @Query private var samples: [HRSample]

    init(range: SampleTimeRange) {
        self.range = range
        let start = Date().addingTimeInterval(-range.seconds)
        self.rangeStart = start
        _samples = Query(
            filter: #Predicate<HRSample> { $0.timestamp >= start },
            sort: \.timestamp
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.primary)
                Text("bpm")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Time", bucket.start),
                y: .value("HR", bucket.bpm),
                width: .fixed(8)
            )
            .foregroundStyle(Color.red)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
    }

    private var footer: some View {
        HStack {
            Text(coverageText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: derived

    private var buckets: [HRBucket] {
        guard !samples.isEmpty else { return [] }
        let now = Date()
        let count = range.bucketCount
        let width = range.seconds / Double(count)

        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)

        for sample in samples {
            let offset = sample.timestamp.timeIntervalSince(rangeStart)
            guard offset >= 0, sample.timestamp <= now else { continue }
            let idx = min(count - 1, Int(offset / width))
            sums[idx] += Double(sample.bpm)
            counts[idx] += 1
        }

        return (0..<count).compactMap { i in
            guard counts[i] > 0 else { return nil }
            let bucketStart = rangeStart.addingTimeInterval(Double(i) * width)
            return HRBucket(start: bucketStart, bpm: sums[i] / Double(counts[i]), sampleCount: counts[i])
        }
    }

    private var samplesInRange: Int {
        buckets.reduce(0) { $0 + $1.sampleCount }
    }

    private var averageText: String {
        guard samplesInRange > 0 else { return "—" }
        let totalSum = buckets.reduce(0.0) { $0 + $1.bpm * Double($1.sampleCount) }
        return "\(Int((totalSum / Double(samplesInRange)).rounded()))"
    }

    private var subtitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: rangeStart)) – \(formatter.string(from: Date()))"
    }

    private var coverageText: String {
        let expected = Int(range.seconds) // ~1 sample/sec
        let got = samplesInRange
        guard expected > 0 else { return "" }
        let pct = min(100, Int(Double(got) / Double(expected) * 100))
        return "\(got) / \(expected) samples · \(pct)% coverage"
    }
}

// MARK: - HR daily/monthly chart bodies (read from summary tables)

private struct DailyHRChartBody: View {
    let range: SampleTimeRange
    @Query private var rows: [DailySummary]

    init(range: SampleTimeRange) {
        self.range = range
        let cutoff = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-range.seconds)
        )
        _rows = Query(
            filter: #Predicate<DailySummary> { $0.date >= cutoff },
            sort: \.date
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var withData: [DailySummary] { rows.filter { $0.hrSampleCount > 0 } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DAILY AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                Text("bpm")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(withData) { row in
            BarMark(
                x: .value("Day", row.date, unit: .day),
                y: .value("Avg HR", row.avgHR)
            )
            .foregroundStyle(Color.red)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: strideCount)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    private var strideCount: Int { range == .sevenDays ? 1 : 5 }

    private var footer: some View {
        Text("\(withData.count) days with data · \(rows.count) days in range")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var averageText: String {
        guard !withData.isEmpty else { return "—" }
        let avg = withData.map(\.avgHR).reduce(0, +) / Double(withData.count)
        return "\(Int(avg.rounded()))"
    }
}

private struct MonthlyHRChartBody: View {
    @Query(sort: \MonthlySummary.yearMonth) private var rows: [MonthlySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var withData: [MonthlySummary] { rows.filter { $0.dayCount > 0 } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MONTHLY AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                Text("bpm")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(withData) { row in
            BarMark(
                x: .value("Month", row.yearMonth, unit: .month),
                y: .value("Avg HR", row.avgHR)
            )
            .foregroundStyle(Color.red)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    private var footer: some View {
        Text("\(withData.count) months with data")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var averageText: String {
        guard !withData.isEmpty else { return "—" }
        let avg = withData.map(\.avgHR).reduce(0, +) / Double(withData.count)
        return "\(Int(avg.rounded()))"
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
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate Variability")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - HRV chart

struct HRVBucket: Identifiable {
    let start: Date
    let rmssd: Double
    let sampleCount: Int
    var id: Date { start }
}

struct HRVChartView: View {
    @ObservedObject var bluetooth: BluetoothManager
    @State private var range: SampleTimeRange = .thirtyMin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Range", selection: $range) {
                    ForEach(SampleTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                switch range.granularity {
                case .raw:
                    HRVChartBody(range: range).id(range)
                case .daily:
                    DailyHRVChartBody(range: range).id(range)
                case .monthly:
                    MonthlyHRVChartBody().id(range)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate Variability")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HRVChartBody: View {
    let range: SampleTimeRange
    let rangeStart: Date
    @Query private var samples: [HRVSample]

    init(range: SampleTimeRange) {
        self.range = range
        let start = Date().addingTimeInterval(-range.seconds)
        self.rangeStart = start
        _samples = Query(
            filter: #Predicate<HRVSample> { $0.timestamp >= start },
            sort: \.timestamp
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.primary)
                Text("ms")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Time", bucket.start),
                y: .value("RMSSD", bucket.rmssd),
                width: .fixed(8)
            )
            .foregroundStyle(Color.purple)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis(.hidden)
    }

    private var footer: some View {
        HStack {
            Text(coverageText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var buckets: [HRVBucket] {
        guard !samples.isEmpty else { return [] }
        let now = Date()
        let count = range.bucketCount
        let width = range.seconds / Double(count)

        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)

        for sample in samples {
            let offset = sample.timestamp.timeIntervalSince(rangeStart)
            guard offset >= 0, sample.timestamp <= now else { continue }
            let idx = min(count - 1, Int(offset / width))
            sums[idx] += sample.rmssdMS
            counts[idx] += 1
        }

        return (0..<count).compactMap { i in
            guard counts[i] > 0 else { return nil }
            let bucketStart = rangeStart.addingTimeInterval(Double(i) * width)
            return HRVBucket(start: bucketStart, rmssd: sums[i] / Double(counts[i]), sampleCount: counts[i])
        }
    }

    private var samplesInRange: Int {
        buckets.reduce(0) { $0 + $1.sampleCount }
    }

    private var averageText: String {
        guard samplesInRange > 0 else { return "—" }
        let totalSum = buckets.reduce(0.0) { $0 + $1.rmssd * Double($1.sampleCount) }
        return "\(Int((totalSum / Double(samplesInRange)).rounded()))"
    }

    private var subtitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: rangeStart)) – \(formatter.string(from: Date()))"
    }

    private var coverageText: String {
        "\(samplesInRange) HRV readings"
    }
}

// MARK: - HRV daily/monthly chart bodies (read from summary tables)

private struct DailyHRVChartBody: View {
    let range: SampleTimeRange
    @Query private var rows: [DailySummary]

    init(range: SampleTimeRange) {
        self.range = range
        let cutoff = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-range.seconds)
        )
        _rows = Query(
            filter: #Predicate<DailySummary> { $0.date >= cutoff },
            sort: \.date
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var withHRV: [DailySummary] { rows.filter { $0.hrvSampleCount > 0 } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DAILY AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                Text("ms")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(withHRV) { row in
            BarMark(
                x: .value("Day", row.date, unit: .day),
                y: .value("Avg HRV", row.avgHRV ?? 0)
            )
            .foregroundStyle(Color.purple)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: strideCount)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    private var strideCount: Int { range == .sevenDays ? 1 : 5 }

    private var footer: some View {
        Text("\(withHRV.count) days with HRV data")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var averageText: String {
        let vals = withHRV.compactMap(\.avgHRV)
        guard !vals.isEmpty else { return "—" }
        return "\(Int((vals.reduce(0, +) / Double(vals.count)).rounded()))"
    }
}

private struct MonthlyHRVChartBody: View {
    @Query(sort: \MonthlySummary.yearMonth) private var rows: [MonthlySummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            footer
        }
    }

    private var withHRV: [MonthlySummary] { rows.filter { $0.daysWithHRV > 0 } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MONTHLY AVERAGE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(averageText)
                    .font(.system(size: 32, weight: .bold))
                Text("ms")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chart: some View {
        Chart(withHRV) { row in
            BarMark(
                x: .value("Month", row.yearMonth, unit: .month),
                y: .value("Avg HRV", row.avgHRV)
            )
            .foregroundStyle(Color.purple)
            .cornerRadius(2)
        }
        .frame(height: 220)
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    private var footer: some View {
        Text("\(withHRV.count) months with HRV data")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var averageText: String {
        guard !withHRV.isEmpty else { return "—" }
        let avg = withHRV.map(\.avgHRV).reduce(0, +) / Double(withHRV.count)
        return "\(Int(avg.rounded()))"
    }
}
