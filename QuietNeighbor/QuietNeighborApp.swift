import SwiftUI

@main
struct QuietNeighborApp: App {
    static let subsystem = "com.lonnylot.QuietNeighbor"

    @StateObject private var mixer = MixerController()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(mixer)
                .frame(width: 360, height: 480)
        } label: {
            Label("QuietNeighbor", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(mixer)
        }
    }
}
