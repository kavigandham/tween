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
}
