import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()

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
    }
}
