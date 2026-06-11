import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var bluetooth: BluetoothManager

    init(modelContainer: ModelContainer) {
        _bluetooth = StateObject(wrappedValue: BluetoothManager(modelContainer: modelContainer))
    }

    var body: some View {
        TabView {
            HomeView(bluetooth: bluetooth)
                .tabItem {
                    Label("Home", systemImage: "heart.fill")
                }

            SettingsView(bluetooth: bluetooth)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .onAppear {
            bluetooth.runStartupMaintenanceAfterFirstRender()
        }
    }
}
