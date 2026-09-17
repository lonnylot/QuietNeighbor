import AppKit
import SwiftUI

@main
struct QuietNeighborApp: App {
    static let subsystem = "com.lonnylot.QuietNeighbor"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(appDelegate.mixer)
                .frame(width: 360, height: 480)
        } label: {
            Label("QuietNeighbor", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.mixer)
        }
    }
}

/// Starts the mixer as soon as the process is up (so saved levels apply
/// before the menu is opened) and tears taps down on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = MixerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stop()
    }
}
