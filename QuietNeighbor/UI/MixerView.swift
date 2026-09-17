import AppKit
import SwiftUI

struct MixerView: View {
    @EnvironmentObject private var mixer: MixerController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if mixer.permission != .authorized {
                permissionBanner
                Divider()
            } else if let lastError = mixer.lastError {
                Text(lastError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }
            appList
            Divider()
            footer
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("QuietNeighbor")
                    .font(.system(size: 14, weight: .semibold))
                Text("Per-app volume · system volume stays master")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier(MixerAccessibility.settingsIdentifier)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(permissionTitle)
                .font(.system(size: 12, weight: .semibold))
            Text("macOS treats process taps as audio capture. QuietNeighbor uses them only to apply per-app gain, then plays through your current output device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if mixer.permission == .notDetermined {
                    Button("Allow Audio Capture") {
                        mixer.requestPermission()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Privacy Settings") {
                        AudioCapturePermission.openSystemSettings()
                    }
                    .controlSize(.small)
                }
                Button("Recheck") {
                    mixer.refresh()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
    }

    private var permissionTitle: String {
        switch mixer.permission {
        case .denied:
            return "Audio capture is denied"
        case .notDetermined:
            return "Audio capture permission needed"
        case .authorized:
            return "Audio capture allowed"
        }
    }

    @ViewBuilder
    private var appList: some View {
        if mixer.apps.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No apps are playing audio")
                    .font(.system(size: 13, weight: .medium))
                Text("Start playback in another app. QuietNeighbor lists processes that are producing sound, or recently did.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(mixer.apps) { app in
                        AppRowView(
                            app: app,
                            onVolume: { mixer.setVolume($0, for: app) },
                            onMute: { mixer.setMuted($0, for: app) }
                        )
                        if app.id != mixer.apps.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                mixer.refresh()
            }
            .controlSize(.small)
            Spacer()
            Button("Quit QuietNeighbor") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
