import SwiftUI
import Charts
import SwiftData

private enum RecoveryQuery {
    static let homeWindowDays = 7
    static let homeSparkCount = 5
    static let showAllPageSize = 50
}

private enum RecoveryRange: String, CaseIterable, Identifiable {
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

private func recoveryTint(for zone: RecoveryZone) -> Color {
    switch zone {
    case .green: return .green
    case .yellow: return .orange
    case .red: return .red
    case .unavailable: return .secondary
    }
}

// MARK: - Home card

struct RecoveryCard: View {
    @Query private var recentRows: [RecoverySummary]

    init() {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let windowStart = cal.date(
            byAdding: .day,
            value: -(RecoveryQuery.homeWindowDays - 1),
            to: todayStart
        ) ?? todayStart
        _recentRows = Query(
            filter: #Predicate<RecoverySummary> {
                $0.day >= windowStart && $0.day <= todayStart
            },
            sort: \RecoverySummary.day,
            order: .reverse
        )
    }

    private var todayStart: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var today: RecoverySummary? {
        recentRows.first { Calendar.current.isDate($0.day, inSameDayAs: todayStart) }
    }

    var body: some View {
        HomeScoreCard(
            icon: "bolt.heart.fill",
            tint: recoveryTint(for: today?.recoveryZone ?? .unavailable),
            title: "Recovery",
            scoreText: scoreValueText,
            unitText: "%",
            isAvailable: isScoreAvailable,
            showsChevron: true
        )
    }

    private var isScoreAvailable: Bool {
        today?.score != nil
    }

    private var scoreValueText: String {
        guard let score = today?.score else { return "" }
        return "\(score)"
    }
}

// MARK: - Detail view

struct RecoveryDetailView: View {
    @State private var range: RecoveryRange = .week

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(RecoveryRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                RecoveryDetailBody(range: range).id(range)

                HealthOptionsSection(
                    unitText: "%",
                    showAllData: { ShowAllRecoveryDataView() },
                    unitPicker: { HealthUnitPickerView(title: "Recovery Unit", unit: "%") }
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecoveryDetailBody: View {
    let range: RecoveryRange
    @Query private var rows: [RecoverySummary]
    private let startDate: Date
    private let endDate: Date

    init(range: RecoveryRange) {
        self.range = range
        let window = range.dateWindow
        self.startDate = window.start
        self.endDate = window.end
        let start = window.start
        let end = window.end
        _rows = Query(
            filter: #Predicate<RecoverySummary> {
                $0.day >= start && $0.day < end && $0.score != nil
            },
            sort: \RecoverySummary.day
        )
    }

    private var points: [HealthPoint] {
        rows.compactMap { row in
            row.score.map { HealthPoint(date: row.day, value: Double($0)) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HealthChartContainer(
                headerLabel: "RECOVERY",
                avgText: averageScoreText,
                unitLabel: "%",
                dateRangeText: range.dateRangeText,
                points: points,
                xDomain: startDate...endDate,
                xStride: range.xStride,
                xFormat: range.xFormat,
                tooltipDateFormat: .dateTime.month(.abbreviated).day().year(),
                tint: .green,
                yStep: 25
            )
            latestSummary
        }
    }

    private var latestSummary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            RecoverySummaryTile(title: "Latest", value: latestScoreText, unit: "%")
            RecoverySummaryTile(title: "Zone", value: latestZoneText, unit: nil)
            RecoverySummaryTile(title: "HRV", value: latestHRVText, unit: "ms")
            RecoverySummaryTile(title: "RHR", value: latestRHRText, unit: "BPM")
            RecoverySummaryTile(title: "Sleep", value: latestSleepText, unit: "min")
            RecoverySummaryTile(title: "Baseline days", value: latestBaselineText, unit: nil)
        }
    }

    private var latest: RecoverySummary? {
        rows.last
    }

    private var averageScoreText: String {
        let values = rows.compactMap(\.score)
        guard !values.isEmpty else { return "—" }
        let avg = values.reduce(0, +) / values.count
        return "\(avg)"
    }

    private var latestScoreText: String {
        guard let score = latest?.score else { return "—" }
        return "\(score)"
    }

    private var latestZoneText: String {
        latest?.recoveryZone.displayName ?? "—"
    }

    private var latestHRVText: String {
        guard let latest, latest.hrvMS > 0 else { return "—" }
        return "\(Int(latest.hrvMS.rounded()))"
    }

    private var latestRHRText: String {
        guard let latest, latest.rhrBPM > 0 else { return "—" }
        return "\(Int(latest.rhrBPM.rounded()))"
    }

    private var latestSleepText: String {
        guard let latest, latest.sleepMinutes > 0 else { return "—" }
        return "\(Int(latest.sleepMinutes.rounded()))"
    }

    private var latestBaselineText: String {
        guard let latest else { return "—" }
        return "\(latest.baselineDayCount)"
    }
}

private struct RecoverySummaryTile: View {
    let title: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Show All Data

struct ShowAllRecoveryDataView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var rows: [RecoverySummary] = []
    @State private var hasMore = true
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty && !hasMore {
                    Text("No recovery scores recorded.")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.persistentModelID) { idx, row in
                            RecoveryDataRow(row: row)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .onAppear {
                                    if row.persistentModelID == rows.last?.persistentModelID {
                                        loadMore()
                                    }
                                }
                            if idx < rows.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }

                if hasMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
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
        var descriptor = FetchDescriptor<RecoverySummary>(
            predicate: #Predicate<RecoverySummary> { $0.day < cursor },
            sortBy: [SortDescriptor(\.day, order: .reverse)]
        )
        descriptor.fetchLimit = RecoveryQuery.showAllPageSize

        do {
            let page = try modelContext.fetch(descriptor)
            rows.append(contentsOf: page)
            hasMore = page.count == RecoveryQuery.showAllPageSize
        } catch {
            hasMore = false
        }
    }
}

private struct RecoveryDataRow: View {
    let row: RecoverySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let score = row.score {
                    Text("\(score)%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(recoveryTint(for: row.recoveryZone))
                } else {
                    Text("Building baseline (\(row.baselineDayCount)/\(RecoveryScore.minimumBaselineDays))")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(row.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }

            if row.hrvMS > 0 || row.rhrBPM > 0 {
                HStack(spacing: 12) {
                    if row.hrvMS > 0 {
                        Text("HRV \(Int(row.hrvMS.rounded())) ms")
                    }
                    if row.rhrBPM > 0 {
                        Text("RHR \(Int(row.rhrBPM.rounded())) BPM")
                    }
                    if row.sleepMinutes > 0 {
                        Text("Sleep \(Int(row.sleepMinutes.rounded())) min")
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }
        }
    }
}
