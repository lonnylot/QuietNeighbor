import XCTest

final class MuteAccessibilityTests: XCTestCase {
    func testMuteIdentifierUsesPersistenceKey() {
        XCTAssertEqual(
            MixerAccessibility.muteIdentifier(for: "com.apple.Music"),
            "quietNeighbor.mute.com.apple.Music"
        )
        XCTAssertEqual(
            MixerAccessibility.rowIdentifier(for: "com.apple.Music"),
            "quietNeighbor.row.com.apple.Music"
        )
        XCTAssertEqual(MixerAccessibility.settingsIdentifier, "quietNeighbor.settings")
        XCTAssertEqual(
            MixerAccessibility.systemAudioRecordingIdentifier,
            "quietNeighbor.systemAudioRecording"
        )
        XCTAssertEqual(
            MixerAccessibility.openSystemAudioRecordingIdentifier,
            "quietNeighbor.openSystemAudioRecording"
        )
    }

    func testSystemAudioRecordingSettingsPreferCaptureThenScreen() {
        let urls = AudioCapturePermission.systemAudioRecordingSettingsURLs
        XCTAssertTrue(urls.contains { $0.contains("Privacy_AudioCapture") })
        XCTAssertTrue(urls.contains { $0.contains("Privacy_ScreenCapture") })
        XCTAssertEqual(urls.first?.contains("Privacy_AudioCapture"), true)
        for string in urls {
            XCTAssertNotNil(URL(string: string), string)
        }
    }
}
