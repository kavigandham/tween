import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Incoming tween:// routing + external maps hand-off (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    /// Hands off to Google Maps: app scheme first (opens the app directly when
    /// installed), Google's universal `/maps/dir/` link otherwise (opens the
    /// app via universal link, or the web version — never a dead end).
    func openGoogleMapsExternally(name: String, coordinate: CLLocationCoordinate2D) {
        showToast("Opening Google Maps…")
        guard let appURL = MapLinks.googleMapsURL(name: name, coordinate: coordinate) else { return }
        UIApplication.shared.open(appURL) { opened in
            guard !opened,
                  let webURL = MapLinks.googleMapsWebURL(name: name, coordinate: coordinate) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(webURL)
            }
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.scheme == "tween", url.host == "search" {
            // Expand-then-focus per docs/ui-research.md §7 — SwiftUI drops the
            // first responder if the sheet is still animating between detents
            // when `searchFocused = true` fires.
            expandThenFocusSearch()
            return
        }
        // Google Maps handoff from the Messages extension (which cannot open
        // other apps itself — extensionContext.open only launches THIS app).
        // Pure trampoline: bounce straight out to Google Maps and touch no
        // meetup state, so Tween is only a hop, not a destination.
        if let handoff = MapLinks.decodeHandoff(url) {
            openGoogleMapsExternally(name: handoff.name, coordinate: handoff.coordinate)
            return
        }

        guard let state = TweenState(url: url) else { return }
        logger.debug("Host opened Tween URL type=\(state.messageType.rawValue, privacy: .public) kind=\(state.kind.rawValue, privacy: .public)")
        let myName = UserProfile.displayName ?? UserName.fallback
        let activeConversationKey = ConversationMeetupStore.lastActiveConversationKey
        let openedOwnProposal = state.kind == .place && state.senderName == myName
        // "I left this conversation's meetup" — the same tombstone the
        // projection gate reads. Direct peer writes below must respect it
        // too, or a departed user tapping a fresh bubble gets the peer pin
        // for one beat before the next refresh nils it (audit at 2b894b0).
        let departedHere = activeConversationKey
            .map { ConversationMeetupStore.localUserLeft(key: $0) } ?? false

        // Save the sender's coord as peer so the map can frame both pings.
        if !openedOwnProposal, !departedHere, let peer = state.participantCoordinate {
            LocationCache.savePeer(peer, isActive: true)
            peerCoordinate = peer
            logger.debug("Host saved peer from URL lat=\(peer.latitude, privacy: .public) lon=\(peer.longitude, privacy: .public)")
        }
        // Roster adoption mirrors the extension's decode path — revision
        // guard, self-tombstone filter, and MERGE instead of verbatim
        // replace. This URL path used to bypass all three, so opening an old
        // link resurrected a stale roster (including this user after they'd
        // left). A `.leave` message may intentionally carry an empty roster.
        var adoptRoster = true
        if let revision = state.revision, let activeConversationKey {
            // Pass messageType so a concurrent .invite opened via the host
            // tween:// path unions too — host/extension must agree on the
            // same payload (parity with decodeAndCache).
            adoptRoster = ConversationMeetupStore.shouldAcceptInbound(
                revision: revision, senderID: state.senderID,
                messageType: state.messageType, key: activeConversationKey)
            if adoptRoster {
                ConversationMeetupStore.noteRevision(
                    revision, sender: state.senderID, key: activeConversationKey)
            }
        }
        if adoptRoster, !state.participants.isEmpty || state.messageType == .leave {
            let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
            let senderKeys = RosterMerge.senderKeys(senderID: state.senderID, senderName: state.senderName)
            if let activeConversationKey {
                // Absorb gossiped departures — minus the local user, whose
                // presence is governed solely by localUserLeft.
                let myKeys: Set<String> = [TweenIdentity.stableID, myName]
                ConversationMeetupStore.noteDeparted(state.departed.filter { !myKeys.contains($0) },
                                                     key: activeConversationKey)
                if state.messageType == .leave {
                    ConversationMeetupStore.noteDeparted(senderKeys, key: activeConversationKey)
                } else {
                    ConversationMeetupStore.clearDeparted(senderKeys, key: activeConversationKey)
                }
            }
            var incoming = state.participants
            if departedHere {
                incoming.removeAll { $0.matches(localContext) }
            }
            let departed = activeConversationKey
                .map { ConversationMeetupStore.departedParticipants(key: $0) } ?? []
            // Scoped-first merge base (parity with the extension's decode):
            // post-leave the global blob is deliberately empty, and merging
            // against [] would collapse the D4 rejoin roster to one sender's
            // partial view (audit at 69a3886).
            let merged = RosterMerge.merge(
                local: scopedFirstRoster(),
                incoming: incoming,
                messageType: state.messageType,
                senderKeys: senderKeys,
                departed: departed)
            // Post-leave, the merged roster stays SCOPED-only: writing it to
            // the un-TTL'd global mirrors would restock exactly the blob the
            // hour-24 resurrection fires from (audit at 18c182a).
            if !departedHere {
                LocationCache.saveParticipantSnapshot(merged, localContext: localContext)
            }
            if let activeConversationKey {
                ConversationMeetupStore.saveParticipants(merged, key: activeConversationKey)
            }
            if !departedHere, let firstRemote = merged.first(where: { !$0.matches(localContext) }) {
                peerCoordinate = firstRemote.coordinate
            } else {
                peerCoordinate = nil
            }
        }
        // Only stamp the inbound-reply timestamp for ACTUAL replies — invites,
        // proposals, and agrees from a peer. Plain `tween://search` deep links
        // (handled above), self-opened URLs, and STALE payloads the revision
        // guard rejected (audit at 69a3886) shouldn't inflate the banner.
        if !openedOwnProposal && adoptRoster
            && (state.kind == .participant || state.messageType == .agree || state.messageType == .leave) {
            PingLog.lastIncomingReplyAt = Date()
            lastReplyAt = PingLog.lastIncomingReplyAt
        }

        switch state.messageType {
        case .propose, .counter:
            if openedOwnProposal {
                if state.messageType == .counter {
                    LocationCache.clearAgreedMeetup()
                    agreedMeetup = nil
                }
                if let activeConversationKey {
                    ConversationMeetupStore.saveProposed(state, key: activeConversationKey)
                }
                showOwnProposalOnMap(state)
                return
            }
            if state.messageType == .counter {
                LocationCache.clearAgreedMeetup()
                agreedMeetup = nil
            }
            if let activeConversationKey {
                ConversationMeetupStore.saveProposed(state, key: activeConversationKey)
            }
            // A friend has suggested a place — open the SpotDetailCard in
            // incoming mode so the user sees Agree / Change buttons rather
            // than the search-result CTA. Build a synthetic MKMapItem to
            // reuse the existing .spot sheet plumbing.
            let placemark = MKPlacemark(coordinate: state.coordinate)
            let item = MKMapItem(placemark: placemark)
            item.name = state.text
            let selection = SpotSelection(
                item: item,
                ranked: nil,  // no ETA chip until we re-rank against fresh self
                incoming: IncomingProposalContext(
                    senderName: state.senderName,
                    senderID: state.senderID,
                    participants: state.participants,
                    agreedNames: state.agreedNames,
                    agreedIDs: state.agreedIDs,
                    isCounter: state.messageType == .counter))
            presentSpot(selection)
            // Frame the map so the user can see the proposed spot in context.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: state.coordinate)
            }

        case .agree:
            if state.isFullyAgreed {
                LocationCache.saveAgreedMeetup(state)
                if let activeConversationKey {
                    ConversationMeetupStore.saveAgreed(state, key: activeConversationKey)
                }
                agreedMeetup = state
                recentSpots = SpotLibrary.recordRecent(storedSpot(for: selection(for: state)))
                selectedResult = nil
                // URL-presented proposal sheets carry no selection, so the
                // deselect above can't close them — dismiss explicitly or
                // the user keeps reading an Agree/Change card for a
                // negotiation that just finished (audit at bb6740d).
                if case .spot(let sel) = activeSheet, sel.incoming != nil {
                    activeSheet = nil
                }
            }
            // A friend's reply that they agree to a previously-proposed spot.
            // No interactive UI needed — just frame the map on it and toast.
            withAnimation(Tokens.Motion.gentle) {
                position = Self.placeCameraPosition(for: state.coordinate)
            }
            let who = state.senderName ?? "Your friend"
            showToast(state.isFullyAgreed
                      ? "Meeting at \(state.text) — \(who) is in."
                      : "\(who) agreed to \(state.text).")

        case .invite:
            // Bare participant invite — the legacy "I'm in" case. Cache and
            // reframe; the user sees the friend's pin and decides what to
            // do (tap I'm in themselves, search a spot, etc).
            reframe()

        case .leave:
            // Gated on the revision guard: a STALE leave URL (its sender may
            // have since rejoined) must not tear down a newer agreement or
            // roster the floor exists to protect. The MERGED roster saved
            // above (departure-filtered by RosterMerge) is authoritative —
            // the payload's verbatim roster never overwrites it (audit at
            // 18c182a).
            guard adoptRoster else { break }
            if state.participants.isEmpty {
                LocationCache.clearAgreedMeetup()
                if let activeConversationKey {
                    ConversationMeetupStore.clearProposalState(key: activeConversationKey)
                }
                agreedMeetup = nil
                pendingProposal = nil
            }
            // A proposal card from someone who just left is dead — dismiss
            // it rather than leaving it orphaned over the departure toast.
            if case .spot(let sel) = activeSheet, sel.incoming != nil {
                activeSheet = nil
            }
            reframe()
            let who = state.senderName ?? "Your friend"
            showToast("\(who) is out.")
        }
    }

    func showOwnProposalOnMap(_ state: TweenState) {
        pendingProposal = state
        selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight)
        let placemark = MKPlacemark(coordinate: state.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = state.text
        // Waiting-pin selection, NOT a browse tap: latch the one-tap
        // presentation off or the sheet the user just sent from re-presents
        // over the waiting toast (audit at bb6740d).
        if selectedResult != item { suppressNextSelectionPresentation = true }
        selectedResult = item
        activeSheet = nil
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: state.coordinate)
        }
        showToast("Waiting for them to agree to \(state.text).")
    }

    /// Sends an agree-bubble back to a friend after they proposed a place
    /// via `tween://` link. Uses the same MFMessageComposeViewController +
    /// MSMessage plumbing as the rich-bubble ping (Slice B), but with an
    /// `.agree` TweenState containing the local user appended to agreedNames.
    func sendAgreeReply(for selection: SpotSelection,
                                 incoming: IncomingProposalContext) {
        guard MFMessageComposeViewController.canSendText() else {
            UIPasteboard.general.string = "I'm in for \(selection.name)"
            showToast("Messages unavailable - copied a reply for you")
            return
        }
        // Synthesise the agree state. Append my name to agreedNames if not
        // already present; the bubble's `isFullyAgreed` flag fires on the
        // receiver's side once everyone-but-the-proposer is in.
        let myName = UserProfile.displayName ?? UserName.fallback
        let myID = TweenIdentity.stableID
        var agreed = incoming.agreedNames
        if !agreed.contains(myName) { agreed.append(myName) }
        // Same namespace rule as the extension (T6/T7): a legacy proposal
        // (no senderID) stays name-namespaced end to end — mixing UUID
        // agreedIDs with name-ids makes consensus unreachable.
        var agreedIDs: [String]
        if incoming.senderID != nil {
            agreedIDs = incoming.agreedIDs
            if !agreedIDs.contains(myID) { agreedIDs.append(myID) }
        } else {
            agreedIDs = []
        }
        guard autoJoinForOutgoingMessage() else {
            // Same parking pattern as sendToChat: the user already said yes —
            // resume the agreement once the fix lands instead of dropping it.
            pendingLocationAction = { sendAgreeReply(for: selection, incoming: incoming) }
            provider.requestOnce()
            showToast("Getting your location — agreeing right after")
            return
        }
        // Fresh-only (audit W4). autoJoin above only returns true after
        // caching a current fix, so this is non-nil here — but reading the
        // fresh accessor (not raw loadSelf) keeps a stale coord from ever
        // entering the agreement roster if that invariant changes.
        let mySelf = freshSelfCoordinateForSend
        var participants = incoming.participants.filter { !$0.matches(LocalParticipantContext(id: myID, name: myName)) }
        if let mySelf {
            participants.append(Participant(id: myID, name: myName, coordinate: mySelf, needsRide: localNeedsRide))
        }

        let revision = nextOutgoingRevisionForActiveConversation()
        let state = TweenState(
            text: selection.name,
            latitude: selection.coordinate.latitude,
            longitude: selection.coordinate.longitude,
            senderName: incoming.senderName ?? UserProfile.displayName,
            senderID: incoming.senderID,
            kind: .place,
            senderCoordinate: mySelf,
            action: .agree,
            messageType: .agree,
            participants: participants,
            agreedNames: agreed,
            agreedIDs: agreedIDs,
            revision: revision
        )

        // Async render the bubble image, then present the composer. The
        // recipient field is left empty so the user picks the same friend
        // they got the link from. The agreement is committed in onSent ONLY:
        // committing before the composer meant a cancelled send still
        // rendered MEETUP SET here for an agreement the peer never received
        // (the extension has always gated these commits on didSend).
        Task { @MainActor in
            guard let message = await composeTweenMessage(
                for: state, totalSeats: state.participants.count) else { return }
            activeSheet = .message(PendingMessage(
                recipients: [],
                body: Self.spotBody(prefix: "I'm in —", name: selection.name, coordinate: selection.coordinate),
                message: message,
                onSent: {
                    noteOutgoingRevision(revision)
                    if let key = ConversationMeetupStore.lastActiveConversationKey {
                        if state.isFullyAgreed {
                            ConversationMeetupStore.saveAgreed(state, key: key)
                        } else {
                            ConversationMeetupStore.saveProposed(state, key: key)
                        }
                    }
                    _ = refreshFromAppGroup()
                },
                onCancelled: {
                    showToast("Not sent — friends still see the old plan")
                }))
        }
    }

    /// Lifts the bottom sheet and focuses the search bar so the user can
    /// pick a different spot than the one their friend proposed. Drops a
    /// pin on the rejected spot so they have spatial context.
    func startChangeFlow(initialCoord: CLLocationCoordinate2D) {
        // Expand-then-focus per docs/ui-research.md §7. The camera nudge runs
        // in parallel with the sheet animation; SwiftUI schedules them on the
        // same tick so the map reframes as the sheet lifts.
        expandThenFocusSearch()
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: initialCoord, bottomBias: 0.12)
        }
    }

    func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (.none, .none):
            return true
        case let (.some(a), .some(b)):
            return a.latitude == b.latitude && a.longitude == b.longitude
        default:
            return false
        }
    }
}
