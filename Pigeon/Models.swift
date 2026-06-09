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

// Pre-aggregated hourly summary. One row per (calendar day, hour-of-day).
// Updated in-place on every raw-sample write so the home card and detail
// "D" tab can render from ~24 tiny rows instead of scanning HRSample.
@Model
final class HourlySummary {
    var hourStart: Date     // top of the hour, local time
    var hrSampleCount: Int
    var sumHR: Double       // avgHR = sumHR / hrSampleCount
    var minHR: Int
    var maxHR: Int
    var hrvSampleCount: Int = 0
    var sumHRV: Double = 0  // avgHRV = sumHRV / hrvSampleCount

    var avgHR: Double { hrSampleCount > 0 ? sumHR / Double(hrSampleCount) : 0 }
    var avgHRV: Double? { hrvSampleCount > 0 ? sumHRV / Double(hrvSampleCount) : nil }

    init(hourStart: Date) {
        self.hourStart = hourStart
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
// the realtime stream is flowing. Historical inserts (from the strap's
// page buffer via SEND_HISTORICAL_DATA) set `sourceKey` so re-syncs
// don't double-insert the same page; realtime leaves it nil.
@Model
final class HRSample {
    var timestamp: Date
    var bpm: Int
    var sourceKey: String? = nil

    init(timestamp: Date, bpm: Int, sourceKey: String? = nil) {
        self.timestamp = timestamp
        self.bpm = bpm
        self.sourceKey = sourceKey
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

// One compact accelerometer aggregate from a WHOOP Raw43/K21 frame.
// Each raw frame carries 100 samples per axis; we store summary stats so
// sleep/walk/activity logic can use the motion signal without persisting the
// full high-rate stream.
@Model
final class MotionSample {
    var timestamp: Date
    var sampleCount: Int

    var meanXG: Double
    var meanYG: Double
    var meanZG: Double
    var magnitudeG: Double

    var minXG: Double
    var maxXG: Double
    var minYG: Double
    var maxYG: Double
    var minZG: Double
    var maxZG: Double

    var rmsDeviationG: Double
    var meanDeltaG: Double
    var maxDeltaG: Double

    var sourceKey: String?

    init(
        timestamp: Date,
        sampleCount: Int,
        meanXG: Double,
        meanYG: Double,
        meanZG: Double,
        magnitudeG: Double,
        minXG: Double,
        maxXG: Double,
        minYG: Double,
        maxYG: Double,
        minZG: Double,
        maxZG: Double,
        rmsDeviationG: Double,
        meanDeltaG: Double,
        maxDeltaG: Double,
        sourceKey: String? = nil
    ) {
        self.timestamp = timestamp
        self.sampleCount = sampleCount
        self.meanXG = meanXG
        self.meanYG = meanYG
        self.meanZG = meanZG
        self.magnitudeG = magnitudeG
        self.minXG = minXG
        self.maxXG = maxXG
        self.minYG = minYG
        self.maxYG = maxYG
        self.minZG = minZG
        self.maxZG = maxZG
        self.rmsDeviationG = rmsDeviationG
        self.meanDeltaG = meanDeltaG
        self.maxDeltaG = maxDeltaG
        self.sourceKey = sourceKey
    }
}
