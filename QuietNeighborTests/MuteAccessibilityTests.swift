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
    }
}
