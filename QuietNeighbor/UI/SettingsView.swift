import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var mixer: MixerController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("QuietNeighbor") {
                LabeledContent("Version", value: Bundle.main.shortVersionString)
                LabeledContent("macOS requirement", value: "14.2 or later")
                LabeledContent("Audio capture", value: permissionLabel)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                Text("Process taps need audio capture / microphone permission. QuietNeighbor is not sandboxed so Core Audio taps can attach to other apps. Prefer a Developer ID signed, notarized build over the App Store sandbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    AudioCapturePermission.openSystemSettings()
                }
                Button("Recheck permission") {
                    mixer.refresh()
                }
            }

            Section("About") {
                Text("Each slider is relative gain versus the current system output. The Mac’s volume keys still act as the master. Levels persist by bundle identifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var permissionLabel: String {
        switch mixer.permission {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private extension Bundle {
    var shortVersionString: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
