import AppKit
import CoreAudio
import Foundation

/// One row in the mixer: a user-facing app that may own several helper processes.
struct AudioApp: Identifiable, Equatable {
    var id: String { persistenceKey }

    /// Bundle id when available; otherwise a stable executable-path key.
    var persistenceKey: String
    var name: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    var icon: NSImage?
    var processObjectIDs: [AudioObjectID]
    var pids: [pid_t]
    var isPlaying: Bool
    var lastHeard: Date?
    var volume: Double
    var isMuted: Bool
    var tapActive: Bool
    var tapError: String?

    var volumePercent: Int {
        Int((min(1, max(0, volume)) * 100).rounded())
    }

    var isRecentlyHeard: Bool {
        guard let lastHeard else { return false }
        return Date().timeIntervalSince(lastHeard) < AudioApp.recentGrace
    }

    static let recentGrace: TimeInterval = 10 * 60
}

/// HAL + process-table snapshot used to build `AudioApp` rows.
struct ResolvedAppIdentity: Equatable, Sendable {
    var persistenceKey: String
    var name: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    var executablePath: String?
    var processObjectIDs: [AudioObjectID]
    var pids: [pid_t]
    var isPlaying: Bool
}
