import SwiftUI
import Charts
import SwiftData

// MARK: - Home card

struct HRVCard: View {
    @Query private var todayHours: [HourlySummary]

    init() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        _todayHours = Query(
            filter: #Predicate<HourlySummary> { $0.hourStart >= start && $0.hourStart < end && $0.hrvSampleCount > 0 },
            sort: \.hourStart
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.purple)
                    Text("Heart Rate Variability")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.purple)
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
                    Text("AVERAGE")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(averageText)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.primary)
                        Text("ms")
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

    private var sparkData: [HourlySummary] {
        Array(todayHours.suffix(5))
    }

    private var averageText: String {
        let withHRV = todayHours.compactMap(\.avgHRV)
        guard !withHRV.isEmpty else { return "—" }
        let avg = withHRV.reduce(0, +) / Double(withHRV.count)
        return "\(Int(avg.rounded()))"
    }

    private var dateText: String {
        Date().formatted(.dateTime.month(.abbreviated).day())
    }

    @ViewBuilder
    private var miniChart: some View {
        if sparkData.count >= 2 {
            Chart {
                ForEach(sparkData, id: \.hourStart) { row in
                    if let v = row.avgHRV {
                        LineMark(
                            x: .value("Hour", row.hourStart),
                            y: .value("HRV", v)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.purple.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    }
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

// MARK: - Detail view

struct HRVDetailView: View {
    @State private var range: HealthTimeRange = .day

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(HealthTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                switch range.source {
                case .hourly:
                    HourlyHRVChartBody().id(range)
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

// MARK: - Day (today's hourly summaries)

private struct HourlyHRVChartBody: View {
    @Query private var rows: [HourlySummary]
    private let startDate: Date
    private let endDate: Date

    init() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        self.startDate = start
        self.endDate = end
        _rows = Query(
            filter: #Predicate<HourlySummary> { $0.hourStart >= start && $0.hourStart < end && $0.hrvSampleCount > 0 },
            sort: \.hourStart
        )
    }

    private var points: [HealthPoint] {
        rows.compactMap { row in
            row.avgHRV.map { HealthPoint(date: row.hourStart, value: $0) }
        }
    }

    var body: some View {
        HealthChartContainer(
            headerLabel: "AVERAGE",
            avgText: averageText,
            unitLabel: "ms",
            dateRangeText: startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            points: points,
            xDomain: startDate...endDate,
            xStride: HealthXStride(component: .hour, count: 6),
            xFormat: .dateTime.hour(),
            tooltipDateFormat: .dateTime.hour().minute(),
            tint: .purple,
            yStep: 10
        )
    }

    private var averageText: String {
        guard !points.isEmpty else { return "—" }
        let avg = points.map(\.value).reduce(0, +) / Double(points.count)
        return "\(Int(avg.rounded()))"
    }
}

// MARK: - Week / Month / 6-Months (daily summaries)

private struct DailyHRVChartBody: View {
    let range: HealthTimeRange
    @Query private var rows: [DailySummary]
    private let startDate: Date
    private let endDate: Date

    init(range: HealthTimeRange) {
        self.range = range
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let days: Int
        switch range {
        case .week:      days = 7
        case .month:     days = 30
        case .sixMonths: days = 180
        default:         days = 30
        }
        let start = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let end = cal.date(byAdding: .day, value: 1, to: todayStart) ?? Date()
        self.startDate = start
        self.endDate = end
        _rows = Query(
            filter: #Predicate<DailySummary> { $0.date >= start && $0.date < end },
            sort: \.date
        )
    }

    private var points: [HealthPoint] {
        rows.compactMap { row in
            row.avgHRV.map { HealthPoint(date: row.date, value: $0) }
        }
    }

    var body: some View {
        HealthChartContainer(
            headerLabel: "AVERAGE",
            avgText: averageText,
            unitLabel: "ms",
            dateRangeText: dateRangeText,
            points: points,
            xDomain: startDate...endDate,
            xStride: xStride,
            xFormat: xFormat,
            tooltipDateFormat: .dateTime.month(.abbreviated).day().year(),
            tint: .purple,
            yStep: 10
        )
    }

    private var xStride: HealthXStride {
        switch range {
        case .week:      return HealthXStride(component: .day, count: 2)
        case .month:     return HealthXStride(component: .day, count: 7)
        case .sixMonths: return HealthXStride(component: .month, count: 2)
        default:         return HealthXStride(component: .day, count: 7)
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .week:      return .dateTime.weekday(.abbreviated)
        case .sixMonths: return .dateTime.month(.abbreviated)
        default:         return .dateTime.day()
        }
    }

    private var averageText: String {
        guard !points.isEmpty else { return "—" }
        let avg = points.map(\.value).reduce(0, +) / Double(points.count)
        return "\(Int(avg.rounded()))"
    }

    private var dateRangeText: String {
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: endDate) ?? endDate
        return "\(startDate.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day().year()))"
    }
}

// MARK: - Year (monthly summaries)

private struct MonthlyHRVChartBody: View {
    @Query private var rows: [MonthlySummary]
    private let startDate: Date
    private let endDate: Date

    init() {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let thisMonthStart = cal.date(from: comps) ?? now
        let end = cal.date(byAdding: .month, value: 1, to: thisMonthStart) ?? now
        let start = cal.date(byAdding: .month, value: -11, to: thisMonthStart) ?? thisMonthStart
        self.startDate = start
        self.endDate = end
        _rows = Query(
            filter: #Predicate<MonthlySummary> { $0.yearMonth >= start && $0.yearMonth < end },
            sort: \.yearMonth
        )
    }

    private var points: [HealthPoint] {
        rows.filter { $0.daysWithHRV > 0 }
            .map { HealthPoint(date: $0.yearMonth, value: $0.avgHRV) }
    }

    var body: some View {
        HealthChartContainer(
            headerLabel: "AVERAGE",
            avgText: averageText,
            unitLabel: "ms",
            dateRangeText: dateRangeText,
            points: points,
            xDomain: startDate...endDate,
            xStride: HealthXStride(component: .month, count: 3),
            xFormat: .dateTime.month(.abbreviated),
            tooltipDateFormat: .dateTime.month(.wide).year(),
            tint: .purple,
            yStep: 10
        )
    }

    private var averageText: String {
        guard !points.isEmpty else { return "—" }
        let avg = points.map(\.value).reduce(0, +) / Double(points.count)
        return "\(Int(avg.rounded()))"
    }

    private var dateRangeText: String {
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: endDate) ?? endDate
        return "\(startDate.formatted(.dateTime.month(.abbreviated).year())) – \(lastMonth.formatted(.dateTime.month(.abbreviated).year()))"
    }
}
