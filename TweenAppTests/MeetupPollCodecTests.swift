import XCTest
import CoreLocation
@testable import TweenApp

/// Regressions from the 2026-09-19 post-push audit. Every test here failed
/// before its fix; several were crashes reachable from a crafted link.
final class MeetupPollCodecTests: XCTestCase {

    private let hassan = Participant(id: "id-hassan", name: "Hassan", latitude: 37.78, longitude: -122.41)
    private let belal = Participant(id: "id-belal", name: "Belal", latitude: 37.76, longitude: -122.43)
    private let kavi = Participant(id: "id-kavi", name: "Kavi", latitude: 37.75, longitude: -122.40)

    private func option(_ name: String, _ lat: Double, by id: String) -> PollOption {
        PollOption(name: name, latitude: lat, longitude: -122.42, proposerID: id)
    }

    // MARK: - Index alignment

    /// AUDIT [CRITICAL] — `opts` dropped options whose proposer wasn't on the
    /// roster, while `votes` and `dec` were indexed against the UNFILTERED
    /// array. One dropped option shifted every later index by one, so a vote
    /// landed on the wrong place and the decision could move somewhere nobody
    /// chose.
    func testVotesAndDecisionIndexTheOptionsThatActuallyShip() {
        var poll = MeetupPoll.empty
        // A ghost: its proposer has left, so it cannot be encoded.
        poll.pick(option("Ghost Cafe", 37.60, by: "id-departed"))
        poll.pick(option("Hey Tea", 37.77, by: hassan.id))
        poll.pick(option("Kung Fu Tea", 37.76, by: belal.id))
        poll.vote(kavi.id, for: option("Kung Fu Tea", 37.76, by: belal.id).id)
        poll.lockIn(option("Kung Fu Tea", 37.76, by: belal.id).id)

        let roster = [hassan, belal, kavi]
        let state = TweenState(text: "Kung Fu Tea", latitude: 37.76, longitude: -122.42,
                               senderName: "Kavi", senderID: kavi.id, kind: .place,
                               messageType: .decided, participants: roster, poll: poll)
        let decoded = try! XCTUnwrap(TweenState(url: try! XCTUnwrap(state.encodedURL())))

        XCTAssertFalse(decoded.poll.options.contains { $0.name == "Ghost Cafe" },
                       "a departed person's pick can't travel")
        XCTAssertEqual(decoded.poll.vote(by: kavi.id),
                       decoded.poll.options.first { $0.name == "Kung Fu Tea" }?.id,
                       "Kavi's vote must survive on the place he actually voted for")
        XCTAssertEqual(decoded.poll.decidedOption?.name, "Kung Fu Tea",
                       "the decision must not slide onto another option")
        XCTAssertEqual(decoded.poll.vote(by: hassan.id),
                       decoded.poll.options.first { $0.name == "Hey Tea" }?.id)
    }

    // MARK: - Crashes reachable from a link

    /// AUDIT [CRITICAL] — `Dictionary(uniqueKeysWithValues:)` TRAPS on a
    /// duplicate key. Participant ids collide for real: `decodeParticipants`
    /// uses the name as the id and `outgoingName` blanks the "You" fallback,
    /// so two unnamed people decode to two entries with id "". The decoded
    /// state is re-encoded on the next line of the receive path (to store it),
    /// so this crashed both processes.
    func testDuplicateParticipantIDsDoNotTrapOnReEncode() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.77&lon=-122.42"
                      + "&kind=place&type=pick&p=%3A37.770000%3A-122.420000,%3A37.760000%3A-122.430000"
                      + "&opts=Hey%20Tea%3A37.770000%3A-122.420000%3A0")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertGreaterThanOrEqual(decoded.participants.count, 1)
        // The crash was here — re-encoding to persist it.
        XCTAssertNotNil(decoded.encodedURL())
    }

    /// Same trap on the other side: two decoded options sharing a content id.
    func testDuplicateOptionIDsDoNotTrapOnReEncode() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.77&lon=-122.42"
                      + "&kind=place&type=pick&p=A%3A37.770000%3A-122.420000,B%3A37.760000%3A-122.430000"
                      + "&opts=Dupe%3A37.770000%3A-122.420000%3A0,Dupe%3A37.770000%3A-122.420000%3A1")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.poll.options.count, 1, "identical places collapse to one option")
        XCTAssertNotNil(decoded.encodedURL())
    }

    // MARK: - Reopening a decision

    /// AUDIT [CRITICAL] — a `.pick` carries no `dec`, and the merge read that
    /// as silence, so every OTHER device kept the old decision and rendered
    /// the settled screen with no vote board: the new pick was invisible and
    /// the only exits were "I'm out" or locking in the stale place.
    func testAPickReopensADecisionOnEveryDevice() {
        var settled = MeetupPoll.empty
        settled.pick(option("Hey Tea", 37.77, by: hassan.id))
        settled.vote(belal.id, for: option("Hey Tea", 37.77, by: hassan.id).id)
        settled.lockIn(option("Hey Tea", 37.77, by: hassan.id).id)
        XCTAssertTrue(settled.isDecided)

        // Belal picks somewhere else on HIS device.
        var reopened = settled
        reopened.pick(option("Kung Fu Tea", 37.76, by: belal.id))
        XCTAssertFalse(reopened.isDecided)

        // It travels, and Hassan — who still holds the decision — adopts it.
        let roster = [hassan, belal]
        let bubble = TweenState(text: "Kung Fu Tea", latitude: 37.76, longitude: -122.42,
                                senderName: "Belal", senderID: belal.id, kind: .place,
                                messageType: .pick, participants: roster, poll: reopened)
        let received = try! XCTUnwrap(TweenState(url: try! XCTUnwrap(bubble.encodedURL())))
        let merged = MeetupPoll.merged(local: settled, incoming: received.poll,
                                       preservingVoteOf: hassan.id)

        XCTAssertFalse(merged.isDecided, "Hassan must be back in the vote, not stuck on the old plan")
        XCTAssertEqual(merged.options.count, 2)
        XCTAssertNil(merged.settledOption(participants: roster))
    }

    func testALockInStillBeatsAnOlderReopen() {
        var reopened = MeetupPoll.empty
        reopened.pick(option("Hey Tea", 37.77, by: hassan.id))
        reopened.lockIn(option("Hey Tea", 37.77, by: hassan.id).id)
        reopened.pick(option("Kung Fu Tea", 37.76, by: belal.id))   // seq 2

        var newer = reopened
        newer.lockIn(option("Kung Fu Tea", 37.76, by: belal.id).id) // seq 3

        XCTAssertEqual(MeetupPoll.merged(local: reopened, incoming: newer).decidedOption?.name,
                       "Kung Fu Tea")
        XCTAssertEqual(MeetupPoll.merged(local: newer, incoming: reopened).decidedOption?.name,
                       "Kung Fu Tea", "merge order must not change the answer")
    }

    // MARK: - Your own vote

    /// AUDIT [MAJOR] — an incoming board is a peer's snapshot and can predate
    /// this device's own vote. Overwriting it moved your vote to a place you
    /// didn't choose, and could settle the meetup on it.
    func testAStaleBoardCannotMoveYourOwnVote() {
        let heyTea = option("Hey Tea", 37.77, by: hassan.id)
        let kungFu = option("Kung Fu Tea", 37.76, by: belal.id)

        var mine = MeetupPoll.empty
        mine.pick(heyTea)
        mine.pick(kungFu)
        mine.vote(belal.id, for: kungFu.id)      // I am Belal; I want Kung Fu Tea

        var stale = MeetupPoll.empty             // a peer's older snapshot
        stale.pick(heyTea)
        stale.pick(kungFu)
        stale.vote(belal.id, for: heyTea.id)     // where my vote USED to be

        let merged = MeetupPoll.merged(local: mine, incoming: stale, preservingVoteOf: belal.id)
        XCTAssertEqual(merged.vote(by: belal.id), kungFu.id)
        XCTAssertNil(merged.settledOption(participants: [hassan, belal]),
                     "a stale bubble must not settle the meetup on my behalf")
    }

    // MARK: - Degradation

    /// AUDIT [MAJOR] — the last rung of the 5000-char ladder drops the board.
    /// Its comment promised the place still survives for peers to absorb; that
    /// was true for a 1.0.3 client and false for a poll-aware one, where the
    /// pick vanished entirely.
    func testABoardlessPickStillReachesTheBoard() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.770000&lon=-122.420000"
                      + "&kind=place&type=pick&fromId=id-hassan")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertTrue(decoded.poll.options.isEmpty, "precondition: the board didn't travel")

        let board = decoded.absorbedPoll
        XCTAssertEqual(board.options.count, 1)
        XCTAssertEqual(board.options.first?.name, "Hey Tea")
        XCTAssertEqual(board.vote(by: "id-hassan"), board.options.first?.id)
    }

    // MARK: - Sender identity

    /// AUDIT [MAJOR] — a `.decided` used to claim the winning option's
    /// PROPOSER as its sender. Three receive-side mechanisms key off
    /// `senderID` (the revision floor's owner, departure-tombstone clearing,
    /// referral attribution), and the caption read "Hassan voted for Hey Tea"
    /// when Belal voted. It must be the composer — while still satisfying a
    /// 1.0.3 client's `isFullyAgreed`.
    func testATerminalBubbleNamesItsComposerAndStillReadsAsAgreedOnOldBuilds() {
        let roster = [hassan, belal]
        // Belal decides on Hassan's place.
        let state = TweenState(text: "Hey Tea", latitude: 37.77, longitude: -122.42,
                               senderName: "Belal", senderID: belal.id,
                               kind: .place, action: .agree, messageType: .decided,
                               participants: roster,
                               agreedNames: ["Hassan"], agreedIDs: [hassan.id])
        XCTAssertEqual(state.senderID, belal.id, "the sender is who sent it")
        XCTAssertTrue(state.isDecided)

        // What a 1.0.3 client sees: it doesn't know `type=decided`, so it
        // infers from kind+action. Reconstruct that reading and check it
        // still lands on a set meetup rather than "0 of 2 agreed".
        XCTAssertEqual(state.action, .agree)
        let asLegacyBuildSeesIt = TweenState(
            text: state.text, latitude: state.latitude, longitude: state.longitude,
            senderName: state.senderName, senderID: state.senderID,
            kind: .place, action: .agree, messageType: .agree,
            participants: state.participants,
            agreedNames: state.agreedNames, agreedIDs: state.agreedIDs)
        XCTAssertTrue(asLegacyBuildSeesIt.isFullyAgreed,
                      "1.0.3 must still read this as a set meetup")
    }
}

/// Regressions the FIX commit (7634cde) introduced, found by the verification
/// audit. The original suite couldn't see most of these because it only ever
/// merged in the peer direction.
final class MeetupPollMergeDirectionTests: XCTestCase {

    private let hassan = Participant(id: "id-hassan", name: "Hassan", latitude: 37.78, longitude: -122.41)
    private let belal = Participant(id: "id-belal", name: "Belal", latitude: 37.76, longitude: -122.43)

    private func heyTea(by id: String) -> PollOption {
        PollOption(name: "Hey Tea", latitude: 37.770, longitude: -122.420, proposerID: id)
    }
    private func kungFuTea(by id: String) -> PollOption {
        PollOption(name: "Kung Fu Tea", latitude: 37.765, longitude: -122.425, proposerID: id)
    }

    /// AUDIT [CRITICAL] — committing a board this device just composed must
    /// NOT preserve the pre-send vote. `preservingVoteOf` is only correct when
    /// `incoming` came from a peer; pointed the other way it reverted the very
    /// vote the user just cast, and re-broadcast the old one on the next send.
    func testCommittingYourOwnSendKeepsYourNewVote() {
        var before = MeetupPoll.empty
        before.pick(heyTea(by: hassan.id))
        before.pick(kungFuTea(by: belal.id))          // I am Belal, voting Kung Fu

        var sent = before
        sent.vote(belal.id, for: heyTea(by: hassan.id).id)   // I change to Hey Tea

        // The commit path: local = pre-send board, incoming = what I just sent.
        let committed = MeetupPoll.merged(local: before, incoming: sent)
        XCTAssertEqual(committed.vote(by: belal.id), heyTea(by: hassan.id).id,
                       "my own send is the fresh copy; it must not be reverted")
        XCTAssertEqual(committed.settledOption(participants: [hassan, belal])?.name, "Hey Tea")
    }

    /// The peer direction still has to hold — this is the fix it was added for.
    func testAPeersStaleBoardStillCannotMoveYourVote() {
        var mine = MeetupPoll.empty
        mine.pick(heyTea(by: hassan.id))
        mine.pick(kungFuTea(by: belal.id))
        var stale = mine
        stale.vote(belal.id, for: heyTea(by: hassan.id).id)

        let merged = MeetupPoll.merged(local: mine, incoming: stale, preservingVoteOf: belal.id)
        XCTAssertEqual(merged.vote(by: belal.id), kungFuTea(by: belal.id).id)
    }

    /// AUDIT [CRITICAL] — the re-assert fallback hung off `if let myVote`, so
    /// when a re-pick removed the place I'd voted for, the board kept my NEW
    /// pick with nobody voting for it, breaking `pick`'s own invariant.
    ///
    /// Note the direction: this is the COMMIT path (`incoming` is the board
    /// this device just composed), so it takes no `preservingVoteOf` — that
    /// flag says "incoming came from a peer and may be stale", which is the
    /// opposite of what's true here. Passing it would filter out my own new
    /// pick, which is precisely why `mergePoll(_:from:)` names the direction
    /// instead of leaving it to an optional argument.
    func testRepickingLeavesYourVoteOnYourNewPick() {
        var before = MeetupPoll.empty
        before.pick(heyTea(by: belal.id))             // my first pick

        var sent = before
        sent.pick(kungFuTea(by: belal.id))            // I'd rather go here

        let merged = MeetupPoll.merged(local: before, incoming: sent)
        XCTAssertEqual(merged.options.map(\.name), ["Kung Fu Tea"])
        XCTAssertEqual(merged.vote(by: belal.id), kungFuTea(by: belal.id).id,
                       "a pick always carries its proposer's vote")
        XCTAssertEqual(merged.voteCount(for: kungFuTea(by: belal.id).id), 1)
    }

    // MARK: - Storage compatibility

    /// AUDIT [CRITICAL] — Swift's synthesized Codable IGNORES default values,
    /// so adding a non-optional `decisionSeq` made every blob written by the
    /// previous build throw `keyNotFound`. `ConversationMeetupStore.load` is a
    /// `try?`, so that discarded the ENTIRE conversation snapshot.
    func testABoardStoredByThePreviousBuildStillDecodes() throws {
        let legacy = Data("""
        {"options":[{"name":"Hey Tea","latitude":37.77,"longitude":-122.42,"proposerID":"id-hassan"}],
         "votes":{"id-hassan":"hey tea@377700,-1224200"}}
        """.utf8)
        let poll = try JSONDecoder().decode(MeetupPoll.self, from: legacy)
        XCTAssertEqual(poll.options.count, 1)
        XCTAssertEqual(poll.decisionSeq, 0)
        XCTAssertFalse(poll.isDecided)
    }

    func testASnapshotSurvivesABoardWrittenWithoutTheNewField() throws {
        // The real blast radius: the snapshot, not just the board.
        var snapshot = MeetupSnapshot(conversationKey: "k", participants: [hassan, belal])
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        snapshot.poll = poll
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(MeetupSnapshot.self, from: data)
        XCTAssertEqual(restored.participants.count, 2)
        XCTAssertEqual(restored.poll?.options.count, 1)
    }

    // MARK: - Size ladder

    /// AUDIT [MAJOR] — the last rung dropped `dec` but kept `decs`, and a
    /// higher generation with no decision reads as "somebody reopened it". A
    /// size-degraded lock-in therefore UN-DECIDED the meetup on exactly the
    /// devices that hadn't seen it yet.
    func testADegradedDecisionDoesNotUnsettleTheMeetup() {
        var settled = MeetupPoll.empty
        settled.pick(heyTea(by: hassan.id))
        settled.vote(belal.id, for: heyTea(by: hassan.id).id)
        settled.lockIn(heyTea(by: hassan.id).id)

        // A payload with no roster can't carry a board — the degraded case.
        let degraded = TweenState(text: "Hey Tea", latitude: 37.770, longitude: -122.420,
                                  senderName: "Hassan", senderID: hassan.id,
                                  kind: .place, messageType: .decided,
                                  participants: [], poll: settled)
        let decoded = try! XCTUnwrap(TweenState(url: try! XCTUnwrap(degraded.encodedURL())))
        XCTAssertTrue(decoded.poll.options.isEmpty, "precondition: the board didn't travel")
        XCTAssertEqual(decoded.poll.decisionSeq, 0,
                       "a generation without its board must not travel either")

        let merged = MeetupPoll.merged(local: settled, incoming: decoded.poll)
        XCTAssertTrue(merged.isDecided, "a degraded bubble must not un-decide a settled meetup")
    }

    // MARK: - Decode index alignment

    /// AUDIT [MAJOR] — `decodeOptions` compacted away rejected records while
    /// `votes`/`dec` still indexed the sender's positions, so every rejection
    /// shifted later votes onto the wrong place. Same defect as the encode
    /// bug, on the other side of the wire.
    func testARejectedOptionRecordDoesNotShiftLaterVotes() {
        // Record 0 is unparseable (too few fields); records 1 and 2 are fine.
        // Votes say participant 0 → option 1, participant 1 → option 2.
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.77&lon=-122.42"
                      + "&kind=place&type=vote"
                      + "&p=A%3A37.780000%3A-122.410000,B%3A37.760000%3A-122.430000"
                      + "&opts=broken%3A1,Hey%20Tea%3A37.770000%3A-122.420000%3A0"
                      + ",Kung%20Fu%20Tea%3A37.765000%3A-122.425000%3A1"
                      + "&votes=1,2")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.poll.options.count, 2, "the broken record is dropped")

        let byName = { (n: String) in decoded.poll.options.first { $0.name == n }?.id }
        XCTAssertEqual(decoded.poll.vote(by: "A"), byName("Hey Tea"))
        XCTAssertEqual(decoded.poll.vote(by: "B"), byName("Kung Fu Tea"))
    }

    /// AUDIT [MAJOR] — a board-less `.vote` used to invent an option owned by
    /// the VOTER. `PollOption.id` carries no proposer, so the misattribution
    /// was permanent: the real proposer's bubble is skipped by the union, and
    /// the place would then vanish when the voter left.
    func testABoardlessVoteDoesNotInventAnOptionOwnedByTheVoter() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.770000&lon=-122.420000"
                      + "&kind=place&type=vote&fromId=id-belal")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertTrue(decoded.absorbedPoll.options.isEmpty,
                      "better to lose the option than to attribute it to the wrong person")
    }
}

/// Third-pass regressions. The merge rule "same proposer, different place =
/// they changed their mind" is only valid when `incoming` is the NEWER
/// statement — which it never is for the local user.
final class MeetupPollStaleBoardTests: XCTestCase {

    private let alice = Participant(id: "id-alice", name: "Alice", latitude: 37.78, longitude: -122.41)
    private let me = Participant(id: "id-me", name: "Me", latitude: 37.76, longitude: -122.43)

    private func heyTea(by id: String) -> PollOption {
        PollOption(name: "Hey Tea", latitude: 37.770, longitude: -122.420, proposerID: id)
    }
    private func kungFuTea(by id: String) -> PollOption {
        PollOption(name: "Kung Fu Tea", latitude: 37.765, longitude: -122.425, proposerID: id)
    }
    private func boba(by id: String) -> PollOption {
        PollOption(name: "Boba Guys", latitude: 37.762, longitude: -122.428, proposerID: id)
    }

    /// AUDIT [HIGH] — tapping a friend's bubble that predates my re-pick used
    /// to delete the place I moved to, resurrect the one I walked away from,
    /// AND re-cast my old vote for it — which in a two-person chat auto-settled
    /// the meetup on a place I had explicitly rejected.
    func testAStalePeerBoardCannotUndoYourRepick() {
        var mine = MeetupPoll.empty
        mine.pick(heyTea(by: me.id))
        mine.pick(boba(by: alice.id))
        mine.pick(kungFuTea(by: me.id))        // I change my mind

        var stale = MeetupPoll.empty           // a peer snapshot from before that
        stale.pick(heyTea(by: me.id))
        stale.pick(boba(by: alice.id))
        stale.vote(alice.id, for: heyTea(by: me.id).id)
        stale.vote(me.id, for: heyTea(by: me.id).id)

        let merged = MeetupPoll.merged(local: mine, incoming: stale, preservingVoteOf: me.id)
            .normalized(participants: [alice, me])

        XCTAssertNotNil(merged.option(proposedBy: me.id))
        XCTAssertEqual(merged.option(proposedBy: me.id)?.name, "Kung Fu Tea",
                       "my current pick stands")
        XCTAssertFalse(merged.options.contains { $0.name == "Hey Tea" },
                       "the place I walked away from must not come back")
        XCTAssertEqual(merged.vote(by: me.id), kungFuTea(by: me.id).id)
        XCTAssertNil(merged.settledOption(participants: [alice, me]),
                     "a stale bubble must not settle the meetup on a rejected place")
    }

    /// ...but a peer is still how this device RELEARNS my pick after a cold
    /// launch, so the exemption only applies when I actually hold one.
    func testAPeerBoardStillRestoresYourPickWhenThisDeviceHasNone() {
        var peer = MeetupPoll.empty
        peer.pick(heyTea(by: me.id))
        peer.pick(boba(by: alice.id))

        let merged = MeetupPoll.merged(local: .empty, incoming: peer, preservingVoteOf: me.id)
        XCTAssertEqual(merged.option(proposedBy: me.id)?.name, "Hey Tea")
        XCTAssertEqual(merged.vote(by: me.id), heyTea(by: me.id).id)
    }

    /// Someone ELSE changing their mind must still work — the exemption is for
    /// the local user only, not a licence to ignore everyone's re-picks.
    func testAPeersOwnRepickIsStillAdopted() {
        var mine = MeetupPoll.empty
        mine.pick(boba(by: alice.id))
        mine.pick(kungFuTea(by: me.id))

        var peer = mine
        peer.pick(heyTea(by: alice.id))        // Alice changes her mind

        let merged = MeetupPoll.merged(local: mine, incoming: peer, preservingVoteOf: me.id)
        XCTAssertEqual(merged.option(proposedBy: alice.id)?.name, "Hey Tea")
        XCTAssertFalse(merged.options.contains { $0.name == "Boba Guys" })
        XCTAssertEqual(merged.options.count, 2, "still one option per person")
    }

    /// AUDIT [LOW] — a generation with no board is not a generation. A crafted
    /// link could otherwise un-decide a settled meetup and propagate it.
    func testAGenerationWithoutABoardIsIgnored() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.770000&lon=-122.420000"
                      + "&kind=place&type=vote&fromId=id-alice&decs=999999")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertEqual(decoded.poll.decisionSeq, 0)

        var settled = MeetupPoll.empty
        settled.pick(heyTea(by: alice.id))
        settled.lockIn(heyTea(by: alice.id).id)
        XCTAssertTrue(MeetupPoll.merged(local: settled, incoming: decoded.poll).isDecided,
                      "a crafted generation must not un-decide the meetup")
    }

    /// AUDIT [MEDIUM-LOW] — `decs` travels with the board, so a `.pick` whose
    /// board was dropped by the size ladder arrives at generation 0 and loses.
    /// The message type is the only surviving evidence of the reopen.
    func testReopenIsIdempotentAndOnlyFiresWhenDecided() {
        var settled = MeetupPoll.empty
        settled.pick(heyTea(by: alice.id))
        settled.lockIn(heyTea(by: alice.id).id)
        let generation = settled.decisionSeq

        settled.reopen()
        XCTAssertFalse(settled.isDecided)
        XCTAssertEqual(settled.decisionSeq, generation + 1)

        settled.reopen()
        XCTAssertEqual(settled.decisionSeq, generation + 1,
                       "reopening an already-open board must not escalate the generation")
    }
}

/// Fourth-pass regression. `merged`'s "this device owns its own pick"
/// exemption only defends a board that HAS my pick in it — so the order in
/// which the extension hydrates matters as much as the merge rule, and the
/// controller isn't reachable from this target. These pin the invariant the
/// ordering exists to satisfy.
final class MeetupPollHydrationTests: XCTestCase {

    private let alice = Participant(id: "id-alice", name: "Alice", latitude: 37.78, longitude: -122.41)
    private let me = Participant(id: "id-me", name: "Me", latitude: 37.76, longitude: -122.43)
    private let key = "hydration-conversation"

    private func opt(_ name: String, _ lat: Double, by id: String) -> PollOption {
        PollOption(name: name, latitude: lat, longitude: -122.42, proposerID: id)
    }

    override func setUp() {
        super.setUp()
        ConversationMeetupStore.clearIncludingSync(key: key)
    }
    override func tearDown() {
        ConversationMeetupStore.clearIncludingSync(key: key)
        super.tearDown()
    }

    /// The stale bubble, merged into an EMPTY board — what a cold launch did
    /// before the hydration moved above the decode. The exemption has nothing
    /// to defend, so the rejected place wins and auto-settles.
    func testMergingAStaleBoardIntoAnEmptyOneLosesYourPick() {
        var stale = MeetupPoll.empty
        stale.pick(opt("Hey Tea", 37.770, by: me.id))       // my OLD pick
        stale.pick(opt("Boba Guys", 37.762, by: alice.id))
        stale.vote(alice.id, for: opt("Hey Tea", 37.770, by: me.id).id)

        let cold = MeetupPoll.merged(local: .empty, incoming: stale, preservingVoteOf: me.id)
        XCTAssertEqual(cold.option(proposedBy: me.id)?.name, "Hey Tea")
        XCTAssertNotNil(cold.settledOption(participants: [alice, me]),
                        "this is the failure the hydration ordering prevents")
    }

    /// Hydrated first — the same bubble, merged into the board the store held.
    func testHydratingFromTheStoreFirstDefendsYourPick() {
        var mine = MeetupPoll.empty
        mine.pick(opt("Hey Tea", 37.770, by: me.id))
        mine.pick(opt("Boba Guys", 37.762, by: alice.id))
        mine.pick(opt("Kung Fu Tea", 37.765, by: me.id))    // I changed my mind
        ConversationMeetupStore.savePoll(mine, key: key)

        var stale = MeetupPoll.empty
        stale.pick(opt("Hey Tea", 37.770, by: me.id))
        stale.pick(opt("Boba Guys", 37.762, by: alice.id))
        stale.vote(alice.id, for: opt("Hey Tea", 37.770, by: me.id).id)

        // The activation order: hydrate from the store, THEN fold in the bubble.
        let hydrated = MeetupPoll.merged(local: ConversationMeetupStore.poll(key: key),
                                         incoming: .empty, preservingVoteOf: me.id)
        let merged = MeetupPoll.merged(local: hydrated, incoming: stale, preservingVoteOf: me.id)
            .normalized(participants: [alice, me])

        XCTAssertEqual(merged.option(proposedBy: me.id)?.name, "Kung Fu Tea")
        XCTAssertEqual(merged.vote(by: me.id), opt("Kung Fu Tea", 37.765, by: me.id).id)
        XCTAssertNil(merged.settledOption(participants: [alice, me]))
    }

    /// AUDIT [LOW/MED] — the reopen inference must not fire when the rebuilt
    /// option didn't land, or the group loses its place and gains no contender.
    func testABoardlessPickFromAnUnnamedSenderRebuildsNothing() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.770000&lon=-122.420000"
                      + "&kind=place&type=pick")!
        let decoded = try! XCTUnwrap(TweenState(url: url))
        XCTAssertTrue(decoded.absorbedPoll.options.isEmpty,
                      "no sender means no proposer, so nothing can be rebuilt — "
                      + "and the caller must not reopen on the strength of it")
    }
}
