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
                            HStack(alignment: .firstTextBaseline) {
                                Text("Home")
                                    .font(.system(size: 34, weight: .bold))
                                Spacer()
                                LiveHRPill(bpm: bluetooth.currentHeartRate)
                            }
                            .padding(.horizontal, Layout.screenHMargin)
                            .padding(.top, 8)

                            VStack(spacing: 12) {
                                NavigationLink {
                                    HeartRateDetailView()
                                } label: {
                                    HeartRateCard()
                                }
                                .buttonStyle(.plain)

                                NavigationLink {
                                    HRVDetailView()
                                } label: {
                                    HRVCard()
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Layout.screenHMargin)

                            Spacer(minLength: 24)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    DisconnectedState()
                }
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Live HR pill

private struct LiveHRPill: View {
    let bpm: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.red)
            Text(bpm.map { "\($0)" } ?? "—")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
        }
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

