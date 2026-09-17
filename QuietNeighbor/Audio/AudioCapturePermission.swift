import AppKit
import AVFoundation
import Foundation

enum AudioCaptureAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined

    var allowsTaps: Bool {
        self == .authorized
    }
}

enum AudioCapturePermission {
    /// Process taps are authorized through the same TCC path as audio capture / microphone.
    static var status: AudioCaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    static func request() async -> AudioCaptureAuthorization {
        if status == .authorized { return .authorized }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return status
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ]
        for string in candidates {
            if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
