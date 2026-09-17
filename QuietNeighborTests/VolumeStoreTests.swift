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
}
