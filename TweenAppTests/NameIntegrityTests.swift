import XCTest
import CoreLocation
@testable import TweenApp

/// Audit F2: an unnamed user's payload used to carry the literal "You", so every
/// peer rendered them as "You" — and a REMOTE "You" was even misclassified as
/// the local user. These lock the fix: never encode the fallback, sanitise it on
/// receipt, and identify self by stable ID, not by name.
final class NameIntegrityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func p(_ id: String, _ name: String) -> Participant {
        Participant(id: id, name: name,
                    coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0))
    }

    // MARK: - Step 2: never encode "You"

    func testStringEncodeBlanksYouFallback() {
        let encoded = TweenState.encodeParticipants([p("id-me", "You"), p("id-sam", "Sam")])
        XCTAssertFalse(encoded.contains("You"), "wire payload must not carry the fallback: \(encoded)")
        let decoded = TweenState.decodeParticipants(encoded)
        XCTAssertEqual(decoded.first?.name, "")     // blanked → sanitised on display
        XCTAssertEqual(decoded.last?.name, "Sam")   // real name untouched
    }

    func testJSONEncodeBlanksYouButKeepsIdentity() {
        let json = TweenState.encodeParticipantJSON([p("id-me", "You")])
        let decoded = json.flatMap(TweenState.decodeParticipantJSON)
        XCTAssertEqual(decoded?.first?.name, "")
        XCTAssertEqual(decoded?.first?.id, "id-me", "stable id must survive so identity is preserved")
    }

    func testOutgoingNameHelper() {
        XCTAssertEqual(TweenState.outgoingName("You"), "")
        XCTAssertEqual(TweenState.outgoingName("Sam"), "Sam")
    }

    func testFullStateEncodeDropsYou() {
        let state = TweenState(
            text: "Blue Bottle",
            latitude: 37.7,
            longitude: -122.4,
            kind: .place,
            messageType: .propose,
            participants: [p("id-me", "You"), p("id-sam", "Sam")])
        let url = state.encodedURL(scheme: "tween", host: "m")
        XCTAssertNotNil(url)
        let round = TweenState(url: url!)
        XCTAssertNotNil(round)
        XCTAssertFalse(round!.participants.contains { $0.name == "You" },
                       "no participant should decode as the literal fallback")
        XCTAssertTrue(round!.participants.contains { $0.name == "Sam" })
    }

    // MARK: - Step 3: receiver sanitisation

    func testPeerDisplayNameSanitisesFallbackAndEmpty() {
        XCTAssertEqual(UserName.peerDisplayName("You"), "Friend")
        XCTAssertEqual(UserName.peerDisplayName(""), "Friend")
        XCTAssertEqual(UserName.peerDisplayName("   "), "Friend")
        XCTAssertEqual(UserName.peerDisplayName("Sam"), "Sam")
    }

    // MARK: - Step 4: identity-based isLocal

    func testRemoteYouNotMisclassifiedAsLocal() {
        // Two unnamed devices both default to "You"; the stable IDs differ.
        let localContext = LocalParticipantContext(id: "my-stable-id", name: "You")
        XCTAssertFalse(p("remote-uuid", "You").matches(localContext),
                       "a remote participant named You must not read as the local user")
        XCTAssertTrue(p("my-stable-id", "You").matches(localContext),
                      "the entry carrying my stable id is me")
    }
}
