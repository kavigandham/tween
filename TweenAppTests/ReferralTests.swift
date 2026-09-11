import XCTest
@testable import TweenApp

final class ReferralPolicyTests: XCTestCase {
    private let me = "00000000-0000-4000-8000-00000000000E"
    private let a = "00000000-0000-4000-8000-00000000000A"
    private let b = "00000000-0000-4000-8000-00000000000B"
    private let c = "00000000-0000-4000-8000-00000000000C"
    private let d = "00000000-0000-4000-8000-00000000000D"
    private let day: TimeInterval = 86_400

    private var newUser: ReferralState { ReferralState(firstSeenAt: Date()) }

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: LocationCache.appGroup)?
            .removePersistentDomain(forName: LocationCache.appGroup)
    }

    // MARK: Who introduced me

    func testFirstInboundBubbleAttributesTheIntroducerOnce() {
        var state = newUser
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &state),
                       [.attributed(to: a)])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: b, referredBy: nil, myID: me, state: &state), [])
        XCTAssertEqual(state.referredBy, a)
    }

    func testAnInviteOutranksAnInferenceUntilIHaveSent() {
        var state = newUser
        _ = ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &state)
        // B's explicit invite takes over from A's ordinary bubble…
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: b, referredBy: nil, myID: me, viaInvite: true, state: &state),
                       [.attributed(to: b)])
        XCTAssertTrue(state.referredViaInvite)
        // …but nothing outranks an invite.
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: c, referredBy: nil, myID: me, viaInvite: true, state: &state), [])
        XCTAssertEqual(state.referredBy, b)
        // And once my first bubble named A, an invite can't rewrite it.
        var sent = newUser
        _ = ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &sent)
        sent.hasSentAny = true
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: b, referredBy: nil, myID: me, viaInvite: true, state: &sent), [])
        XCTAssertEqual(sent.referredBy, a)
    }

    func testExistingAndOldInstallsCanNeverBeIntroduced() {
        var existing = ReferralState(firstSeenAt: Date(), existingUser: true)
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, viaInvite: true, state: &existing), [])
        var old = ReferralState(firstSeenAt: Date().addingTimeInterval(-15 * day))
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &old), [])
    }

    func testNonInstallIDsAndMyselfAreRefused() {
        var state = newUser
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: me, referredBy: nil, myID: me, state: &state), [])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: "Sam", referredBy: nil, myID: me, state: &state), [])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: String(repeating: "x", count: 4000),
                                                  referredBy: nil, myID: me, state: &state), [])
        XCTAssertNil(state.referredBy)
    }

    func testOwesReplyOnlyForAnUnansweredInvite() {
        var state = newUser
        _ = ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &state)
        XCTAssertNil(ReferralPolicy.owesReply(state), "an inferred introducer is not owed a reply")
        _ = ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, viaInvite: true, state: &state)
        XCTAssertEqual(ReferralPolicy.owesReply(state), a)
        state.repliedTo.append(a)
        XCTAssertNil(ReferralPolicy.owesReply(state))
    }

    // MARK: Whom I introduced

    func testThreeDistinctReferralsGrantNinetyDays_DedupedPerSender() {
        var state = ReferralState(existingUser: true)
        let t0 = Date()
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: a, referredBy: me, myID: me, state: &state, now: t0),
                       [.referral(count: 1)])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: a, referredBy: me, myID: me, state: &state, now: t0), [])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: b, referredBy: me, myID: me, state: &state, now: t0),
                       [.referral(count: 2)])
        XCTAssertEqual(ReferralPolicy.noteInbound(senderID: c, referredBy: a, myID: me, state: &state, now: t0), [],
                       "someone else's referral is not mine")
        let events = ReferralPolicy.noteInbound(senderID: d, referredBy: me, myID: me, state: &state, now: t0)
        XCTAssertEqual(events, [.referral(count: 3), .granted(until: t0 + ReferralPolicy.grantDuration)])
        XCTAssertTrue(ReferralPolicy.grantActive(state, now: t0 + 89 * day))
        XCTAssertFalse(ReferralPolicy.grantActive(state, now: t0 + 91 * day))
        XCTAssertEqual(ReferralPolicy.progress(state, now: t0), 3, "a full ring while the grant runs")
        XCTAssertEqual(ReferralPolicy.progress(state, now: t0 + 91 * day), 0, "a fresh cycle once it lapses")
    }

    func testSixReferralsStackASecondGrantOnTheFirst() {
        var state = ReferralState(existingUser: true)
        let t0 = Date()
        let ids = (1...6).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        for id in ids.prefix(3) {
            _ = ReferralPolicy.noteInbound(senderID: id, referredBy: me, myID: me, state: &state, now: t0)
        }
        let firstUntil = state.grantedUntil!
        for id in ids.suffix(3) {
            _ = ReferralPolicy.noteInbound(senderID: id, referredBy: me, myID: me, state: &state, now: t0 + 10 * day)
        }
        XCTAssertEqual(state.grantedUntil, firstUntil + ReferralPolicy.grantDuration, "extends, never restarts")
        XCTAssertEqual(state.grantsAwarded, 2)
    }

    func testOutboundReferrerExpiresAfterThirtyDays() {
        var state = newUser
        let t0 = Date()
        _ = ReferralPolicy.noteInbound(senderID: a, referredBy: nil, myID: me, state: &state, now: t0)
        XCTAssertEqual(ReferralPolicy.outboundReferrer(state, now: t0 + 29 * day), a)
        XCTAssertNil(ReferralPolicy.outboundReferrer(state, now: t0 + 31 * day))
    }

    // MARK: Messages and payloads

    func testReferralMessagesRoundTripAndRefuseJunk() throws {
        let invite = ReferralMessage(kind: .invite, senderID: a, senderName: "Hassan")
        let decodedInvite = try XCTUnwrap(ReferralMessage(url: try XCTUnwrap(invite.encodedURL())))
        XCTAssertEqual(decodedInvite, invite)
        XCTAssertTrue(invite.encodedURL()!.absoluteString.hasPrefix("https://"), "constraint 2: https only")

        let joined = ReferralMessage(kind: .joined, senderID: b, senderName: "Kavi", inviterID: a)
        XCTAssertEqual(ReferralMessage(url: try XCTUnwrap(joined.encodedURL())), joined)

        // A joined reply must name the invite it answers; ids must be UUIDs.
        XCTAssertNil(ReferralMessage(url: URL(string: "https://tween.app/r?k=joined&fromId=\(b)")!))
        XCTAssertNil(ReferralMessage(url: URL(string: "https://tween.app/r?k=invite&fromId=Sam")!))
        XCTAssertNil(ReferralMessage(url: URL(string: "tween://r?k=invite&fromId=\(a)")!), "no custom scheme")
        // A meetup bubble is not a referral message, and vice versa.
        let meetup = TweenState(text: "I'm in", latitude: 1, longitude: 1, senderID: a).encodedURL()!
        XCTAssertNil(ReferralMessage(url: meetup))
        XCTAssertNil(TweenState(url: invite.encodedURL()!))
    }

    func testPayloadCarriesTheReferrer_BoundedAndDroppedFirstWhenOversize() throws {
        let state = TweenState(text: "I'm in", latitude: 37.3, longitude: -121.9,
                               senderName: "Sam", senderID: b, referredBy: a)
        let url = try XCTUnwrap(state.encodedURL())
        XCTAssertEqual(TweenState(url: url)?.referredBy, a)

        let junk = URL(string: "https://tween.app/m?t=x&lat=1&lon=1&ref=Sam&fromId=\(String(repeating: "x", count: 100))")!
        let decoded = try XCTUnwrap(TweenState(url: junk))
        XCTAssertNil(decoded.referredBy, "a non-install ref is dropped")
        XCTAssertNil(decoded.senderID, "an unbounded fromId is dropped")

        // Long enough to need slimming: ref goes before anything else.
        let crowd = (0..<40).map { i in
            Participant(id: String(format: "00000000-0000-4000-8000-%012d", i),
                        name: "Person number \(i) with a long name", latitude: 37, longitude: -122)
        }
        let big = TweenState(text: "Somewhere", latitude: 37, longitude: -122, senderID: b,
                             participants: crowd, referredBy: a)
        if let slim = big.encodedURL(), slim.absoluteString.count > 0,
           !slim.absoluteString.contains("pj=") {
            XCTAssertFalse(slim.absoluteString.contains("ref="), "ref is dropped before the roster")
        }
    }

    // MARK: Store hooks

    func testBootstrapMarksInstallsAlreadyInUseAsExisting() {
        ReferralStore.clear()
        Referrals.bootstrapIfNeeded()
        XCTAssertFalse(ReferralStore.load().existingUser, "a clean install is new")

        ReferralStore.clear()
        UserProfile.displayName = "Hassan"
        Referrals.bootstrapIfNeeded()
        XCTAssertTrue(ReferralStore.load().existingUser, "an install with a name was already in use")

        // Idempotent: never re-decides.
        UserProfile.displayName = nil
        Referrals.bootstrapIfNeeded()
        XCTAssertTrue(ReferralStore.load().existingUser)
    }

    func testJoinedRepliesGrantProThroughTheSharedFlag() {
        ProEntitlement.setUnlocked(false)
        ReferralStore.save(ReferralState(existingUser: true))
        for friend in [a, b, c] {
            let reply = ReferralMessage(kind: .joined, senderID: friend, senderName: nil, inviterID: me)
            _ = Referrals.noteInbound(reply, myID: me)
        }
        XCTAssertEqual(ReferralStore.load().referrals, [a, b, c])
        XCTAssertTrue(ProEntitlement.isUnlocked, "the grant flows into the cached Pro flag both processes read")
        ReferralStore.clear()
        ProEntitlement.syncUnlockedFlag()
        XCTAssertFalse(ProEntitlement.isUnlocked, "and goes with it")
    }
}

final class ProAdPolicyTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testEveryThirdMapsHandoffOrVisitEarnsAnAd() {
        var state = EngagementState()
        NudgePolicy.recordMapsHandoff(in: &state)
        NudgePolicy.recordMapsHandoff(in: &state)
        XCTAssertFalse(state.proAdPending)
        NudgePolicy.recordMapsHandoff(in: &state)
        XCTAssertTrue(state.proAdPending)

        var visits = EngagementState()
        for _ in 0..<2 { NudgePolicy.recordSession(in: &visits) }
        XCTAssertFalse(visits.proAdPending)
        NudgePolicy.recordSession(in: &visits)
        XCTAssertTrue(visits.proAdPending)
    }

    func testAdRespectsUnlockCooldownAndBackoff() {
        let t0 = Date()
        var state = EngagementState()
        state.proAdPending = true
        XCTAssertFalse(NudgePolicy.takeProAd(in: &state, proUnlocked: true, now: t0))
        XCTAssertFalse(state.proAdPending, "dropped, not deferred")

        state.proAdPending = true
        XCTAssertTrue(NudgePolicy.takeProAd(in: &state, proUnlocked: false, now: t0))
        state.proAdPending = true
        XCTAssertFalse(NudgePolicy.takeProAd(in: &state, proUnlocked: false, now: t0 + 2 * day), "3-day floor")
        state.proAdPending = true
        XCTAssertTrue(NudgePolicy.takeProAd(in: &state, proUnlocked: false, now: t0 + 4 * day))

        state.proDismissals = 2
        state.proAdPending = true
        XCTAssertFalse(NudgePolicy.takeProAd(in: &state, proUnlocked: false, now: t0 + 8 * day),
                       "two Not-nows move ads to a 14-day floor")
        state.proAdPending = true
        XCTAssertTrue(NudgePolicy.takeProAd(in: &state, proUnlocked: false, now: t0 + 19 * day))
    }
}
