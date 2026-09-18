import Foundation

/// Stable Accessibility identifiers for Mac QA / Accessibility Inspector.
enum MixerAccessibility {
    static func muteIdentifier(for persistenceKey: String) -> String {
        "quietNeighbor.mute.\(persistenceKey)"
    }

    static func volumeIdentifier(for persistenceKey: String) -> String {
        "quietNeighbor.volume.\(persistenceKey)"
    }

    static func levelIdentifier(for persistenceKey: String) -> String {
        "quietNeighbor.level.\(persistenceKey)"
    }

    static func rowIdentifier(for persistenceKey: String) -> String {
        "quietNeighbor.row.\(persistenceKey)"
    }

    static func errorIdentifier(for persistenceKey: String) -> String {
        "quietNeighbor.error.\(persistenceKey)"
    }

    static let settingsIdentifier = "quietNeighbor.settings"
    static let systemAudioRecordingIdentifier = "quietNeighbor.systemAudioRecording"
    static let openSystemAudioRecordingIdentifier = "quietNeighbor.openSystemAudioRecording"
}
