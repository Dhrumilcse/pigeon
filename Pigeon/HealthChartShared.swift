import SwiftUI
import Charts

// Shared infrastructure for Apple Health-style metric detail charts.
// HR and HRV both feed into ChartContainer with their own tint + units.

enum Layout {
    // Gap on the left and right of every screen's content (titles, cards, lists).
    static let screenHMargin: CGFloat = 20
}

/// Compact half-width score tile used on Home (Recovery, Sleep Performance, …).
struct HomeScoreCard: View {
    let icon: String
    let tint: Color
    let title: String
    let scoreText: String
    let unitText: String
    var isAvailable: Bool = true
    var showsChevron: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .opacity(showsChevron ? 1 : 0)
            }
            .frame(height: 18)

            Group {
                if isAvailable {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(scoreText)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                        Text(unitText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Not Available")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 34, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

    static let height: CGFloat = 112
}

enum HealthTimeRange: String, CaseIterable, Identifiable {
    case day = "D"
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"

    var id: String { rawValue }

    enum Source { case hourly, daily, monthly }
    var source: Source {
        switch self {
        case .day:                       return .hourly
        case .week, .month, .sixMonths:  return .daily
        case .year:                      return .monthly
        }
    }
}

struct HealthPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

struct HealthXStride {
    let component: Calendar.Component
    let count: Int
}

func niceYAxisValues(min: Double, max: Double, step roundTo: Double = 10, count: Int = 4) -> [Double] {
    guard count > 1 else { return [min] }
    let pad = (max - min) == 0 ? roundTo / 2 : 0
    let lo = (Foundation.floor((min - pad) / roundTo)) * roundTo
    let hi = (Foundation.ceil((max + pad) / roundTo)) * roundTo
    let step = (hi - lo) / Double(count - 1)
    return (0..<count).map { lo + step * Double($0) }
}

struct HealthChartContainer: View {
    let headerLabel: String
    let avgText: String
    let unitLabel: String
    let dateRangeText: String
    let points: [HealthPoint]
    let xDomain: ClosedRange<Date>
    let xStride: HealthXStride
    let xFormat: Date.FormatStyle
    let tooltipDateFormat: Date.FormatStyle
    let tint: Color
    let yStep: Double

    @State private var selectedDate: Date?

    private var yValues: [Double] {
        guard !points.isEmpty else { return [0, 25, 50, 75] }
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 0
        return niceYAxisValues(min: lo, max: hi, step: yStep, count: 4)
    }

    private var selectedPoint: HealthPoint? {
        guard let d = selectedDate, !points.isEmpty else { return nil }
        return points.min(by: {
            abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d))
        })
    }

    private var displayValueText: String {
        guard let sp = selectedPoint else { return avgText }
        return Int(sp.value.rounded()).formatted()
    }

    private var displayDateText: String {
        guard let sp = selectedPoint else { return dateRangeText }
        return sp.date.formatted(tooltipDateFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayValueText)
                    .font(.system(size: 36, weight: .bold))
                Text(unitLabel)
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            Text(displayDateText)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.value)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Date", p.date),
                    y: .value("Value", p.value)
                )
                .symbolSize(36)
                .foregroundStyle(tint)
            }

            if let sp = selectedPoint {
                RuleMark(x: .value("Selected", sp.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Selected", sp.date),
                    y: .value("Value", sp.value)
                )
                .symbolSize(80)
                .foregroundStyle(tint)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: (yValues.first ?? 0)...(yValues.last ?? 100))
        .chartYAxis {
            AxisMarks(position: .trailing, values: yValues) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: xStride.component, count: xStride.count)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xFormat)
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 280)
    }

}

// MARK: - Options section (Apple Health–style)

struct HealthOptionsSection<ShowAll: View, UnitPicker: View>: View {
    let unitText: String
    @ViewBuilder var showAllData: () -> ShowAll
    @ViewBuilder var unitPicker: () -> UnitPicker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPTIONS")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                NavigationLink {
                    showAllData()
                } label: {
                    HealthOptionsRow(title: "Show All Data", value: nil)
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 16)

                NavigationLink {
                    unitPicker()
                } label: {
                    HealthOptionsRow(title: "Unit", value: unitText)
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}

private struct HealthOptionsRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 17))
                .foregroundColor(.primary)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 17))
                    .foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// A simple Unit picker page with a single selected option. Mirrors Apple
// Health for symmetry — the underlying metric only has one canonical unit
// (BPM for HR, ms for HRV), so this is informational.
struct HealthUnitPickerView: View {
    let title: String
    let unit: String

    var body: some View {
        List {
            Section {
                HStack {
                    Text(unit)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Show-all-data day row

// A row in the "Show All Data" list, formatted like Apple Health:
// "<low>–<high>" on the left, date on the right.
struct HealthDaySummaryRow: View {
    let low: Int
    let high: Int
    let unit: String
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(low)–\(high)")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                Text(unit)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
    }
}

// Rounded-card list of day rows. Mirrors the visual of an inset-grouped
// List section, but lives inside a ScrollView so the page header can sit
// flush against the nav bar (a real List adds ~80pt of grouped-style
// padding above the first section, which doesn't match the detail view).
struct HealthDayList<Day: Identifiable, RowContent: View>: View {
    let days: [Day]
    @ViewBuilder var row: (Day) -> RowContent

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { idx, day in
                row(day)
                if idx < days.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// Hour row for nested show-all-data navigation (day → hour → samples).
struct HealthHourSummaryRow: View {
    let low: Int
    let high: Int
    let unit: String
    let hourStart: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(low)–\(high)")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                Text(unit)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(hourStart.formatted(.dateTime.hour().minute()))
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
    }
}

struct HealthHourList<Hour: Identifiable, RowContent: View>: View {
    let hours: [Hour]
    @ViewBuilder var row: (Hour) -> RowContent

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(hours.enumerated()), id: \.element.id) { idx, hour in
                row(hour)
                if idx < hours.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// Wraps a HealthDaySummaryRow (or similar) with the standard navigation
// row chrome: 16pt horizontal padding, 14pt vertical padding, trailing
// chevron, and a tappable rectangle for the hit area.
struct HealthDayLinkRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// Row for an individual sample inside a single day.
struct HealthSampleRow: View {
    let value: Int
    let unit: String
    let date: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(.primary)
                Text(unit)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(date.formatted(.dateTime.hour().minute().second()))
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
    }
}
