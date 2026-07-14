import SwiftUI
import MapKit
import CoreLocation
import MessageUI
import Messages
import UIKit
import Combine
import os

// Send-to-chat + compose hand-off (split from OnboardingView.swift — structure plan R2).
extension OnboardingView {
    // MARK: - Hand-off

    /// Centers the map on a tapped result and sizes the sheet to the spot card
    /// (which now renders AS the sheet). The camera is biased so the pin clears
    /// the taller card; the reset-map control can still pull back to the route.
    func focusMap(on item: MKMapItem) {
        withAnimation(Tokens.Motion.gentle) {
            position = Self.placeCameraPosition(for: item.placemark.coordinate, bottomBias: 0.18)
        }
        withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .height(Tokens.Layout.sheetPeekHeight) }
    }

    /// Frames the camera to fit the top result pins (Map mode). Capped like
    /// frameSearchResults: displayedItems now carries vicinity-cut leftovers
    /// below the ranked spots, and fitting a far unranked hit would zoom the
    /// camera out to state scale after every ranked search (post-push verify).
    func frameResults() {
        let coords = displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate)
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) { position = Self.cameraPosition(for: coords, padding: 1.35) }
    }

    /// Frames the social context plus the visible search hits, so the result list
    /// and map feel connected as soon as a live search returns.
    func frameSearchResults() {
        let resultCoords = displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate)
        let context = [savedCoordinate, peerCoordinate].compactMap { $0 } + manualParticipants.map(\.coordinate)
        let coords = context + resultCoords
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, padding: 1.45, minSpan: 0.04)
        }
    }

    func expandToSearchDetent() {
        guard isMinimalDetent else { return }
        withAnimation(Tokens.Motion.snappy) { selectedSheetDetent = .fraction(0.45) }
    }

    /// Expand-then-focus (`docs/ui-research.md` §7): first drive the sheet
    /// to the search detent, then wait for the sheet's detent animation to
    /// finish before setting `@FocusState`. SwiftUI drops the first responder
    /// if a sheet is still animating between detents when focus is requested,
    /// so setting both in the same synchronous block silently no-ops.
    ///
    /// `Tokens.Motion.snappy` is a 400 ms `.easeInOut` (see
    /// `Shared/Tokens.swift:148`), so we wait 450 ms — a small margin past
    /// the animation's end. The pending focus task is retained on `self` so
    /// a rapid re-entry cancels the prior one; otherwise a user who backs
    /// out of the sheet between call and fire would get an unexpected
    /// keyboard.
    func expandThenFocusSearch() {
        withAnimation(Tokens.Motion.snappy) {
            selectedSheetDetent = .fraction(0.45)
        }
        focusExpandTask?.cancel()
        focusExpandTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450 * 1_000_000)
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
    }

    /// Frames every result pin PLUS self and peer, biased upward so the pins
    /// clear the bottom sheet. Called on every committed search (both view
    /// modes) so the map is correctly positioned the instant the sheet is
    /// lowered — in list mode the sheet snaps to full and covers most of the
    /// map, so this framing is what the user sees the moment they drag down or
    /// tap a result card.
    func frameResultsWithParticipants() {
        // Same rankCap prefix as the other framers — far unranked leftovers
        // stay in the LIST but must not drive the camera (post-push verify).
        var coords = displayedItems.prefix(Self.rankCap).map(\.placemark.coordinate)
        if let me = savedCoordinate { coords.append(me) }
        if let peer = peerCoordinate { coords.append(peer) }
        coords.append(contentsOf: manualParticipants.map(\.coordinate))
        guard !coords.isEmpty else { return }
        withAnimation(Tokens.Motion.gentle) {
            position = Self.cameraPosition(for: coords, bottomBias: 0.35)
        }
    }

    /// Composes a pre-filled iMessage for the chosen spot: a short blurb plus the
    /// `TweenState` deep link the friend's extension decodes. The old `sms:` bounce
    /// opened a blank composer, so the friend received nothing.
    func sendToChat(_ selection: SpotSelection) {
        ensureNamed {
            guard autoJoinForOutgoingMessage() else {
                // Park the send and resume it the moment the fix arrives —
                // discarding the tap made "Send to chat" feel broken.
                pendingLocationAction = { sendToChat(selection) }
                provider.requestOnce()
                showToast("Getting your location — sending right after")
                return
            }
            let coord = selection.coordinate
            let participants = proposalParticipantsForCurrentContext()
            guard !participants.isEmpty else {
                showToast("Tap I'm in first so your friend has a way to join")
                return
            }
            let revision = nextOutgoingRevisionForActiveConversation()
            let messageType: TweenState.MessageType = agreedMeetup == nil ? .propose : .counter
            let state = TweenState(
                text: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                senderName: UserProfile.displayName,
                senderID: TweenIdentity.stableID,
                kind: .place,
                senderCoordinate: savedCoordinate,        // set by ensureNamed
                messageType: messageType,
                participants: participants,
                revision: revision)
            guard let appURL = state.encodedURL(scheme: "tween", host: "m") else { return }

            // Still stage the draft so the sender's own extension can pre-fill if
            // they open Tween in the drawer (device-local; not how the friend gets
            // it). Bound to the last-active conversation so no other chat adopts it.
            OutgoingDraftStore.save(OutgoingDraft(
                spotName: selection.name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                conversationKey: ConversationMeetupStore.lastActiveConversationKey))

            if MFMessageComposeViewController.canSendText() {
                Task { @MainActor in
                    guard let message = await composeTweenMessage(
                        for: state, totalSeats: max(participants.count, 2)) else { return }
                    // Route through the existing enum-driven sheet; empty recipients so
                    // the user picks who in Messages (no selected-friend concept here).
                    activeSheet = .message(PendingMessage(
                        recipients: [],
                        // The plain-text body carries a universal Apple Maps link
                        // so anyone in the chat — including people without Tween —
                        // can tap for directions (the rich bubble is app-only).
                        body: Self.spotBody(prefix: "Let's meet at", name: selection.name, coordinate: coord),
                        message: message,
                        onSent: {
                            noteOutgoingRevision(revision)
                            if let key = ConversationMeetupStore.lastActiveConversationKey {
                                ConversationMeetupStore.saveProposed(state, key: key)
                            }
                            pendingProposal = state
                            if messageType == .counter {
                                LocationCache.clearAgreedMeetup()
                                agreedMeetup = nil
                            }
                            PingLog.logGenericInvite()
                            lastGenericInviteAt = PingLog.lastGenericInviteAt
                            showOwnProposalOnMap(state)
                        },
                        onCancelled: {
                            // Cancel rollback: the staged hand-off must die with
                            // the send, or the extension force-expands over a
                            // proposal the user abandoned (W7).
                            OutgoingDraftStore.clear()
                            showToast("Not sent — your proposal stayed here")
                        }))
                }
            } else {
                let who = UserProfile.displayName ?? "I"
                let body = """
                \(who) picked \(selection.name) on Tween.
                Open this in Tween to share your ping:
                \(appURL.absoluteString)
                """
                UIPasteboard.general.string = body
                showToast("Message copied — paste it into your chat")
            }
        }
    }

    /// The coordinate safe to embed in an outgoing payload as "where I am
    /// now": the in-memory fix if we know it's fresh, else the cache's own
    /// fresh coordinate. Nil when everything we have is stale/absent — the
    /// caller must then request a fresh fix rather than shipping an old one.
    /// This is the single funnel that stops stale-coordinate laundering on
    /// the host side (audit W4).
    var freshSelfCoordinateForSend: CLLocationCoordinate2D? {
        if let saved = savedCoordinate, let at = savedCoordinateAt,
           Date().timeIntervalSince(at) <= LocationCache.freshnessWindow {
            return saved
        }
        return LocationCache.freshSelfCoordinate()
    }

    @discardableResult
    func autoJoinForOutgoingMessage() -> Bool {
        // Only join with a coordinate we KNOW is current. This used to reuse
        // a cached coord of ANY age and re-save it isActive:true with a
        // now-timestamp — laundering a stale location into the outgoing
        // bubble and defeating the 5-min freshness window the fairness
        // ranking depends on (audit W4, host half). No fresh fix → return
        // false; callers park the action + requestOnce(), then resume once a
        // current coordinate lands (their existing no-coordinate path).
        guard let coordinate = freshSelfCoordinateForSend else { return false }
        withAnimation(Tokens.Motion.spring) {
            savedCoordinate = coordinate
            savedCoordinateAt = Date()
            isUserIn = true
        }
        // Preserve declared-location provenance on re-save — dropping it here
        // stripped isManual on the first proposal/agree, after which the poll
        // and a background GPS fix clobbered the "I'll be at…" pin (post-push
        // audit).
        LocationCache.save(coordinate, isActive: true, isManual: selfIsManual)
        saveLocalParticipant(coordinate)
        return true
    }

    func proposalParticipantsForCurrentContext() -> [Participant] {
        let myName = UserProfile.displayName ?? UserName.fallback
        let localContext = LocalParticipantContext(id: TweenIdentity.stableID, name: myName)
        var participants = scopedFirstRoster().filter { !$0.matches(localContext) }
        if let savedCoordinate {
            participants.append(Participant(id: TweenIdentity.stableID, name: myName, coordinate: savedCoordinate, needsRide: localNeedsRide))
        }
        return participants
    }

    /// Opens driving directions to the chosen spot in the user's preferred
    /// maps app (Settings → Apple/Google).
    func openDirections(to item: MKMapItem) {
        switch MapsPreference.current {
        case .apple:
            item.openInMaps(launchOptions: [
                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
            ])
        case .google:
            openGoogleMapsExternally(name: item.name ?? "Spot",
                                     coordinate: item.placemark.coordinate)
        }
    }

    func dismissTutorial() {
        OnboardingFlags.hasSeenOnboarding = true
        showTutorial = false
    }

}
