#if DEBUG
import SwiftUI
import CoreLocation
import MapKit

/// A DEBUG-only screenshot harness for the Messages extension surfaces.
///
/// The extension's `CompactView` and `ExpandedView` live behind
/// `MSMessagesAppViewController`, which can't be hosted in a XCUITest target.
/// This view renders both inside the host app with seeded coordinates (SF + San
/// Jose) and a sample ranking, so a collaborator can launch the app with the
/// `-HARNESS` argument and screenshot-verify the extension UI on a real device.
///
/// Reached only from `ContentView` when `-HARNESS` is present, and the whole
/// file is excluded from release builds by the surrounding `#if DEBUG`.
struct HarnessView: View {
    var focus: HarnessFocus = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s5) {
                if focus == .all {
                    section("Compact View") {
                        CompactView(
                            received: nil,
                            isUserIn: false,
                            onImIn: {},
                            onExpand: {}
                        )
                        .frame(height: 230)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }

                    section("Compact Location View") {
                        CompactView(
                            received: DebugLaunchSeed.received,
                            isUserIn: true,
                            onImIn: {},
                            onImOut: {},
                            onExpand: {}
                        )
                        .frame(height: 300)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }

                    section("Expanded View") {
                        ExpandedView(
                            received: DebugLaunchSeed.received,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: DebugLaunchSeed.rankedSpots,
                            isUserIn: true,
                            onImIn: {},
                            onSelectSpot: { _ in }
                        )
                        .frame(height: 520)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.invite) {
                    section("Invite Prompt View") {
                        ExpandedView(
                            received: DebugLaunchSeed.invite,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: [],
                            isUserIn: false,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onOpenFullApp: {}
                        )
                        .frame(height: 620)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.meetup) {
                    section("Meetup Set View") {
                        ExpandedView(
                            received: DebugLaunchSeed.agreed,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: [],
                            isUserIn: true,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onOpenFullApp: {},
                            onOpenInMaps: { _ in }
                        )
                        .frame(height: 620)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.proposalDraft) {
                    section("Proposal With Draft View") {
                        ExpandedView(
                            received: DebugLaunchSeed.incomingProposal,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: DebugLaunchSeed.rankedSpots,
                            isUserIn: true,
                            draft: DebugLaunchSeed.draft,
                            localParticipantID: DebugLaunchSeed.localParticipantID,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onAgreePlace: { _ in },
                            onSendDraft: {},
                            onOpenFullApp: {}
                        )
                        .frame(height: 760)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.ownProposal) {
                    section("Own Proposal View") {
                        ExpandedView(
                            received: DebugLaunchSeed.ownProposal,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: DebugLaunchSeed.rankedSpots,
                            isUserIn: true,
                            localParticipantID: DebugLaunchSeed.localParticipantID,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onAgreePlace: { _ in },
                            onOpenFullApp: {}
                        )
                        .frame(height: 760)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.soloWaiting) {
                    section("Solo Waiting View") {
                        ExpandedView(
                            received: nil,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: [],
                            isUserIn: true,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onOpenFullApp: {}
                        )
                        .frame(height: 760)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }

                if focus.includes(.twoReadyNoResults) {
                    section("Two Ready No Results View") {
                        ExpandedView(
                            received: DebugLaunchSeed.invite,
                            selfCoord: DebugLaunchSeed.selfCoordinate,
                            rankedSpots: [],
                            isUserIn: true,
                            totalSeats: 2,
                            isRanking: false,
                            onImIn: {},
                            onImOut: {},
                            onSelectSpot: { _ in },
                            onOpenFullApp: {}
                        )
                        .frame(height: 760)
                        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                    }
                }
            }
            .padding(Tokens.Spacing.s4)
        }
        .background(Tokens.Palette.surfaceSecondary)
    }

    /// A labeled card. The label text is what `TweenAppUITests` waits on.
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s2) {
            Text(title)
                .font(Tokens.Typography.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

enum HarnessFocus: Equatable {
    case all
    case invite
    case meetup
    case proposalDraft
    case ownProposal
    case soloWaiting
    case twoReadyNoResults

    static var current: HarnessFocus {
        if CommandLine.arguments.contains("-HARNESS_INVITE") { return .invite }
        if CommandLine.arguments.contains("-HARNESS_MEETUP") { return .meetup }
        if CommandLine.arguments.contains("-HARNESS_PROPOSAL_DRAFT") { return .proposalDraft }
        if CommandLine.arguments.contains("-HARNESS_OWN_PROPOSAL") { return .ownProposal }
        if CommandLine.arguments.contains("-HARNESS_SOLO_WAITING") { return .soloWaiting }
        if CommandLine.arguments.contains("-HARNESS_TWO_READY_NO_RESULTS") { return .twoReadyNoResults }
        return .all
    }

    func includes(_ focus: HarnessFocus) -> Bool {
        self == .all || self == focus
    }
}

/// Chrome-free, full-screen renders of the extension surfaces, for App Store
/// screenshots.
///
/// `HarnessView` wraps each surface in a labelled section at a fixed height —
/// fine for eyeballing a layout, useless as a screenshot: the captures it
/// produced carried a debug title bar, and `DebugLaunchSeed.rankedSpots` passes
/// `item: nil`, so every row rendered as the literal word "Spot".
///
/// This renders ONE surface edge to edge, exactly as Messages presents it, and
/// the ranking is REAL — a live `MKLocalSearch` around the midpoint of the two
/// seeded participants, ranked by the shipping `FairnessRanker`. Real place
/// names, real drive times, both people's minutes.
struct HarnessShotView: View {
    var focus: HarnessFocus = .all
    var category: MessagesSearchCategory = .coffee

    @State private var spots: [RankedSpot] = []
    @State private var isRanking = true

    private var state: TweenState {
        switch focus {
        case .meetup: return DebugLaunchSeed.agreed
        case .invite:  return DebugLaunchSeed.invite
        default:       return DebugLaunchSeed.browsing
        }
    }

    var body: some View {
        ExpandedView(
            received: state,
            selfCoord: DebugLaunchSeed.selfCoordinate,
            rankedSpots: spots,
            isUserIn: true,
            totalSeats: 2,
            isRanking: isRanking,
            localParticipantID: DebugLaunchSeed.localParticipantID,
            onImIn: {},
            onSelectSpot: { _ in },
            selectedSearchCategory: category)
            .task { await rank() }
    }

    private func rank() async {
        let participants = state.participants.isEmpty
            ? DebugLaunchSeed.browsing.participants
            : state.participants
        let midpoint = CLLocationCoordinate2D(
            latitude: participants.map(\.latitude).reduce(0, +) / Double(participants.count),
            longitude: participants.map(\.longitude).reduce(0, +) / Double(participants.count))

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.mapKitQuery
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.poiCategories)
        request.region = MKCoordinateRegion(center: midpoint,
                                            latitudinalMeters: 12_000,
                                            longitudinalMeters: 12_000)
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        spots = await FairnessRanker.rank(candidates: items, participants: participants, cap: 5)
        isRanking = false
    }
}

/// Hardcoded fixtures that drive the harness. Kept separate from the view so the
/// seed is easy to reuse and obviously test-only. DEBUG builds only.
enum DebugLaunchSeed {
    static let localParticipantID = "local-user"
    /// Downtown San Francisco — stands in for the friend's shared spot.
    static let friendCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    /// San Jose — stands in for our own shared location.
    static let selfCoordinate = CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863)

    static let received = TweenState(
        text: "Blue Bottle Coffee",
        latitude: friendCoordinate.latitude,
        longitude: friendCoordinate.longitude
    )

    static let invite = TweenState(
        text: "Kavi Gandham wants to meet",
        latitude: friendCoordinate.latitude,
        longitude: friendCoordinate.longitude,
        senderName: "Kavi Gandham",
        kind: .participant,
        senderCoordinate: friendCoordinate,
        messageType: .invite,
        participants: [
            Participant(id: "Kavi", name: "Kavi Gandham", coordinate: friendCoordinate),
            Participant(id: "You", name: "You", coordinate: selfCoordinate)
        ]
    )

    /// Both people in, browsing spots — the state the ranked list renders in.
    /// Coordinates are the two seeds below, so a real search around their
    /// midpoint returns places that are genuinely between them.
    static let browsing = TweenState(
        text: "Finding fair spots",
        latitude: friendCoordinate.latitude,
        longitude: friendCoordinate.longitude,
        senderName: "Kavi Gandham",
        senderID: "remote-kavi",
        kind: .participant,
        senderCoordinate: friendCoordinate,
        messageType: .invite,
        participants: [
            Participant(id: "remote-kavi", name: "Kavi", coordinate: friendCoordinate),
            Participant(id: localParticipantID, name: "You", coordinate: selfCoordinate)
        ]
    )

    // Palo Alto — BETWEEN the two seeds. It used to sit in South Carolina while
    // both participants were in California, which forced the snapshot map to
    // frame the continental US and made every capture unusable.
    static let agreed = TweenState(
        text: "Philz Coffee",
        latitude: 37.4419,
        longitude: -122.1430,
        senderName: "You",
        kind: .place,
        senderCoordinate: selfCoordinate,
        action: .agree,
        messageType: .agree,
        participants: [
            Participant(id: "You", name: "You", coordinate: selfCoordinate),
            Participant(id: "Friend", name: "Friend", coordinate: friendCoordinate)
        ],
        agreedNames: ["Friend"]
    )

    static let incomingProposal = TweenState(
        text: "Hangry Joe's Hot Chicken",
        latitude: 32.0810,
        longitude: -81.1007,
        senderName: "Hassan",
        senderID: "remote-hassan",
        kind: .place,
        senderCoordinate: friendCoordinate,
        action: .invite,
        messageType: .propose,
        participants: [
            Participant(id: "remote-hassan", name: "Hassan", coordinate: friendCoordinate),
            Participant(id: localParticipantID, name: "Kavi Gandham", coordinate: selfCoordinate)
        ]
    )

    static let ownProposal = TweenState(
        text: "Barnes & Noble",
        latitude: 39.0438,
        longitude: -77.4874,
        senderName: "Hassan",
        senderID: localParticipantID,
        kind: .place,
        senderCoordinate: selfCoordinate,
        action: .invite,
        messageType: .propose,
        participants: [
            Participant(id: localParticipantID, name: "Hassan", coordinate: selfCoordinate),
            Participant(id: "remote-ashraf", name: "Ashraf Ullah", coordinate: friendCoordinate)
        ]
    )

    static let draft = OutgoingDraft(
        spotName: "McDonald's",
        latitude: 32.0854,
        longitude: -81.0912
    )

    static let rankedSpots: [RankedSpot] = [
        RankedSpot(item: nil, etas: [
            ParticipantETA(id: "you", name: "You", eta: 1_260, fromRoute: true),
            ParticipantETA(id: "hassan", name: "Hassan", eta: 1_380, fromRoute: true),
            ParticipantETA(id: "kavi", name: "Kavi", eta: 1_500, fromRoute: true),
            ParticipantETA(id: "khanna", name: "Khanna", eta: 1_620, fromRoute: true)
        ], confidence: 1.0),
        RankedSpot(item: nil, etas: [
            ParticipantETA(id: "you", name: "You", eta: 900, fromRoute: true),
            ParticipantETA(id: "hassan", name: "Hassan", eta: 1_320, fromRoute: true),
            ParticipantETA(id: "kavi", name: "Kavi", eta: 1_860, fromRoute: true),
            ParticipantETA(id: "khanna", name: "Khanna", eta: 2_160, fromRoute: true)
        ], confidence: 1.0),
        RankedSpot(item: nil, etas: [
            ParticipantETA(id: "you", name: "You", eta: 780, fromRoute: false),
            ParticipantETA(id: "hassan", name: "Hassan", eta: 1_020, fromRoute: false),
            ParticipantETA(id: "kavi", name: "Kavi", eta: 1_980, fromRoute: false),
            ParticipantETA(id: "khanna", name: "Khanna", eta: 2_520, fromRoute: false)
        ], confidence: 0.5)
    ]
}

#Preview {
    HarnessView()
}
#endif
