import XCTest
import CoreLocation
@testable import TweenApp

/// The 2026-09-20 device report: "I sent a place from the app, he agreed, and
/// when it says both agreed we tap it and it asks to choose a place instead of
/// Open in Maps — and the chip says Friend while the rows say Saad."
///
/// One cause with three faces: a roster whose identity had collapsed to
/// DISPLAY NAMES (which `Participant`'s own doc says happens whenever a
/// payload travels without usable ids) met a board keyed by STABLE IDS.
final class BoardIdentityRegressionTests: XCTestCase {

    private let hassanID = "11111111-2222-3333-4444-555555555555"
    private let saadID   = "66666666-7777-8888-9999-000000000000"

    private func hunan(by proposer: String) -> PollOption {
        PollOption(name: "Hunan Village", latitude: 39.05, longitude: -77.48, proposerID: proposer)
    }

    /// The settled board, as it stands on the device that sent the lock-in.
    private func settledBoard(proposer: String, voter: String) -> MeetupPoll {
        var board = MeetupPoll.empty
        board.pick(hunan(by: proposer))
        board.vote(voter, for: hunan(by: proposer).id)
        board.lockIn(hunan(by: proposer).id)
        return board
    }

    // MARK: - The wipe

    /// A name-keyed roster must not delete an id-keyed board. It used to drop
    /// every option, clear the decision AND bump `decisionSeq`, which left the
    /// extension on "Ready to pick a spot" with an empty board.
    func testNameKeyedRosterKeepsAnIDKeyedBoardSettled() {
        let board = settledBoard(proposer: hassanID, voter: saadID)
        let nameKeyed = [Participant(id: "Saad", name: "Saad", latitude: 39.00, longitude: -77.50),
                         Participant(id: "Hassan", name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: nameKeyed, departed: [])

        XCTAssertEqual(normalized.options.map(\.name), ["Hunan Village"],
                       "an id/name identity mismatch is not a departure — the board must survive")
        XCTAssertEqual(normalized.decidedOptionID, hunan(by: hassanID).id)
        XCTAssertEqual(normalized.decisionSeq, board.decisionSeq,
                       "bumping the generation here is what made the wipe permanent")
        XCTAssertNotNil(normalized.settledOption(participants: nameKeyed))
    }

    /// And the mirror image: an id-keyed roster against a name-keyed board
    /// (the bubble arrived without usable ids, so its options resolved to
    /// names).
    func testIDKeyedRosterKeepsANameKeyedBoardSettled() {
        let board = settledBoard(proposer: "Hassan", voter: "Saad")
        let idKeyed = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                       Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: idKeyed, departed: [])

        XCTAssertNotNil(normalized.settledOption(participants: idKeyed))
        XCTAssertEqual(normalized.decisionSeq, board.decisionSeq)
    }

    /// Devices that already ran the broken build have an EMPTY board with an
    /// inflated `decisionSeq` sitting in their App Group. `merged` gives the
    /// decision slot to the newer generation, so that stale generation still
    /// out-ranks the peer's real lock-in — the meetup has to come back anyway.
    ///
    /// Constructed by hand on purpose: with the fix in place `normalized` can
    /// no longer PRODUCE this board, so deriving it from a normalize would
    /// merge a board with itself and assert nothing.
    func testAnAlreadyWipedBoardStillRecoversOnTheNextTap() {
        let peer = settledBoard(proposer: hassanID, voter: saadID)
        var wiped = MeetupPoll.empty
        wiped.decisionSeq = peer.decisionSeq + 1      // the old wipe's bogus "reopen"
        let roster = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let merged = MeetupPoll.merged(local: wiped, incoming: peer, preservingVoteOf: hassanID)
            .normalized(participants: roster, departed: [])

        XCTAssertEqual(merged.options.map(\.name), ["Hunan Village"],
                       "the place comes back through the union")
        XCTAssertNotNil(merged.settledOption(participants: roster),
                        "and unanimity re-settles it even though the stale generation holds `dec`")
    }

    /// A real departure still takes that person's pick with it — the guard
    /// above must not become "never drop anything".
    func testALeaversPickIsStillRemoved() {
        var board = MeetupPoll.empty
        board.pick(hunan(by: saadID))
        board.lockIn(hunan(by: saadID).id)
        let remaining = [Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: remaining, departed: [])

        XCTAssertTrue(normalized.options.isEmpty, "a leaver takes their pick with them")
        XCTAssertNil(normalized.decidedOptionID)
        XCTAssertGreaterThan(normalized.decisionSeq, board.decisionSeq,
                             "THAT is a real reopen, and must still say so")
    }

    /// An UNNAMED participant must not become a wildcard: their empty name
    /// would otherwise match every option whose proposer failed to resolve.
    /// Scored alongside a resolvable option so the keyspace guard above stays
    /// out of it and this tests the key set itself.
    func testAnEmptyNameIsNotAnIdentityKey() {
        var board = MeetupPoll.empty
        board.pick(hunan(by: hassanID))
        board.pick(PollOption(name: "Ledo Pizza", latitude: 39.02, longitude: -77.49,
                              proposerID: ""))
        let roster = [Participant(id: saadID, name: "", latitude: 39.00, longitude: -77.50),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: roster, departed: [])

        XCTAssertEqual(normalized.options.map(\.name), ["Hunan Village"],
                       "the unnamed participant must not vouch for an unresolvable proposer")
    }

    // MARK: - The bail-out must not become the opposite bug

    /// The audit's case (2026-09-21): three people, ONE proposer, the group
    /// locks his place in, and then he leaves. The remaining two must not be
    /// pinned to MEETUP SET at a place its chooser walked away from — that
    /// state has no board and no "I'm out" to escape it.
    func testTheOnlyProposerLeavingAThreePersonChatReopensTheBoard() {
        let belalID = "BBBBBBBB-0000-0000-0000-000000000000"
        var board = MeetupPoll.empty
        board.pick(hunan(by: hassanID))
        board.vote(saadID, for: hunan(by: hassanID).id)
        board.vote(belalID, for: hunan(by: hassanID).id)
        board.lockIn(hunan(by: hassanID).id)

        let remaining = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                         Participant(id: belalID, name: "Belal", latitude: 39.20, longitude: -77.40)]
        let normalized = board.normalized(participants: remaining, departed: [hassanID])

        XCTAssertTrue(normalized.options.isEmpty, "the leaver takes his pick with him")
        XCTAssertNil(normalized.decidedOptionID)
        XCTAssertNil(normalized.settledOption(participants: remaining))
        XCTAssertGreaterThan(normalized.decisionSeq, board.decisionSeq,
                             "this IS a reopen and must propagate as one")
        XCTAssertNil(normalized.votes[hassanID], "a leaver's vote must stop counting")
    }

    /// The keyspace mismatch is still held, because no tombstone explains it.
    func testAMismatchWithNoTombstoneStillKeepsTheBoard() {
        let board = settledBoard(proposer: hassanID, voter: saadID)
        let nameKeyed = [Participant(id: "Saad", name: "Saad", latitude: 39.00, longitude: -77.50),
                         Participant(id: "Hassan", name: "Hassan", latitude: 39.10, longitude: -77.45)]

        XCTAssertNotNil(board.normalized(participants: nameKeyed, departed: [])
                            .settledOption(participants: nameKeyed))
    }

    /// A DEPARTED member's name-keyed option must not be rescued by a live
    /// member who merely shares their display name. `RosterMerge.isDeparted`
    /// gates name matching on `id == name` for exactly this reason.
    func testALeaversOptionIsNotRescuedByANameCollision() {
        let belalID = "BBBBBBBB-0000-0000-0000-000000000000"
        var board = MeetupPoll.empty
        board.pick(hunan(by: "Saad"))          // departed, name-keyed
        board.pick(PollOption(name: "Ledo Pizza", latitude: 39.02, longitude: -77.49,
                              proposerID: belalID))
        // A DIFFERENT, live, id-keyed person who happens to be called Saad.
        let roster = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                      Participant(id: belalID, name: "Belal", latitude: 39.20, longitude: -77.40)]

        let normalized = board.normalized(participants: roster, departed: ["Saad"])

        XCTAssertEqual(normalized.options.map(\.name), ["Ledo Pizza"],
                       "a shared display name must not vouch for someone who left")
    }

    /// The view re-merges the SELECTED bubble's board and re-normalizes it, so
    /// it needs the tombstones too. Without them `ExpandedView` re-admitted the
    /// option the controller had just dropped and offered "Lock in <it>", which
    /// a send would then broadcast back to everyone.
    func testTheViewAlsoScopesTheBoardToTombstones() {
        let belalID = "BBBBBBBB-0000-0000-0000-000000000000"
        var board = MeetupPoll.empty
        board.pick(hunan(by: hassanID))
        board.lockIn(hunan(by: hassanID).id)
        // Hassan's own pick bubble, still sitting in the snapshot after he left.
        let hisBubble = TweenState(text: "Hunan Village", latitude: 39.05, longitude: -77.48,
                                   senderName: "Hassan", senderID: hassanID, kind: .place,
                                   messageType: .pick, participants: [], poll: board)
        let remaining = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                         Participant(id: belalID, name: "Belal", latitude: 39.20, longitude: -77.40)]

        let view = ExpandedView(received: hisBubble,
                                selfCoord: CLLocationCoordinate2D(latitude: 39.00, longitude: -77.50),
                                rankedSpots: [],
                                isUserIn: true,
                                localParticipantID: saadID,
                                rosterParticipants: remaining,
                                poll: .empty,
                                departed: [hassanID],
                                onImIn: {},
                                onSelectSpot: { _ in })

        XCTAssertTrue(view.board.options.isEmpty,
                      "the tapped bubble must not re-admit a departed proposer's place")
        XCTAssertFalse(view.isMeetupSet, "and it must not read as a settled meetup")
        XCTAssertNil(view.settledOption)
    }

    /// A PARTIAL keyspace mismatch: one option resolves, one is name-keyed from
    /// a legacy bubble. The collapsed one must survive — the old all-or-nothing
    /// guard deleted it precisely because its neighbour resolved.
    func testAPartialKeyspaceMismatchKeepsTheCollapsedOption() {
        let belalID = "BBBBBBBB-0000-0000-0000-000000000000"
        var board = MeetupPoll.empty
        board.pick(hunan(by: belalID))                     // resolves
        board.pick(PollOption(name: "Ledo Pizza", latitude: 39.02, longitude: -77.49,
                              proposerID: "Hassan"))       // name-keyed, collapsed
        let roster = [Participant(id: belalID, name: "Belal", latitude: 39.20, longitude: -77.40),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: roster, departed: [])

        XCTAssertEqual(Set(normalized.options.map(\.name)), ["Hunan Village", "Ledo Pizza"],
                       "one resolvable neighbour is not proof the other person left")
    }

    /// And a MIXED board — one proposer tombstoned, one merely unresolvable.
    /// The tombstoned one goes; the unresolvable one stays. The old guard was
    /// all-or-nothing, so the single tombstone disarmed it and took both.
    func testATombstonedProposerDoesNotTakeAnUnresolvableOneWithIt() {
        var board = MeetupPoll.empty
        board.pick(hunan(by: hassanID))                    // tombstoned below
        board.pick(PollOption(name: "Ledo Pizza", latitude: 39.02, longitude: -77.49,
                              proposerID: "Belal"))        // name-keyed, no tombstone
        let roster = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                      Participant(id: "ZZZ", name: "Zoe", latitude: 39.30, longitude: -77.30)]

        let normalized = board.normalized(participants: roster, departed: [hassanID])

        XCTAssertEqual(normalized.options.map(\.name), ["Ledo Pizza"])
    }

    /// An unnamed participant decodes with `id == ""`. Excluding empty ids from
    /// the MATCHING keys must not also strip their vote — that made unanimity
    /// unreachable for their whole group.
    func testAnUnnamedParticipantKeepsTheirVote() {
        var board = MeetupPoll.empty
        board.pick(hunan(by: hassanID))
        board.vote("", for: hunan(by: hassanID).id)
        let roster = [Participant(id: "", name: "", latitude: 39.00, longitude: -77.50),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]

        let normalized = board.normalized(participants: roster, departed: [])

        XCTAssertEqual(normalized.votes[""], hunan(by: hassanID).id)
        XCTAssertNotNil(normalized.unanimousOption(participants: roster),
                        "both voted the same way — that is a settled meetup")
    }

    // MARK: - How the roster collapsed in the first place

    /// `pids` is POSITIONAL. One participant with an empty id (which is what an
    /// unnamed person decodes to) used to shorten the list, fail the count
    /// check, and silently drop the real ids for EVERYONE.
    func testPidsSurvivesAnEmptyID() {
        let roster = [Participant(id: "", name: "", latitude: 39.00, longitude: -77.50),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]
        let state = TweenState(text: "Hunan Village", latitude: 39.05, longitude: -77.48,
                               senderName: "Hassan", senderID: hassanID, kind: .place,
                               messageType: .pick, participants: roster, revision: 1)
        // `pj` is the first thing the 5000-char ladder drops, and `pids` exists
        // precisely to carry identity when it does.
        var components = URLComponents(url: state.encodedURL()!, resolvingAgainstBaseURL: false)!
        components.queryItems = components.queryItems!.filter { $0.name != "pj" }

        let decoded = TweenState(url: components.url!)

        XCTAssertEqual(decoded?.participants.map(\.id), ["", hassanID])
    }

    /// An EMPTY `pids=` must not downgrade the name-keys `p=` already gave us.
    /// `decodeAlignedNames("")` is `[""]`, which now PASSES the count check
    /// that `decodeNames`'s `[]` used to fail — so the guard has to be on the
    /// value, not the count.
    func testAnEmptyPidsDoesNotEraseANameKey() {
        let state = TweenState(text: "Hunan Village", latitude: 39.05, longitude: -77.48,
                               senderName: "Hassan", senderID: hassanID, kind: .place,
                               messageType: .pick,
                               participants: [Participant(id: "Saad", name: "Saad",
                                                          latitude: 39.00, longitude: -77.50)],
                               revision: 1)
        var components = URLComponents(url: state.encodedURL()!, resolvingAgainstBaseURL: false)!
        components.queryItems = components.queryItems!
            .filter { $0.name != "pj" }
            .map { $0.name == "pids" ? URLQueryItem(name: "pids", value: "") : $0 }

        let decoded = TweenState(url: components.url!)

        XCTAssertEqual(decoded?.participants.map(\.id), ["Saad"],
                       "an empty id is not an identity")
    }

    // MARK: - The panel disagreeing with itself

    /// "There's no sync — Friend and Saad": with `received` nil (every
    /// snapshot-restore path), the chips fell through to a synthetic
    /// `Participant(id: "peer", name: "Friend")` while the spot rows beside
    /// them were already labelled from the controller's real roster.
    func testChipsUseTheControllerRosterWhenNoBubbleIsSelected() {
        let roster = [Participant(id: saadID, name: "Saad", latitude: 39.00, longitude: -77.50),
                      Participant(id: hassanID, name: "Hassan", latitude: 39.10, longitude: -77.45)]
        let view = ExpandedView(received: nil,
                                selfCoord: CLLocationCoordinate2D(latitude: 39.10, longitude: -77.45),
                                rankedSpots: [],
                                isUserIn: true,
                                localParticipantID: hassanID,
                                rosterParticipants: roster,
                                onImIn: {},
                                onSelectSpot: { _ in })

        XCTAssertEqual(view.otherParticipants.map(\.name), ["Saad"],
                       "the chip must name the same person the ranked rows do")
    }

    // MARK: - The terminal-state predicate

    /// `ConversationMeetupStore.saveAgreed` stores on `isDecided`; the reader
    /// in `effectiveReceived` used to gate on `isFullyAgreed`, which is false
    /// for anything that isn't a legacy `.agree`. The two must agree, or the
    /// store keeps an agreement the restore refuses to show.
    func testAPollEraLockInReadsAsDecidedNotAsFullyAgreed() {
        let state = TweenState(text: "Hunan Village", latitude: 39.05, longitude: -77.48,
                               senderName: "Saad", senderID: saadID, kind: .place,
                               messageType: .decided,
                               participants: [Participant(id: saadID, name: "Saad",
                                                          latitude: 39.00, longitude: -77.50),
                                              Participant(id: hassanID, name: "Hassan",
                                                          latitude: 39.10, longitude: -77.45)],
                               poll: settledBoard(proposer: hassanID, voter: saadID))

        XCTAssertTrue(state.isDecided)
        XCTAssertFalse(state.isFullyAgreed,
                       "documents WHY the reader must not use isFullyAgreed here")
    }
}
