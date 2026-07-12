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

    func testDeactivatedManualSelfIsNotSendable() {
        // The freshness exemption is opt-in-gated: an ACTIVE declaration travels,
        // a deactivated one (after leaving) must NOT be re-shared (post-push audit).
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        XCTAssertNotNil(LocationCache.freshSelfCoordinate())
        LocationCache.deactivateSelf()
        XCTAssertNil(LocationCache.freshSelfCoordinate(),
                     "a deactivated declaration must not be sendable")
    }

    func testProductionResetMakesManualSelfUnsendable() {
        // startFreshMeetup is the production reset (clearAll has no prod callers).
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        LocationCache.startFreshMeetup()
        XCTAssertFalse(LocationCache.isActive, "a reset deactivates the manual self")
        XCTAssertNil(LocationCache.freshSelfCoordinate(),
                     "after a reset the declared self must not travel in a send")
        LocationCache.clearAll()
        XCTAssertNil(LocationCache.loadSelf()?.coordinate, "clearAll wipes it entirely")
    }

    func testDeactivatePreservesManualFlag() {
        LocationCache.save(coord, at: stale, isActive: true, isManual: true)
        LocationCache.setActive(false)
        XCTAssertEqual(LocationCache.loadSelf()?.isManual, true,
                       "flipping the active flag must not lose provenance")
    }

    // MARK: Poll must not wipe a solo ranking after a leave

    func testLeaveResetsRankingOnlyWhileTearingDownPeerState() {
        // Device bug: after leaving a meetup, the conversation keeps a leave
        // tombstone, so refreshFromAppGroup saw `localLeft == true` on EVERY 2 s
        // poll. It unconditionally cleared rankedSpots — wiping a fresh solo/
        // manual A→B search the user started AFTER leaving ("search works, then
        // it refreshes and loses all logic"). The reset must fire only on the
        // tick that actually tears down live peer state, not forever after.

        // The teardown tick: a peer (or extras) is still present, being removed.
        XCTAssertTrue(OnboardingView.shouldResetRankingOnLeave(
            localLeft: true, hasLivePeerState: true),
            "the tick the departure lands should clear stale peer chips")

        // Every subsequent poll: tombstone still says left, but the peer is gone.
        // A solo/manual ranking has no departed-peer chips — it must survive.
        XCTAssertFalse(OnboardingView.shouldResetRankingOnLeave(
            localLeft: true, hasLivePeerState: false),
            "a solo A→B search after leaving must not be wiped on every poll")

        // Not left → never reset from this path, regardless of peer state.
        XCTAssertFalse(OnboardingView.shouldResetRankingOnLeave(
            localLeft: false, hasLivePeerState: true))
        XCTAssertFalse(OnboardingView.shouldResetRankingOnLeave(
            localLeft: false, hasLivePeerState: false))
    }
}
