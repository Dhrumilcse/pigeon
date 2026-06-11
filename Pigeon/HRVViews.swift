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

                HealthOptionsSection(
                    unitText: "ms",
                    showAllData: { ShowAllHRVDataView() },
                    unitPicker: { HealthUnitPickerView(title: "HRV Unit", unit: "ms") }
                )
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart Rate Variability")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Show All Data (HRV)

// Lists every day that has HRV samples, newest first. DailySummary doesn't
// track minHRV/maxHRV, so each row queries its own day's HRVSample to derive
// low/high. List virtualization keeps it cheap.
struct ShowAllHRVDataView: View {
    @State private var range: HealthTimeRange = .day
    @Environment(\.modelContext) private var modelContext
    @State private var days: [DailySummary] = []
    @State private var hasMoreDays = true
    @State private var isLoadingDays = false

    private let dayPageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Range", selection: $range) {
                    ForEach(HealthTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                switch range.source {
                case .hourly:
                    HourlyHRVAllDataCard().id(range)
                case .daily:
                    DailyHRVAllDataCard(range: range).id(range)
                case .monthly:
                    MonthlyHRVAllDataCard().id(range)
                }

                if !days.isEmpty {
                    HealthDayList(days: days) { day in
                        NavigationLink {
                            DayHRVHoursView(dayStart: day.date)
                        } label: {
                            HealthDayLinkRow {
                                HRVDayRow(dayStart: day.date)
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if day.persistentModelID == days.last?.persistentModelID {
                                loadMoreDays()
                            }
                        }
                    }
                }

                if hasMoreDays {
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
            if days.isEmpty && hasMoreDays {
                loadMoreDays()
            }
        }
    }

    private func loadMoreDays() {
        guard !isLoadingDays, hasMoreDays else { return }
        isLoadingDays = true
        defer { isLoadingDays = false }

        let cursor = days.last?.date ?? Date.distantFuture
        var descriptor = FetchDescriptor<DailySummary>(
            predicate: #Predicate<DailySummary> { $0.hrvSampleCount > 0 && $0.date < cursor },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = dayPageSize

        do {
            let page = try modelContext.fetch(descriptor)
            days.append(contentsOf: page)
            hasMoreDays = page.count == dayPageSize
        } catch {
            hasMoreDays = false
        }
    }
}

// MARK: - HRV All Data chart bodies (one per range source)

// Summary tables track avgHRV but not min/max, so the visualization is a
// scatter of per-period averages rather than range bars.

private struct HourlyHRVAllDataCard: View {
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
        rows.map { HealthPoint(date: $0.hourStart, value: Double($0.hrvSampleCount)) }
    }

    private var sampleCount: Int { rows.reduce(0) { $0 + $1.hrvSampleCount } }

    var body: some View {
        HealthChartContainer(
            headerLabel: "SAMPLES",
            avgText: sampleCount.formatted(),
            unitLabel: "",
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
}

private struct DailyHRVAllDataCard: View {
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
            filter: #Predicate<DailySummary> { $0.date >= start && $0.date < end && $0.hrvSampleCount > 0 },
            sort: \.date
        )
    }

    private var points: [HealthPoint] {
        rows.map { HealthPoint(date: $0.date, value: Double($0.hrvSampleCount)) }
    }

    private var sampleCount: Int { rows.reduce(0) { $0 + $1.hrvSampleCount } }

    private var dateRangeText: String {
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: endDate) ?? endDate
        return "\(startDate.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day().year()))"
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

    var body: some View {
        HealthChartContainer(
            headerLabel: "SAMPLES",
            avgText: sampleCount.formatted(),
            unitLabel: "",
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
}

private struct MonthlyHRVAllDataCard: View {
    // Per-month HRV sample counts: group DailySummary by month (neither
    // MonthlySummary nor any other table stores hrvSampleCount per month).
    @Query private var days: [DailySummary]
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
        _days = Query(
            filter: #Predicate<DailySummary> { $0.date >= start && $0.date < end && $0.hrvSampleCount > 0 },
            sort: \.date
        )
    }

    private var points: [HealthPoint] {
        let cal = Calendar.current
        var byMonth: [Date: Int] = [:]
        for d in days {
            let comps = cal.dateComponents([.year, .month], from: d.date)
            guard let monthStart = cal.date(from: comps) else { continue }
            byMonth[monthStart, default: 0] += d.hrvSampleCount
        }
        return byMonth.map { HealthPoint(date: $0.key, value: Double($0.value)) }
            .sorted { $0.date < $1.date }
    }

    private var sampleCount: Int { days.reduce(0) { $0 + $1.hrvSampleCount } }

    private var dateRangeText: String {
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: endDate) ?? endDate
        return "\(startDate.formatted(.dateTime.month(.abbreviated).year())) – \(lastMonth.formatted(.dateTime.month(.abbreviated).year()))"
    }

    var body: some View {
        HealthChartContainer(
            headerLabel: "SAMPLES",
            avgText: sampleCount.formatted(),
            unitLabel: "",
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
}

private struct HRVDayRow: View {
    let dayStart: Date
    @Environment(\.modelContext) private var modelContext
    @State private var bounds: (low: Int, high: Int)?
    @State private var hasLoadedBounds = false

    var body: some View {
        Group {
            if let bounds {
                HealthDaySummaryRow(low: bounds.low, high: bounds.high, unit: "ms", date: dayStart)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("—")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(dayStart.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
        }
        .task {
            loadBoundsIfNeeded()
        }
    }

    private func loadBoundsIfNeeded() {
        guard !hasLoadedBounds else { return }
        hasLoadedBounds = true

        let start = dayStart
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        var lowDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.rmssdMS)]
        )
        lowDescriptor.fetchLimit = 1

        var highDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.rmssdMS, order: .reverse)]
        )
        highDescriptor.fetchLimit = 1

        guard let low = try? modelContext.fetch(lowDescriptor).first,
              let high = try? modelContext.fetch(highDescriptor).first else {
            return
        }
        bounds = (
            low: Int(low.rmssdMS.rounded()),
            high: Int(high.rmssdMS.rounded())
        )
    }
}

// MARK: - Per-day hour list

struct DayHRVHoursView: View {
    let dayStart: Date
    @Query private var hours: [HourlySummary]

    init(dayStart: Date) {
        self.dayStart = dayStart
        let end = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        _hours = Query(
            filter: #Predicate<HourlySummary> {
                $0.hourStart >= dayStart && $0.hourStart < end && $0.hrvSampleCount > 0
            },
            sort: \.hourStart,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if hours.isEmpty {
                    Text("No samples recorded.")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                } else {
                    HealthHourList(hours: hours) { hour in
                        NavigationLink {
                            HourHRVSamplesView(hourStart: hour.hourStart)
                        } label: {
                            HealthDayLinkRow {
                                HRVHourRow(hourStart: hour.hourStart)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Layout.screenHMargin)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HRVHourRow: View {
    let hourStart: Date
    @Environment(\.modelContext) private var modelContext
    @State private var bounds: (low: Int, high: Int)?
    @State private var hasLoadedBounds = false

    private var hourEnd: Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: hourStart) ?? hourStart
    }

    var body: some View {
        Group {
            if let bounds {
                HealthHourSummaryRow(low: bounds.low, high: bounds.high, unit: "ms", hourStart: hourStart)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("—")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(hourStart.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
        }
        .task {
            loadBoundsIfNeeded()
        }
    }

    private func loadBoundsIfNeeded() {
        guard !hasLoadedBounds else { return }
        hasLoadedBounds = true

        let start = hourStart
        let end = hourEnd

        var lowDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.rmssdMS)]
        )
        lowDescriptor.fetchLimit = 1

        var highDescriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.rmssdMS, order: .reverse)]
        )
        highDescriptor.fetchLimit = 1

        guard let low = try? modelContext.fetch(lowDescriptor).first,
              let high = try? modelContext.fetch(highDescriptor).first else {
            return
        }
        bounds = (
            low: Int(low.rmssdMS.rounded()),
            high: Int(high.rmssdMS.rounded())
        )
    }
}

// MARK: - Per-hour HRV samples

struct HourHRVSamplesView: View {
    let hourStart: Date
    @Environment(\.modelContext) private var modelContext
    @State private var samples: [HRVSample] = []
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false

    private let pageSize = 100

    private var hourEnd: Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: hourStart) ?? hourStart
    }

    var body: some View {
        List {
            if samples.isEmpty && !hasMore {
                Section {
                    Text("No samples recorded.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(samples) { sample in
                        HealthSampleRow(
                            value: Int(sample.rmssdMS.rounded()),
                            unit: "ms",
                            date: sample.timestamp
                        )
                        .onAppear {
                            if sample.persistentModelID == samples.last?.persistentModelID {
                                loadMore()
                            }
                        }
                    }
                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle(hourStart.formatted(.dateTime.hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if samples.isEmpty && hasMore {
                loadMore()
            }
        }
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        let cursor = samples.last?.timestamp ?? hourEnd
        let start = hourStart

        var descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < cursor },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = pageSize

        do {
            let page = try modelContext.fetch(descriptor)
            samples.append(contentsOf: page)
            hasMore = page.count == pageSize
        } catch {
            hasMore = false
        }
    }
}

// MARK: - Per-day HRV samples (legacy — prefer hour drill-down)

struct DayHRVSamplesView: View {
    let dayStart: Date
    @Environment(\.modelContext) private var modelContext
    @State private var samples: [HRVSample] = []
    @State private var hasMore: Bool = true
    @State private var isLoading: Bool = false

    private let pageSize = 100

    var body: some View {
        List {
            if samples.isEmpty && !hasMore {
                Section {
                    Text("No samples recorded.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(samples) { sample in
                        HealthSampleRow(
                            value: Int(sample.rmssdMS.rounded()),
                            unit: "ms",
                            date: sample.timestamp
                        )
                        .onAppear {
                            if sample.persistentModelID == samples.last?.persistentModelID {
                                loadMore()
                            }
                        }
                    }
                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle(dayStart.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if samples.isEmpty && hasMore {
                loadMore()
            }
        }
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let cursor = samples.last?.timestamp ?? dayEnd
        let start = dayStart

        var descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate<HRVSample> { $0.timestamp >= start && $0.timestamp < cursor },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = pageSize

        do {
            let page = try modelContext.fetch(descriptor)
            samples.append(contentsOf: page)
            hasMore = page.count == pageSize
        } catch {
            hasMore = false
        }
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
