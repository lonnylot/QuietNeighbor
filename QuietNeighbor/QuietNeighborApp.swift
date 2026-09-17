import AppKit
import SwiftUI

@main
struct QuietNeighborApp: App {
    static let subsystem = "com.lonnylot.QuietNeighbor"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(MixerHost.shared)
                .frame(width: 360, height: 480)
        } label: {
            Label("QuietNeighbor", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(MixerHost.shared)
        }
    }
}

/// Process-wide mixer, created on the main actor. First access starts
/// monitoring so saved levels apply before the menu bar is opened.
enum MixerHost {
    @MainActor
    static let shared: MixerController = {
        let controller = MixerController()
        controller.start()
        return controller
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Body or this callback may run first; start() is idempotent.
        MainActor.assumeIsolated {
            _ = MixerHost.shared
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            MixerHost.shared.stop()
        }
    }
}
