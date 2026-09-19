#if DEBUG
import SwiftUI
import CoreLocation
import MapKit

/// Edge-to-edge renders of the extension surfaces for App Store captures.
///
/// Why this exists alongside `HarnessShotView`:
///
///  * **The seed was the problem.** `DebugLaunchSeed` puts the two people in
///    San Francisco and San Jose — 45 miles apart — so every real search
///    returned 36-to-40-minute drives. The shipped screenshots therefore
///    argued AGAINST the product: the pitch is "a fair spot between you", and
///    the evidence on screen was an hour of driving. These two are a
///    believable meetup (Oakland ↔ Berkeley), where the fair spot really is
///    about twelve minutes each and the numbers sell the idea by themselves.
///  * **The set was stale.** It predates the vote board and "leaving now"
///    entirely — the two things that now make Tween different from a map.
///
/// Place names come from a REAL `MKLocalSearch` around the midpoint, exactly
/// as the app would find them. Nothing here is fabricated branding, and
/// MapKit search needs no location permission, so this works in a simulator
/// that has no CoreLocation at all.
///
/// Launch with `-SHOT <scene>`; see `ShotScene`.
struct ShotHarness: View {
    let scene: ShotScene

    @State private var spots: [RankedSpot] = []
    @State private var board = MeetupPoll.empty
    @State private var isRanking = true

    var body: some View {
        Group {
            switch scene {
            case .fair:
                expanded(received: ShotSeed.browsing, poll: .empty, marks: [], spots: spots)
            case .vote:
                expanded(received: votePick, poll: board, marks: [], spots: spots)
            case .plan:
                expanded(received: decidedState, poll: decidedBoard, marks: ShotSeed.enRoute, spots: [])
            case .compact:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CompactView(
                        received: votePick,
                        isUserIn: true,
                        localParticipantID: ShotSeed.myID,
                        currentParticipantCount: 2,
                        onImIn: {}, onExpand: {})
                        .frame(height: 300)
                }
            }
        }
        .task { await load() }
    }

    private func expanded(received: TweenState, poll: MeetupPoll,
                          marks: [EnRouteLog.Mark], spots: [RankedSpot]) -> some View {
        ExpandedView(
            received: received,
            selfCoord: ShotSeed.me,
            rankedSpots: spots,
            isUserIn: true,
            totalSeats: 2,
            isRanking: isRanking && spots.isEmpty && scene == .fair,
            localParticipantID: ShotSeed.myID,
            rosterParticipants: ShotSeed.roster,
            poll: poll,
            enRouteMarks: marks,
            onImIn: {}, onImOut: {}, onSelectSpot: { _ in },
            selectedSearchCategory: .coffee)
    }

    // MARK: - Derived states

    /// The bubble the vote scene is "looking at" — the friend's pick.
    private var votePick: TweenState {
        guard let option = board.option(proposedBy: ShotSeed.friendID) else {
            return ShotSeed.browsing
        }
        return TweenState(
            text: option.name, latitude: option.latitude, longitude: option.longitude,
            senderName: "Kavi", senderID: ShotSeed.friendID,
            kind: .place, senderCoordinate: ShotSeed.friend,
            messageType: .pick, participants: ShotSeed.roster, poll: board)
    }

    private var decidedBoard: MeetupPoll {
        guard let winner = board.option(proposedBy: ShotSeed.friendID) else { return board }
        var settled = board
        settled.vote(ShotSeed.myID, for: winner.id)
        settled.lockIn(winner.id)
        return settled
    }

    private var decidedState: TweenState {
        guard let winner = decidedBoard.decidedOption else { return ShotSeed.browsing }
        return TweenState(
            text: winner.name, latitude: winner.latitude, longitude: winner.longitude,
            senderName: "Kavi", senderID: ShotSeed.friendID,
            kind: .place, senderCoordinate: ShotSeed.friend,
            messageType: .decided, participants: ShotSeed.roster,
            agreedNames: ["You"], agreedIDs: [ShotSeed.myID],
            poll: decidedBoard)
    }

    // MARK: - Real ranking

    private func load() async {
        let participants = ShotSeed.roster
        let midpoint = MapGeometry.centroid(of: participants)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = OpenNowFilter.qualified("coffee shop", enabled: true)
        request.region = MKCoordinateRegion(center: midpoint,
                                            latitudinalMeters: 6_000,
                                            longitudinalMeters: 6_000)
        request.resultTypes = .pointOfInterest
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        let ranked = await FairnessRanker.rank(candidates: items, participants: participants, cap: 5)
        spots = ranked
        isRanking = false
        // Build the contested board from the two fairest REAL results, so the
        // vote scene shows the same places the fairness scene just ranked —
        // one story across the set instead of four unrelated captures.
        guard ranked.count >= 2 else { return }
        var built = MeetupPoll.empty
        if let first = ranked.first?.item {
            built.pick(PollOption(name: first.name ?? "Spot",
                                  coordinate: first.placemark.coordinate,
                                  proposerID: ShotSeed.friendID))
        }
        if let second = ranked.dropFirst().first?.item {
            built.pick(PollOption(name: second.name ?? "Spot",
                                  coordinate: second.placemark.coordinate,
                                  proposerID: ShotSeed.myID))
        }
        board = built
    }
}

/// Which surface to capture.
enum ShotScene: String, CaseIterable {
    /// Two people in, real spots ranked by everyone's drive time.
    case fair
    /// The disagreement, as a vote — the thing no other app does.
    case vote
    /// It's a plan, with a friend's live ETA underneath.
    case plan
    /// The compact strip, at keyboard height.
    case compact

    static var current: ShotScene? {
        guard let index = CommandLine.arguments.firstIndex(of: "-SHOT"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return ShotScene(rawValue: CommandLine.arguments[index + 1])
    }
}

/// Seed for store captures. Two neighbourhoods a real person might actually be
/// meeting across — see `ShotHarness` for why the old SF↔San Jose seed made
/// every screenshot undersell the app.
enum ShotSeed {
    static let myID = "shot-you"
    static let friendID = "shot-kavi"

    /// Downtown Oakland — "me".
    static let me = CLLocationCoordinate2D(latitude: 37.8044, longitude: -122.2712)
    /// Berkeley — the friend.
    static let friend = CLLocationCoordinate2D(latitude: 37.8715, longitude: -122.2730)

    static let roster = [
        Participant(id: myID, name: "You", coordinate: me),
        Participant(id: friendID, name: "Kavi", coordinate: friend)
    ]

    static let browsing = TweenState(
        text: "Kavi", latitude: friend.latitude, longitude: friend.longitude,
        senderName: "Kavi", senderID: friendID,
        kind: .participant, senderCoordinate: friend,
        messageType: .invite, participants: roster)

    static let enRoute = [
        EnRouteLog.Mark(participantID: friendID, name: "Kavi",
                        etaSeconds: 11 * 60, sentAt: Date().addingTimeInterval(-60))
    ]
}
#endif
