import XCTest

final class VolumePreferenceTests: XCTestCase {
    func testDefaultDoesNotNeedTap() {
        XCTAssertFalse(VolumePreference.default.needsTap)
        XCTAssertEqual(VolumePreference.default.effectiveGain, 1)
    }

    func testLowVolumeNeedsTap() {
        let preference = VolumePreference(volume: 0.5, isMuted: false)
        XCTAssertTrue(preference.needsTap)
        XCTAssertEqual(preference.effectiveGain, 0.5)
    }

    func testMutedNeedsTapEvenAtFullVolume() {
        let preference = VolumePreference(volume: 1, isMuted: true)
        XCTAssertTrue(preference.needsTap)
        XCTAssertEqual(preference.effectiveGain, 0)
    }

    func testNearUnityIsPassthrough() {
        XCTAssertFalse(VolumePreference(volume: 0.997, isMuted: false).needsTap)
        XCTAssertTrue(VolumePreference(volume: 0.99, isMuted: false).needsTap)
    }

    func testClampsVolume() {
        XCTAssertEqual(VolumePreference(volume: 1.4, isMuted: false).clampedVolume, 1)
        XCTAssertEqual(VolumePreference(volume: -0.2, isMuted: false).clampedVolume, 0)
        XCTAssertEqual(VolumePreference(volume: 1.4, isMuted: false).effectiveGain, 1)
    }
}
