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
                NavigationLink(destination: SkinTemperatureHourlySummaryTableView()) {
                    TableRowLabel(icon: "thermometer.medium", color: .pink, name: "SkinTemperatureHourlySummary",
                                  subtitle: "Pre-aggregated skin temperature per hour")
                }
                NavigationLink(destination: DailySummaryTableView()) {
                    TableRowLabel(icon: "calendar", color: .blue, name: "DailySummary",
                                  subtitle: "Pre-aggregated HR + HRV per day")
                }
                NavigationLink(destination: MonthlySummaryTableView()) {
                    TableRowLabel(icon: "calendar.badge.clock", color: .indigo, name: "MonthlySummary",
                                  subtitle: "Pre-aggregated HR + HRV per month")
                }
                NavigationLink(destination: SleepWindowSummaryTableView()) {
                    TableRowLabel(icon: "bed.double.fill", color: .purple, name: "SleepWindowSummary",
                                  subtitle: "Detected overnight sleep windows")
                }
                NavigationLink(destination: RecoverySummaryTableView()) {
                    TableRowLabel(icon: "bolt.heart.fill", color: .green, name: "RecoverySummary",
                                  subtitle: "Daily recovery scores")
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
                NavigationLink(destination: SkinTemperatureSampleTableView()) {
                    TableRowLabel(icon: "thermometer", color: .pink, name: "SkinTemperatureSample",
                                  subtitle: "WHOOP historical temperature candidates")
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

struct SkinTemperatureHourlySummaryTableView: View {
    @Query(sort: \SkinTemperatureHourlySummary.hourStart, order: .reverse) private var rows: [SkinTemperatureHourlySummary]

    private static let schema: [(String, String)] = [
        ("hourStart",    "Date — top of the hour, local time"),
        ("sampleCount",  "Int — accepted skin temperature samples in this hour"),
        ("sumCelsius",   "Double — running sum of decoded temperature"),
        ("minCelsius",   "Double — lowest decoded temperature in hour"),
        ("maxCelsius",   "Double — highest decoded temperature in hour"),
        ("sumRawU16",    "Double — running sum of unsigned raw register values"),
        ("minRawU16",    "Int — lowest unsigned raw register value in hour"),
        ("maxRawU16",    "Int — highest unsigned raw register value in hour"),
        ("avgCelsius",   "Double? (computed) — sumCelsius / sampleCount"),
        ("avgRawU16",    "Double? (computed) — sumRawU16 / sampleCount"),
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
                        KV("samples", "\(row.sampleCount)")
                        KV("avg_temp", row.avgCelsius.map { String(format: "%.2f C", $0) } ?? "—")
                        KV("min/max_temp", row.sampleCount > 0 ? String(format: "%.2f / %.2f C", row.minCelsius, row.maxCelsius) : "—")
                        KV("avg_raw", row.avgRawU16.map { String(format: "%.1f", $0) } ?? "—")
                        KV("min/max_raw", row.sampleCount > 0 ? "\(row.minRawU16) / \(row.maxRawU16)" : "—")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SkinTemperatureHourlySummary")
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

struct RecoverySummaryTableView: View {
    @Query(sort: \RecoverySummary.day, order: .reverse) private var rows: [RecoverySummary]

    var body: some View {
        List {
            Section(header: Text("Rows (\(rows.count))")) {
                if rows.isEmpty {
                    Text("No data yet").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.day.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                        KV("score", row.score.map { "\($0)%" } ?? "—")
                        KV("zone", row.zone)
                        KV("hrv", String(format: "%.1f ms", row.hrvMS))
                        KV("rhr", String(format: "%.1f bpm", row.rhrBPM))
                        KV("sleep", String(format: "%.0f min", row.sleepMinutes))
                        KV("baseline_days", "\(row.baselineDayCount)")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("RecoverySummary")
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

struct SleepWindowSummaryTableView: View {
    @Query(sort: \SleepWindowSummary.day, order: .reverse) private var rows: [SleepWindowSummary]

    private static let schema: [(String, String)] = [
        ("day",               "Date — local wake day, midnight"),
        ("start",             "Date — detected sleep/rest start"),
        ("end",               "Date — detected sleep/rest end"),
        ("durationMinutes",   "Double — detected window length"),
        ("confidence",        "Double — 0...1 detector confidence"),
        ("method",            "String — detector version"),
        ("motionBucketCount", "Int — expected 10m buckets in the window"),
        ("stillBucketCount",  "Int — quiet 10m buckets"),
        ("hrSampleCount",     "Int — HR samples inside the window"),
        ("avgHR",             "Double? — mean HR inside the window"),
        ("qualityFlags",      "String — comma-separated detector notes"),
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
                        Text(row.day.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                        KV("window", "\(row.start.formatted(date: .omitted, time: .shortened)) - \(row.end.formatted(date: .omitted, time: .shortened))")
                        KV("duration", String(format: "%.1f hr", row.durationMinutes / 60.0))
                        KV("confidence", String(format: "%.0f%%", row.confidence * 100))
                        KV("motion", "\(row.stillBucketCount) / \(row.motionBucketCount) still buckets")
                        KV("hr_samples", "\(row.hrSampleCount)")
                        KV("avg_hr", row.avgHR.map { String(format: "%.1f bpm", $0) } ?? "—")
                        KV("flags", row.qualityFlags)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SleepWindowSummary")
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

struct SkinTemperatureSampleTableView: View {
    @Query(sort: \SkinTemperatureSample.timestamp, order: .reverse) private var rows: [SkinTemperatureSample]

    private static let schema: [(String, String)] = [
        ("timestamp",     "Date — historical packet timestamp from the strap"),
        ("celsius",       "Double? — decoded temperature candidate"),
        ("packetK",       "Int — source historical packet family"),
        ("schemaField",   "String — Noop-derived WHOOP5 historical mapping name"),
        ("rawBodyOffset", "Int — byte offset within Pigeon's WHOOP payload"),
        ("encoding",      "String — integer encoding and scale"),
        ("rawHex",        "String — original two bytes"),
        ("rawI16LE",      "Int? — signed little-endian interpretation"),
        ("rawU16LE",      "Int? — unsigned little-endian interpretation"),
        ("semanticStatus","String — validation status"),
        ("sourceKey",     "String — packet/page dedupe key"),
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
                        Text(row.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.headline.monospacedDigit())
                        KV("temp", row.celsius.map { String(format: "%.2f C", $0) } ?? "—")
                        KV("packet", "K\(row.packetK)")
                        KV("field", row.schemaField)
                        KV("encoding", "\(row.encoding) payload+\(row.rawBodyOffset)")
                        KV("raw", "\(row.rawHex) i16=\(row.rawI16LE.map(String.init) ?? "?") u16=\(row.rawU16LE.map(String.init) ?? "?")")
                        KV("status", row.semanticStatus)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SkinTemperatureSample")
        .navigationBarTitleDisplayMode(.inline)
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
