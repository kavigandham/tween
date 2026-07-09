import XCTest
import CoreLocation
@testable import TweenApp

final class ParticipantCodecTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        LocationCache.clearAll()
    }

    // MARK: - URL encoding/decoding of participants

    func testSingleParticipantRoundTrips() throws {
        let participants = [Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30)]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .invite,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, 1)
        XCTAssertEqual(decoded.participants[0].name, "Alice")
        XCTAssertEqual(decoded.participants[0].latitude, 38.84, accuracy: 1e-5)
        XCTAssertEqual(decoded.participants[0].longitude, -77.30, accuracy: 1e-5)
        XCTAssertEqual(decoded.messageType, .invite)
    }

    func testParticipantRideRequestDefaultsToFalseWhenMissing() throws {
        let legacyJSON = """
        {"id":"Alice","name":"Alice","latitude":38.84,"longitude":-77.30}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Participant.self, from: legacyJSON)

        XCTAssertFalse(decoded.needsRide)
    }

    func testParticipantRideRequestRoundTripsThroughURL() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30, needsRide: true),
            Participant(id: "Bob", name: "Bob", latitude: 38.90, longitude: -77.35)
        ]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .invite,
            participants: participants
        )

        let decoded = try XCTUnwrap(TweenState(url: try XCTUnwrap(state.encodedURL())))

        XCTAssertTrue(try XCTUnwrap(decoded.participants.first { $0.name == "Alice" }).needsRide)
        XCTAssertFalse(try XCTUnwrap(decoded.participants.first { $0.name == "Bob" }).needsRide)
    }

    func testFiveParticipantsRoundTrip() throws {
        let participants = (0..<5).map { i in
            Participant(id: "P\(i)", name: "Person\(i)", latitude: 38.0 + Double(i) * 0.01, longitude: -77.0 - Double(i) * 0.01)
        }
        let state = TweenState(
            text: "Blue Bottle",
            latitude: 38.5,
            longitude: -77.5,
            senderName: "Person0",
            kind: .place,
            messageType: .propose,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, 5)
        for (i, p) in decoded.participants.enumerated() {
            XCTAssertEqual(p.name, "Person\(i)")
            XCTAssertEqual(p.latitude, 38.0 + Double(i) * 0.01, accuracy: 1e-5)
            XCTAssertEqual(p.longitude, -77.0 - Double(i) * 0.01, accuracy: 1e-5)
        }
        XCTAssertEqual(decoded.messageType, .propose)
    }

    func testParticipantIDsRoundTripThroughURL() throws {
        let participants = [
            Participant(id: "uuid-a", name: "Hassan", latitude: 38.84, longitude: -77.30),
            Participant(id: "uuid-b", name: "Hassan", latitude: 38.90, longitude: -77.35)
        ]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Hassan",
            senderID: "uuid-a",
            kind: .participant,
            participants: participants)

        let decoded = try XCTUnwrap(TweenState(url: try XCTUnwrap(state.encodedURL())))

        XCTAssertEqual(decoded.senderID, "uuid-a")
        XCTAssertEqual(decoded.participants.map(\.id), ["uuid-a", "uuid-b"])
        XCTAssertEqual(decoded.participants.map(\.name), ["Hassan", "Hassan"])
    }

    func testTenParticipantUrlStaysUnder5000Chars() throws {
        let participants = (0..<10).map { i in
            Participant(id: "Participant\(i)", name: "Participant\(i)Surname",
                        latitude: 38.0 + Double(i) * 0.001,
                        longitude: -77.0 - Double(i) * 0.001)
        }
        let state = TweenState(
            text: "Some Reasonably Long Spot Name",
            latitude: 38.5, longitude: -77.5,
            senderName: "Participant0Surname",
            kind: .place,
            messageType: .propose,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, 10)
    }

    // MARK: - Backward compatibility with legacy URLs

    func testLegacyParticipantUrlDecodesWithSynthesizedRoster() throws {
        // A bubble from a pre-group build: only t/lat/lon/kind/from. No p=.
        let legacyURL = URL(string:
            "https://tween.app/m?t=I%27m%20in&lat=38.840000&lon=-77.300000&kind=participant&from=Alice"
        )!
        let decoded = try XCTUnwrap(TweenState(url: legacyURL))
        // Old kind=participant ⇒ messageType inferred as .invite
        XCTAssertEqual(decoded.messageType, .invite)
        // Synthesized 1-element participants from senderName + main coord
        XCTAssertEqual(decoded.participants.count, 1)
        XCTAssertEqual(decoded.participants[0].name, "Alice")
        XCTAssertEqual(decoded.participants[0].latitude, 38.84, accuracy: 1e-5)
    }

    func testLegacyPlaceUrlDecodesWithSenderAsParticipant() throws {
        // Legacy propose-style URL: kind=place + slat/slon for the sender.
        let legacyURL = URL(string:
            "https://tween.app/m?t=Hangry%20Joe%27s&lat=38.850000&lon=-77.280000&kind=place&from=Alice&slat=38.840000&slon=-77.300000"
        )!
        let decoded = try XCTUnwrap(TweenState(url: legacyURL))
        XCTAssertEqual(decoded.messageType, .propose)
        XCTAssertEqual(decoded.participants.count, 1)
        XCTAssertEqual(decoded.participants[0].name, "Alice")
        XCTAssertEqual(decoded.participants[0].latitude, 38.84, accuracy: 1e-5)
        XCTAssertEqual(decoded.participants[0].longitude, -77.30, accuracy: 1e-5)
        // Main coord remains the place
        XCTAssertEqual(decoded.latitude, 38.85, accuracy: 1e-5)
        XCTAssertEqual(decoded.longitude, -77.28, accuracy: 1e-5)
    }

    func testLegacyAgreedUrlInfersAgreeMessageType() throws {
        let legacyURL = URL(string:
            "https://tween.app/m?t=Hangry%20Joe%27s&lat=38.85&lon=-77.28&kind=place&action=agree&from=Bob"
        )!
        let decoded = try XCTUnwrap(TweenState(url: legacyURL))
        XCTAssertEqual(decoded.messageType, .agree)
    }

    // MARK: - Agreement tracking

    func testAgreedNamesRoundTrip() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30),
            Participant(id: "Bob",   name: "Bob",   latitude: 38.90, longitude: -77.35),
            Participant(id: "Carol", name: "Carol", latitude: 38.82, longitude: -77.32)
        ]
        let state = TweenState(
            text: "Hangry Joe's",
            latitude: 38.85, longitude: -77.28,
            senderName: "Bob",
            kind: .place,
            messageType: .agree,
            participants: participants,
            agreedNames: ["Bob", "Carol"]
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.agreedNames, ["Bob", "Carol"])
    }

    func testIsFullyAgreedWhenAllNonProposerAgreed() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 0, longitude: 0),
            Participant(id: "Bob",   name: "Bob",   latitude: 0, longitude: 0),
            Participant(id: "Carol", name: "Carol", latitude: 0, longitude: 0)
        ]
        // Alice proposes; Bob and Carol agree.
        let state = TweenState(
            text: "Spot",
            latitude: 0, longitude: 0,
            senderName: "Alice",
            kind: .place,
            messageType: .agree,
            participants: participants,
            agreedNames: ["Bob", "Carol"]
        )
        XCTAssertTrue(state.isFullyAgreed)
    }

    func testIsNotFullyAgreedWhenSomeoneMissing() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 0, longitude: 0),
            Participant(id: "Bob",   name: "Bob",   latitude: 0, longitude: 0),
            Participant(id: "Carol", name: "Carol", latitude: 0, longitude: 0)
        ]
        let state = TweenState(
            text: "Spot",
            latitude: 0, longitude: 0,
            senderName: "Alice",
            kind: .place,
            messageType: .agree,
            participants: participants,
            agreedNames: ["Bob"]
        )
        XCTAssertFalse(state.isFullyAgreed)
    }

    func testAgreementUsesParticipantIDsWhenNamesCollide() throws {
        let participants = [
            Participant(id: "proposer", name: "Hassan", latitude: 0, longitude: 0),
            Participant(id: "agreeing", name: "Hassan", latitude: 0, longitude: 0),
            Participant(id: "waiting", name: "Hassan", latitude: 0, longitude: 0)
        ]
        let state = TweenState(
            text: "Cafe",
            latitude: 0, longitude: 0,
            senderName: "Hassan",
            senderID: "proposer",
            kind: .place,
            messageType: .agree,
            participants: participants,
            agreedNames: ["Hassan"],
            agreedIDs: ["agreeing"]
        )

        XCTAssertFalse(state.isFullyAgreed)
        XCTAssertEqual(state.missingAgreementNames(excluding: "agreeing", name: "Hassan"), ["Hassan"])
    }

    func testInviteIsNeverFullyAgreed() throws {
        let state = TweenState(
            text: "I'm in",
            latitude: 0, longitude: 0,
            senderName: "Alice",
            kind: .participant,
            messageType: .invite,
            participants: [Participant(id: "Alice", name: "Alice", latitude: 0, longitude: 0)]
        )
        XCTAssertFalse(state.isFullyAgreed)
    }

    // MARK: - Leaving

    func testLeaveMessageRoundTripsWithUpdatedRoster() throws {
        let remaining = [
            Participant(id: "Bob", name: "Bob", latitude: 38.90, longitude: -77.35)
        ]
        let state = TweenState(
            text: "I'm out",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .leave,
            participants: remaining
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.messageType, .leave)
        XCTAssertEqual(decoded.participants, remaining)
        XCTAssertNil(decoded.participantCoordinate)
        XCTAssertFalse(decoded.representsParticipantLocation)
    }

    func testLeaveMessageCanCarryEmptyRoster() throws {
        let state = TweenState(
            text: "I'm out",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .leave,
            participants: []
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.messageType, .leave)
        XCTAssertEqual(decoded.participants, [])
        XCTAssertNil(decoded.participantCoordinate)
    }

    // MARK: - Name escaping

    func testNameWithCommaSurvivesRoundTrip() throws {
        let name = "O'Brien, Pat"
        let participants = [Participant(id: name, name: name, latitude: 38.84, longitude: -77.30)]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84, longitude: -77.30,
            senderName: name,
            kind: .participant,
            messageType: .invite,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, 1)
        XCTAssertEqual(decoded.participants[0].name, name)
    }

    func testNameWithColonSurvivesRoundTrip() throws {
        let name = "Dr: Smith"
        let participants = [Participant(id: name, name: name, latitude: 38.84, longitude: -77.30)]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84, longitude: -77.30,
            senderName: name,
            kind: .participant,
            messageType: .invite,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, 1)
        XCTAssertEqual(decoded.participants[0].name, name)
    }

    // MARK: - LocationCache participants persistence

    func testSaveAndLoadParticipants() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30),
            Participant(id: "Bob",   name: "Bob",   latitude: 38.90, longitude: -77.35)
        ]
        LocationCache.saveParticipants(participants)
        let loaded = LocationCache.loadParticipants()
        XCTAssertEqual(loaded, participants)
    }

    func testLoadParticipantsReturnsEmptyWhenUnset() {
        XCTAssertEqual(LocationCache.loadParticipants(), [])
    }

    func testClearParticipantsRemovesData() {
        LocationCache.saveParticipants([Participant(id: "A", name: "A", latitude: 0, longitude: 0)])
        LocationCache.clearParticipants()
        XCTAssertEqual(LocationCache.loadParticipants(), [])
    }

    func testParticipantSnapshotUpdatesLegacyPeerProjection() throws {
        let participants = [
            Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30),
            Participant(id: "Bob", name: "Bob", latitude: 38.90, longitude: -77.35),
            Participant(id: "Carol", name: "Carol", latitude: 38.82, longitude: -77.32)
        ]

        LocationCache.saveParticipantSnapshot(participants, localName: "Alice")

        XCTAssertEqual(LocationCache.loadParticipants(), participants)
        XCTAssertTrue(LocationCache.isPeerActive)
        let peer = try XCTUnwrap(LocationCache.loadPeer())
        XCTAssertEqual(peer.latitude, 38.90, accuracy: 1e-5)
        XCTAssertEqual(peer.longitude, -77.35, accuracy: 1e-5)
    }

    func testParticipantSnapshotClearsLegacyPeerWhenNoRemoteRemains() {
        LocationCache.savePeer(CLLocationCoordinate2D(latitude: 38.90, longitude: -77.35), isActive: true)

        LocationCache.saveParticipantSnapshot([
            Participant(id: "Alice", name: "Alice", latitude: 38.84, longitude: -77.30)
        ], localName: "Alice")

        XCTAssertFalse(LocationCache.isPeerActive)
    }

    // MARK: - Conversation-scoped meetup persistence

    func testConversationKeysAreStableForParticipantOrder() {
        let first = ConversationMeetupStore.conversationKey(localID: "A", remotes: ["B", "C"])
        let second = ConversationMeetupStore.conversationKey(localID: "C", remotes: ["A", "B"])
        XCTAssertEqual(first, second)
    }

    func testConversationSnapshotsDoNotShareDraftsOrProposals() throws {
        let ab = ConversationMeetupStore.conversationKey(localID: "A", remotes: ["B"])
        let ac = ConversationMeetupStore.conversationKey(localID: "A", remotes: ["C"])
        let participants = [
            Participant(id: "A", name: "Hassan", latitude: 32.0, longitude: -81.0),
            Participant(id: "B", name: "Hamza", latitude: 33.0, longitude: -82.0)
        ]
        let state = TweenState(
            text: "Hangry Joe's",
            latitude: 32.1,
            longitude: -81.1,
            senderName: "Hassan",
            senderID: "A",
            kind: .place,
            messageType: .propose,
            participants: participants)
        let draft = OutgoingDraft(spotName: "Hangry Joe's", latitude: 32.1, longitude: -81.1)

        ConversationMeetupStore.save(MeetupSnapshot(
            conversationKey: ab,
            participants: participants,
            proposedState: state,
            pendingDraft: draft), key: ab)
        ConversationMeetupStore.save(MeetupSnapshot(conversationKey: ac), key: ac)

        let abSnapshot = try XCTUnwrap(ConversationMeetupStore.load(key: ab))
        let acSnapshot = try XCTUnwrap(ConversationMeetupStore.load(key: ac))
        XCTAssertEqual(abSnapshot.proposedState?.text, "Hangry Joe's")
        // Drafts live under their own conversation-scoped key now; an inline
        // draft handed to save() is folded into it, never silently dropped.
        XCTAssertEqual(ConversationMeetupStore.loadDraft(key: ab)?.spotName, "Hangry Joe's")
        XCTAssertNil(acSnapshot.proposedState)
        XCTAssertNil(ConversationMeetupStore.loadDraft(key: ac))
    }

    func testSameConversationRestoresParticipants() throws {
        let key = ConversationMeetupStore.conversationKey(localID: "A", remotes: ["B"])
        let participants = [
            Participant(id: "A", name: "Hassan", latitude: 32.0, longitude: -81.0),
            Participant(id: "B", name: "Hamza", latitude: 33.0, longitude: -82.0, needsRide: true)
        ]

        ConversationMeetupStore.saveParticipants(participants, key: key)

        let loaded = try XCTUnwrap(ConversationMeetupStore.load(key: key))
        XCTAssertEqual(loaded.participants, participants)
    }

    func testParticipantMatchesLocalContextByUUIDOrLegacyName() {
        let uuidParticipant = Participant(id: "uuid-A", name: "Hassan", latitude: 0, longitude: 0)
        let legacyParticipant = Participant(id: "Hassan", name: "Hassan", latitude: 0, longitude: 0)

        XCTAssertTrue(uuidParticipant.matches(LocalParticipantContext(id: "uuid-A", name: "Hassan")))
        XCTAssertTrue(legacyParticipant.matches(LocalParticipantContext(id: nil, name: "Hassan")))
        XCTAssertTrue(uuidParticipant.matches(LocalParticipantContext(id: nil, name: "Hassan")))
    }

    func testForeignUUIDPeerWithCollidingNameDoesNotMatchLocalContext() {
        // A peer's roster entry carries a UUID minted on THEIR device; when both
        // devices default to the same display name ("You"), the peer must not be
        // mistaken for the local user.
        let peer = Participant(id: "uuid-B", name: "You", latitude: 0, longitude: 0)
        XCTAssertFalse(peer.matches(LocalParticipantContext(id: "uuid-A", name: "You")))
    }

    func testLegacyNameIDEntryStillMatchesWhenContextHasUUID() {
        // A host-app-minted self entry (id == name) checked from the extension,
        // where the context carries the conversation UUID.
        let legacy = Participant(id: "Hassan", name: "Hassan", latitude: 0, longitude: 0)
        XCTAssertTrue(legacy.matches(LocalParticipantContext(id: "uuid-A", name: "Hassan")))
    }

    func testUUIDEntryMatchesByIDEvenWhenDisplayNamesDiffer() {
        // The user renamed themselves between sends; the stable UUID still wins.
        let mine = Participant(id: "uuid-A", name: "Hassan", latitude: 0, longitude: 0)
        XCTAssertTrue(mine.matches(LocalParticipantContext(id: "uuid-A", name: "You")))
    }

    func testNameAsIDContextKeepsFilteringUUIDEntriesByName() {
        // Guards OnboardingView.sendAgreeReply, which passes the display name as
        // the context id: the user's own UUID-stamped entry must still count as
        // "me" so the agree roster carries exactly one self entry.
        let mine = Participant(id: "uuid-A", name: "Hassan", latitude: 0, longitude: 0)
        XCTAssertTrue(mine.matches(LocalParticipantContext(id: "Hassan", name: "Hassan")))
    }

    func testAgreeSnapshotPreservesProposerAndRecordsAgreer() throws {
        let key = ConversationMeetupStore.conversationKey(localID: "A", remotes: ["B"])
        let participants = [
            Participant(id: "A", name: "Hassan", latitude: 32.0, longitude: -81.0),
            Participant(id: "B", name: "Hamza", latitude: 33.0, longitude: -82.0)
        ]
        let agreed = TweenState(
            text: "Country Cafe",
            latitude: 32.1,
            longitude: -81.1,
            senderName: "Hassan",
            senderID: "A",
            kind: .place,
            action: .agree,
            messageType: .agree,
            participants: participants,
            agreedNames: ["Hamza"],
            agreedIDs: ["B"])

        ConversationMeetupStore.saveAgreed(agreed, key: key)

        let loaded = try XCTUnwrap(ConversationMeetupStore.load(key: key)?.agreedState)
        XCTAssertEqual(loaded.senderID, "A")
        XCTAssertEqual(loaded.agreedIDs, ["B"])
        XCTAssertTrue(loaded.isFullyAgreed)
    }

    // MARK: - UserName persistence

    func testUserNameRoundTrip() {
        XCTAssertNil(UserName.load())
        UserName.save("Kavi")
        XCTAssertEqual(UserName.load(), "Kavi")
        XCTAssertEqual(UserName.loadOrFallback(), "Kavi")
    }

    func testUserNameTrimsAndIgnoresEmpty() {
        UserName.save("   ")
        XCTAssertNil(UserName.load())
        UserName.save("  Pat ")
        XCTAssertEqual(UserName.load(), "Pat")
    }

    func testUserNameFallback() {
        XCTAssertNil(UserName.load())
        XCTAssertEqual(UserName.loadOrFallback(), UserName.fallback)
    }

    // MARK: - Stable install identity

    func testStableIDMintsOnceAndPersists() {
        let first = TweenIdentity.stableID
        let second = TweenIdentity.stableID
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "The install ID must never change once minted")
        XCTAssertNotNil(UUID(uuidString: first))
    }

    // MARK: - Payload revision (v2)

    func testRevisionRoundTripsThroughURL() throws {
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .invite,
            participants: [Participant(id: "uuid-a", name: "Alice", latitude: 38.84, longitude: -77.30)],
            revision: 7
        )
        let url = try XCTUnwrap(state.encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.revision, 7)
    }

    func testLegacyURLDecodesWithNilRevision() throws {
        let url = try XCTUnwrap(URL(string: "https://tween.app/m?t=I'm%20in&lat=38.84&lon=-77.30&kind=participant"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertNil(decoded.revision)
    }

    func testStoreTracksHighestRevision() {
        let key = "rev-test-key"
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 0)
        ConversationMeetupStore.noteRevision(3, key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 3)
        ConversationMeetupStore.noteRevision(2, key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 3, "Lower revisions must never regress the stored maximum")
        ConversationMeetupStore.noteRevision(5, key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 5)
    }

    // MARK: - Leave tombstone

    func testLeaveTombstoneRoundTrip() {
        let key = "tombstone-key"
        XCTAssertFalse(ConversationMeetupStore.localUserLeft(key: key))
        ConversationMeetupStore.setLocalUserLeft(true, key: key)
        XCTAssertTrue(ConversationMeetupStore.localUserLeft(key: key))
        ConversationMeetupStore.setLocalUserLeft(false, key: key)
        XCTAssertFalse(ConversationMeetupStore.localUserLeft(key: key))
    }

    func testTombstonePersistsAcrossOtherSnapshotWrites() {
        let key = "tombstone-key-2"
        ConversationMeetupStore.setLocalUserLeft(true, key: key)
        // Unrelated writes (roster updates from stale peers, revisions) must
        // not clear the tombstone — only an explicit rejoin does.
        ConversationMeetupStore.saveParticipants(
            [Participant(id: "peer", name: "Kavi", latitude: 1, longitude: 2)], key: key)
        ConversationMeetupStore.noteRevision(4, key: key)
        XCTAssertTrue(ConversationMeetupStore.localUserLeft(key: key))
    }

    // MARK: - Compact-format IDs (pids) and oversize fallback

    func testCompactFallbackRestoresIDsFromPids() throws {
        let participants = [
            Participant(id: "uuid-alice", name: "Alice", latitude: 38.84, longitude: -77.30, needsRide: true),
            Participant(id: "uuid-bob", name: "Bob", latitude: 38.90, longitude: -77.35)
        ]
        let state = TweenState(
            text: "I'm in",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .participant,
            messageType: .invite,
            participants: participants
        )
        let url = try XCTUnwrap(state.encodedURL())
        // Simulate the pj-less path (what an oversize send produces): strip pj
        // and decode from p= + pids= alone.
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems = components.queryItems?.filter { $0.name != "pj" }
        let slim = try XCTUnwrap(components.url)
        let decoded = try XCTUnwrap(TweenState(url: slim))
        XCTAssertEqual(decoded.participants.map(\.id), ["uuid-alice", "uuid-bob"],
                       "pids must restore real identity when the JSON roster is absent")
        XCTAssertEqual(decoded.participants.map(\.name), ["Alice", "Bob"])
        XCTAssertTrue(decoded.participants[0].needsRide)
    }

    func testOversizePayloadDropsPJInsteadOfFailing() throws {
        // Enough participants with UUID ids to push the pj-inclusive URL past
        // 5000 chars while the compact p= + pids= form still fits.
        let participants = (0..<28).map { index in
            Participant(id: UUID().uuidString,
                        name: "Participant Number \(index)",
                        latitude: 38.0 + Double(index) * 0.01,
                        longitude: -77.0 - Double(index) * 0.01)
        }
        let state = TweenState(
            text: "Big Group Meetup",
            latitude: 38.84,
            longitude: -77.30,
            senderName: "Alice",
            kind: .place,
            messageType: .propose,
            participants: participants,
            revision: 1
        )
        let url = try XCTUnwrap(state.encodedURL(), "Oversize payloads should degrade, not fail")
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
        XCTAssertFalse(url.absoluteString.contains("pj="), "The JSON roster is what gets dropped")
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.participants.count, participants.count)
        XCTAssertEqual(decoded.participants.map(\.id), participants.map(\.id),
                       "Identity survives the compact fallback via pids")
        XCTAssertEqual(decoded.revision, 1)
    }

    // MARK: - Sync-state split (TTL exemption, migration, tie-break)

    private func legacySnapshotData(key: String,
                                    lastRevision: Int? = nil,
                                    localUserLeft: Bool? = nil,
                                    departedKeys: [String]? = nil,
                                    pendingDraft: OutgoingDraft? = nil) -> Data {
        var snapshot = MeetupSnapshot(conversationKey: key)
        snapshot.lastRevision = lastRevision
        snapshot.localUserLeft = localUserLeft
        snapshot.departedKeys = departedKeys
        snapshot.pendingDraft = pendingDraft
        return try! JSONEncoder().encode(snapshot)
    }

    func testTTLClearKeepsRevisionFloorAndTombstones() {
        let key = "ttl-survival"
        ConversationMeetupStore.noteRevision(7, sender: "sender-A", key: key)
        ConversationMeetupStore.setLocalUserLeft(true, key: key)
        ConversationMeetupStore.noteDeparted(["gone-B"], key: key)
        ConversationMeetupStore.saveParticipants(
            [Participant(id: "peer", name: "Kavi", latitude: 1, longitude: 2)], key: key)
        ConversationMeetupStore.saveDraft(
            OutgoingDraft(spotName: "Cafe", latitude: 1, longitude: 2), key: key)

        ConversationMeetupStore.clear(key: key)   // the 24 h TTL path

        XCTAssertNil(ConversationMeetupStore.load(key: key), "Snapshot cleared")
        XCTAssertNil(ConversationMeetupStore.loadDraft(key: key), "Draft cleared with the TTL")
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 7,
                       "Revision floor must survive the TTL — it only blocks stale bubbles")
        XCTAssertEqual(ConversationMeetupStore.lastRevisionSender(key: key), "sender-A")
        XCTAssertTrue(ConversationMeetupStore.localUserLeft(key: key),
                      "Leave tombstone must survive the TTL or D4 re-breaks after a day")
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["gone-B"])
    }

    func testLegacySnapshotFieldsMigrateToSyncAndDraftKeys() {
        let key = "legacy-migrate"
        let draft = OutgoingDraft(spotName: "Old Draft", latitude: 3, longitude: 4)
        let data = legacySnapshotData(key: key, lastRevision: 5, localUserLeft: true,
                                      departedKeys: ["gone-X"], pendingDraft: draft)
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(data, forKey: "conversationMeetup." + key)

        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 5)
        XCTAssertTrue(ConversationMeetupStore.localUserLeft(key: key))
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["gone-X"])
        XCTAssertEqual(ConversationMeetupStore.loadDraft(key: key)?.spotName, "Old Draft")

        // The migrated values survive the legacy blob being cleared by TTL.
        ConversationMeetupStore.clear(key: key)
        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 5)
        XCTAssertTrue(ConversationMeetupStore.localUserLeft(key: key))
    }

    func testLegacyInlineValuesDoNotResurrectAfterLaterWrites() {
        let key = "legacy-no-resurrect"
        let data = legacySnapshotData(key: key, lastRevision: 5, localUserLeft: true)
        UserDefaults(suiteName: LocationCache.appGroup)?
            .set(data, forKey: "conversationMeetup." + key)

        // Migrate, then move the canonical values on.
        ConversationMeetupStore.noteRevision(9, sender: "sender-B", key: key)
        ConversationMeetupStore.setLocalUserLeft(false, key: key)
        // A later big-blob mutation must not shadow them with stale inline copies.
        ConversationMeetupStore.saveParticipants(
            [Participant(id: "peer", name: "Kavi", latitude: 1, longitude: 2)], key: key)

        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 9)
        XCTAssertFalse(ConversationMeetupStore.localUserLeft(key: key))
        XCTAssertNil(ConversationMeetupStore.load(key: key)?.lastRevision,
                     "save() must strip the legacy inline fields")
    }

    func testRevisionTieBreakMatrix() {
        let key = "tie-break"
        // Legacy payloads (no revision) always accept.
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(revision: nil, senderID: "A", key: key))
        // Empty floor: anything accepts.
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(revision: 1, senderID: "A", key: key))

        ConversationMeetupStore.noteRevision(5, sender: "A", key: key)
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(revision: 6, senderID: "B", key: key),
                      "Above the floor always accepts")
        XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(revision: 4, senderID: "A", key: key),
                       "Below the floor always rejects, even for the floor sender")
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(revision: 5, senderID: "A", key: key),
                      "Re-tap of the bubble that set the floor keeps working")
        XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(revision: 5, senderID: "B", key: key),
                       "Concurrent same-revision PLACE mint by another device rejects")
        XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(revision: 5, senderID: nil, key: key),
                       "Tie with unknown sender rejects once a floor sender exists")

        // Pre-migration floor (no sender recorded): legacy >= behavior.
        let legacyKey = "tie-break-legacy"
        ConversationMeetupStore.noteRevision(5, key: legacyKey)
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(revision: 5, senderID: "B", key: legacyKey))
        // First sender-carrying note at the floor backfills the sender.
        ConversationMeetupStore.noteRevision(5, sender: "A", key: legacyKey)
        XCTAssertEqual(ConversationMeetupStore.lastRevisionSender(key: legacyKey), "A")
        XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(revision: 5, senderID: "B", key: legacyKey))
    }

    /// The concurrent-join exception: two people tapping "I'm in" before
    /// either sees the other both mint revision 1 from an empty floor, so an
    /// .invite at the floor from a DIFFERENT sender must be accepted (their
    /// rosters union). Everything else at the floor stays strict, and a
    /// below-floor invite still rejects (leaver-resurrection guard).
    func testConcurrentInviteAcceptedAtFloorButNotBelow() {
        let key = "tie-break-invite"
        ConversationMeetupStore.noteRevision(1, sender: "A", key: key)

        // The other person's concurrent "I'm in" at the same revision: accept.
        XCTAssertTrue(ConversationMeetupStore.shouldAcceptInbound(
            revision: 1, senderID: "B", messageType: .invite, key: key),
            "Concurrent independent joins must union, not reject each other")

        // A place mint at the same revision from another device stays strict.
        for placeType in [TweenState.MessageType.propose, .counter, .agree, .leave] {
            XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(
                revision: 1, senderID: "B", messageType: placeType, key: key),
                "\(placeType) at the floor from another sender must still reject")
        }

        // A stale (below-floor) invite from a departed sender must NOT be
        // admitted — RosterMerge treats an invite as a rejoin, so the
        // below-floor reject is the resurrection guard and must stay strict.
        ConversationMeetupStore.noteRevision(5, sender: "A", key: key)
        XCTAssertFalse(ConversationMeetupStore.shouldAcceptInbound(
            revision: 2, senderID: "B", messageType: .invite, key: key),
            "A below-floor invite must reject so it can't resurrect a leaver")
    }

    func testStaleSnapshotSaveCannotDropConcurrentRevision() {
        let key = "race-structural"
        // Process A holds a snapshot...
        ConversationMeetupStore.saveParticipants(
            [Participant(id: "a", name: "A", latitude: 1, longitude: 1)], key: key)
        let stale = ConversationMeetupStore.load(key: key)!
        // ...process B notes a revision + tombstone meanwhile...
        ConversationMeetupStore.noteRevision(3, sender: "B", key: key)
        ConversationMeetupStore.noteDeparted(["gone-C"], key: key)
        // ...and process A writes its stale snapshot back.
        ConversationMeetupStore.save(stale, key: key)

        XCTAssertEqual(ConversationMeetupStore.lastRevision(key: key), 3,
                       "Sync state lives under its own key — a stale snapshot save can't clobber it")
        XCTAssertEqual(ConversationMeetupStore.departedParticipants(key: key), ["gone-C"])
    }

    // MARK: - Coordinate blob active flags (audit W11)

    func testActiveFlagRidesInsideCoordinateBlob() {
        LocationCache.save(CLLocationCoordinate2D(latitude: 1, longitude: 2), isActive: true)
        XCTAssertEqual(LocationCache.loadSelf()?.isActive, true,
                       "Coord + flag must land in ONE atomic blob write")
        XCTAssertTrue(LocationCache.isActive)
        LocationCache.deactivateSelf()
        XCTAssertEqual(LocationCache.loadSelf()?.isActive, false)
        XCTAssertFalse(LocationCache.isActive)
        XCTAssertFalse(LocationCache.isOptedIn)
    }

    func testLegacyCoordBlobWithoutFlagHonorsLegacyBoolKey() throws {
        // A pre-split blob (no isActive field) must keep deferring to the
        // legacy bool key so nothing regresses mid-upgrade.
        let legacy = LocationCache.CachedCoord(latitude: 1, longitude: 2, timestamp: Date())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: LocationCache.appGroup))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "tween.cache.self")
        defaults.set(true, forKey: "tween.cache.self.active")
        XCTAssertNil(LocationCache.loadSelf()?.isActive)
        XCTAssertTrue(LocationCache.isActive)
        defaults.set(false, forKey: "tween.cache.self.active")
        XCTAssertFalse(LocationCache.isActive)
    }

    func testStaleCoordinateDefeatsIsActiveDespiteFlag() {
        LocationCache.save(CLLocationCoordinate2D(latitude: 1, longitude: 2),
                           at: Date(timeIntervalSinceNow: -6 * 60), isActive: true)
        XCTAssertFalse(LocationCache.isActive,
                       "The 5-min freshness window still gates the coordinate (locks the W4 fix)")
        XCTAssertTrue(LocationCache.isOptedIn,
                      "Opt-in is a user decision, not a freshness question")
    }

    func testFreshSelfCoordinateGatesStrictlyOnAge() {
        XCTAssertNil(LocationCache.freshSelfCoordinate(), "No cache → nil")

        // A stale coordinate must NOT be offered for an outgoing payload,
        // even though it's the user's real (old) location — this is the
        // funnel that stops host-side coordinate laundering (audit W4).
        LocationCache.save(CLLocationCoordinate2D(latitude: 10, longitude: 20),
                           at: Date(timeIntervalSinceNow: -6 * 60), isActive: true)
        XCTAssertNil(LocationCache.freshSelfCoordinate(),
                     "A 6-minute-old fix is stale and must not travel in a bubble")

        // A fresh coordinate is offered regardless of opt-in — freshness is
        // "is this current", not "am I in".
        LocationCache.save(CLLocationCoordinate2D(latitude: 30, longitude: 40), isActive: false)
        let fresh = LocationCache.freshSelfCoordinate()
        XCTAssertEqual(fresh?.latitude, 30)
        XCTAssertEqual(fresh?.longitude, 40)
    }

    func testDraftSurvivesSnapshotMutationsAndClearsWithTTL() {
        let key = "draft-key-split"
        ConversationMeetupStore.saveDraft(
            OutgoingDraft(spotName: "Boba", latitude: 1, longitude: 2), key: key)
        ConversationMeetupStore.saveParticipants(
            [Participant(id: "a", name: "A", latitude: 1, longitude: 1)], key: key)
        XCTAssertEqual(ConversationMeetupStore.loadDraft(key: key)?.spotName, "Boba",
                       "Snapshot mutations must not drop the pending draft")
        ConversationMeetupStore.lastActiveConversationKey = key
        XCTAssertTrue(ConversationMeetupStore.hasLiveMeetup(within: 60),
                      "A pending draft alone counts as a live meetup")
        ConversationMeetupStore.clear(key: key)
        XCTAssertNil(ConversationMeetupStore.loadDraft(key: key))
    }
}
