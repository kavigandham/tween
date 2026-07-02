import XCTest
@testable import TweenApp

/// Coverage of per-friend ping timestamps and the incoming-reply stamp, both
/// backed by the App Group suite (wiped before each test).
final class PingLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        if let defaults = UserDefaults(suiteName: LocationCache.appGroup) {
            for key in defaults.dictionaryRepresentation().keys {
                defaults.removeObject(forKey: key)
            }
        }
        PingLog.clear()
    }

    // 1. A logged ping is retrievable at roughly the time it was logged.
    func testLogAndRetrieve() {
        let friend = TweenFriend(name: "Ada")
        let before = Date()
        PingLog.logPing(for: friend.id)

        let last = PingLog.lastPing(for: friend.id)
        XCTAssertNotNil(last)
        XCTAssertEqual(last!.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 1.0)
    }

    // 2. Two friends keep independent ping stamps.
    func testTwoFriendsIndependent() {
        let ada = TweenFriend(name: "Ada")
        let grace = TweenFriend(name: "Grace")

        let adaTime = Date(timeIntervalSince1970: 1_000_000)
        PingLog.logPing(for: ada.id, at: adaTime)

        // Grace is never pinged.
        XCTAssertEqual(PingLog.lastPing(for: ada.id), adaTime)
        XCTAssertNil(PingLog.lastPing(for: grace.id))
    }

    // 3. The incoming-reply timestamp round-trips through the suite.
    func testLastIncomingReplyRoundTrips() {
        XCTAssertNil(PingLog.lastIncomingReplyAt)

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        PingLog.lastIncomingReplyAt = stamp

        XCTAssertEqual(try XCTUnwrap(PingLog.lastIncomingReplyAt).timeIntervalSince1970,
                       stamp.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // 4. Generic invites cover Messages sends where iOS does not expose a name.
    func testGenericInviteRoundTrips() {
        XCTAssertNil(PingLog.lastGenericInviteAt)

        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        PingLog.logGenericInvite(at: stamp)

        XCTAssertEqual(try XCTUnwrap(PingLog.lastGenericInviteAt).timeIntervalSince1970,
                       stamp.timeIntervalSince1970,
                       accuracy: 1.0)
    }
}
