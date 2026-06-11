import SwiftUI
import SwiftData

@main
struct PigeonApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: HRSample.self, RRSample.self, HRVSample.self,
                                                    MotionSample.self, MotionBucketSummary.self,
                                                    SleepWindowSummary.self, RecoverySummary.self,
                                                    HourlySummary.self, DailySummary.self,
                                                    MonthlySummary.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContainer: modelContainer)
        }
        .modelContainer(modelContainer)
    }
}
