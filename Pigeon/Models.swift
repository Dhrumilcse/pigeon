import Foundation
import SwiftData

enum StrainScore {
    static let method = "strain_v1"
    static let restingHRFallback = 60.0
    static let maxHRFallback = 190.0
    static let maxSampleGapSeconds = 120.0
    static let loadScale = 55.0

    static func loadIncrement(bpm: Int, durationSeconds: TimeInterval) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let reserve = maxHRFallback - restingHRFallback
        guard reserve > 0 else { return 0 }
        let intensity = max(0, min(1.5, (Double(bpm) - restingHRFallback) / reserve))
        return pow(intensity, 1.67) * (durationSeconds / 60.0)
    }

    static func score(from load: Double) -> Double {
        guard load > 0 else { return 0 }
        return min(21.0, 21.0 * (1.0 - exp(-load / loadScale)))
    }

    /// WHOOP strain zone label for a 0–21 score.
    static func categoryLabel(for score: Double) -> String {
        zone(for: score).label
    }

    static func zone(for score: Double) -> StrainZoneInfo {
        zones.first { score < $0.upperBound } ?? zones[zones.count - 1]
    }

    static let maxScore = 21.0

    static let zones: [StrainZoneInfo] = [
        StrainZoneInfo(label: "Light", lowerBound: 0, upperBound: 10),
        StrainZoneInfo(label: "Moderate", lowerBound: 10, upperBound: 14),
        StrainZoneInfo(label: "High", lowerBound: 14, upperBound: 18),
        StrainZoneInfo(label: "All Out", lowerBound: 18, upperBound: 21),
    ]
}

struct StrainZoneInfo: Identifiable {
    let label: String
    let lowerBound: Double
    let upperBound: Double

    var id: String { label }

    var widthFraction: Double {
        (upperBound - lowerBound) / StrainScore.maxScore
    }
}

// WHOOP-style cardiovascular strain approximation. This is not WHOOP's
// proprietary model; it is a local HR-reserve/TRIMP-inspired daily load.
@Model
final class DailyStrainSummary {
    var date: Date
    var method: String
    var sampleCount: Int
    var activeSeconds: Double
    var strainLoad: Double
    var score: Double
    var minHR: Int
    var maxHR: Int
    var lastSampleAt: Date?

    init(date: Date) {
        self.date = date
        self.method = StrainScore.method
        self.sampleCount = 0
        self.activeSeconds = 0
        self.strainLoad = 0
        self.score = 0
        self.minHR = 0
        self.maxHR = 0
        self.lastSampleAt = nil
    }
}

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

// Pre-aggregated skin temperature summary. Kept separate from HourlySummary
// because this stream is historical-only and still carries raw-register data.
@Model
final class SkinTemperatureHourlySummary {
    var hourStart: Date
    var sampleCount: Int
    var sumCelsius: Double
    var minCelsius: Double
    var maxCelsius: Double
    var sumRawU16: Double
    var minRawU16: Int
    var maxRawU16: Int

    var avgCelsius: Double? { sampleCount > 0 ? sumCelsius / Double(sampleCount) : nil }
    var avgRawU16: Double? { sampleCount > 0 ? sumRawU16 / Double(sampleCount) : nil }

    init(hourStart: Date) {
        self.hourStart = hourStart
        self.sampleCount = 0
        self.sumCelsius = 0
        self.minCelsius = 0
        self.maxCelsius = 0
        self.sumRawU16 = 0
        self.minRawU16 = 0
        self.maxRawU16 = 0
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

enum MotionStillness {
    static let meanDeltaThresholdG = 0.03
    static let rmsThresholdG = 0.08
    static let deepSleepStillFraction = 0.90
    static let deepSleepMeanDeltaThresholdG = 0.015

    static func isStill(meanDeltaG: Double, rmsDeviationG: Double) -> Bool {
        meanDeltaG < meanDeltaThresholdG && rmsDeviationG < rmsThresholdG
    }

    static func isDeepStill(stillFraction: Double, avgMeanDeltaG: Double) -> Bool {
        stillFraction >= deepSleepStillFraction && avgMeanDeltaG <= deepSleepMeanDeltaThresholdG
    }
}

// Pre-aggregated motion summary. One row per bucket resolution so charts read
// a small, fixed number of rows instead of scanning raw MotionSample history.
@Model
final class MotionBucketSummary {
    var bucketStart: Date
    var bucketSeconds: Int
    var sampleCount: Int
    var stillCount: Int
    var sumMeanDeltaG: Double
    var maxDeltaG: Double
    var firstSampleAt: Date?
    var lastSampleAt: Date?

    var avgMeanDeltaG: Double {
        sampleCount > 0 ? sumMeanDeltaG / Double(sampleCount) : 0
    }

    init(bucketStart: Date, bucketSeconds: Int) {
        self.bucketStart = bucketStart
        self.bucketSeconds = bucketSeconds
        self.sampleCount = 0
        self.stillCount = 0
        self.sumMeanDeltaG = 0
        self.maxDeltaG = 0
        self.firstSampleAt = nil
        self.lastSampleAt = nil
    }
}

enum SleepWindowDetection {
    static let minimumConfidence = 0.60
}

// Detected main overnight sleep/rest window. The `day` is the local wake day
// (midnight at the date the window ends), not necessarily the date it starts.
@Model
final class SleepWindowSummary {
    var day: Date
    var start: Date
    var end: Date
    var durationMinutes: Double
    var confidence: Double
    var method: String
    var motionBucketCount: Int
    var stillBucketCount: Int
    var hrSampleCount: Int
    var avgHR: Double?
    var qualityFlags: String

    init(day: Date,
         start: Date,
         end: Date,
         durationMinutes: Double,
         confidence: Double,
         method: String,
         motionBucketCount: Int,
         stillBucketCount: Int,
         hrSampleCount: Int,
         avgHR: Double?,
         qualityFlags: String) {
        self.day = day
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.confidence = confidence
        self.method = method
        self.motionBucketCount = motionBucketCount
        self.stillBucketCount = stillBucketCount
        self.hrSampleCount = hrSampleCount
        self.avgHR = avgHR
        self.qualityFlags = qualityFlags
    }
}

// Daily recovery score for the wake day. Computed from sleep-window HRV, RHR,
// and duration vs a rolling personal baseline (WHOOP-style zones).
@Model
final class RecoverySummary {
    var day: Date
    var score: Int?
    var zone: String
    var method: String
    var hrvMS: Double
    var rhrBPM: Double
    var sleepMinutes: Double
    var hrvSampleCount: Int
    var baselineDayCount: Int
    var baselineHRVMS: Double?
    var baselineRHRBPM: Double?
    var baselineSleepMinutes: Double?
    var hrvComponent: Double
    var rhrComponent: Double
    var sleepComponent: Double

    var recoveryZone: RecoveryZone {
        RecoveryZone(rawValue: zone) ?? .unavailable
    }

    init(day: Date,
         score: Int?,
         zone: RecoveryZone,
         method: String,
         hrvMS: Double,
         rhrBPM: Double,
         sleepMinutes: Double,
         hrvSampleCount: Int,
         baselineDayCount: Int,
         baselineHRVMS: Double?,
         baselineRHRBPM: Double?,
         baselineSleepMinutes: Double?,
         hrvComponent: Double,
         rhrComponent: Double,
         sleepComponent: Double) {
        self.day = day
        self.score = score
        self.zone = zone.rawValue
        self.method = method
        self.hrvMS = hrvMS
        self.rhrBPM = rhrBPM
        self.sleepMinutes = sleepMinutes
        self.hrvSampleCount = hrvSampleCount
        self.baselineDayCount = baselineDayCount
        self.baselineHRVMS = baselineHRVMS
        self.baselineRHRBPM = baselineRHRBPM
        self.baselineSleepMinutes = baselineSleepMinutes
        self.hrvComponent = hrvComponent
        self.rhrComponent = rhrComponent
        self.sleepComponent = sleepComponent
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

// Candidate skin-temperature reading decoded from WHOOP historical packets.
// Units/semantics are intentionally marked in `semanticStatus` until validated
// against official WHOOP recovery exports or app-visible skin temperature.
@Model
final class SkinTemperatureSample {
    var timestamp: Date
    var celsius: Double?
    var packetK: Int
    var schemaField: String
    var rawBodyOffset: Int
    var encoding: String
    var rawHex: String
    var rawI16LE: Int?
    var rawU16LE: Int?
    var semanticStatus: String
    var sourceKey: String

    init(
        timestamp: Date,
        celsius: Double?,
        packetK: Int,
        schemaField: String,
        rawBodyOffset: Int,
        encoding: String,
        rawHex: String,
        rawI16LE: Int?,
        rawU16LE: Int?,
        semanticStatus: String,
        sourceKey: String
    ) {
        self.timestamp = timestamp
        self.celsius = celsius
        self.packetK = packetK
        self.schemaField = schemaField
        self.rawBodyOffset = rawBodyOffset
        self.encoding = encoding
        self.rawHex = rawHex
        self.rawI16LE = rawI16LE
        self.rawU16LE = rawU16LE
        self.semanticStatus = semanticStatus
        self.sourceKey = sourceKey
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
