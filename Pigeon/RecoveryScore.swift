import Foundation

// WHOOP-style daily recovery from sleep-window physiology. Not a copy of WHOOP's
// proprietary model — uses the same inputs we can measure locally.

enum RecoveryZone: String, CaseIterable {
    case green
    case yellow
    case red
    case unavailable

    var displayName: String {
        switch self {
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .unavailable: return "Unavailable"
        }
    }
}

enum RecoveryScore {
    static let minimumBaselineDays = 4
    static let baselineLookbackDays = 21
    static let minimumHRVSamples = 5
    static let method = "recovery_v1"

    static let hrvWeight = 0.60
    static let rhrWeight = 0.25
    static let sleepWeight = 0.15

    struct NightlyMetrics {
        let hrvMS: Double
        let rhrBPM: Double
        let sleepMinutes: Double
        let hrvSampleCount: Int
    }

    struct Baseline {
        let hrvMS: Double
        let rhrBPM: Double
        let sleepMinutes: Double
        let dayCount: Int
    }

    struct Result {
        let score: Int
        let zone: RecoveryZone
        let hrvComponent: Double
        let rhrComponent: Double
        let sleepComponent: Double
    }

    static func zone(for score: Int) -> RecoveryZone {
        switch score {
        case 67...: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    static func compute(today: NightlyMetrics, baseline: Baseline) -> Result? {
        guard baseline.dayCount >= minimumBaselineDays else { return nil }
        guard today.hrvSampleCount >= minimumHRVSamples,
              today.hrvMS > 0,
              today.rhrBPM > 0,
              today.sleepMinutes > 0,
              baseline.hrvMS > 0,
              baseline.rhrBPM > 0,
              baseline.sleepMinutes > 0 else {
            return nil
        }

        let hrvComponent = componentHigherIsBetter(today: today.hrvMS, baseline: baseline.hrvMS)
        let rhrComponent = componentLowerIsBetter(today: today.rhrBPM, baseline: baseline.rhrBPM)
        let sleepComponent = min(today.sleepMinutes / baseline.sleepMinutes, 1.0)

        let raw = hrvComponent * hrvWeight +
            rhrComponent * rhrWeight +
            sleepComponent * sleepWeight
        let score = max(1, min(100, Int((raw * 100).rounded())))
        return Result(
            score: score,
            zone: zone(for: score),
            hrvComponent: hrvComponent,
            rhrComponent: rhrComponent,
            sleepComponent: sleepComponent
        )
    }

    /// Higher HRV vs baseline → higher component (0…1).
    private static func componentHigherIsBetter(today: Double, baseline: Double) -> Double {
        let ratio = today / baseline
        return clamp((ratio - 0.70) / 0.60, lower: 0, upper: 1)
    }

    /// Lower RHR vs baseline → higher component (0…1).
    private static func componentLowerIsBetter(today: Double, baseline: Double) -> Double {
        let ratio = baseline / today
        return clamp((ratio - 0.92) / 0.16, lower: 0, upper: 1)
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }
}
