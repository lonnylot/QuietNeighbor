import XCTest

final class VolumeStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "quietneighbor.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripVolumeAndMute() {
        let store = VolumeStore(defaults: defaults)
        store.setVolume(0.4, for: "com.example.app")
        store.setMuted(true, for: "com.example.app")

        let reloaded = VolumeStore(defaults: defaults)
        let preference = reloaded.preference(for: "com.example.app")
        XCTAssertEqual(preference.volume, 0.4, accuracy: 0.0001)
        XCTAssertTrue(preference.isMuted)
        XCTAssertTrue(preference.needsTap)
    }

    func testUnknownKeyReturnsDefault() {
        let store = VolumeStore(defaults: defaults)
        XCTAssertEqual(store.preference(for: "missing.bundle"), .default)
    }

    func testResetToDefaultRemovesEntry() {
        let store = VolumeStore(defaults: defaults)
        store.setVolume(0.2, for: "com.example.app")
        store.setVolume(1, for: "com.example.app")
        store.setMuted(false, for: "com.example.app")
        XCTAssertNil(store.allPreferences()["com.example.app"])
    }

    func testMuteForcesSilenceAndUnmuteRestoresSlider() {
        let store = VolumeStore(defaults: defaults)
        store.setVolume(0.5, for: "com.apple.Music")
        store.setMuted(true, for: "com.apple.Music")

        var preference = store.preference(for: "com.apple.Music")
        XCTAssertTrue(preference.isMuted)
        XCTAssertEqual(preference.volume, 0.5, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain, 0)
        XCTAssertEqual(TapGain.linear(volume: preference.volume, isMuted: preference.isMuted), 0)

        store.setMuted(false, for: "com.apple.Music")
        preference = store.preference(for: "com.apple.Music")
        XCTAssertFalse(preference.isMuted)
        XCTAssertEqual(preference.volume, 0.5, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            TapGain.linear(volume: preference.volume, isMuted: preference.isMuted),
            0.5,
            accuracy: 0.0001
        )
    }

    func testMuteAlonePersistsAtFullVolume() {
        let store = VolumeStore(defaults: defaults)
        store.setMuted(true, for: "com.apple.Music")

        let preference = store.preference(for: "com.apple.Music")
        XCTAssertTrue(preference.isMuted)
        XCTAssertEqual(preference.volume, 1, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain, 0)
        XCTAssertTrue(preference.needsTap)

        let reloaded = VolumeStore(defaults: defaults)
        XCTAssertTrue(reloaded.preference(for: "com.apple.Music").isMuted)
        XCTAssertEqual(reloaded.preference(for: "com.apple.Music").effectiveGain, 0)
    }

    func testPartialSliderPersistsAsContinuousGainNotMute() {
        let store = VolumeStore(defaults: defaults)
        store.setVolume(0.5, for: "com.apple.Music")

        let preference = store.preference(for: "com.apple.Music")
        XCTAssertFalse(preference.isMuted)
        XCTAssertEqual(preference.volume, 0.5, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain, 0.5, accuracy: 0.0001)
        XCTAssertTrue(preference.needsTap)

        let command = TapGain.ioCommand(for: preference)
        XCTAssertFalse(command.muted)
        XCTAssertEqual(command.gain, 0.5, accuracy: 0.0001)
        XCTAssertNotEqual(command.gain, 0)
    }

    func testUnmuteRestoresSavedVolumeWithoutClearingIt() {
        let store = VolumeStore(defaults: defaults)
        store.setVolume(0.35, for: "com.example.loud")
        store.setMuted(true, for: "com.example.loud")
        store.setMuted(false, for: "com.example.loud")

        let preference = store.preference(for: "com.example.loud")
        XCTAssertFalse(preference.isMuted)
        XCTAssertEqual(preference.volume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(preference.effectiveGain, 0.35, accuracy: 0.0001)
    }
}
