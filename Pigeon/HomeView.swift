import SwiftUI

struct HomeView: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        HomeHeader(bluetooth: bluetooth)
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
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Home header

private struct HomeHeader: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(.system(size: 34, weight: .bold))
                    Text(statusText(now: context.date))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if bluetooth.connectionState == .connected {
                    LiveHRPill(bpm: bluetooth.currentHeartRate)
                        .padding(.top, 5)
                }
            }
        }
    }

    private func statusText(now: Date) -> String {
        "\(connectionText) • \(syncText(now: now))"
    }

    private var connectionText: String {
        switch bluetooth.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Not connected"
        }
    }

    private func syncText(now: Date) -> String {
        if bluetooth.historicalSyncInProgress {
            return "Syncing…"
        }
        guard let last = bluetooth.lastHistoricalSyncAt else {
            return "Never synced"
        }
        return "Last synced \(Self.compactRelativeTime(from: last, to: now))"
    }

    private static func compactRelativeTime(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w ago" }

        let months = days / 30
        if months < 12 { return "\(months)mo ago" }

        return "\(days / 365)y ago"
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
