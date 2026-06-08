import SwiftUI

struct HomeView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if bluetooth.connectionState == .connected {
                    ScrollView {
                        VStack(spacing: 24) {
                            LiveHeartRateReadout(bpm: bluetooth.currentHeartRate)
                                .padding(.vertical, 32)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                                MetricCard(
                                    title: "HRV",
                                    value: bluetooth.currentHRV.map { "\(Int($0.rounded())) ms" } ?? "—"
                                )
                                MetricCard(
                                    title: "Battery",
                                    value: bluetooth.batteryLevel.map { "\($0)%" } ?? "—"
                                )
                            }
                            .padding(.horizontal, 24)

                            Spacer(minLength: 24)
                        }
                        .padding(.top, 24)
                    }
                } else {
                    DisconnectedState()
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Live HR readout

private struct LiveHeartRateReadout: View {
    let bpm: Int?

    var body: some View {
        VStack(spacing: 16) {
            if let bpm {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(bpm)")
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("bpm")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 12)
                }
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Live")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("--")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(0.3))
                Text("Waiting for data")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DisconnectedState: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.secondary.opacity(0.5))
            VStack(spacing: 8) {
                Text("Not Connected")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                Text("Connect to your WHOOP in Settings")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }
}

