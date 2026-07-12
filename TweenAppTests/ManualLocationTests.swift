import XCTest
import CoreLocation
@testable import TweenApp

/// The manual-location primitive powering solo A→B, "I'll be at…", and adding a
/// non-app-user. A DECLARED location (not a GPS fix) must not age out of the
/// 5-minute freshness window, and a locally-added point must be identifiable so
/// it never rides into a sent bubble.
final class ManualLocationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    private let coord = CLLocationCoordinate2D(latitude: 37.33, longitude: -121.88)
    private let stale = Date(timeIntervalSinceNow: -600)   // 10 min ago

    // MARK: Participant.manual

    func testManualParticipantIsFlagged() {
        let m = Participant.manual(label: "The office", coordinate: coord)
        XCTAssertTrue(m.isManual)
        XCTAssertTrue(m.id.hasPrefix("manual:"))
        XCTAssertEqual(m.name, "The office")
        XCTAssertFalse(Participant(id: "abc", name: "Sam", coordinate: coord).isManual)
    }

    // MARK: Freshness exemption

    func testManualSelfIsFreshEvenWhenOld() {
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        XCTAssertNotNil(LocationCache.freshSelfCoordinate(),
                        "a declared location never goes stale")
        XCTAssertTrue(LocationCache.isActive)
    }

    func testGpsSelfStillAgesOut() {
        LocationCache.save(coord, at: stale, isActive: true, isManual: false)
        XCTAssertNil(LocationCache.freshSelfCoordinate(),
                     "a measured GPS fix past the window is stale")
        XCTAssertFalse(LocationCache.isActive)
    }

    func testPreProvenanceBlobDecodesAsGps() {
        // A blob written before isManual existed decodes with isManual == nil
        // and must behave like GPS (ages out).
        struct LegacyCoord: Codable { let latitude, longitude: Double; let timestamp: Date; let isActive: Bool? }
        let legacy = LegacyCoord(latitude: coord.latitude, longitude: coord.longitude,
                                 timestamp: stale, isActive: true)
        let data = try! JSONEncoder().encode(legacy)
        UserDefaults(suiteName: LocationCache.appGroup)?.set(data, forKey: "tween.cache.self")
        XCTAssertNil(LocationCache.freshSelfCoordinate())
    }

    func testResetDeactivatesThenClearsManualSelf() {
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        LocationCache.startFreshMeetup()
        XCTAssertFalse(LocationCache.isActive, "a reset deactivates the manual self")
        LocationCache.clearAll()
        XCTAssertNil(LocationCache.loadSelf()?.coordinate, "clearAll wipes it entirely")
    }

    func testDeactivatePreservesManualFlag() {
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        LocationCache.setActive(false)
        XCTAssertEqual(LocationCache.loadSelf()?.isManual, true,
                       "flipping the active flag must not lose provenance")
    }
}
