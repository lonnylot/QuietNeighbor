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
            }

            HStack(spacing: 8) {
                Button {
                    onMute(!app.isMuted)
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : speakerSymbol)
                        .foregroundStyle(app.isMuted ? Color.secondary : Color.accentColor)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

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
                .accessibilityLabel("\(app.name) volume")
            }

            if let tapError = app.tapError {
                Text(tapError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
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
