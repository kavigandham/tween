import XCTest
@testable import TweenApp

/// Coverage of the host→extension spot hand-off, backed by the App Group suite
/// (wiped before each test).
final class OutgoingDraftTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        OutgoingDraftStore.clear()
    }

    // 1. A saved draft round-trips through the suite intact.
    func testSaveLoadRoundTrip() {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = OutgoingDraft(
            spotName: "Blue Bottle Coffee",
            latitude: 37.7825,
            longitude: -122.4099,
            timestamp: stamp)

        OutgoingDraftStore.save(draft)

        let loaded = OutgoingDraftStore.load()
        XCTAssertEqual(loaded, draft)
        XCTAssertEqual(loaded?.spotName, "Blue Bottle Coffee")
        XCTAssertEqual(loaded?.latitude, 37.7825)
        XCTAssertEqual(loaded?.longitude, -122.4099)
    }

    // 2. Clearing removes the staged draft.
    func testClearRemovesDraft() {
        OutgoingDraftStore.save(OutgoingDraft(
            spotName: "Dolores Park", latitude: 37.7596, longitude: -122.4269))
        XCTAssertNotNil(OutgoingDraftStore.load())

        OutgoingDraftStore.clear()
        XCTAssertNil(OutgoingDraftStore.load())
    }

    // 3. Saving again overwrites the prior draft rather than stacking.
    func testOverwriteReplaces() {
        OutgoingDraftStore.save(OutgoingDraft(
            spotName: "First Spot", latitude: 1, longitude: 2))
        OutgoingDraftStore.save(OutgoingDraft(
            spotName: "Second Spot", latitude: 3, longitude: 4))

        let loaded = OutgoingDraftStore.load()
        XCTAssertEqual(loaded?.spotName, "Second Spot")
        XCTAssertEqual(loaded?.latitude, 3)
        XCTAssertEqual(loaded?.longitude, 4)
    }
}
