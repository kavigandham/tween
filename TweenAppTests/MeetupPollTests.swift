import XCTest
import CoreLocation
@testable import TweenApp

/// The vote board, and specifically the bug it was built to kill: a friend
/// disagreeing with your place used to resolve as an agreement TO your place,
/// because "somewhere else" and "yes, that one" shared a single slot.
final class MeetupPollTests: XCTestCase {

    private let hassan = Participant(id: "id-hassan", name: "Hassan", latitude: 37.78, longitude: -122.41)
    private let belal = Participant(id: "id-belal", name: "Belal", latitude: 37.76, longitude: -122.43)
    private let kavi = Participant(id: "id-kavi", name: "Kavi", latitude: 37.75, longitude: -122.40)

    private func heyTea(by id: String) -> PollOption {
        PollOption(name: "Hey Tea", latitude: 37.770, longitude: -122.420, proposerID: id)
    }

    private func kungFuTea(by id: String) -> PollOption {
        PollOption(name: "Kung Fu Tea", latitude: 37.765, longitude: -122.425, proposerID: id)
    }

    // MARK: - The reported bug

    /// Hassan picks, Belal picks something else. BOTH stay on the board, it's
    /// a tie, and nothing is decided — the old model resolved this as
    /// "everyone agreed to Hassan's place".
    func testDisagreementLeavesBothPicksStandingAndDecidesNothing() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.pick(kungFuTea(by: belal.id))

        XCTAssertEqual(poll.options.count, 2)
        XCTAssertEqual(poll.voteCount(for: heyTea(by: hassan.id).id), 1)
        XCTAssertEqual(poll.voteCount(for: kungFuTea(by: belal.id).id), 1)
        XCTAssertTrue(poll.isTie)
        XCTAssertNil(poll.leader, "a tie has no leader")
        XCTAssertNil(poll.settledOption(participants: [hassan, belal]),
                     "a disagreement must not settle itself, least of all onto the first pick")
    }

    /// ...and it resolves when someone actually changes their mind.
    func testSwitchingYourVoteSettlesItUnanimously() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.pick(kungFuTea(by: belal.id))

        poll.vote(belal.id, for: heyTea(by: hassan.id).id)

        XCTAssertFalse(poll.isTie)
        XCTAssertEqual(poll.leader?.name, "Hey Tea")
        XCTAssertEqual(poll.settledOption(participants: [hassan, belal])?.name, "Hey Tea")
    }

    /// A plurality never auto-decides — somebody has to say so. Otherwise the
    /// third person merely ADDING a contender would hand the meetup to the
    /// place that happened to be ahead.
    func testPluralityNeedsAnExplicitLockIn() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.vote(belal.id, for: heyTea(by: hassan.id).id)
        poll.pick(kungFuTea(by: kavi.id))

        let everyone = [hassan, belal, kavi]
        XCTAssertTrue(poll.everyoneVoted(participants: everyone))
        XCTAssertEqual(poll.leader?.name, "Hey Tea")
        XCTAssertNil(poll.settledOption(participants: everyone),
                     "2-1 is a leader, not a decision")

        poll.lockIn(heyTea(by: hassan.id).id)
        XCTAssertEqual(poll.settledOption(participants: everyone)?.name, "Hey Tea")
    }

    // MARK: - One option per person

    func testRepickingReplacesYourOwnOptionAndDropsItsBorrowedVotes() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.vote(belal.id, for: heyTea(by: hassan.id).id)
        XCTAssertEqual(poll.voteCount(for: heyTea(by: hassan.id).id), 2)

        poll.pick(kungFuTea(by: hassan.id))

        XCTAssertEqual(poll.options.count, 1, "one option per person")
        XCTAssertEqual(poll.options.first?.name, "Kung Fu Tea")
        XCTAssertEqual(poll.vote(by: hassan.id), kungFuTea(by: hassan.id).id)
        XCTAssertNil(poll.vote(by: belal.id),
                     "Belal voted for a place that no longer exists; his vote must not be moved for him")
    }

    func testPickReopensADecidedMeetup() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.lockIn(heyTea(by: hassan.id).id)
        XCTAssertTrue(poll.isDecided)

        poll.pick(kungFuTea(by: belal.id))
        XCTAssertFalse(poll.isDecided)
    }

    // MARK: - Merge

    /// Two people pick before either has seen the other. Both devices must end
    /// up with the same two-option board, whichever order the bubbles arrive.
    func testConcurrentPicksUnionInEitherOrder() {
        var mine = MeetupPoll.empty
        mine.pick(heyTea(by: hassan.id))
        var theirs = MeetupPoll.empty
        theirs.pick(kungFuTea(by: belal.id))

        let a = MeetupPoll.merged(local: mine, incoming: theirs)
        let b = MeetupPoll.merged(local: theirs, incoming: mine)

        XCTAssertEqual(Set(a.options.map(\.id)), Set(b.options.map(\.id)))
        XCTAssertEqual(a.votes, b.votes)
        XCTAssertEqual(a.standings.map(\.option.id), b.standings.map(\.option.id),
                       "standings order must be device-independent")
    }

    func testMergeAdoptsARepickRatherThanKeepingBoth() {
        var mine = MeetupPoll.empty
        mine.pick(heyTea(by: hassan.id))
        var theirs = MeetupPoll.empty
        theirs.pick(kungFuTea(by: hassan.id))

        let merged = MeetupPoll.merged(local: mine, incoming: theirs)
        XCTAssertEqual(merged.options.count, 1)
        XCTAssertEqual(merged.options.first?.name, "Kung Fu Tea")
    }

    /// A person who leaves takes their pick and their vote with them —
    /// otherwise an unattended place can win the vote.
    func testLeavingRemovesYourPickAndYourVote() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.pick(kungFuTea(by: belal.id))

        let remaining = poll.normalized(participants: [hassan])
        XCTAssertEqual(remaining.options.count, 1)
        XCTAssertEqual(remaining.options.first?.name, "Hey Tea")
        XCTAssertNil(remaining.vote(by: belal.id))
    }

    func testNormalizeDropsADecisionWhoseOptionIsGone() {
        var poll = MeetupPoll.empty
        poll.pick(kungFuTea(by: belal.id))
        poll.lockIn(kungFuTea(by: belal.id).id)

        let remaining = poll.normalized(participants: [hassan])
        XCTAssertFalse(remaining.isDecided)
    }

    /// Same cafe, float noise from two different MapKit responses: one option.
    func testNearIdenticalCoordinatesCollapseToOneOption() {
        let a = PollOption(name: "Hey Tea", latitude: 37.770000, longitude: -122.420000, proposerID: hassan.id)
        let b = PollOption(name: "Hey Tea", latitude: 37.770004, longitude: -122.419998, proposerID: belal.id)
        XCTAssertEqual(a.id, b.id)
    }

    // MARK: - Wire format

    func testBoardSurvivesAURLRoundTrip() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.pick(kungFuTea(by: belal.id))
        poll.vote(kavi.id, for: heyTea(by: hassan.id).id)

        let state = TweenState(
            text: "Hey Tea",
            latitude: 37.770, longitude: -122.420,
            senderName: "Kavi", senderID: kavi.id,
            kind: .place,
            messageType: .vote,
            participants: [hassan, belal, kavi],
            poll: poll)

        let url = try! XCTUnwrap(state.encodedURL())
        XCTAssertLessThanOrEqual(url.absoluteString.count, 5000)
        let decoded = try! XCTUnwrap(TweenState(url: url))

        XCTAssertEqual(decoded.messageType, .vote)
        XCTAssertEqual(Set(decoded.poll.options.map(\.name)), ["Hey Tea", "Kung Fu Tea"])
        XCTAssertEqual(decoded.poll.votes, poll.votes)
        XCTAssertEqual(decoded.poll.option(proposedBy: belal.id)?.name, "Kung Fu Tea")
    }

    func testDecisionSurvivesAURLRoundTrip() {
        var poll = MeetupPoll.empty
        poll.pick(heyTea(by: hassan.id))
        poll.vote(belal.id, for: heyTea(by: hassan.id).id)
        poll.lockIn(heyTea(by: hassan.id).id)

        let state = TweenState(
            text: "Hey Tea",
            latitude: 37.770, longitude: -122.420,
            senderName: "Belal", senderID: belal.id,
            kind: .place,
            messageType: .decided,
            participants: [hassan, belal],
            poll: poll)

        let decoded = try! XCTUnwrap(TweenState(url: try! XCTUnwrap(state.encodedURL())))
        XCTAssertTrue(decoded.isDecided)
        XCTAssertEqual(decoded.poll.decidedOption?.name, "Hey Tea")
    }

    func testEnRouteCarriesAnETA() {
        let state = TweenState(
            text: "Hey Tea",
            latitude: 37.770, longitude: -122.420,
            senderName: "Hassan", senderID: hassan.id,
            kind: .place,
            messageType: .enroute,
            participants: [hassan, belal],
            etaSeconds: 720)

        let decoded = try! XCTUnwrap(TweenState(url: try! XCTUnwrap(state.encodedURL())))
        XCTAssertEqual(decoded.messageType, .enroute)
        XCTAssertEqual(decoded.etaSeconds, 720)
        XCTAssertTrue(decoded.isDecided, "you only leave for a place the group settled on")
        XCTAssertTrue(BubbleCaption.etaLine(state: decoded).contains("12 min"))
    }

    /// A nonsense ETA must read as absent rather than rendering "1440 min".
    func testAbsurdETAIsRejected() {
        let url = URL(string: "https://tween.app/m?t=Hey%20Tea&lat=37.77&lon=-122.42&kind=place&type=enroute&eta=999999")!
        XCTAssertNil(TweenState(url: url)?.etaSeconds)
    }

    // MARK: - Back-compat with pre-poll threads

    /// A 1.0.3 `.propose` is a pick, and its sender has voted for it.
    func testLegacyProposeAbsorbsAsAPick() {
        let state = TweenState(
            text: "Hey Tea", latitude: 37.770, longitude: -122.420,
            senderName: "Hassan", senderID: hassan.id,
            kind: .place, messageType: .propose,
            participants: [hassan, belal])

        let board = state.absorbedPoll
        XCTAssertEqual(board.options.count, 1)
        XCTAssertEqual(board.options.first?.proposerID, hassan.id)
        XCTAssertEqual(board.vote(by: hassan.id), board.options.first?.id)
    }

    /// A 1.0.3 `.counter` becomes a SECOND option, never an agreement to the
    /// first — this is the regression guard for the reported bug arriving
    /// from an old build still in the thread.
    func testLegacyCounterAbsorbsAsASecondOptionNotAnAgreement() {
        let propose = TweenState(
            text: "Hey Tea", latitude: 37.770, longitude: -122.420,
            senderName: "Hassan", senderID: hassan.id,
            kind: .place, messageType: .propose,
            participants: [hassan, belal])
        let counter = TweenState(
            text: "Kung Fu Tea", latitude: 37.765, longitude: -122.425,
            senderName: "Belal", senderID: belal.id,
            kind: .place, messageType: .counter,
            participants: [hassan, belal])

        let board = MeetupPoll.merged(local: propose.absorbedPoll, incoming: counter.absorbedPoll)
        XCTAssertEqual(board.options.count, 2)
        XCTAssertNil(board.settledOption(participants: [hassan, belal]))
        XCTAssertTrue(board.isTie)
    }

    /// A 1.0.3 full agreement still lands on the terminal screen.
    func testLegacyFullAgreementAbsorbsAsADecision() {
        let state = TweenState(
            text: "Hey Tea", latitude: 37.770, longitude: -122.420,
            senderName: "Hassan", senderID: hassan.id,
            kind: .place, action: .agree, messageType: .agree,
            participants: [hassan, belal],
            agreedNames: ["Belal"], agreedIDs: [belal.id])

        XCTAssertTrue(state.isFullyAgreed)
        XCTAssertTrue(state.isDecided)
        XCTAssertEqual(state.absorbedPoll.decidedOption?.name, "Hey Tea")
    }

    /// A build that predates the poll infers the type from `kind`+`action`.
    /// A pick has to read as a proposal there and a decision as an agreement,
    /// or a 1.0.3 user sees nonsense in a thread they share with 1.1.
    func testPollTypesCarryLegacyActionsForOlderBuilds() {
        let pick = TweenState(text: "Hey Tea", latitude: 37.77, longitude: -122.42,
                              senderID: hassan.id, kind: .place, messageType: .pick,
                              participants: [hassan, belal])
        XCTAssertEqual(pick.action, .invite, "reads as .propose on 1.0.3")

        for type in [TweenState.MessageType.vote, .decided, .enroute] {
            let state = TweenState(text: "Hey Tea", latitude: 37.77, longitude: -122.42,
                                   senderID: hassan.id, kind: .place, messageType: type,
                                   participants: [hassan, belal])
            XCTAssertEqual(state.action, .agree, "\(type) must read as .agree on 1.0.3")
        }
    }

    // MARK: - Concurrency guard

    /// Two people picking at the same revision is the NORMAL opening of a
    /// vote. The revision tie-break must let both in; a terminal decision
    /// still has to lose the tie.
    func testConcurrentPicksAreBothAdditiveButDecisionsAreNot() {
        XCTAssertTrue(TweenState.MessageType.pick.isAdditive)
        XCTAssertTrue(TweenState.MessageType.vote.isAdditive)
        XCTAssertTrue(TweenState.MessageType.invite.isAdditive)
        XCTAssertFalse(TweenState.MessageType.decided.isAdditive)
        XCTAssertFalse(TweenState.MessageType.leave.isAdditive)
    }
}
