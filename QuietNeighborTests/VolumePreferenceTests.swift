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
        XCTAssertNotEqual(preference.effectiveGain, 0, "50% must be half gain, not mute")
    }

    func testSliderIsContinuousRelativeGain() {
        for step in 0...100 {
            let volume = Double(step) / 100
            let preference = VolumePreference(volume: volume, isMuted: false)
            XCTAssertEqual(preference.effectiveGain, volume, accuracy: 0.0001)
            XCTAssertEqual(
                TapGain.linear(volume: volume, isMuted: false),
                Float32(volume),
                accuracy: 0.0001
            )
            if step == 0 {
                XCTAssertEqual(preference.effectiveGain, 0)
            } else if step == 100 {
                XCTAssertEqual(preference.effectiveGain, 1)
                XCTAssertFalse(preference.needsTap)
            } else {
                XCTAssertGreaterThan(preference.effectiveGain, 0)
                XCTAssertLessThan(preference.effectiveGain, 1)
            }
        }
    }

    func testMutedNeedsTapEvenAtFullVolume() {
        let preference = VolumePreference(volume: 1, isMuted: true)
        XCTAssertTrue(preference.needsTap)
        XCTAssertEqual(preference.effectiveGain, 0)
        XCTAssertNotEqual(preference, .default)
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

    func testNeedsTapDoesNotMeanMute() {
        let preference = VolumePreference(volume: 0.25, isMuted: false)
        XCTAssertTrue(preference.needsTap)
        XCTAssertFalse(preference.isMuted)
        XCTAssertEqual(preference.effectiveGain, 0.25, accuracy: 0.0001)
        let command = TapGain.ioCommand(for: preference)
        XCTAssertFalse(command.muted)
        XCTAssertEqual(command.gain, 0.25, accuracy: 0.0001)
    }
}
