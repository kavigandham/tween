import XCTest
import CoreLocation
import MapKit
@testable import TweenApp

/// The payload is the whole protocol, and every byte of it is attacker-
/// controlled: anyone in the conversation composes bubbles, and any app, web
/// page or note can hand the host a crafted `tween://` link. These are the
/// hostile cases from the 2026-10-13 pen-test — each one was reachable, and
/// none of them had a test.
///
/// Per-coordinate validation already had good coverage (`lat=nan`,
/// out-of-range, `arr`/`tt` bounds). What was missing was everything about
/// SIZE and IDENTITY: how many records, how long one name, whose id a bubble
/// may claim to be, and how far a counter may jump.
final class HostilePayloadTests: XCTestCase {

    private let key = "hostile-payload"

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for k in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: k)
            }
        }
    }

    // MARK: - Size

    /// ~700 participant records fit in one 5000-char payload. Nothing capped
    /// the COUNT, so a single bubble was persisted as the conversation roster
    /// and then fanned out one `MKDirections` request per participant per
    /// candidate inside the extension's ~120 MB ceiling.
    func testAnOversizeRosterIsCappedOnDecode() {
        let raw = (0..<700).map { "n\($0):37.77:-122.42" }.joined(separator: ",")
        let decoded = TweenState.decodeParticipants(raw)
        XCTAssertEqual(decoded.count, TweenState.maxParticipants)
        XCTAssertLessThanOrEqual(decoded.count, 32, "32 is the iMessage group-chat maximum")
    }

    /// The JSON roster rejects wholesale rather than truncating, so the
    /// caller falls back to the per-entry-validated `p=`.
    func testAnOversizeJSONRosterIsRejectedEntirely() throws {
        let many = (0..<700).map {
            Participant(id: "id-\($0)", name: "N\($0)", latitude: 37.77, longitude: -122.42)
        }
        let base64 = try JSONEncoder().encode(many).base64EncodedString()
        XCTAssertNil(TweenState.decodeParticipantJSON(base64))
    }

    /// `maxNameLength` bounds GRAPHEMES, but the wire allows only ASCII, so a
    /// 60-grapheme emoji name percent-encodes to thousands of characters. One
    /// such name made `encodedURL()` return nil for every send in that
    /// conversation — and that nil is reported as "couldn't send, try again",
    /// with no way out from the UI.
    func testAnEmojiHeavyRosterStillProducesASendableURL() {
        let family = "👨‍👩‍👧‍👦"
        let hostileName = String(repeating: family, count: 60)
        let participants = (0..<8).map {
            Participant(id: "id-\($0)", name: hostileName,
                        latitude: 37.7 + Double($0) / 100, longitude: -122.4)
        }
        var poll = MeetupPoll.empty
        for p in participants {
            poll.pick(PollOption(name: hostileName, latitude: p.latitude,
                                 longitude: p.longitude, proposerID: p.id))
        }
        let state = TweenState(text: hostileName, latitude: 37.77, longitude: -122.42,
                               senderName: hostileName, senderID: "id-0", kind: .place,
                               messageType: .pick, participants: participants,
                               agreedNames: participants.map(\.name), poll: poll)
        let url = state.encodedURL()
        XCTAssertNotNil(url, "a long non-ASCII name must not make the bubble unsendable")
        XCTAssertLessThanOrEqual(url?.absoluteString.count ?? .max, 5000)
    }

    /// One name, bounded by what it costs ON THE WIRE.
    func testBoundedNameBoundsEncodedLengthNotJustGraphemeCount() {
        let bounded = TweenState.boundedName(String(repeating: "👨‍👩‍👧‍👦", count: 60))
        XCTAssertLessThanOrEqual(TweenState.encodedLength(bounded),
                                 TweenState.maxEncodedNameLength)
        XCTAssertFalse(bounded.isEmpty, "bounding must not erase the name entirely")
    }

    /// `gone=` is persisted into the TTL-exempt tombstone set, so ~1000
    /// entries from one bubble grew that set for the life of the install.
    func testTheGossipAndAgreedListsAreCappedOnDecode() {
        let raw = (0..<1000).map { "k\($0)" }.joined(separator: ",")
        XCTAssertEqual(TweenState.decodeNames(raw).count, TweenState.maxNameListCount)
    }

    /// `from=` was the one wire string with no length bound, and it becomes a
    /// persisted tombstone key when the payload carries no `fromId`.
    func testAnUnboundedSenderNameIsBoundedOnDecode() {
        let huge = String(repeating: "A", count: 4_000)
        var components = URLComponents(string: "https://tween.app/m")!
        components.queryItems = [
            .init(name: "t", value: "Hey Tea"),
            .init(name: "lat", value: "37.77"),
            .init(name: "lon", value: "-122.42"),
            .init(name: "from", value: huge)
        ]
        let state = TweenState(url: components.url!)
        XCTAssertNotNil(state)
        XCTAssertLessThanOrEqual(state?.senderName?.count ?? .max, TweenState.maxNameLength)
    }

    // MARK: - Identity

    /// Manual / declared participants are LOCAL planning data: a group's
    /// home-base seeds and "where I'll be" points must never ride a payload.
    /// That held only by construction — no encoder enforced it.
    func testManualParticipantsNeverReachThePayload() throws {
        let real = Participant(id: "id-real", name: "Belal", latitude: 37.76, longitude: -122.43)
        let seeded = Participant.manual(label: "Saad's place",
                                        coordinate: CLLocationCoordinate2D(latitude: 37.80,
                                                                           longitude: -122.40))
        let state = TweenState(text: "I'm in", latitude: 37.78, longitude: -122.41,
                               senderID: "id-mine", kind: .participant,
                               participants: [real, seeded])
        let absolute = try XCTUnwrap(state.encodedURL()?.absoluteString)
        XCTAssertFalse(absolute.contains("manual:"), "a declared location must not be broadcast")
        XCTAssertFalse(absolute.contains("Saad"), "nor its label")
        XCTAssertTrue(absolute.contains("Belal"), "the real participant still travels")
    }

    /// The board is indexed against the SAME roster array that `p=` encodes,
    /// so filtering manual participants must not shift a vote onto the wrong
    /// person.
    func testFilteringManualParticipantsKeepsTheBoardAligned() throws {
        let a = Participant(id: "id-a", name: "Ann", latitude: 37.78, longitude: -122.41)
        let seeded = Participant.manual(label: "Seed",
                                        coordinate: CLLocationCoordinate2D(latitude: 37.80,
                                                                           longitude: -122.40))
        let b = Participant(id: "id-b", name: "Bo", latitude: 37.76, longitude: -122.43)
        var poll = MeetupPoll.empty
        let bosPlace = PollOption(name: "Kung Fu Tea", latitude: 37.765,
                                  longitude: -122.425, proposerID: b.id)
        poll.pick(bosPlace)
        poll.vote(a.id, for: bosPlace.id)

        let state = TweenState(text: "Kung Fu Tea", latitude: 37.765, longitude: -122.425,
                               senderID: b.id, kind: .place, messageType: .pick,
                               participants: [a, seeded, b], poll: poll)
        let decoded = try XCTUnwrap(TweenState(url: try XCTUnwrap(state.encodedURL())))
        XCTAssertEqual(decoded.participants.count, 2)
        XCTAssertEqual(decoded.poll.votes["id-a"], decoded.poll.options.first?.id,
                       "Ann's vote must still point at Bo's place after the seed was dropped")
        XCTAssertEqual(decoded.poll.options.first?.proposerID, b.id)
    }

    /// `agreedNames` and `from=` were the two display-name paths that shipped
    /// raw, so the "You" fallback went out on the wire — the exact sibling-site
    /// miss the name-sanitization lesson is about.
    func testTheFallbackNameNeverShipsOnAnyNamePath() throws {
        let state = TweenState(text: "Hey Tea", latitude: 37.77, longitude: -122.42,
                               senderName: UserName.fallback, senderID: "id-mine",
                               kind: .place, messageType: .decided,
                               participants: [Participant(id: "id-mine", name: UserName.fallback,
                                                          latitude: 37.78, longitude: -122.41)],
                               agreedNames: [UserName.fallback, "Belal"])
        let url = try XCTUnwrap(state.encodedURL()?.absoluteString)
        XCTAssertFalse(url.contains("from=\(UserName.fallback)"))
        XCTAssertFalse(url.contains("agreed=\(UserName.fallback)"))
        XCTAssertFalse(url.contains("=You,"), "nor as the first element of a list")
        XCTAssertTrue(url.contains("Belal"), "a real name still travels")
    }

    // MARK: - Ordering

    /// `rev=1000000000` became the conversation's floor, after which every
    /// honest peer bubble was rejected as stale — silently, and permanently,
    /// since the sync state is deliberately TTL-exempt. The bubble itself is
    /// still adopted; it just carries no ordering.
    func testAnAbsurdRevisionCannotPoisonTheFloor() {
        ConversationMeetupStore.noteRevision(5, sender: "A", key: key)
        ConversationMeetupStore.noteRevision(1_000_000_000, sender: "attacker", key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 5,
                       "an implausible jump must not move the floor")
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(
            revision: 6, senderID: "B", messageType: .pick, key: key),
            "honest peers must keep being heard")
    }

    /// A plausible advance still works — the clamp must not freeze ordering.
    func testAPlausibleRevisionStillRaisesTheFloor() {
        ConversationMeetupStore.noteRevision(5, sender: "A", key: key)
        ConversationMeetupStore.noteRevision(9, sender: "B", key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 9)
    }

    // MARK: - Derived geometry

    /// Every INPUT coordinate is validated, but the DERIVED span was not: two
    /// individually-valid participants at opposite corners of the world gave a
    /// 251° latitude delta, which then reached `MKMapSnapshotterOptions` and
    /// `MKLocalSearch.Request` — the same class of input as the `lat=nan`
    /// crash, one derivation downstream.
    func testWorldSpanningParticipantsProduceAValidRegion() {
        let region = MapGeometry.region(for: [
            CLLocationCoordinate2D(latitude: 89.9, longitude: -179.9),
            CLLocationCoordinate2D(latitude: -89.9, longitude: 179.9)
        ])
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 180)
        XCTAssertLessThanOrEqual(region.span.longitudeDelta, 360)
        XCTAssertTrue(CLLocationCoordinate2DIsValid(region.center))
    }

    // MARK: - Entitlement

    /// The referral grant is a stored `Date` compared against the device
    /// clock. Setting the clock to 2099 before the third referral landed wrote
    /// a grant that survived the clock being corrected.
    func testAClockRolledForwardCannotMintAPermanentGrant() throws {
        let year2099 = Date(timeIntervalSince1970: 4_070_908_800)
        var state = ReferralState(existingUser: true)
        let me = UUID().uuidString
        for friend in [UUID().uuidString, UUID().uuidString, UUID().uuidString] {
            _ = ReferralPolicy.noteInbound(senderID: friend, referredBy: me, myID: me,
                                           senderKey: "vouched-\(friend)",
                                           state: &state, now: year2099)
        }
        let until = try XCTUnwrap(state.grantedUntil)
        XCTAssertLessThanOrEqual(until.timeIntervalSince(year2099),
                                 ReferralPolicy.maxGrantHorizon,
                                 "a grant may never exceed the horizon, whatever the clock says")
    }

    /// …and a blob that already holds a poisoned date heals on read.
    func testAPoisonedStoredGrantIsReclampedOnDecode() throws {
        let json = #"{"existingUser":true,"grantedUntil":4070908800}"#
        let decoded = try JSONDecoder().decode(ReferralState.self,
                                               from: Data(json.utf8))
        let until = try XCTUnwrap(decoded.grantedUntil)
        XCTAssertLessThanOrEqual(until.timeIntervalSinceNow,
                                 ReferralPolicy.maxGrantHorizon + 60)
    }

    /// The referral ledger is written on bubble ARRIVAL, with no user
    /// interaction, and had no bound at all.
    func testTheReferralLedgerIsBounded() {
        var state = ReferralState(existingUser: true)
        let me = UUID().uuidString
        for _ in 0..<(ReferralPolicy.maxLedgerEntries + 40) {
            let friend = UUID().uuidString
            _ = ReferralPolicy.noteInbound(senderID: friend, referredBy: me, myID: me,
                                           senderKey: "vouched-\(friend)", state: &state)
        }
        XCTAssertLessThanOrEqual(state.referrals.count, ReferralPolicy.maxLedgerEntries)
        XCTAssertLessThanOrEqual(state.referralSenderKeys.count, ReferralPolicy.maxLedgerEntries)
    }

    // MARK: - Board scoping

    /// `normalized` deliberately KEEPS a vote key it can neither place nor
    /// tombstone, so a legacy name-keyed bubble adds a second key for the same
    /// person. `voteProgress` counted it: a two-person chat read "2 of 3
    /// voted", and the "Lock in" escape hatch never appeared.
    func testAnUnresolvableVoteKeyDoesNotInflateVoteProgress() {
        let a = Participant(id: "id-a", name: "Ann", latitude: 37.78, longitude: -122.41)
        let b = Participant(id: "id-b", name: "Bo", latitude: 37.76, longitude: -122.43)
        var poll = MeetupPoll.empty
        let place = PollOption(name: "Hey Tea", latitude: 37.77, longitude: -122.42,
                               proposerID: a.id)
        poll.pick(place)
        poll.vote(a.id, for: place.id)
        poll.vote(b.id, for: place.id)
        poll.vote("Ann", for: place.id)   // the legacy name-keyed duplicate

        let progress = poll.voteProgress(participants: [a, b])
        XCTAssertEqual(progress.total, 2, "the ROSTER says how many people are here")
        XCTAssertEqual(progress.voted, 2)
        XCTAssertGreaterThanOrEqual(progress.voted, progress.total,
                                    "so the settled check can actually become true")
    }

    /// Everyone left: there is no board. But an empty roster with no
    /// tombstones is a roster that has not HYDRATED yet — clearing there would
    /// blink a live meetup off the screen.
    func testAnEmptyRosterClearsTheBoardOnlyWhenSomeoneActuallyLeft() {
        var poll = MeetupPoll.empty
        let place = PollOption(name: "Hey Tea", latitude: 37.77, longitude: -122.42,
                               proposerID: "id-a")
        poll.pick(place)
        poll.lockIn(place.id)

        let everyoneLeft = poll.normalized(participants: [], departed: ["id-a"])
        XCTAssertTrue(everyoneLeft.options.isEmpty)
        XCTAssertNil(everyoneLeft.decidedOptionID,
                     "a settled meetup for a group of nobody is not a meetup")

        let notHydrated = poll.normalized(participants: [], departed: [])
        XCTAssertEqual(notHydrated.decidedOptionID, place.id,
                       "no tombstone means the roster simply isn't loaded yet")
    }
}
