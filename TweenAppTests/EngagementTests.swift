import XCTest
import CoreLocation
@testable import TweenApp

/// SplitMix64: a tiny seeded generator, so the "random number from 1 to
/// 10" is reproducible in tests. (A constant word would spin
/// `Int.random(in:using:)`'s rejection sampling forever.)
private struct FixedRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class NudgePolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
    }

    /// Drives events until a nudge fires; returns the count it fired at.
    private func eventsUntilNudge(_ target: Nudge, state: inout EngagementState,
                                  proUnlocked: Bool = false, now: Date = Date(),
                                  rng: inout FixedRNG, limit: Int = 100) -> Int? {
        for i in 1...limit {
            if NudgePolicy.record(.sendToChat, in: &state, proUnlocked: proUnlocked,
                                  now: now, using: &rng) == target {
                return i
            }
        }
        return nil
    }

    func testFirstProNudgeLandsWithinOneToTenEvents() {
        // Whatever the roll, the first Pro pop-up is due at a count in 1…10.
        for seed in [UInt64(0), 3, 7, 9, 42, 999_999] {
            var rng = FixedRNG(seed: seed)
            var state = EngagementState()
            let at = eventsUntilNudge(.pro, state: &state, rng: &rng)
            XCTAssertNotNil(at, "seed \(seed)")
            XCTAssertTrue((1...10).contains(at!), "seed \(seed) fired at \(at!)")
        }
    }

    func testProNudgeNeverShowsWhenUnlocked() {
        var rng = FixedRNG(seed: 1)
        var state = EngagementState()
        XCTAssertNil(eventsUntilNudge(.pro, state: &state, proUnlocked: true, rng: &rng, limit: 50))
    }

    func testProNudgeRespectsCooldownThenReRolls() {
        var rng = FixedRNG(seed: 1)
        var state = EngagementState()
        let t0 = Date()
        let firedAt = eventsUntilNudge(.pro, state: &state, now: t0, rng: &rng)!
        XCTAssertTrue((1...10).contains(firedAt))
        XCTAssertTrue(NudgePolicy.proRepeatWindow.contains(state.proNextAt! - firedAt))
        // Enough events for the threshold, but inside the 7-day cooldown: no.
        for _ in 0..<10 {
            XCTAssertNotEqual(NudgePolicy.record(.imIn, in: &state, proUnlocked: false,
                                                 now: t0 + 1 * day, using: &rng), .pro)
        }
        // Past the cooldown: yes.
        XCTAssertEqual(NudgePolicy.record(.imIn, in: &state, proUnlocked: false,
                                          now: t0 + 8 * day, using: &rng), .pro)
    }

    func testTwoDismissalsBackOffToThirtyDays() {
        var rng = FixedRNG(seed: 1)
        var state = EngagementState()
        let t0 = Date()
        XCTAssertNotNil(eventsUntilNudge(.pro, state: &state, now: t0, rng: &rng))
        NudgePolicy.noteProDismissed(in: &state)
        NudgePolicy.noteProDismissed(in: &state)
        for _ in 0..<10 { _ = NudgePolicy.record(.imIn, in: &state, proUnlocked: false, now: t0, using: &rng) }
        XCTAssertNotEqual(NudgePolicy.record(.imIn, in: &state, proUnlocked: false,
                                             now: t0 + 8 * day, using: &rng), .pro,
                          "7 days is no longer enough after two dismissals")
        XCTAssertEqual(NudgePolicy.record(.imIn, in: &state, proUnlocked: false,
                                          now: t0 + 31 * day, using: &rng), .pro)
    }

    func testReviewAskLandsWithinThreeToTenAndYieldsToPro() {
        // Pro unlocked, so only the review ask is in play.
        for seed in [UInt64(0), 5, 9, 12345] {
            var rng = FixedRNG(seed: seed)
            var state = EngagementState()
            let at = eventsUntilNudge(.review, state: &state, proUnlocked: true, rng: &rng)
            XCTAssertNotNil(at, "seed \(seed)")
            XCTAssertTrue((3...10).contains(at!), "seed \(seed) fired at \(at!)")
        }
        // Both due on the same event: Pro wins, review waits for a later one.
        var rng = FixedRNG(seed: 1)
        var state = EngagementState()
        var results: [Nudge] = []
        let t0 = Date()
        for _ in 1...30 {
            if let nudge = NudgePolicy.record(.agreed, in: &state, proUnlocked: false, now: t0, using: &rng) {
                results.append(nudge)
            }
        }
        XCTAssertEqual(results.first, .pro, "the Pro pop-up comes before any review ask")
        XCTAssertTrue(results.contains(.review))
        XCTAssertEqual(results.filter { $0 == .pro }.count, 1, "one Pro pop-up per cooldown window")
        XCTAssertEqual(results.filter { $0 == .review }.count, 1, "one review ask per cooldown window")
    }

    func testReviewCooldownIsSixtyDays() {
        var rng = FixedRNG(seed: 1)
        var state = EngagementState()
        let t0 = Date()
        XCTAssertNotNil(eventsUntilNudge(.review, state: &state, proUnlocked: true, now: t0, rng: &rng))
        XCTAssertNotNil(state.reviewLastAskedAt)
        for _ in 0..<25 {
            XCTAssertNil(NudgePolicy.record(.sendToChat, in: &state, proUnlocked: true,
                                            now: t0 + 30 * day, using: &rng))
        }
        XCTAssertEqual(NudgePolicy.record(.sendToChat, in: &state, proUnlocked: true,
                                          now: t0 + 61 * day, using: &rng), .review)
    }

    func testStoreRoundTrips() {
        var state = EngagementState()
        state.count(.imIn); state.count(.sendToChat); state.count(.agreed)
        state.proNextAt = 7
        state.proLastShownAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.proDismissals = 1
        EngagementStore.save(state)
        XCTAssertEqual(EngagementStore.load(), state)
        XCTAssertEqual(EngagementStore.load().positiveEvents, 3)
        EngagementStore.clear()
        XCTAssertEqual(EngagementStore.load(), EngagementState())
    }
}

final class TourDemoFriendTests: XCTestCase {
    func testDemoFriendIsAboutTwentyMinutesNorthEast() {
        let me = CLLocationCoordinate2D(latitude: 39.0438, longitude: -77.4874) // Ashburn
        let friend = OnboardingView.demoFriendCoordinate(from: me)
        let metres = CLLocation(latitude: me.latitude, longitude: me.longitude)
            .distance(from: CLLocation(latitude: friend.latitude, longitude: friend.longitude))
        let expected = 20 * 60 * TravelMode.driving.fallbackMetresPerSecond
        XCTAssertEqual(metres, expected, accuracy: expected * 0.05)
        XCTAssertGreaterThan(friend.latitude, me.latitude, "north")
        XCTAssertGreaterThan(friend.longitude, me.longitude, "east")
    }
}
