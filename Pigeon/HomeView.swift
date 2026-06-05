import SwiftUI

struct HomeView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                if bluetooth.connectionState == .connected {
                    // Connected - show data
                    ScrollView {
                        VStack(spacing: 32) {
                            // Live heart rate
                            if let heartRate = bluetooth.currentHeartRate {
                                VStack(spacing: 16) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("\(heartRate)")
                                            .font(.system(size: 96, weight: .bold, design: .rounded))
                                            .foregroundColor(.primary)

                                        Text("bpm")
                                            .font(.system(size: 28, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .padding(.bottom, 12)
                                    }

                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 10, height: 10)

                                        Text("Live")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                            } else {
                                VStack(spacing: 16) {
                                    Text("--")
                                        .font(.system(size: 96, weight: .bold, design: .rounded))
                                        .foregroundColor(.secondary.opacity(0.3))

                                    Text("Waiting for data")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                            }

                            // Stats grid
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                                if let hrv = bluetooth.currentHRV {
                                    MetricCard(title: "HRV", value: "\(String(format: "%.0f", hrv)) ms")
                                } else {
                                    MetricCard(title: "HRV", value: "--")
                                }

                                if let temp = bluetooth.currentSkinTemp {
                                    MetricCard(title: "Skin Temp", value: "\(String(format: "%.1f", temp))°C")
                                } else {
                                    MetricCard(title: "Skin Temp", value: "--")
                                }

                                if let spo2 = bluetooth.currentSpO2 {
                                    MetricCard(title: "SpO2", value: "\(spo2)%")
                                } else {
                                    MetricCard(title: "SpO2", value: "--")
                                }

                                MetricCard(title: "Packets", value: "\(bluetooth.receivedPackets.count)")
                            }
                            .padding(.horizontal, 24)

                            Spacer()
                        }
                        .padding(.top, 24)
                    }
                } else {
                    // Not connected
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
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
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
