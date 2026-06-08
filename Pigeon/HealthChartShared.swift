import SwiftUI
import Charts

// Shared infrastructure for Apple Health-style metric detail charts.
// HR and HRV both feed into ChartContainer with their own tint + units.

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
    let tooltipLabel: String
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            chart
            trendRow
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(avgText)
                    .font(.system(size: 36, weight: .bold))
                Text(unitLabel)
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            Text(dateRangeText)
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
                    .annotation(
                        position: .top,
                        spacing: 8,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        tooltip(for: sp)
                    }

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

    private func tooltip(for p: HealthPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tooltipLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(p.value.rounded()))")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                Text(unitLabel)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Text(p.date.formatted(tooltipDateFormat))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray5))
        )
    }

    private var trendRow: some View {
        HStack {
            Text("Trend")
                .font(.system(size: 17))
                .foregroundColor(.primary)
            Spacer()
            Text("None")
                .font(.system(size: 17))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }
}
