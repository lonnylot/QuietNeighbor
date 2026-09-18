import SwiftUI

struct AppRowView: View {
    let app: AudioApp
    let onVolume: (Double) -> Void
    let onMute: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                appIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(app.isMuted ? "Muted" : "\(app.volumePercent)%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(app.isMuted ? .secondary : .primary)
                    .frame(width: 48, alignment: .trailing)
                    .accessibilityIdentifier(MixerAccessibility.levelIdentifier(for: app.persistenceKey))
                    .accessibilityLabel(app.isMuted ? "\(app.name) is muted" : "\(app.name) volume \(app.volumePercent) percent")
            }

            HStack(spacing: 10) {
                muteToggle

                Slider(
                    value: Binding(
                        get: { app.volume },
                        set: onVolume
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(app.isMuted)
                .opacity(app.isMuted ? 0.45 : 1)
                .accessibilityIdentifier(MixerAccessibility.volumeIdentifier(for: app.persistenceKey))
                .accessibilityLabel("\(app.name) volume")
                .accessibilityValue("\(app.volumePercent) percent")
            }

            if let tapError = app.tapError {
                Text(tapError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(MixerAccessibility.errorIdentifier(for: app.persistenceKey))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MixerAccessibility.rowIdentifier(for: app.persistenceKey))
    }

    private var muteToggle: some View {
        Toggle(isOn: Binding(
            get: { app.isMuted },
            set: onMute
        )) {
            Image(systemName: app.isMuted ? "speaker.slash.fill" : speakerSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(app.isMuted ? Color.secondary : Color.accentColor)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .toggleStyle(LargeHitMuteToggleStyle())
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .help(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityIdentifier(MixerAccessibility.muteIdentifier(for: app.persistenceKey))
        .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityValue(app.isMuted ? "Muted" : "Unmuted")
        .accessibilityHint("Silences only this app. System volume stays the master.")
        .accessibilityAddTraits(.isButton)
    }

    private var statusText: String {
        if app.isPlaying { return "Playing" }
        if app.isRecentlyHeard { return "Recently played" }
        if app.isMuted { return "Muted · saved" }
        return "Saved level"
    }

    private var speakerSymbol: String {
        switch app.volume {
        case 0:
            return "speaker.fill"
        case ..<0.4:
            return "speaker.wave.1.fill"
        case ..<0.75:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

/// Button-styled mute toggle with a 36×36 hit target.
private struct LargeHitMuteToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
}
