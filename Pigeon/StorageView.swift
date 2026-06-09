import SwiftUI
import SwiftData

struct LocalStorageView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(destination: HourlySummaryTableView()) {
                    TableRowLabel(icon: "clock", color: .teal, name: "HourlySummary",
                                  subtitle: "Pre-aggregated HR per hour")
                }
                NavigationLink(destination: DailySummaryTableView()) {
                    TableRowLabel(icon: "calendar", color: .blue, name: "DailySummary",
                                  subtitle: "Pre-aggregated HR + HRV per day")
                }
                NavigationLink(destination: MonthlySummaryTableView()) {
                    TableRowLabel(icon: "calendar.badge.clock", color: .indigo, name: "MonthlySummary",
                                  subtitle: "Pre-aggregated HR + HRV per month")
                }
                NavigationLink(destination: MotionBucketSummaryTableView()) {
                    TableRowLabel(icon: "figure.walk.motion", color: .orange, name: "MotionBucketSummary",
                                  subtitle: "Pre-aggregated motion per chart bucket")
                }
            } header: { Text("Summaries") }

            Section {
                NavigationLink(destination: HRSampleTableView()) {
                    TableRowLabel(icon: "heart.fill", color: .red, name: "HRSample",
                                  subtitle: "Raw HR at ~1 Hz")
                }
                NavigationLink(destination: RRSampleTableView()) {
                    TableRowLabel(icon: "waveform.path.ecg", color: .orange, name: "RRSample",
                                  subtitle: "Beat-to-beat R-R intervals")
                }
                NavigationLink(destination: HRVSampleTableView()) {
                    TableRowLabel(icon: "waveform", color: .purple, name: "HRVSample",
                                  subtitle: "RMSSD computed per 60 s window")
                }
                NavigationLink(destination: MotionSampleTableView()) {
                    TableRowLabel(icon: "figure.walk.motion", color: .orange, name: "MotionSample",
                                  subtitle: "Compact Raw43 accelerometer aggregates")
                }
            } header: { Text("Raw Samples") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Local Storage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Table detail views

struct HourlySummaryTableView: View {
    @Query(sort: \HourlySummary.hourStart, order: .reverse) private var rows: [HourlySummary]

    private static let schema: [(String, String)] = [
        ("hourStart",      "Date — top of the hour, local time"),
        ("hrSampleCount",  "Int — raw HR inserts in this hour"),
        ("sumHR",          "Double — running sum of bpm"),
        ("minHR",          "Int — lowest bpm in hour"),
        ("maxHR",          "Int — highest bpm in hour"),
        ("hrvSampleCount", "Int — RMSSD values computed in this hour"),
        ("sumHRV",         "Double — running sum of RMSSD"),
        ("avgHR",          "Double (computed) — sumHR / hrSampleCount"),
        ("avgHRV",         "Double? (computed) — sumHRV / hrvSampleCount"),
    ]

    private static let hourFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h a"; return f
    }()

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 50 of \(rows.count)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(50)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.hourFmt.string(from: row.hourStart))
                            .font(.headline)
                        KV("hr_samples",  "\(row.hrSampleCount)")
                        KV("avg_hr",      row.hrSampleCount > 0 ? String(format: "%.1f bpm", row.avgHR) : "—")
                        KV("min/max",     row.hrSampleCount > 0 ? "\(row.minHR) / \(row.maxHR) bpm" : "—")
                        KV("hrv_samples", "\(row.hrvSampleCount)")
                        if let avg = row.avgHRV {
                            KV("avg_hrv", String(format: "%.1f ms", avg))
                        } else {
                            KV("avg_hrv", "—")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HourlySummary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DailySummaryTableView: View {
    @Query(sort: \DailySummary.date, order: .reverse) private var rows: [DailySummary]

    private static let schema: [(String, String)] = [
        ("date",           "Date — start of day, midnight local"),
        ("hrSampleCount",  "Int — raw HR inserts today"),
        ("sumHR",          "Double — running sum of bpm"),
        ("minHR",          "Int — lowest bpm today"),
        ("maxHR",          "Int — highest bpm today"),
        ("hrvSampleCount", "Int — RMSSD values computed today"),
        ("sumHRV",         "Double — running sum of RMSSD"),
        ("avgHR",          "Double (computed) — sumHR / hrSampleCount"),
        ("avgHRV",         "Double? (computed) — sumHRV / hrvSampleCount"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Rows (\(rows.count))")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                        KV("hr_samples", "\(row.hrSampleCount)")
                        KV("avg_hr",     row.hrSampleCount > 0 ? String(format: "%.1f bpm", row.avgHR) : "—")
                        KV("min/max",    row.hrSampleCount > 0 ? "\(row.minHR) / \(row.maxHR) bpm" : "—")
                        KV("hrv_samples","\(row.hrvSampleCount)")
                        if let avg = row.avgHRV {
                            KV("avg_hrv", String(format: "%.1f ms", avg))
                        } else {
                            KV("avg_hrv", "—")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("DailySummary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MonthlySummaryTableView: View {
    @Query(sort: \MonthlySummary.yearMonth, order: .reverse) private var rows: [MonthlySummary]

    private static let schema: [(String, String)] = [
        ("yearMonth",   "Date — first of month, midnight local"),
        ("dayCount",    "Int — distinct days with HR data"),
        ("avgHR",       "Double — mean of daily avgHR"),
        ("minHR",       "Int — lowest daily minHR"),
        ("maxHR",       "Int — highest daily maxHR"),
        ("daysWithHRV", "Int — days that had HRV data"),
        ("avgHRV",      "Double — mean of daily avgHRV"),
    ]

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Rows (\(rows.count))")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.monthFmt.string(from: row.yearMonth))
                            .font(.headline)
                        KV("days",    "\(row.dayCount)")
                        KV("avg_hr",  row.dayCount > 0 ? String(format: "%.1f bpm", row.avgHR) : "—")
                        KV("min/max", row.dayCount > 0 ? "\(row.minHR) / \(row.maxHR) bpm" : "—")
                        KV("days_hrv","\(row.daysWithHRV)")
                        KV("avg_hrv", row.daysWithHRV > 0 ? String(format: "%.1f ms", row.avgHRV) : "—")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MonthlySummary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MotionBucketSummaryTableView: View {
    @Query(sort: \MotionBucketSummary.bucketStart, order: .reverse) private var rows: [MotionBucketSummary]

    private static let schema: [(String, String)] = [
        ("bucketStart",   "Date — start of the local chart bucket"),
        ("bucketSeconds", "Int — bucket width in seconds"),
        ("sampleCount",   "Int — raw motion rows folded into this bucket"),
        ("stillCount",    "Int — rows below the stillness thresholds"),
        ("sumMeanDeltaG", "Double — running sum of average movement"),
        ("maxDeltaG",     "Double — largest movement spike in the bucket"),
        ("first/last",    "Date? — raw sample coverage inside the bucket"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 100 of \(rows.count)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(100)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.bucketStart.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline)
                        KV("bucket", "\(row.bucketSeconds / 60)m")
                        KV("samples", "\(row.sampleCount)")
                        KV("still", "\(row.stillCount)")
                        KV("avg_motion", String(format: "%.4f g", row.avgMeanDeltaG))
                        KV("max_spike", String(format: "%.4f g", row.maxDeltaG))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MotionBucketSummary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HRSampleTableView: View {
    @Query(sort: \HRSample.timestamp, order: .reverse) private var rows: [HRSample]

    private static let schema: [(String, String)] = [
        ("timestamp", "Date — when the sample was recorded"),
        ("bpm",       "Int — heart rate in beats per minute"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 50 of \(rows.count)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(50)) { row in
                    HStack {
                        Text(row.timestamp.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                        Spacer()
                        Text("\(row.bpm) bpm")
                            .font(.body.monospacedDigit())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HRSample")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RRSampleTableView: View {
    @Query(sort: \RRSample.timestamp, order: .reverse) private var rows: [RRSample]

    private static let schema: [(String, String)] = [
        ("timestamp",  "Date — when the interval was recorded"),
        ("intervalMS", "Double — R-R interval in milliseconds"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 50 of \(rows.count)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(50)) { row in
                    HStack {
                        Text(row.timestamp.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                        Spacer()
                        Text(String(format: "%.1f ms", row.intervalMS))
                            .font(.body.monospacedDigit())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("RRSample")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HRVSampleTableView: View {
    @Query(sort: \HRVSample.timestamp, order: .reverse) private var rows: [HRVSample]

    private static let schema: [(String, String)] = [
        ("timestamp", "Date — when RMSSD was computed"),
        ("rmssdMS",   "Double — RMSSD value in milliseconds"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 50 of \(rows.count)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows.prefix(50)) { row in
                    HStack {
                        Text(row.timestamp.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                        Spacer()
                        Text(String(format: "%.1f ms", row.rmssdMS))
                            .font(.body.monospacedDigit())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HRVSample")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MotionSampleTableView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var rows: [MotionSample] = []
    @State private var totalCount = 0

    private static let schema: [(String, String)] = [
        ("timestamp",     "Date — Raw43 frame timestamp from the strap"),
        ("sampleCount",   "Int — accel samples per axis in the frame"),
        ("meanX/Y/ZG",    "Double — mean gravity/accel per axis, in g"),
        ("magnitudeG",    "Double — sqrt(meanX² + meanY² + meanZ²)"),
        ("min/max X/Y/Z", "Double — per-axis range within the frame, in g"),
        ("rmsDeviationG", "Double — spread around the mean vector; useful for movement intensity"),
        ("meanDeltaG",    "Double — average sample-to-sample vector change"),
        ("maxDeltaG",     "Double — largest sample-to-sample vector change"),
        ("sourceKey",     "String? — raw43 timestamp/subseconds/header key"),
    ]

    var body: some View {
        List {
            SchemaSection(fields: Self.schema)
            Section(header: Text("Last 100 of \(totalCount)")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.headline.monospacedDigit())
                        KV("n", "\(row.sampleCount)")
                        KV("mean_xyz", String(format: "%.3f / %.3f / %.3f g", row.meanXG, row.meanYG, row.meanZG))
                        KV("|g|", String(format: "%.3f", row.magnitudeG))
                        KV("range_x", String(format: "%.3f ... %.3f g", row.minXG, row.maxXG))
                        KV("range_y", String(format: "%.3f ... %.3f g", row.minYG, row.maxYG))
                        KV("range_z", String(format: "%.3f ... %.3f g", row.minZG, row.maxZG))
                        KV("rms", String(format: "%.4f g", row.rmsDeviationG))
                        KV("delta_avg/max", String(format: "%.4f / %.4f g", row.meanDeltaG, row.maxDeltaG))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MotionSample")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadRows()
        }
    }

    private func loadRows() {
        totalCount = (try? modelContext.fetchCount(FetchDescriptor<MotionSample>())) ?? 0
        var descriptor = FetchDescriptor<MotionSample>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 100
        rows = (try? modelContext.fetch(descriptor)) ?? []
    }
}

// MARK: - Shared components

private struct TableRowLabel: View {
    let icon: String
    let color: Color
    let name: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SchemaSection: View {
    let fields: [(String, String)]

    var body: some View {
        Section(header: Text("Schema")) {
            ForEach(fields, id: \.0) { name, type in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct KV: View {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }

    var body: some View {
        HStack {
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}
