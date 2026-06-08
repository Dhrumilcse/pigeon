import Foundation
import SwiftData

// Pre-aggregated daily summary. One row per calendar day.
// Updated in-place on every raw-sample write so reads never scan HRSample.
@Model
final class DailySummary {
    var date: Date          // start of day, midnight local time
    var hrSampleCount: Int
    var sumHR: Double       // running sum — avgHR = sumHR / hrSampleCount
    var minHR: Int
    var maxHR: Int
    var hrvSampleCount: Int
    var sumHRV: Double      // running sum — avgHRV = sumHRV / hrvSampleCount

    var avgHR: Double { hrSampleCount > 0 ? sumHR / Double(hrSampleCount) : 0 }
    var avgHRV: Double? { hrvSampleCount > 0 ? sumHRV / Double(hrvSampleCount) : nil }

    init(date: Date) {
        self.date = date
        self.hrSampleCount = 0
        self.sumHR = 0
        self.minHR = 0
        self.maxHR = 0
        self.hrvSampleCount = 0
        self.sumHRV = 0
    }
}

// Pre-aggregated monthly summary. One row per calendar month.
// Recomputed from the daily rows for that month (≤31 fetches) whenever
// a daily summary changes — far cheaper than scanning raw samples.
@Model
final class MonthlySummary {
    var yearMonth: Date     // first day of the month, midnight local time
    var dayCount: Int       // distinct days with HR data
    var avgHR: Double       // mean of daily avgHR values
    var minHR: Int
    var maxHR: Int
    var daysWithHRV: Int
    var avgHRV: Double      // mean of daily avgHRV (0 if no HRV data)

    init(yearMonth: Date) {
        self.yearMonth = yearMonth
        self.dayCount = 0
        self.avgHR = 0
        self.minHR = 0
        self.maxHR = 0
        self.daysWithHRV = 0
        self.avgHRV = 0
    }
}

// One heart-rate reading from the WHOOP strap. Written at ~1 Hz while
// the realtime stream is flowing.
@Model
final class HRSample {
    var timestamp: Date
    var bpm: Int

    init(timestamp: Date, bpm: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

// A single beat-to-beat R-R interval as reported by the strap, in ms.
// Sparse — only written when the strap is confident enough to mark
// individual R-peaks.
@Model
final class RRSample {
    var timestamp: Date
    var intervalMS: Double

    init(timestamp: Date, intervalMS: Double) {
        self.timestamp = timestamp
        self.intervalMS = intervalMS
    }
}

// RMSSD HRV value computed from the rolling 60-second RR-window at this
// moment. Written each time `ingestRRIntervals` publishes a new value.
@Model
final class HRVSample {
    var timestamp: Date
    var rmssdMS: Double

    init(timestamp: Date, rmssdMS: Double) {
        self.timestamp = timestamp
        self.rmssdMS = rmssdMS
    }
}
