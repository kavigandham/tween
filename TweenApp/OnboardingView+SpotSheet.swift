import SwiftUI
import CoreLocation

// The spot-detail sheet and its CHILD sheets, split out of OnboardingView's
// `.sheet(item: $activeSheet)` switch.
//
// Two reasons this lives in its own file:
//
// 1. Correctness. A child sheet must be presented BY the spot sheet, not by
//    swapping `activeSheet` from inside it — that swap is a dismiss-then-
//    re-present which silently drops on iOS 26 (the dead-button bug this
//    repo already documents for the Friends panel). Keeping the child's
//    `.sheet(item:)` attached to the card here makes that structural.
//
// 2. Compilation. With the child-sheet modifier attached inline, the switch's
//    single expression exceeded the type-checker's time limit and the error
//    surfaced way off in the Friends branch. A function boundary fixes it.
extension OnboardingView {
    /// Sheets the SPOT DETAIL sheet presents as its own children. Same rule as
    /// `FriendsSubSheet`: never swap `activeSheet` while a sheet is up.
    enum SpotSubSheet: Identifiable {
        /// Pro: schedule the meetup, set per-person travel modes, and hang a
        /// leave-by reminder / calendar event off it.
        case plan(SpotSelection)
        /// Shown when a locked user taps the Pro "Plan" affordance. Routed here
        /// rather than through `friendsSubSheet`: that modifier is attached
        /// inside the `.friends` branch, so setting it from the spot card
        /// presented NOTHING and left the paywall armed to ambush the Friends
        /// panel later (audit 2026-08-02).
        case paywall

        var id: String {
            switch self {
            case .plan(let s): return "plan-\(s.id)"
            case .paywall:     return "spot-paywall"
            }
        }
    }

    @ViewBuilder
    func spotDetailSheet(_ selection: SpotSelection) -> some View {
        SpotDetailCard(
            name: selection.name,
            address: selection.address,
            coordinate: selection.coordinate,
            ranked: selection.ranked,
            mapItem: selection.item,
            selfCoordinate: savedCoordinate,
            incoming: selection.incoming.map {
                SpotDetailCard.IncomingProposal(
                    senderName: $0.senderName,
                    isCounter: $0.isCounter)
            },
            isCurrentMeetup: isCurrentMeetup(selection),
            isFavorite: isFavorite(selection),
            onToggleFavorite: { toggleFavorite(selection) },
            onSendToChat: { sendToChat(selection) },
            onAgree: {
                if let incoming = selection.incoming {
                    sendAgreeReply(for: selection, incoming: incoming)
                }
            },
            onChange: { startChangeFlow(initialCoord: selection.coordinate) },
            onPlan: {
                spotSubSheet = ProEntitlement.isUnlocked ? .plan(selection) : .paywall
            },
            onSetTravelMode: { setLocalTravelMode($0) },
            // Scoped to THIS spot: the flag used to be global, so every card in
            // the list read "Planned" once anything was scheduled.
            planIsSet: MeetupPlanStore.isScheduled(for: selection.name)
        )
        .sheet(item: $spotSubSheet) { sub in
            spotSubSheetContent(sub)
        }
    }

    /// Extracted from the friends sub-sheet switch: passing the search region
    /// and place resolver through (so a member's address can be set without
    /// leaving the group) pushed that expression past the type-checker's limit.
    @ViewBuilder
    func groupEditorSheet(_ group: FriendGroup?,
                          draftMemberIDs: [UUID] = []) -> some View {
        GroupEditorSheet(
            group: group,
            draftMemberIDs: draftMemberIDs,
            friends: friends,
            onSave: { saved in
                GroupStore.upsert(saved)
                groups = GroupStore.load()
                // Reload the ROSTER too. Addresses set inside the editor are
                // written straight to FriendRoster, and without this the
                // parent kept its pre-edit copy — so openGroup still saw
                // `homeBase == nil` and refused with "no home bases yet",
                // telling the user to do the thing they had just done. The
                // path this replaced did reload; dropping that line made the
                // whole feature inert (audit 2026-08-04).
                friends = FriendRoster.load()
                pendingGroupFriends.commit()
                friendsSubSheet = nil
            },
            onDelete: { id in
                GroupStore.delete(id: id)
                groups = GroupStore.load()
                friendsSubSheet = nil
            },
            onCancel: {
                // Backing out undoes friends this flow created — INCLUDING any
                // address set on them, because the friend row itself goes. (An
                // earlier comment here claimed addresses survived; they don't,
                // and saying so was simply wrong. Addresses on PRE-EXISTING
                // friends do survive, since those rows are untouched.)
                // The real rollback lives in the sheet's onDismiss so a swipe
                // is covered too; this just closes.
                friendsSubSheet = nil
            },
            onRosterChanged: { friends = FriendRoster.load() },
            searchRegion: searchRegion,
            resolvePlace: resolvePlace)
    }

    @ViewBuilder
    func spotSubSheetContent(_ sub: SpotSubSheet) -> some View {
        switch sub {
        case .plan(let selection):
            // Prefer the LIVE ranking over `selection.ranked`, which is frozen
            // at present-time and never refreshed. Without this, changing your
            // mode to walking and saving re-ranks the list but the reminder
            // still arms off the stale driving ETA — and a deep-linked proposal
            // (which arrives with `ranked: nil`) could never arm one at all
            // (audit 2026-08-02).
            // Same 0.0002° tolerance `isCurrentMeetup` uses to identify a spot.
            let live = rankedSpots.first { spot in
                guard let c = spot.item?.placemark.coordinate else { return false }
                return abs(c.latitude - selection.coordinate.latitude) < 0.0002
                    && abs(c.longitude - selection.coordinate.longitude) < 0.0002
            }
            let myETA: TimeInterval? = (live ?? selection.ranked)?.etas
                .first { $0.id == TweenIdentity.stableID }?.eta
            // The SAME roster the ranker uses, so the ids a travel mode is
            // keyed by are the ids FairnessRanker looks it up with. Handing the
            // sheet a different id namespace was why per-person modes silently
            // did nothing (audit 2026-08-02).
            let roster: [Participant] = searchRankingParticipants ?? currentParticipants
            PlanMeetupSheet(
                spotName: selection.name,
                coordinate: selection.coordinate,
                myTravelTime: myETA,
                participants: roster,
                localParticipantID: TweenIdentity.stableID,
                // Re-rank immediately: arrival time and travel modes only feed
                // the ranker at rank time, so without this a saved plan left
                // the list unchanged and looked broken. Routed through
                // `searchTask` so repeated saves supersede rather than race.
                onSaved: { rerankAfterPlanChange() })
        case .paywall:
            PaywallSheet()
        }
    }
}
