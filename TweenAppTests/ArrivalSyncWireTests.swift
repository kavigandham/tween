import XCTest
import CoreLocation
@testable import TweenApp

/// Arrival Sync on the wire: the two fields it adds to `MSMessage.url`, their
/// bounds, and where they sit on the 5000-char size ladder (constraint 2).
final class ArrivalSyncWireTests: XCTestCase {

    private let target = Date(timeIntervalSince1970: 1_800_001_440)  // a whole second

    private func people(_ count: Int, longNames: Bool = false) -> [Participant] {
        (0..<count).map { index in
            Participant(id: "id-\(index)",
                        name: longNames
                            ? String(repeating: "Name\(index)", count: 12)
                            : "P\(index)",
                        latitude: 37.77 + Double(index) / 1000,
                        longitude: -122.41 - Double(index) / 1000)
        }
    }

    private func enroute(participants: [Participant],
                         arrivalTarget: Date?,
                         travelSeconds: [String: Int],
                         poll: MeetupPoll = .empty) -> TweenState {
        TweenState(text: "Blue Bottle",
                   latitude: 37.7749,
                   longitude: -122.4194,
                   senderName: "Hassan",
                   senderID: "id-0",
                   kind: .place,
                   messageType: .enroute,
                   participants: participants,
                   revision: 7,
                   poll: poll,
                   etaSeconds: 24 * 60,
                   arrivalTarget: arrivalTarget,
                   travelSeconds: travelSeconds)
    }

    // MARK: - Round trip

    func testArrivalTargetAndLegsSurviveTheRoundTrip() throws {
        let roster = people(3)
        let legs = ["id-0": 24 * 60, "id-1": 14 * 60, "id-2": 19 * 60]
        let url = try XCTUnwrap(enroute(participants: roster,
                                        arrivalTarget: target,
                                        travelSeconds: legs).encodedURL())
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.arrivalTarget, target)
        XCTAssertEqual(decoded.travelSeconds, legs)
    }

    func testLegsAreIndexedAgainstTheRosterNotKeyedByID() throws {
        // A participant id is a 36-char UUID; repeating one per entry would
        // eat the ceiling for a group. So `tt` is positional, exactly like
        // the board's `votes`.
        let roster = people(3)
        let url = try XCTUnwrap(enroute(participants: roster,
                                        arrivalTarget: target,
                                        travelSeconds: ["id-1": 840]).encodedURL())
        XCTAssertTrue(url.absoluteString.contains("tt=-,840,-"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.travelSeconds, ["id-1": 840])
    }

    func testAPlainLeavingNowCarriesNeitherField() throws {
        // How a receiver tells a non-Pro announcement from a synchronised
        // departure: no `arr`, so nothing to synchronise against.
        let url = try XCTUnwrap(enroute(participants: people(2),
                                        arrivalTarget: nil,
                                        travelSeconds: [:]).encodedURL())
        XCTAssertFalse(url.absoluteString.contains("arr="))
        XCTAssertFalse(url.absoluteString.contains("tt="))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertNil(decoded.arrivalTarget)
        XCTAssertTrue(decoded.travelSeconds.isEmpty)
    }

    func testABubbleFromAnOlderBuildStillDecodes() throws {
        // Back-compat: 1.0.5 threads are full of `.enroute` bubbles with `eta`
        // and no `arr`. They must keep working as announcements.
        let url = try XCTUnwrap(URL(string:
            "https://tween.app/m?t=Blue%20Bottle&lat=37.774900&lon=-122.419400"
            + "&kind=place&from=Hassan&fromId=id-0&type=enroute&eta=1440"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.messageType, .enroute)
        XCTAssertEqual(decoded.etaSeconds, 1440)
        XCTAssertNil(decoded.arrivalTarget)
    }

    // MARK: - Bounds (the `lat=nan` / `rev=Int.max` hardening, applied here)

    func testAnAbsurdArrivalTargetReadsAsAbsent() throws {
        for raw in ["9999999999999", "-1", "0", "notanumber"] {
            let url = try XCTUnwrap(URL(string:
                "https://tween.app/m?t=Blue%20Bottle&lat=37.774900&lon=-122.419400"
                + "&kind=place&type=enroute&arr=\(raw)"))
            let decoded = try XCTUnwrap(TweenState(url: url))
            // Degrades to a plain announcement rather than arming a reminder
            // off a crafted timestamp.
            XCTAssertNil(decoded.arrivalTarget, "arr=\(raw) was accepted")
        }
    }

    func testAnOutOfRangeLegIsDroppedNotClamped() throws {
        let roster = people(2)
        let url = try XCTUnwrap(URL(string:
            "https://tween.app/m?t=Blue%20Bottle&lat=37.774900&lon=-122.419400"
            + "&kind=place&type=enroute&p=\(TweenState.encodeParticipants(roster))"
            + "&pids=\(TweenState.encodeNames(roster.map(\.id)))"
            + "&tt=99999999,840"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        // A day-plus "travel time" is junk and would arm a reminder a day out.
        XCTAssertNil(decoded.travelSeconds["id-0"])
        XCTAssertEqual(decoded.travelSeconds["id-1"], 840)
    }

    func testLegsWithoutARosterAreIgnored() throws {
        // `tt` only means anything alongside the roster it was indexed
        // against — the same rule the board's wire format follows.
        let url = try XCTUnwrap(URL(string:
            "https://tween.app/m?t=Blue%20Bottle&lat=37.774900&lon=-122.419400"
            + "&kind=place&type=enroute&tt=840,1440"))
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertTrue(decoded.travelSeconds.isEmpty)
    }

    func testEncodingRefusesToEmitLegsWithoutARoster() throws {
        let url = try XCTUnwrap(enroute(participants: [],
                                        arrivalTarget: target,
                                        travelSeconds: ["id-0": 840]).encodedURL())
        XCTAssertFalse(url.absoluteString.contains("tt="))
        // `arr` does not depend on the roster, so it still travels.
        XCTAssertTrue(url.absoluteString.contains("arr="))
    }

    func testAllEmptyLegsAreOmitted() throws {
        // Nothing but separators and dashes is not worth the characters.
        let roster = people(3)
        let url = try XCTUnwrap(enroute(participants: roster,
                                        arrivalTarget: target,
                                        travelSeconds: ["id-nobody": 840]).encodedURL())
        XCTAssertFalse(url.absoluteString.contains("tt="))
    }

    // MARK: - The size ladder

    func testTheArrivalTargetSurvivesEvenWhenTheBoardIsDropped() throws {
        // `arr` IS the feature, and it is a fixed ~14 characters, so it sits
        // on no rung of the ladder. `tt` costs per participant and is only a
        // convenience (every receiver re-measures its own leg), so it goes
        // early — before the base64 roster and before the board.
        let roster = people(8, longNames: true)
        var poll = MeetupPoll.empty
        for (index, person) in roster.enumerated() {
            poll.pick(PollOption(name: String(repeating: "A Very Long Cafe Name \(index)", count: 6),
                                 latitude: 37.77 + Double(index) / 500,
                                 longitude: -122.41,
                                 proposerID: person.id))
        }
        let legs = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, 900) })
        let url = try XCTUnwrap(enroute(participants: roster,
                                        arrivalTarget: target,
                                        travelSeconds: legs,
                                        poll: poll).encodedURL())
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
        XCTAssertTrue(url.absoluteString.contains("arr="),
                      "the arrival target must never be sacrificed")
        let decoded = try XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.arrivalTarget, target)
    }

    func testAnOversizePayloadStaysUnderTheCeiling() throws {
        let roster = people(8, longNames: true)
        let legs = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, 3600) })
        let url = try XCTUnwrap(enroute(participants: roster,
                                        arrivalTarget: target,
                                        travelSeconds: legs).encodedURL())
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
    }

    // MARK: - Codec helpers

    func testEncodeTravelSecondsMarksUnknownWithADash() {
        let roster = people(3)
        XCTAssertEqual(
            TweenState.encodeTravelSeconds(["id-0": 60, "id-2": 120], participants: roster),
            "60,-,120")
    }

    func testDecodeTravelSecondsSkipsEmptyIdentities() {
        // An unnamed participant decodes with id "" — admitting it would file
        // every unattributable leg under one key.
        let roster = [Participant(id: "", name: "", latitude: 1, longitude: 1),
                      Participant(id: "id-1", name: "P1", latitude: 1, longitude: 1)]
        XCTAssertEqual(TweenState.decodeTravelSeconds("60,120", participants: roster),
                       ["id-1": 120])
    }

    func testDecodeTravelSecondsIgnoresExtraTokens() {
        // A sender with a longer roster than ours: the extra positions have
        // nobody to belong to.
        XCTAssertEqual(
            TweenState.decodeTravelSeconds("60,120,180", participants: people(1)),
            ["id-0": 60])
    }
}
