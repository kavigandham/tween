import XCTest
@testable import TweenApp

final class ReferralPolicyTests: XCTestCase {
    private let me = "ME"
    private let day: TimeInterval = 86_400

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
    }

    func testFirstInboundBubbleAttributesTheIntroducerOnce() {
        var state = ReferralState()
        let first = ReferralPolicy.noteInbound(senderID: "A", referredBy: nil, myID: me, state: &state)
        XCTAssertEqual(first, [.attributed(to: "A")])
        XCTAssertEqual(state.referredBy, "A")
        // A second sender does not replace the introducer.
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "B", referredBy: nil, myID: me, state: &state), [])
        XCTAssertEqual(state.referredBy, "A")
    }

    func testNoAttributionAfterIHaveSent_OrToMyself() {
        var state = ReferralState()
        ReferralPolicy.noteInbound(senderID: me, referredBy: nil, myID: me, state: &state)
        XCTAssertNil(state.referredBy, "my own bubble never introduces me")
        state.hasSentAny = true
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "A", referredBy: nil, myID: me, state: &state), [])
        XCTAssertNil(state.referredBy, "I was already here")
    }

    func testThreeDistinctReferralsGrantNinetyDays_DedupedPerSender() {
        var state = ReferralState(hasSentAny: true)
        let t0 = Date()
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "A", referredBy: me, myID: me, state: &state, now: t0),
                       [.referral(count: 1)])
        // The same friend sending again is still one referral.
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "A", referredBy: me, myID: me, state: &state, now: t0), [])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "B", referredBy: me, myID: me, state: &state, now: t0),
                       [.referral(count: 2)])
        // A bubble carrying someone ELSE's id is not my referral.
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "C", referredBy: "OTHER", myID: me, state: &state, now: t0), [])
        let events = ReferralPolicy.noteInbound(senderID: "D", referredBy: me, myID: me, state: &state, now: t0)
        XCTAssertEqual(events.first, .referral(count: 3))
        XCTAssertEqual(events.last, .granted(until: t0 + ReferralPolicy.grantDuration))
        XCTAssertTrue(ReferralPolicy.grantActive(state, now: t0 + 89 * day))
        XCTAssertFalse(ReferralPolicy.grantActive(state, now: t0 + 91 * day))
        XCTAssertEqual(ReferralPolicy.progress(state, now: t0), 3, "a full bar while the grant runs")
    }

    func testSixReferralsStackASecondGrantOnTheFirst() {
        var state = ReferralState(hasSentAny: true)
        let t0 = Date()
        for id in ["A", "B", "C"] {
            _ = ReferralPolicy.noteInbound(senderID: id, referredBy: me, myID: me, state: &state, now: t0)
        }
        let firstUntil = state.grantedUntil!
        for id in ["D", "E", "F"] {
            _ = ReferralPolicy.noteInbound(senderID: id, referredBy: me, myID: me, state: &state, now: t0 + 10 * day)
        }
        XCTAssertEqual(state.grantedUntil, firstUntil + ReferralPolicy.grantDuration, "extends, never restarts")
        XCTAssertEqual(state.grantsAwarded, 2)
        XCTAssertEqual(ReferralPolicy.progress(state, now: t0 + 10 * day), 3)
    }

    func testOutboundReferrerExpiresAfterThirtyDays() {
        var state = ReferralState()
        let t0 = Date()
        _ = ReferralPolicy.noteInbound(senderID: "A", referredBy: nil, myID: me, state: &state, now: t0)
        XCTAssertEqual(ReferralPolicy.outboundReferrer(state, now: t0 + 29 * day), "A")
        XCTAssertNil(ReferralPolicy.outboundReferrer(state, now: t0 + 31 * day))
    }

    func testPayloadCarriesTheReferrerAndRoundTrips() throws {
        let state = TweenState(text: "I'm in", latitude: 37.3, longitude: -121.9,
                               senderName: "Sam", senderID: "SAM", referredBy: "ME")
        let url = try XCTUnwrap(state.encodedURL())
        XCTAssertTrue(url.absoluteString.contains("ref=ME"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.referredBy, "ME")
        // Absent stays absent — older builds never send it.
        let plain = try XCTUnwrap(TweenState(url: try XCTUnwrap(
            TweenState(text: "I'm in", latitude: 37.3, longitude: -121.9, senderID: "SAM").encodedURL())))
        XCTAssertNil(plain.referredBy)
    }

    func testStoreHookGrantsProAndPersists() {
        ProEntitlement.setUnlocked(false)
        XCTAssertFalse(ProEntitlement.isUnlocked)
        var stored = ReferralState(hasSentAny: true)
        ReferralStore.save(stored)
        for id in ["A", "B", "C"] {
            let bubble = TweenState(text: "I'm in", latitude: 1, longitude: 1, senderID: id, referredBy: "ME")
            _ = Referrals.noteInbound(bubble, myID: "ME")
        }
        stored = ReferralStore.load()
        XCTAssertEqual(stored.referrals, ["A", "B", "C"])
        XCTAssertNotNil(ProEntitlement.referralGrantUntil)
        XCTAssertTrue(ProEntitlement.isUnlocked, "the grant flows into the cached Pro flag both processes read")
        ReferralStore.clear()
        ProEntitlement.syncUnlockedFlag()
        XCTAssertFalse(ProEntitlement.isUnlocked, "and expires with it")
    }
}
