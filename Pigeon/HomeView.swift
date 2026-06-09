import SwiftUI
import Charts
import SwiftData

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

                            NavigationLink {
                                MotionDetailView()
                            } label: {
                                MotionCard()
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

// MARK: - Motion

private enum MotionRange: String, CaseIterable, Identifiable {
    case day = "D"
    case week = "W"
    case month = "M"

    var id: String { rawValue }

    static let homeWindowSeconds: TimeInterval = 12 * 60 * 60

    var dayCount: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    var xStride: HealthXStride {
        switch self {
        case .day: return HealthXStride(component: .hour, count: 6)
        case .week: return HealthXStride(component: .day, count: 2)
        case .month: return HealthXStride(component: .day, count: 7)
        }
    }

    var xFormat: Date.FormatStyle {
        switch self {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day()
        }
    }

    var tooltipDateFormat: Date.FormatStyle {
        switch self {
        case .day: return .dateTime.hour().minute()
        case .week, .month: return .dateTime.month(.abbreviated).day().year()
        }
    }

    var bucketSeconds: TimeInterval {
        switch self {
        case .day: return 10 * 60
        case .week: return 60 * 60
        case .month: return 6 * 60 * 60
        }
    }

    var dateWindow: (start: Date, end: Date) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        switch self {
        case .day:
            let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
            return (todayStart, end)
        case .week, .month:
            let start = cal.date(byAdding: .day, value: -(dayCount - 1), to: todayStart) ?? todayStart
            let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
            return (start, end)
        }
    }

    var dateRangeText: String {
        let window = dateWindow
        switch self {
        case .day:
            return window.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week, .month:
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: window.end) ?? window.end
            return "\(window.start.formatted(.dateTime.month(.abbreviated).day())) - \(lastDay.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
    }
}

private struct MotionStats {
    static let stillMeanDeltaThresholdG = 0.03
    static let stillRMSThresholdG = 0.08

    let samples: [MotionSample]
    let stillCount: Int
    let averageMotionG: Double
    let maxSpikeG: Double

    var sampleCount: Int { samples.count }
    var stillnessPercent: Double? {
        guard !samples.isEmpty else { return nil }
        return Double(stillCount) * 100.0 / Double(samples.count)
    }
    var firstSample: MotionSample? { samples.first }
    var lastSample: MotionSample? { samples.last }

    static func make(from samples: [MotionSample]) -> MotionStats {
        let still = samples.filter(isStill).count
        let avg = samples.isEmpty ? 0 : samples.map(\.meanDeltaG).reduce(0, +) / Double(samples.count)
        let maxSpike = samples.map(\.maxDeltaG).max() ?? 0
        return MotionStats(samples: samples, stillCount: still, averageMotionG: avg, maxSpikeG: maxSpike)
    }

    static func isStill(_ sample: MotionSample) -> Bool {
        sample.meanDeltaG < stillMeanDeltaThresholdG && sample.rmsDeviationG < stillRMSThresholdG
    }
}

private struct MotionChartPoint: Identifiable {
    let date: Date
    let value: Double
    let maxSpikeG: Double
    var id: Date { date }
}

struct MotionCard: View {
    @Query private var rows: [MotionSample]

    init() {
        let start = Date().addingTimeInterval(-MotionRange.homeWindowSeconds)
        _rows = Query(
            filter: #Predicate<MotionSample> { $0.timestamp >= start },
            sort: \.timestamp
        )
    }

    private var stats: MotionStats {
        MotionStats.make(from: rows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bed.double.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("Motion")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Spacer()
                Text("12h")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STILLNESS")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(stillnessText)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
                miniChart
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

    private var stillnessText: String {
        guard let value = stats.stillnessPercent else { return "—" }
        return "\(Int(value.rounded()))"
    }

    @ViewBuilder
    private var miniChart: some View {
        let sparkRows = Array(rows.suffix(40))
        if sparkRows.count >= 2 {
            Chart {
                ForEach(sparkRows, id: \.timestamp) { row in
                    LineMark(
                        x: .value("Time", row.timestamp),
                        y: .value("Motion", row.meanDeltaG)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 150, height: 44)
        } else {
            Color.clear.frame(width: 150, height: 44)
        }
    }
}

struct MotionDetailView: View {
    @State private var range: MotionRange = .day

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(MotionRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                MotionDetailBody(range: range).id(range)

                HealthOptionsSection(
                    unitText: "g",
                    showAllData: { MotionSampleTableView() },
                    unitPicker: { HealthUnitPickerView(title: "Motion Unit", unit: "g") }
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Motion")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MotionDetailBody: View {
    let range: MotionRange
    @Query private var rows: [MotionSample]
    private let startDate: Date
    private let endDate: Date

    init(range: MotionRange) {
        self.range = range
        let window = range.dateWindow
        self.startDate = window.start
        self.endDate = window.end
        let start = window.start
        let end = window.end
        _rows = Query(
            filter: #Predicate<MotionSample> { $0.timestamp >= start && $0.timestamp < end },
            sort: \.timestamp
        )
    }

    private var stats: MotionStats {
        MotionStats.make(from: rows)
    }

    private var chartPoints: [MotionChartPoint] {
        MotionBuckets.points(from: rows, bucketSeconds: range.bucketSeconds)
    }

    private var xDomain: ClosedRange<Date> {
        startDate...endDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            chartHeader
            movementChart
            summaryGrid
        }
    }

    private var chartHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MOVEMENT")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(stillnessText)
                    .font(.system(size: 36, weight: .bold))
                    .monospacedDigit()
                Text("% still")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            Text(rangeText)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var movementChart: some View {
        if chartPoints.count >= 2 {
            Chart(chartPoints) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Mean delta", point.value)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXScale(domain: xDomain)
            .chartYAxis {
                AxisMarks(position: .trailing)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: range.xStride.component, count: range.xStride.count)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: range.xFormat)
                }
            }
            .frame(height: 280)
        } else {
            ContentUnavailableView(
                "No Motion Data",
                systemImage: "bed.double",
                description: Text("Leave Pigeon connected while wearing WHOOP to collect overnight motion.")
            )
            .frame(minHeight: 220)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            MotionSummaryTile(title: "Samples", value: "\(stats.sampleCount)", unit: nil)
            MotionSummaryTile(title: "Avg Motion", value: MotionFormat.g(stats.averageMotionG), unit: nil)
            MotionSummaryTile(title: "Max Spike", value: MotionFormat.g(stats.maxSpikeG), unit: nil)
            MotionSummaryTile(title: "Window", value: sampleWindowText, unit: nil)
        }
    }

    private var stillnessText: String {
        guard let value = stats.stillnessPercent else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private var rangeText: String {
        guard let first = stats.firstSample, let last = stats.lastSample else {
            return "No samples for \(range.dateRangeText)"
        }
        return "\(first.timestamp.formatted(date: .omitted, time: .shortened)) - \(last.timestamp.formatted(date: .omitted, time: .shortened))"
    }

    private var sampleWindowText: String {
        guard let first = stats.firstSample, let last = stats.lastSample else { return "—" }
        let minutes = Int(last.timestamp.timeIntervalSince(first.timestamp) / 60)
        if minutes < 60 { return "\(max(minutes, 0))m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct MotionSummaryTile: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private enum MotionFormat {
    static func g(_ value: Double) -> String {
        String(format: "%.3fg", value)
    }
}

private enum MotionBuckets {
    static func points(from samples: [MotionSample], bucketSeconds: TimeInterval) -> [MotionChartPoint] {
        guard bucketSeconds > 0 else { return [] }

        var buckets: [TimeInterval: (sum: Double, count: Int, maxSpike: Double)] = [:]
        for sample in samples {
            let bucket = floor(sample.timestamp.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
            var current = buckets[bucket] ?? (sum: 0, count: 0, maxSpike: 0)
            current.sum += sample.meanDeltaG
            current.count += 1
            current.maxSpike = max(current.maxSpike, sample.maxDeltaG)
            buckets[bucket] = current
        }

        return buckets
            .sorted { $0.key < $1.key }
            .map { bucket, value in
                MotionChartPoint(
                    date: Date(timeIntervalSince1970: bucket),
                    value: value.count > 0 ? value.sum / Double(value.count) : 0,
                    maxSpikeG: value.maxSpike
                )
            }
    }
}
