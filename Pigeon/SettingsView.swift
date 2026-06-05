import SwiftUI
import CoreBluetooth

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

                Section {
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
