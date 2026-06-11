import SwiftUI
import Charts
import SwiftData

// RHR = unweighted mean HR during the detected sleep window (SleepWindowSummary.avgHR).

private enum RHRQuery {
    static let homeWindowDays = 7
    static let homeSparkCount = 5
    static let showAllPageSize = 50
}

private enum RHRRange: String, CaseIterable, Identifiable {
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"

    var id: String { rawValue }

    var dayCount: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .sixMonths: return 180
        case .year: return 365
        }
    }

    var xStride: HealthXStride {
        switch self {
        case .week: return HealthXStride(component: .day, count: 2)
        case .month: return HealthXStride(component: .day, count: 7)
        case .sixMonths, .year: return HealthXStride(component: .month, count: 2)
        }
    }

    var xFormat: Date.FormatStyle {
        switch self {
        case .week: return .dateTime.weekday(.abbreviated)
        case .sixMonths, .year: return .dateTime.month(.abbreviated)
        case .month: return .dateTime.day()
        }
    }

    var dateWindow: (start: Date, end: Date) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(dayCount - 1), to: todayStart) ?? todayStart
        let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
        return (start, end)
    }

    var dateRangeText: String {
        let window = dateWindow
        let startText = window.start.formatted(.dateTime.month(.abbreviated).day())
        let endText = Calendar.current.date(byAdding: .day, value: -1, to: window.end)?
            .formatted(.dateTime.month(.abbreviated).day().year()) ?? ""
        return "\(startText) – \(endText)"
    }
}

// MARK: - Home card

struct RHRCard: View {
    @Query private var recentRows: [SleepWindowSummary]

    init() {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(
            byAdding: .day,
            value: -(RHRQuery.homeWindowDays - 1),
            to: todayStart
        ) ?? todayStart
        let minimumConfidence = SleepWindowDetection.minimumConfidence
        _recentRows = Query(
            filter: #Predicate<SleepWindowSummary> {
                $0.day >= windowStart &&
                $0.day <= todayStart &&
                $0.confidence >= minimumConfidence &&
                $0.hrSampleCount > 0
            },
            sort: \SleepWindowSummary.day,
            order: .reverse
        )
    }

    private var todayStart: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var today: SleepWindowSummary? {
        recentRows.first { Calendar.current.isDate($0.day, inSameDayAs: todayStart) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.pink)
                    Text("Resting Heart Rate")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.pink)
                }
                Spacer()
                Text(dateText)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RESTING")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(rhrText(today?.avgHR))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                        Text("BPM")
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

    private var sparkData: [SleepWindowSummary] {
        Array(recentRows.prefix(RHRQuery.homeSparkCount).reversed())
    }

    private var dateText: String {
        Date().formatted(.dateTime.month(.abbreviated).day())
    }

    private func rhrText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))"
    }

    @ViewBuilder
    private var miniChart: some View {
        if sparkData.count >= 2 {
            Chart {
                ForEach(sparkData, id: \.day) { row in
                    if let value = row.avgHR {
                        LineMark(
                            x: .value("Day", row.day),
                            y: .value("RHR", value)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.pink.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 150, height: 44)
            .drawingGroup()
        } else {
            Color.clear.frame(width: 150, height: 44)
        }
    }
}

// MARK: - Detail view

struct RHRDetailView: View {
    @State private var range: RHRRange = .week

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(RHRRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                RHRDetailBody(range: range).id(range)

                HealthOptionsSection(
                    unitText: "BPM",
                    showAllData: { ShowAllRHRDataView() },
                    unitPicker: { HealthUnitPickerView(title: "RHR Unit", unit: "BPM") }
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Resting Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RHRDetailBody: View {
    let range: RHRRange
    @Query private var rows: [SleepWindowSummary]
    private let startDate: Date
    private let endDate: Date

    init(range: RHRRange) {
        self.range = range
        let window = range.dateWindow
        self.startDate = window.start
        self.endDate = window.end
        let start = window.start
        let end = window.end
        let minimumConfidence = SleepWindowDetection.minimumConfidence
        _rows = Query(
            filter: #Predicate<SleepWindowSummary> {
                $0.day >= start &&
                $0.day < end &&
                $0.confidence >= minimumConfidence &&
                $0.hrSampleCount > 0
            },
            sort: \.day
        )
    }

    private var points: [HealthPoint] {
        rows.compactMap { row in
            guard let value = row.avgHR else { return nil }
            return HealthPoint(date: row.day, value: value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HealthChartContainer(
                headerLabel: "AVERAGE RHR",
                avgText: averageRHRText,
                unitLabel: "BPM",
                dateRangeText: range.dateRangeText,
                points: points,
                xDomain: startDate...endDate,
                xStride: range.xStride,
                xFormat: range.xFormat,
                tooltipDateFormat: .dateTime.month(.abbreviated).day().year(),
                tint: .pink,
                yStep: 5
            )
            latestSummary
        }
    }

    private var latestSummary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            RHRSummaryTile(title: "Latest", value: latestRHRText, unit: "BPM")
            RHRSummaryTile(title: "Samples", value: latestSampleText, unit: nil)
            RHRSummaryTile(title: "Confidence", value: latestConfidenceText, unit: nil)
            RHRSummaryTile(title: "Window", value: latestWindowText, unit: nil)
        }
    }

    private var latest: SleepWindowSummary? {
        rows.last
    }

    private var averageRHRText: String {
        let values = rows.compactMap(\.avgHR)
        guard !values.isEmpty else { return "—" }
        let avg = values.reduce(0, +) / Double(values.count)
        return "\(Int(avg.rounded()))"
    }

    private var latestRHRText: String {
        guard let value = latest?.avgHR else { return "—" }
        return "\(Int(value.rounded()))"
    }

    private var latestSampleText: String {
        guard let latest else { return "—" }
        return latest.hrSampleCount.formatted()
    }

    private var latestConfidenceText: String {
        guard let latest else { return "—" }
        return "\(Int((latest.confidence * 100).rounded()))%"
    }

    private var latestWindowText: String {
        guard let latest else { return "—" }
        let start = latest.start.formatted(date: .omitted, time: .shortened)
        let end = latest.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}

// MARK: - Show All Data

struct ShowAllRHRDataView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var rows: [SleepWindowSummary] = []
    @State private var hasMore = true
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if rows.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Resting Heart Rate",
                        systemImage: "heart.text.square",
                        description: Text("RHR is computed from heart rate during a detected sleep window. Wear WHOOP overnight while connected.")
                    )
                    .frame(minHeight: 260)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            RHRDataRow(row: row)
                                .onAppear {
                                    if row.persistentModelID == rows.last?.persistentModelID {
                                        loadMore()
                                    }
                                }
                            if row.persistentModelID != rows.last?.persistentModelID {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("All Recorded Data")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if rows.isEmpty && hasMore {
                loadMore()
            }
        }
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        let cursor = rows.last?.day ?? Date.distantFuture
        let minimumConfidence = SleepWindowDetection.minimumConfidence
        var descriptor = FetchDescriptor<SleepWindowSummary>(
            predicate: #Predicate<SleepWindowSummary> {
                $0.day < cursor &&
                $0.confidence >= minimumConfidence &&
                $0.hrSampleCount > 0
            },
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        descriptor.fetchLimit = RHRQuery.showAllPageSize

        do {
            let page = try modelContext.fetch(descriptor)
            rows.append(contentsOf: page)
            hasMore = page.count == RHRQuery.showAllPageSize
        } catch {
            hasMore = false
        }
    }
}

private struct RHRDataRow: View {
    let row: SleepWindowSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(rhrText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            HStack {
                Text("\(row.start.formatted(date: .omitted, time: .shortened)) – \(row.end.formatted(date: .omitted, time: .shortened))")
                Spacer()
                Text("\(row.hrSampleCount) samples")
            }
            .font(.system(size: 14))
            .foregroundColor(.secondary)
            if row.qualityFlags != "ok" {
                Text(row.qualityFlags)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }

    private var rhrText: String {
        guard let value = row.avgHR else { return "— BPM" }
        return "\(Int(value.rounded())) BPM"
    }
}

private struct RHRSummaryTile: View {
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
