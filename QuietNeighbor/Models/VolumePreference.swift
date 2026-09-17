import Foundation

/// Persisted per-app mixer state, keyed by bundle identifier (or a stable fallback).
struct VolumePreference: Codable, Equatable, Sendable {
    /// Relative linear amplitude versus the system output, 0...1.
    /// 50% is half as loud as the current system volume — not mute.
    var volume: Double
    var isMuted: Bool

    static let `default` = VolumePreference(volume: 1, isMuted: false)

    var clampedVolume: Double {
        min(1, max(0, volume))
    }

    /// A tap is only required when we must intercept the process (mute or not-100%).
    var needsTap: Bool {
        isMuted || clampedVolume < 0.995
    }

    /// Mute forces 0; otherwise the slider level. Continuous — not binary 0/1.
    var effectiveGain: Double {
        isMuted ? 0 : clampedVolume
    }
}
